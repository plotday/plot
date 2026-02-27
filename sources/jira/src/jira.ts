import { Version3Client } from "jira.js";

import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
  NewContact,
} from "@plotday/twister";
import type {
  Project,
  ProjectSyncOptions,
  ProjectSource,
} from "@plotday/twister/common/projects";
import { Source } from "@plotday/twister/source";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

type SyncState = {
  startAt: number;
  batchNumber: number;
  issuesProcessed: number;
  initialSync: boolean;
};

/**
 * Jira project management source
 *
 * Implements the ProjectSource interface for syncing Jira projects and issues
 * with Plot threads.
 */
export class Jira extends Source<Jira> implements ProjectSource {
  static readonly PROVIDER = AuthProvider.Atlassian;
  static readonly SCOPES = ["read:jira-work", "write:jira-work", "read:jira-user"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: Jira.PROVIDER,
          scopes: Jira.SCOPES,
          linkTypes: [
            {
              type: "issue",
              label: "Issue",
              logo: "https://api.iconify.design/logos/jira.svg",
              statuses: [
                { status: "open", label: "Open" },
                { status: "done", label: "Done" },
              ],
            },
          ],
          getChannels: this.getChannels,
          onChannelEnabled: this.onChannelEnabled,
          onChannelDisabled: this.onChannelDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://*.atlassian.net/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Create Jira API client using channel-based auth
   */
  private async getClient(projectId: string): Promise<Version3Client> {
    const token = await this.tools.integrations.get(Jira.PROVIDER, projectId);
    if (!token) {
      throw new Error("No Jira authentication token available");
    }
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
   * Returns available Jira projects as channel resources.
   */
  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const cloudId = token.provider?.cloud_id;
    if (!cloudId) {
      throw new Error("No Jira cloud ID in authorization");
    }
    const client = new Version3Client({
      host: `https://api.atlassian.com/ex/jira/${cloudId}`,
      authentication: { oauth2: { accessToken: token.token } },
    });
    const projects = await client.projects.searchProjects({ maxResults: 100 });
    return (projects.values || []).map((p) => ({
      id: p.id,
      title: p.name,
    }));
  }

  /**
   * Called when a channel is enabled for syncing.
   * Sets up webhook and auto-starts sync.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup webhook and queue first batch
    await this.setupJiraWebhook(channel.id);
    await this.startBatchSync(channel.id);
  }

  /**
   * Called when a channel is disabled.
   * Stops sync and archives all threads from this channel.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  /**
   * Get list of Jira projects
   */
  async getProjects(projectId: string): Promise<Project[]> {
    const client = await this.getClient(projectId);

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
  async startSync(
    options: {
      projectId: string;
    } & ProjectSyncOptions
  ): Promise<void> {
    const { projectId, timeMin } = options;

    // Setup webhook for real-time updates
    await this.setupJiraWebhook(projectId);

    // Start initial batch sync
    await this.startBatchSync(projectId, { timeMin });
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
    projectId: string
  ): Promise<void> {
    try {
      // Create webhook URL - this can be used for manual webhook configuration
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        projectId
      );

      // Store webhook URL for reference
      await this.set(`webhook_url_${projectId}`, webhookUrl);
    } catch (error) {
      console.error("Failed to create webhook URL:", error);
    }
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
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
      projectId,
      options
    );

    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of issues
   */
  private async syncBatch(
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${projectId}`);
    if (!state) {
      throw new Error(`Sync state not found for project ${projectId}`);
    }

    const client = await this.getClient(projectId);

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
      const linkWithNotes = await this.convertIssueToLink(
        issue,
        projectId
      );
      // Set unread based on sync type (false for initial sync to avoid notification overload)
      linkWithNotes.unread = !state.initialSync;
      // Inject sync metadata for filtering on disable
      linkWithNotes.channelId = projectId;
      linkWithNotes.meta = { ...linkWithNotes.meta, syncProvider: "atlassian", syncableId: projectId };
      await this.tools.integrations.saveLink(linkWithNotes);
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
   * Get the cloud ID using channel-based auth
   */
  private async getCloudId(projectId: string): Promise<string> {
    const token = await this.tools.integrations.get(Jira.PROVIDER, projectId);
    if (!token) throw new Error("No Jira token available");
    const cloudId = token.provider?.cloud_id;
    if (!cloudId) throw new Error("Jira cloud ID not found");
    return cloudId;
  }

  /**
   * Convert a Jira issue to a Plot Link
   */
  private async convertIssueToLink(
    issue: any,
    projectId: string
  ): Promise<NewLinkWithNotes> {
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
    try {
      cloudId = await this.getCloudId(projectId);
      issueUrl = `https://api.atlassian.com/ex/jira/${cloudId}/browse/${issue.key}`;
    } catch (error) {
      console.error("Failed to get cloud ID for issue URL:", error);
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

    // Build thread-level actions
    const threadActions: Action[] = [];
    if (issueUrl) {
      threadActions.push({
        type: ActionType.external,
        title: `Open in Jira`,
        url: issueUrl,
      });
    }

    // Create initial note with description (actions moved to thread level)
    notes.push({
      key: "description",
      content: description,
      created: fields.created ? new Date(fields.created) : undefined,
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
      type: "issue",
      title: fields.summary || issue.key,
      created: fields.created ? new Date(fields.created) : undefined,
      meta: {
        issueKey: issue.key,
        projectId,
      },
      author: authorContact,
      assignee: assigneeContact ?? null, // Explicitly set to null for unassigned issues
      status: fields.resolutiondate ? "done" : "open",
      actions: threadActions.length > 0 ? threadActions : undefined,
      sourceUrl: issueUrl ?? null,
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
   * Update issue with new values from the app
   */
  async updateIssue(link: import("@plotday/twister").Link): Promise<void> {
    const issueKey = link.meta?.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in link meta");
    }
    const projectId = link.meta?.projectId as string;

    const client = await this.getClient(projectId);

    // Handle field updates (title, assignee)
    const updateFields: any = {};

    if (link.title) {
      updateFields.summary = link.title;
    }

    updateFields.assignee = link.assignee
      ? { id: link.assignee.id }
      : null;

    if (Object.keys(updateFields).length > 0) {
      await client.issues.editIssue({
        issueIdOrKey: issueKey,
        fields: updateFields,
      });
    }

    // Handle workflow state transitions based on link status and assignee
    const transitions = await client.issues.getTransitions({
      issueIdOrKey: issueKey,
    });

    let targetTransition;

    const isDone = link.status === "done" || link.status === "closed" || link.status === "completed" || link.status === "resolved";
    if (isDone) {
      targetTransition = transitions.transitions?.find(
        (tr) =>
          tr.name?.toLowerCase() === "done" ||
          tr.name?.toLowerCase() === "close" ||
          tr.name?.toLowerCase() === "resolve" ||
          tr.to?.name?.toLowerCase() === "done" ||
          tr.to?.name?.toLowerCase() === "closed" ||
          tr.to?.name?.toLowerCase() === "resolved"
      );
    } else if (link.assignee) {
      targetTransition = transitions.transitions?.find(
        (tr) =>
          tr.name?.toLowerCase() === "start progress" ||
          tr.name?.toLowerCase() === "in progress" ||
          tr.to?.name?.toLowerCase() === "in progress"
      );
    } else {
      targetTransition = transitions.transitions?.find(
        (tr) =>
          tr.name?.toLowerCase() === "reopen" ||
          tr.name?.toLowerCase() === "to do" ||
          tr.name?.toLowerCase() === "open" ||
          tr.to?.name?.toLowerCase() === "to do" ||
          tr.to?.name?.toLowerCase() === "open"
      );
    }

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
   * @param meta - Thread metadata containing issueKey and projectId
   * @param body - Comment text (converted to ADF format)
   * @param noteId - Optional Plot note ID for dedup
   */
  async addIssueComment(
    meta: import("@plotday/twister").ThreadMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void> {
    const issueKey = meta.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in thread meta");
    }
    const projectId = meta.projectId as string;
    const client = await this.getClient(projectId);

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
    projectId: string
  ): Promise<void> {
    const payload = request.body as any;

    // Split handling by webhook event type for efficiency
    if (payload.webhookEvent?.startsWith("jira:issue_")) {
      await this.handleIssueWebhook(payload, projectId);
    } else if (payload.webhookEvent?.startsWith("comment_")) {
      await this.handleCommentWebhook(payload, projectId);
    } else {
      console.log("Ignoring webhook event:", payload.webhookEvent);
    }
  }

  /**
   * Handle issue webhook events - only updates issue metadata, not comments
   */
  private async handleIssueWebhook(
    payload: any,
    projectId: string
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
      cloudId = await this.getCloudId(projectId);
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

    // Create partial link update (empty notes = doesn't touch existing notes)
    const link: NewLinkWithNotes = {
      ...(source ? { source } : {}),
      type: "issue",
      title: fields.summary || issue.key,
      created: fields.created ? new Date(fields.created) : undefined,
      meta: {
        issueKey: issue.key,
        projectId,
      },
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: fields.resolutiondate ? "done" : "open",
      preview: description || null,
      notes: [],
    };

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Handle comment webhook events - only updates the specific comment
   */
  private async handleCommentWebhook(
    payload: any,
    projectId: string
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
      cloudId = await this.getCloudId(projectId);
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

    // Create link update with single comment note
    const link: NewLinkWithNotes = {
      ...(source ? { source } : {}),
      type: "issue",
      title: issue.key, // Placeholder; upsert by source will preserve existing title
      notes: [
        {
          key: `comment-${comment.id}`,
          // If this comment originated from Plot, identify by note ID so we update the existing note
          // rather than creating a duplicate
          ...(plotNoteId ? { id: plotNoteId } : {}),
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

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Stop syncing a Jira project
   */
  async stopSync(projectId: string): Promise<void> {
    // Cleanup webhook URL
    await this.clear(`webhook_url_${projectId}`);
    await this.clear(`webhook_id_${projectId}`);

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
