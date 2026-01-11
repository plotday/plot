import { Version3Client } from "jira.js";

import {
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  ActivityUpdate,
  type NewActivityWithNotes,
  type NewNote,
  Uuid,
} from "@plotday/twister";
import type { Actor, ActorId, NewContact } from "@plotday/twister/plot";
import type {
  Project,
  ProjectAuth,
  ProjectSyncOptions,
  ProjectTool,
} from "@plotday/twister/common/projects";
import { Tool, type ToolBuilder } from "@plotday/twister/tool";
import { type Callback, Callbacks } from "@plotday/twister/tools/callbacks";
import {
  AuthLevel,
  AuthProvider,
  type Authorization,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { ContactAccess, Plot } from "@plotday/twister/tools/plot";
import { Tasks } from "@plotday/twister/tools/tasks";

type SyncState = {
  startAt: number;
  batchNumber: number;
  issuesProcessed: number;
  initialSync: boolean;
};

/**
 * Jira project management tool
 *
 * Implements the ProjectTool interface for syncing Jira projects and issues
 * with Plot activities.
 */
export class Jira extends Tool<Jira> implements ProjectTool {
  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://*.atlassian.net/*"] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      plot: build(Plot, { contact: { access: ContactAccess.Write } }),
    };
  }

  /**
   * Create Jira API client with auth token
   */
  private async getClient(authToken: string): Promise<Version3Client> {
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.tools.integrations.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    // Get the cloud ID from provider metadata
    const cloudId = token.provider?.cloud_id;
    if (!cloudId) {
      throw new Error("Jira cloud ID not found in authorization");
    }

    return new Version3Client({
      host: `https://api.atlassian.com/ex/jira/${cloudId}`,
      authentication: {
        oauth2: {
          accessToken: token.token,
        },
      },
    });
  }

  /**
   * Request Jira OAuth authorization
   */
  async requestAuth<
    TCallback extends (auth: ProjectAuth, ...args: any[]) => any
  >(
    callback: TCallback,
    ...extraArgs: TCallback extends (auth: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<ActivityLink> {
    const jiraScopes = ["read:jira-work", "write:jira-work", "read:jira-user"];

    // Generate opaque token for authorization
    const authToken = crypto.randomUUID();

    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Atlassian,
        level: AuthLevel.User,
        scopes: jiraScopes,
      },
      this.onAuthSuccess,
      authToken,
      callbackToken
    );
  }

  /**
   * Handle successful OAuth authorization
   */
  private async onAuthSuccess(
    authorization: Authorization,
    authToken: string,
    callbackToken: Callback
  ): Promise<void> {
    // Store authorization for later use
    await this.set(`authorization:${authToken}`, authorization);

    // Execute the callback with the auth token
    await this.run(callbackToken, { authToken });
  }

  /**
   * Get list of Jira projects
   */
  async getProjects(authToken: string): Promise<Project[]> {
    const client = await this.getClient(authToken);

    // Get all projects the user has access to
    const projects = await client.projects.searchProjects({
      maxResults: 100,
    });

    return (projects.values || []).map((project) => ({
      id: project.id,
      name: project.name,
      description: project.description || null,
      key: project.key,
    }));
  }

  /**
   * Start syncing issues from a Jira project
   */
  async startSync<
    TCallback extends (issue: NewActivityWithNotes, ...args: any[]) => any
  >(
    options: {
      authToken: string;
      projectId: string;
    } & ProjectSyncOptions,
    callback: TCallback,
    ...extraArgs: TCallback extends (issue: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<void> {
    const { authToken, projectId, timeMin } = options;

    // Setup webhook for real-time updates
    await this.setupJiraWebhook(authToken, projectId);

    // Store callback for webhook processing
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`callback_${projectId}`, callbackToken);

    // Start initial batch sync
    await this.startBatchSync(authToken, projectId, { timeMin });
  }

  /**
   * Setup Jira webhook for real-time updates
   * Note: Webhook API varies by Jira version, so we skip for now
   */
  private async setupJiraWebhook(
    authToken: string,
    projectId: string
  ): Promise<void> {
    // TODO: Implement Jira webhooks once we confirm the correct API
    // The jira.js library webhook API may vary by Jira version
    console.log(`Jira webhooks not yet implemented for project ${projectId}`);
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
    authToken: string,
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    // Initialize sync state
    await this.set(`sync_state_${projectId}`, {
      startAt: 0,
      batchNumber: 1,
      issuesProcessed: 0,
      initialSync: true,
    });

    // Queue first batch
    const batchCallback = await this.callback(
      this.syncBatch,
      authToken,
      projectId,
      options
    );

    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of issues
   */
  private async syncBatch(
    authToken: string,
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${projectId}`);
    if (!state) {
      throw new Error(`Sync state not found for project ${projectId}`);
    }

    // Retrieve callback token from storage
    const callbackToken = await this.get<Callback>(`callback_${projectId}`);
    if (!callbackToken) {
      throw new Error(`Callback token not found for project ${projectId}`);
    }

    const client = await this.getClient(authToken);

    // Build JQL query
    let jql = `project = ${projectId}`;
    if (options?.timeMin) {
      const timeMinStr = options.timeMin.toISOString().split("T")[0];
      jql += ` AND created >= "${timeMinStr}"`;
    }
    jql += ` ORDER BY created ASC`;

    // Fetch batch of issues (50 at a time)
    const batchSize = 50;
    const searchResult = await client.issueSearch.searchForIssuesUsingJql({
      jql,
      startAt: state.startAt,
      maxResults: batchSize,
      fields: [
        "summary",
        "description",
        "status",
        "assignee",
        "reporter",
        "creator",
        "comment",
        "created",
        "updated",
      ],
    });

    // Process each issue
    for (const issue of searchResult.issues || []) {
      const activityWithNotes = await this.convertIssueToActivity(
        issue,
        projectId,
        authToken
      );
      // Set unread based on sync type (false for initial sync to avoid notification overload)
      activityWithNotes.unread = !state.initialSync;
      // Execute the callback using the callback token
      await this.tools.callbacks.run(callbackToken, activityWithNotes);
    }

    // Check if more pages
    const totalIssues = searchResult.total || 0;
    const nextStartAt = state.startAt + batchSize;

    if (nextStartAt < totalIssues) {
      await this.set(`sync_state_${projectId}`, {
        startAt: nextStartAt,
        batchNumber: state.batchNumber + 1,
        issuesProcessed:
          state.issuesProcessed + (searchResult.issues?.length || 0),
        initialSync: state.initialSync,
      });

      // Queue next batch
      const nextBatch = await this.callback(
        this.syncBatch,
        authToken,
        projectId,
        options
      );
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Initial sync is complete - cleanup sync state
      await this.clear(`sync_state_${projectId}`);
    }
  }

  /**
   * Get the cloud ID from stored authorization
   */
  private async getCloudId(authToken: string): Promise<string> {
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.tools.integrations.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    const cloudId = token.provider?.cloud_id;
    if (!cloudId) {
      throw new Error("Jira cloud ID not found in authorization");
    }

    return cloudId;
  }

  /**
   * Convert a Jira issue to a Plot Activity
   */
  private async convertIssueToActivity(
    issue: any,
    projectId: string,
    authToken?: string
  ): Promise<NewActivityWithNotes> {
    const fields = issue.fields || {};
    const status = fields.status?.name;
    const comments = fields.comment?.comments || [];
    const reporter = fields.reporter || fields.creator;
    const assignee = fields.assignee;

    // Prepare author and assignee contacts - will be passed directly as NewContact
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (reporter?.emailAddress) {
      authorContact = {
        email: reporter.emailAddress,
        name: reporter.displayName,
        avatar: reporter.avatarUrls?.["48x48"],
      };
    }
    if (assignee?.emailAddress) {
      assigneeContact = {
        email: assignee.emailAddress,
        name: assignee.displayName,
        avatar: assignee.avatarUrls?.["48x48"],
      };
    }

    // Get cloud ID for constructing the issue URL
    let issueUrl: string | undefined;
    if (authToken) {
      try {
        const cloudId = await this.getCloudId(authToken);
        issueUrl = `https://api.atlassian.com/ex/jira/${cloudId}/browse/${issue.key}`;
      } catch (error) {
        console.error("Failed to get cloud ID for issue URL:", error);
      }
    }

    // Build notes array: always create initial note with description and link
    const notes: NewNote[] = [];

    // Extract description (if any)
    let description: string | null = null;
    if (fields.description) {
      // Jira uses Atlassian Document Format (ADF), need to convert to plain text
      description =
        typeof fields.description === "string"
          ? fields.description
          : this.extractTextFromADF(fields.description);
    }

    // Canonical URL for this issue (required for upsert)
    const canonicalUrl = issueUrl || `jira:issue:${projectId}:${issue.key}`;

    // Create initial note with description and link to Jira issue
    const links: ActivityLink[] = [];
    if (issueUrl) {
      links.push({
        type: ActivityLinkType.external,
        title: `Open in Jira`,
        url: issueUrl,
      });
    }

    notes.push({
      activity: { source: canonicalUrl },
      key: "description",
      content: description,
      created: fields.created ? new Date(fields.created) : undefined,
      links: links.length > 0 ? links : null,
    });

    // Add comments as additional notes (with unique IDs, not upserted)
    for (const comment of comments) {
      const commentText =
        typeof comment.body === "string"
          ? comment.body
          : this.extractTextFromADF(comment.body);
      notes.push({
        id: Uuid.Generate(),
        activity: { source: canonicalUrl },
        content: commentText,
        created: comment.created ? new Date(comment.created) : undefined,
      });
    }

    return {
      source: canonicalUrl,
      type: ActivityType.Action,
      title: fields.summary || issue.key,
      created: fields.created ? new Date(fields.created) : undefined,
      meta: {
        issueKey: issue.key,
        projectId,
      },
      author: authorContact,
      assignee: assigneeContact ?? null, // Explicitly set to null for unassigned issues
      done: fields.resolutiondate ? new Date(fields.resolutiondate) : null,
      notes,
    };
  }

  /**
   * Extract plain text from Atlassian Document Format (ADF)
   */
  private extractTextFromADF(adf: any): string {
    if (!adf || typeof adf !== "object") {
      return "";
    }

    let text = "";

    const traverse = (node: any) => {
      if (node.type === "text") {
        text += node.text || "";
      }

      if (node.content && Array.isArray(node.content)) {
        for (const child of node.content) {
          traverse(child);
        }
        // Add newline after paragraphs
        if (node.type === "paragraph") {
          text += "\n";
        }
      }
    };

    traverse(adf);
    return text.trim();
  }

  /**
   * Update issue with new values
   *
   * @param authToken - Authorization token
   * @param update - ActivityUpdate with changed fields
   */
  async updateIssue(authToken: string, update: ActivityUpdate): Promise<void> {
    // Extract Jira issue key from meta
    const source = update.meta?.source as string | undefined;
    const issueKey = source?.split(":").pop();
    if (!issueKey) {
      throw new Error("Invalid source format for Jira issue");
    }

    const client = await this.getClient(authToken);

    // Handle field updates (title, assignee)
    const updateFields: any = {};

    if (update.title !== undefined) {
      updateFields.summary = update.title;
    }

    if (update.assignee !== undefined) {
      updateFields.assignee = update.assignee
        ? { id: update.assignee.id }
        : null;
    }

    // Apply field updates if any
    if (Object.keys(updateFields).length > 0) {
      await client.issues.editIssue({
        issueIdOrKey: issueKey,
        fields: updateFields,
      });
    }

    // Handle workflow state transitions based on start + done combination
    if (update.start !== undefined || update.done !== undefined) {
      // Get available transitions for this issue
      const transitions = await client.issues.getTransitions({
        issueIdOrKey: issueKey,
      });

      let targetTransition;

      // Determine target state based on combination
      if (update.done !== undefined && update.done !== null) {
        // Completed - look for "Done", "Close", or "Resolve" transition
        targetTransition = transitions.transitions?.find(
          (t) =>
            t.name?.toLowerCase() === "done" ||
            t.name?.toLowerCase() === "close" ||
            t.name?.toLowerCase() === "resolve" ||
            t.to?.name?.toLowerCase() === "done" ||
            t.to?.name?.toLowerCase() === "closed" ||
            t.to?.name?.toLowerCase() === "resolved"
        );
      } else if (update.start !== undefined && update.start !== null) {
        // In Progress - look for "Start Progress" or "In Progress" transition
        targetTransition = transitions.transitions?.find(
          (t) =>
            t.name?.toLowerCase() === "start progress" ||
            t.name?.toLowerCase() === "in progress" ||
            t.to?.name?.toLowerCase() === "in progress"
        );
      } else if (
        (update.start !== undefined && update.start === null) ||
        (update.done !== undefined && update.done === null)
      ) {
        // Backlog/Todo - look for "To Do", "Open", or "Reopen" transition
        targetTransition = transitions.transitions?.find(
          (t) =>
            t.name?.toLowerCase() === "reopen" ||
            t.name?.toLowerCase() === "to do" ||
            t.name?.toLowerCase() === "open" ||
            t.to?.name?.toLowerCase() === "to do" ||
            t.to?.name?.toLowerCase() === "open"
        );
      }

      // Execute transition if found
      if (targetTransition) {
        await client.issues.doTransition({
          issueIdOrKey: issueKey,
          transition: {
            id: targetTransition.id!,
          },
        });
      }
    }
  }

  /**
   * Add a comment to a Jira issue
   *
   * @param authToken - Authorization token
   * @param issueKey - Jira issue key (e.g., "PROJ-123")
   * @param body - Comment text (converted to ADF format)
   */
  async addIssueComment(
    authToken: string,
    issueKey: string,
    body: string
  ): Promise<void> {
    const client = await this.getClient(authToken);

    // Convert plain text to Atlassian Document Format (ADF)
    const adfBody = this.convertTextToADF(body);

    await client.issueComments.addComment({
      issueIdOrKey: issueKey,
      comment: adfBody,
    });
  }

  /**
   * Convert plain text to Atlassian Document Format (ADF)
   */
  private convertTextToADF(text: string): any {
    // Split text into paragraphs
    const paragraphs = text.split("\n\n").filter((p) => p.trim());

    return {
      version: 1,
      type: "doc",
      content: paragraphs.map((paragraph) => ({
        type: "paragraph",
        content: [
          {
            type: "text",
            text: paragraph.trim(),
          },
        ],
      })),
    };
  }

  /**
   * Handle incoming webhook events from Jira
   */
  private async onWebhook(
    request: WebhookRequest,
    projectId: string,
    authToken: string
  ): Promise<void> {
    const payload = request.body as any;

    // Jira webhook events have different structure
    if (
      payload.webhookEvent?.startsWith("jira:issue_") ||
      payload.webhookEvent?.startsWith("comment_")
    ) {
      const callbackToken = await this.get<Callback>(`callback_${projectId}`);
      if (!callbackToken) return;

      const issue = payload.issue;
      if (!issue) return;

      const activityWithNotes = await this.convertIssueToActivity(
        issue,
        projectId,
        authToken
      );

      // Webhooks are incremental updates - mark as unread
      activityWithNotes.unread = true;

      // Execute stored callback
      await this.tools.callbacks.run(callbackToken, activityWithNotes);
    }
  }

  /**
   * Stop syncing a Jira project
   */
  async stopSync(authToken: string, projectId: string): Promise<void> {
    // TODO: Remove webhook when webhook support is implemented
    await this.clear(`webhook_id_${projectId}`);

    // Cleanup callback
    const callbackToken = await this.get<Callback>(`callback_${projectId}`);
    if (callbackToken) {
      await this.deleteCallback(callbackToken);
      await this.clear(`callback_${projectId}`);
    }

    // Cleanup sync state
    await this.clear(`sync_state_${projectId}`);
  }
}

export default Jira;
