import { Version3Client } from "jira.js";

import {
  type ActivityLink,
  ActivityType,
  type NewActivityWithNotes,
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
    const jiraScopes = [
      "read:jira-work",
      "write:jira-work",
      "read:jira-user",
    ];

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
    authToken: string,
    projectId: string,
    callback: TCallback,
    options?: ProjectSyncOptions,
    ...extraArgs: TCallback extends (issue: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<void> {
    // Setup webhook for real-time updates
    await this.setupJiraWebhook(authToken, projectId);

    // Store callback for webhook processing
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`callback_${projectId}`, callbackToken);

    // Start initial batch sync
    await this.startBatchSync(authToken, projectId, options);
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
        "comment",
        "created",
        "updated",
      ],
    });

    // Process each issue
    for (const issue of searchResult.issues || []) {
      const activityWithNotes = await this.convertIssueToActivity(
        issue,
        projectId
      );
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
        issuesProcessed: state.issuesProcessed + (searchResult.issues?.length || 0),
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
      // Cleanup sync state
      await this.clear(`sync_state_${projectId}`);
    }
  }

  /**
   * Convert a Jira issue to a Plot Activity
   */
  private async convertIssueToActivity(
    issue: any,
    projectId: string
  ): Promise<NewActivityWithNotes> {
    const fields = issue.fields || {};
    const status = fields.status?.name;
    const comments = fields.comment?.comments || [];

    // Build notes array: description + comments
    const notes: Array<{ content: string }> = [];

    if (fields.description) {
      // Jira uses Atlassian Document Format (ADF), need to convert to plain text
      const description =
        typeof fields.description === "string"
          ? fields.description
          : this.extractTextFromADF(fields.description);
      notes.push({ content: description });
    }

    for (const comment of comments) {
      const commentText =
        typeof comment.body === "string"
          ? comment.body
          : this.extractTextFromADF(comment.body);
      notes.push({ content: commentText });
    }

    // Ensure at least one note exists
    if (notes.length === 0) {
      notes.push({ content: "" });
    }

    return {
      type: ActivityType.Action,
      title: fields.summary || issue.key,
      source: `jira:issue:${projectId}:${issue.key}`,
      doneAt:
        status === "Done" || status === "Closed" || status === "Resolved"
          ? new Date()
          : null,
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
        projectId
      );

      // Execute stored callback
      await this.run(callbackToken, activityWithNotes);
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
