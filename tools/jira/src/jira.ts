import { Version3Client } from "jira.js";

import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  type ActorId,
  type NewActivity,
  type NewActivityWithNotes,
  NewContact,
  Serializable,
} from "@plotday/twister";
import type {
  Project,
  ProjectAuth,
  ProjectSyncOptions,
  ProjectTool,
} from "@plotday/twister/common/projects";
import { Tool, type ToolBuilder } from "@plotday/twister/tool";
import { type Callback, Callbacks } from "@plotday/twister/tools/callbacks";
import {
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
    // Try new pattern first (authToken is an ActorId)
    let token = await this.tools.integrations.get(AuthProvider.Atlassian, authToken as ActorId);

    // Fall back to legacy authorization lookup
    if (!token) {
      const authorization = await this.get<Authorization>(
        `authorization:${authToken}`
      );
      if (!authorization) {
        throw new Error("Authorization no longer available");
      }

      token = await this.tools.integrations.get(authorization.provider, authorization.actor.id);
    }

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
    TArgs extends Serializable[],
    TCallback extends (auth: ProjectAuth, ...args: TArgs) => any
  >(callback: TCallback, ...extraArgs: TArgs): Promise<ActivityLink> {
    const jiraScopes = ["read:jira-work", "write:jira-work", "read:jira-user"];

    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Atlassian,
        scopes: jiraScopes,
      },
      this.onAuthSuccess,
      callbackToken
    );
  }

  /**
   * Handle successful OAuth authorization
   */
  private async onAuthSuccess(
    authorization: Authorization,
    callbackToken: Callback
  ): Promise<void> {
    // Execute the callback with the auth token (actor ID)
    await this.run(callbackToken, { authToken: authorization.actor.id as string });
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
    TArgs extends Serializable[],
    TCallback extends (issue: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      authToken: string;
      projectId: string;
    } & ProjectSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
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
   *
   * Note: Jira webhooks need to be configured manually in Jira's administration panel.
   * This method creates the webhook URL that should be used in Jira's webhook settings.
   *
   * To configure manually in Jira:
   * 1. Go to Settings > System > WebHooks
   * 2. Create a new webhook
   * 3. Use the webhook URL created by this method
   * 4. Select events: issue_created, issue_updated, issue_deleted, comment_created, comment_updated, comment_deleted
   * 5. Set JQL filter: project = {projectId}
   */
  private async setupJiraWebhook(
    authToken: string,
    projectId: string
  ): Promise<void> {
    try {
      // Create webhook URL - this can be used for manual webhook configuration
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        projectId,
        authToken
      );

      // Store webhook URL for reference
      await this.set(`webhook_url_${projectId}`, webhookUrl);

      // TODO: Implement programmatic webhook creation when Jira API access is available
      // The jira.js library doesn't expose webhook creation methods
      // Manual configuration is required for now
    } catch (error) {
      console.error("Failed to create webhook URL:", error);
    }
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
    authToken: string,
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    // Initialize sync state with options stored in state
    await this.set(`sync_state_${projectId}`, {
      startAt: 0,
      batchNumber: 1,
      issuesProcessed: 0,
      initialSync: true,
      timeMin: options?.timeMin?.toISOString() ?? null,
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
    // Try new pattern first (authToken is an ActorId)
    let token = await this.tools.integrations.get(AuthProvider.Atlassian, authToken as ActorId);

    // Fall back to legacy authorization lookup
    if (!token) {
      const authorization = await this.get<Authorization>(
        `authorization:${authToken}`
      );
      if (!authorization) {
        throw new Error("Authorization no longer available");
      }

      token = await this.tools.integrations.get(authorization.provider, authorization.actor.id);
    }

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
        ...atlassianSource(reporter.accountId),
      };
    }
    if (assignee?.emailAddress) {
      assigneeContact = {
        email: assignee.emailAddress,
        name: assignee.displayName,
        avatar: assignee.avatarUrls?.["48x48"],
        ...atlassianSource(assignee.accountId),
      };
    }

    // Get cloud ID for constructing stable source identifier and issue URL
    let cloudId: string | undefined;
    let issueUrl: string | undefined;
    if (authToken) {
      try {
        cloudId = await this.getCloudId(authToken);
        issueUrl = `https://api.atlassian.com/ex/jira/${cloudId}/browse/${issue.key}`;
      } catch (error) {
        console.error("Failed to get cloud ID for issue URL:", error);
      }
    }

    // Build notes array: always create initial note with description and link
    const notes: any[] = [];

    // Extract description (if any)
    let description: string | null = null;
    if (fields.description) {
      // Jira uses Atlassian Document Format (ADF), need to convert to plain text
      const extracted =
        typeof fields.description === "string"
          ? fields.description
          : this.extractTextFromADF(fields.description);
      if (extracted && extracted.trim().length > 0) {
        description = extracted;
      }
    }

    // Stable source identifier using immutable issue ID (not mutable issue.key)
    const source = cloudId && issue.id
      ? `jira:${cloudId}:issue:${issue.id}`
      : undefined;

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
      key: "description",
      content: description,
      created: fields.created ? new Date(fields.created) : undefined,
      links: links.length > 0 ? links : null,
      author: authorContact,
    });

    // Add comments as additional notes (with unique IDs, not upserted)
    for (const comment of comments) {
      // Extract comment author
      let commentAuthor: NewContact | undefined;
      const author = comment.author;
      if (author?.emailAddress) {
        commentAuthor = {
          email: author.emailAddress,
          name: author.displayName,
          avatar: author.avatarUrl,
          ...atlassianSource(author.accountId),
        };
      }

      const commentText =
        typeof comment.body === "string"
          ? comment.body
          : this.extractTextFromADF(comment.body);
      notes.push({
        key: `comment-${comment.id}`,
        content: commentText,
        created: comment.created ? new Date(comment.created) : undefined,
        author: commentAuthor,
      });
    }

    return {
      ...(source ? { source } : {}),
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
      preview: description || null,
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
   * @param activity - The updated activity
   */
  async updateIssue(authToken: string, activity: Activity): Promise<void> {
    // Extract Jira issue key from meta
    const issueKey = activity.meta?.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in activity meta");
    }

    const client = await this.getClient(authToken);

    // Handle field updates (title, assignee)
    const updateFields: any = {};

    if (activity.title !== null) {
      updateFields.summary = activity.title;
    }

    updateFields.assignee = activity.assignee
      ? { id: activity.assignee.id }
      : null;

    // Apply field updates if any
    if (Object.keys(updateFields).length > 0) {
      await client.issues.editIssue({
        issueIdOrKey: issueKey,
        fields: updateFields,
      });
    }

    // Handle workflow state transitions based on start + done combination
    // Get available transitions for this issue
    const transitions = await client.issues.getTransitions({
      issueIdOrKey: issueKey,
    });

    let targetTransition;

    // Determine target state based on combination
    if (activity.type === ActivityType.Action && activity.done !== null) {
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
    } else if (activity.start !== null) {
      // In Progress - look for "Start Progress" or "In Progress" transition
      targetTransition = transitions.transitions?.find(
        (t) =>
          t.name?.toLowerCase() === "start progress" ||
          t.name?.toLowerCase() === "in progress" ||
          t.to?.name?.toLowerCase() === "in progress"
      );
    } else {
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

  /**
   * Add a comment to a Jira issue
   *
   * @param authToken - Authorization token
   * @param meta - Activity metadata containing issueKey
   * @param body - Comment text (converted to ADF format)
   */
  async addIssueComment(
    authToken: string,
    meta: import("@plotday/twister").ActivityMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void> {
    const issueKey = meta.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in activity meta");
    }
    const client = await this.getClient(authToken);

    // Convert plain text to Atlassian Document Format (ADF)
    const adfBody = this.convertTextToADF(body);

    const result = await client.issueComments.addComment({
      issueIdOrKey: issueKey,
      comment: adfBody,
      properties: noteId ? [{ key: "plotNoteId", value: noteId }] : undefined,
    });

    if (result?.id) {
      return `comment-${result.id}`;
    }
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

    // Get callback token (needed by both handlers)
    const callbackToken = await this.get<Callback>(`callback_${projectId}`);
    if (!callbackToken) {
      console.warn("No callback token found for project:", projectId);
      return;
    }

    // Split handling by webhook event type for efficiency
    if (payload.webhookEvent?.startsWith("jira:issue_")) {
      await this.handleIssueWebhook(
        payload,
        projectId,
        authToken,
        callbackToken
      );
    } else if (payload.webhookEvent?.startsWith("comment_")) {
      await this.handleCommentWebhook(
        payload,
        projectId,
        authToken,
        callbackToken
      );
    } else {
      console.log("Ignoring webhook event:", payload.webhookEvent);
    }
  }

  /**
   * Handle issue webhook events - only updates issue metadata, not comments
   */
  private async handleIssueWebhook(
    payload: any,
    projectId: string,
    authToken: string,
    callbackToken: Callback
  ): Promise<void> {

    const issue = payload.issue;
    if (!issue) {
      console.error("No issue in webhook payload");
      return;
    }

    const fields = issue.fields || {};
    const reporter = fields.reporter || fields.creator;
    const assignee = fields.assignee;

    // Prepare author and assignee contacts
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (reporter?.emailAddress) {
      authorContact = {
        email: reporter.emailAddress,
        name: reporter.displayName,
        avatar: reporter.avatarUrls?.["48x48"],
        ...atlassianSource(reporter.accountId),
      };
    }
    if (assignee?.emailAddress) {
      assigneeContact = {
        email: assignee.emailAddress,
        name: assignee.displayName,
        avatar: assignee.avatarUrls?.["48x48"],
        ...atlassianSource(assignee.accountId),
      };
    }

    // Get cloud ID for constructing stable source identifier
    let cloudId: string | undefined;
    try {
      cloudId = await this.getCloudId(authToken);
    } catch (error) {
      console.error("Failed to get cloud ID for source identifier:", error);
    }

    // Stable source identifier using immutable issue ID (not mutable issue.key)
    const source = cloudId && issue.id
      ? `jira:${cloudId}:issue:${issue.id}`
      : undefined;

    // Extract description
    let description: string | null = null;
    if (fields.description) {
      const extracted =
        typeof fields.description === "string"
          ? fields.description
          : this.extractTextFromADF(fields.description);
      if (extracted && extracted.trim().length > 0) {
        description = extracted;
      }
    }

    // Create partial activity update (no notes = doesn't touch existing notes)
    const activity: NewActivity = {
      ...(source ? { source } : {}),
      type: ActivityType.Action,
      title: fields.summary || issue.key,
      created: fields.created ? new Date(fields.created) : undefined,
      meta: {
        issueKey: issue.key,
        projectId,
      },
      author: authorContact,
      assignee: assigneeContact ?? null,
      done: fields.resolutiondate ? new Date(fields.resolutiondate) : null,
      preview: description || null,
    };

    await this.tools.callbacks.run(callbackToken, activity);
  }

  /**
   * Handle comment webhook events - only updates the specific comment
   */
  private async handleCommentWebhook(
    payload: any,
    projectId: string,
    authToken: string,
    callbackToken: Callback
  ): Promise<void> {

    const comment = payload.comment;
    const issue = payload.issue;

    if (!comment || !issue) {
      console.error("Missing comment or issue in webhook payload");
      return;
    }

    // Get cloud ID for constructing stable source identifier
    let cloudId: string | undefined;
    try {
      cloudId = await this.getCloudId(authToken);
    } catch (error) {
      console.error("Failed to get cloud ID for source identifier:", error);
    }

    // Stable source identifier using immutable issue ID (not mutable issue.key)
    const source = cloudId && issue.id
      ? `jira:${cloudId}:issue:${issue.id}`
      : undefined;

    // Extract comment author
    let commentAuthor: NewContact | undefined;
    const author = comment.author;
    if (author?.emailAddress) {
      commentAuthor = {
        email: author.emailAddress,
        name: author.displayName,
        avatar: author.avatarUrls?.["48x48"],
        ...atlassianSource(author.accountId),
      };
    }

    // Extract comment text
    const commentText =
      typeof comment.body === "string"
        ? comment.body
        : this.extractTextFromADF(comment.body);

    // Check for Plot note ID in comment properties (set when comment was created from Plot)
    const plotNoteId = comment.properties?.find(
      (p: any) => p.key === "plotNoteId"
    )?.value;

    // Create activity update with single comment note
    const activity: NewActivityWithNotes = {
      ...(source ? { source } : {}),
      type: ActivityType.Action, // Required field (will match existing activity)
      notes: [
        {
          key: `comment-${comment.id}`,
          // If this comment originated from Plot, identify by note ID so we update the existing note
          // rather than creating a duplicate
          ...(plotNoteId ? { id: plotNoteId } : {}),
          activity: source ? { source } : undefined,
          content: commentText,
          created: comment.created ? new Date(comment.created) : undefined,
          author: commentAuthor,
        } as any,
      ],
      meta: {
        issueKey: issue.key,
        projectId,
      },
    };

    await this.tools.callbacks.run(callbackToken, activity);
  }

  /**
   * Stop syncing a Jira project
   */
  async stopSync(_authToken: string, projectId: string): Promise<void> {
    // Cleanup webhook URL
    await this.clear(`webhook_url_${projectId}`);
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

/**
 * Returns a `source` property for NewContact if the Atlassian accountId is valid.
 * Used for Atlassian personal data reporting compliance.
 */
function atlassianSource(accountId: string | undefined): Pick<NewContact, "source"> | {} {
  if (accountId && accountId !== "_unknown_") {
    return { source: { provider: AuthProvider.Atlassian, accountId } };
  }
  return {};
}

export default Jira;
