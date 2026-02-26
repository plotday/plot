import { type Issue, LinearClient } from "@linear/sdk";
import type {
  EntityWebhookPayloadWithCommentData,
  EntityWebhookPayloadWithIssueData,
  LinearWebhookPayload,
} from "@linear/sdk/webhooks";
import { LinearWebhookClient } from "@linear/sdk/webhooks";

import {
  type Action,
  ActionType,
  type Link,
  ThreadMeta,
  ThreadType,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type {
  Project,
  ProjectSyncOptions,
  ProjectSource,
} from "@plotday/twister/common/projects";
import type { NewContact } from "@plotday/twister/plot";
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

// Cloudflare Workers provides Buffer global
declare const Buffer: {
  from(
    data: string | ArrayBuffer | Uint8Array,
    encoding?: string
  ): Uint8Array & { toString(encoding?: string): string };
};

type SyncState = {
  after: string | null;
  batchNumber: number;
  issuesProcessed: number;
  initialSync: boolean;
};

/**
 * Linear project management source
 *
 * Implements the ProjectSource interface for syncing Linear teams and issues
 * with Plot threads.
 */
export class Linear extends Source<Linear> implements ProjectSource {
  static readonly PROVIDER = AuthProvider.Linear;
  static readonly SCOPES = ["read", "write", "admin"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [
          {
            provider: Linear.PROVIDER,
            scopes: Linear.SCOPES,
            linkTypes: [
              {
                type: "issue",
                label: "Issue",
                logo: "https://api.iconify.design/logos/linear-icon.svg",
                statuses: [
                  { status: "open", label: "Open" },
                  { status: "done", label: "Done" },
                ],
              },
            ],
            onLinkUpdated: this.onLinkUpdated,
            getChannels: this.getChannels,
            onChannelEnabled: this.onChannelEnabled,
            onChannelDisabled: this.onChannelDisabled,
          },
        ],
      }),
      network: build(Network, { urls: ["https://api.linear.app/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Create Linear API client using channel-based auth
   */
  private async getClient(projectId: string): Promise<LinearClient> {
    const token = await this.tools.integrations.get(Linear.PROVIDER, projectId);
    if (!token) {
      throw new Error("No Linear authentication token available");
    }
    return new LinearClient({ accessToken: token.token });
  }

  /**
   * Returns available Linear teams as channel resources.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const client = new LinearClient({ accessToken: token.token });
    const teams = await client.teams();
    return teams.nodes.map((team) => ({
      id: team.id,
      title: team.name,
    }));
  }

  /**
   * Called when a channel resource is enabled for syncing.
   * Sets up webhook and auto-starts sync.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup webhook and begin batch sync
    await this.setupLinearWebhook(channel.id);
    await this.startBatchSync(channel.id);
  }

  /**
   * Called when a channel resource is disabled.
   * Stops sync and archives all threads from this channel.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  /**
   * Called when a link's status is changed from the Flutter app.
   * Maps the link status back to a Linear workflow state.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const issueId = link.meta?.linearId as string | undefined;
    if (!issueId) return;

    const projectId = link.meta?.projectId as string | undefined;
    if (!projectId) return;

    const client = await this.getClient(projectId);
    const issue = await client.issue(issueId);
    const team = await issue.team;
    if (!team) return;

    const states = await team.states();
    let targetState;

    if (link.status === "done") {
      targetState = states.nodes.find(
        (s) =>
          s.name === "Done" ||
          s.name === "Completed" ||
          s.type === "completed"
      );
    } else {
      // "open" or any non-done status -> reopen
      targetState = states.nodes.find(
        (s) =>
          s.name === "Todo" || s.name === "Backlog" || s.type === "unstarted"
      );
    }

    if (targetState) {
      await client.updateIssue(issueId, { stateId: targetState.id });
    }
  }

  /**
   * Get list of Linear teams (projects)
   */
  async getProjects(projectId: string): Promise<Project[]> {
    const client = await this.getClient(projectId);
    const teams = await client.teams();

    return teams.nodes.map((team) => ({
      id: team.id,
      name: team.name,
      description: team.description || null,
      key: team.key,
    }));
  }

  /**
   * Start syncing issues from a Linear team
   */
  async startSync(
    options: {
      projectId: string;
    } & ProjectSyncOptions
  ): Promise<void> {
    const { projectId, timeMin } = options;

    // Setup webhook for real-time updates
    await this.setupLinearWebhook(projectId);

    // Start initial batch sync
    await this.startBatchSync(projectId, { timeMin });
  }

  /**
   * Setup Linear webhook for real-time updates
   */
  private async setupLinearWebhook(projectId: string): Promise<void> {
    try {
      const client = await this.getClient(projectId);

      // Create webhook URL first (Linear requires valid URL at creation time)
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        projectId
      );

      // Skip webhook setup for localhost (development mode)
      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      // Create webhook in Linear with the actual URL
      const webhookPayload = await client.createWebhook({
        url: webhookUrl,
        teamId: projectId,
        resourceTypes: ["Issue", "Comment"],
      });

      // Extract and store webhook ID and secret
      const webhook = await webhookPayload.webhook;
      if (webhook?.id) {
        await this.set(`webhook_id_${projectId}`, webhook.id);
      }
      if (webhook?.secret) {
        await this.set(`webhook_secret_${projectId}`, webhook.secret);
      }
    } catch (error) {
      console.error(
        "Failed to set up Linear webhook - real-time updates will not work:",
        error
      );
    }
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    // Initialize sync state
    await this.set(`sync_state_${projectId}`, {
      after: null,
      batchNumber: 1,
      issuesProcessed: 0,
      initialSync: true,
    });

    // Queue first batch
    const batchCallback = await this.callback(
      this.syncBatch,
      projectId,
      options ?? null
    );

    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of issues
   */
  private async syncBatch(
    projectId: string,
    options?: ProjectSyncOptions | null
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${projectId}`);
    if (!state) {
      throw new Error(`Sync state not found for project ${projectId}`);
    }

    const client = await this.getClient(projectId);
    const team = await client.team(projectId);

    // Build filter
    const filter: any = {};
    if (options?.timeMin) {
      filter.created = { gte: options.timeMin };
    }

    // Fetch batch of issues (50 at a time)
    const issuesConnection = await team.issues({
      first: 50,
      after: state.after || undefined,
      filter: Object.keys(filter).length > 0 ? filter : undefined,
    });

    // Process each issue
    for (const issue of issuesConnection.nodes) {
      const link = await this.convertIssueToLink(
        issue,
        projectId,
        state.initialSync
      );

      if (link) {
        // Inject sync metadata for bulk operations (e.g. disable filtering)
        link.meta = {
          ...link.meta,
          syncProvider: "linear",
          syncableId: projectId,
        };
        await this.tools.integrations.saveLink(link);
      }
    }

    // Check if more pages
    if (issuesConnection.pageInfo.hasNextPage) {
      await this.set(`sync_state_${projectId}`, {
        after: issuesConnection.pageInfo.endCursor,
        batchNumber: state.batchNumber + 1,
        issuesProcessed: state.issuesProcessed + issuesConnection.nodes.length,
        initialSync: state.initialSync,
      });

      // Queue next batch
      const nextBatch = await this.callback(
        this.syncBatch,
        projectId,
        options ?? null
      );
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Initial sync is complete - cleanup sync state
      await this.clear(`sync_state_${projectId}`);
    }
  }

  /**
   * Convert a Linear issue to a NewLinkWithNotes
   */
  private async convertIssueToLink(
    issue: Issue,
    projectId: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    let creator, assignee, comments;

    try {
      creator = await issue.creator;
    } catch (error) {
      console.error(
        "Error fetching creator:",
        error instanceof Error ? error.message : String(error)
      );
      creator = null;
    }

    try {
      assignee = await issue.assignee;
    } catch (error) {
      console.error(
        "Error fetching assignee:",
        error instanceof Error ? error.message : String(error)
      );
      assignee = null;
    }

    try {
      comments = await issue.comments();
    } catch (error) {
      console.error(
        "Error fetching comments:",
        error instanceof Error ? error.message : String(error)
      );
      comments = { nodes: [] };
    }

    // Prepare author and assignee contacts - will be passed directly as NewContact
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (creator?.email) {
      authorContact = {
        email: creator.email,
        name: creator.name,
        avatar: creator.avatarUrl ?? undefined,
      };
    }
    if (assignee?.email) {
      assigneeContact = {
        email: assignee.email,
        name: assignee.name,
        avatar: assignee.avatarUrl ?? undefined,
      };
    }

    // Prepare description content
    const description = issue.description || "";
    const hasDescription = description.trim().length > 0;

    // Build thread-level actions
    const threadActions: Action[] = [];
    if (issue.url) {
      threadActions.push({
        type: ActionType.external,
        title: `Open in Linear`,
        url: issue.url,
      });
    }

    // Build notes array: description note + comment notes
    const notes: any[] = [];

    notes.push({
      key: "description",
      content: hasDescription ? description : null,
      created: issue.createdAt,
      author: authorContact,
    });

    // Add comments as notes (with unique IDs, not upserted)
    for (const comment of comments.nodes) {
      // Fetch comment author
      let commentAuthor: NewContact | undefined;
      try {
        const user = await comment.user;
        if (user?.email) {
          commentAuthor = {
            email: user.email,
            name: user.name,
            avatar: user.avatarUrl ?? undefined,
          };
        }
      } catch (error) {
        console.error(
          "Error fetching comment user:",
          error instanceof Error ? error.message : String(error)
        );
      }

      notes.push({
        key: `comment-${comment.id}`,
        content: comment.body,
        created: comment.createdAt,
        author: commentAuthor,
      });
    }

    const newLink: NewLinkWithNotes = {
      source: `linear:issue:${issue.id}`,
      type: "issue",
      title: issue.title,
      created: issue.createdAt,
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: issue.completedAt || issue.canceledAt ? "done" : "open",
      meta: {
        linearId: issue.id,
        projectId,
      },
      actions: threadActions.length > 0 ? threadActions : undefined,
      sourceUrl: issue.url ?? null,
      notes,
      preview: hasDescription ? description : null,
      ...(initialSync ? { unread: false } : {}), // false for initial sync, omit for incremental updates
      ...(initialSync ? { archived: false } : {}), // unarchive on initial sync only
    };

    return newLink;
  }

  /**
   * Update issue with new values
   *
   * @param thread - The updated thread
   */
  async updateIssue(
    thread: import("@plotday/twister").Thread
  ): Promise<void> {
    // Get the Linear issue ID from thread meta
    const issueId = thread.meta?.linearId as string | undefined;
    if (!issueId) {
      throw new Error("Linear issue ID not found in thread meta");
    }

    const projectId = thread.meta?.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Project ID not found in thread meta");
    }

    const client = await this.getClient(projectId);
    const issue = await client.issue(issueId);
    const updateFields: any = {};

    // Handle title
    if (thread.title !== null) {
      updateFields.title = thread.title;
    }

    // Handle order -> sortOrder
    if (thread.order !== undefined && thread.order !== null) {
      updateFields.sortOrder = thread.order;
    }

    // Handle assignee - map Plot actor to Linear user via email lookup
    if (!thread.assignee) {
      updateFields.assigneeId = null;
    } else {
      const email = thread.assignee.email;
      if (email) {
        // Check cache first
        let linearUserId = await this.get<string>(`linear_user:${email}`);

        if (!linearUserId) {
          // Query Linear for user by email
          const users = await client.users({
            filter: { email: { eq: email } },
          });
          const linearUser = users.nodes[0];

          if (linearUser) {
            linearUserId = linearUser.id;
            await this.set(`linear_user:${email}`, linearUserId);
          }
        }

        if (linearUserId) {
          updateFields.assigneeId = linearUserId;
        } else {
          console.warn(
            `No Linear user found for email ${email}, skipping assignee update`
          );
        }
      } else {
        console.warn(
          `No email found for assignee actor, skipping assignee update`
        );
      }
    }

    // Handle state based on assignee + done combination
    const team = await issue.team;
    if (team) {
      const states = await team.states();
      let targetState;

      // Determine target state based on combination
      if (thread.type === ThreadType.Action && thread.done !== null) {
        // Completed
        targetState = states.nodes.find(
          (s) =>
            s.name === "Done" ||
            s.name === "Completed" ||
            s.type === "completed"
        );
      } else if (thread.assignee !== null) {
        // In Progress (has assignee, not done)
        targetState = states.nodes.find(
          (s) => s.name === "In Progress" || s.type === "started"
        );
      } else {
        // Backlog/Todo (no assignee, not done)
        targetState = states.nodes.find(
          (s) =>
            s.name === "Todo" || s.name === "Backlog" || s.type === "unstarted"
        );
      }

      if (targetState) {
        updateFields.stateId = targetState.id;
      }
    }

    // Apply updates if any fields changed
    if (Object.keys(updateFields).length > 0) {
      await client.updateIssue(issueId, updateFields);
    }
  }

  /**
   * Add a comment to a Linear issue
   *
   * @param meta - Thread metadata containing linearId and projectId
   * @param body - Comment text (markdown supported)
   */
  async addIssueComment(
    meta: ThreadMeta,
    body: string
  ): Promise<string | void> {
    const issueId = meta.linearId as string | undefined;
    if (!issueId) {
      throw new Error("Linear issue ID not found in thread meta");
    }

    const projectId = meta.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Project ID not found in thread meta");
    }

    const client = await this.getClient(projectId);

    const payload = await client.createComment({
      issueId,
      body,
    });

    const comment = await payload.comment;
    if (comment?.id) {
      return `comment-${comment.id}`;
    }
  }

  /**
   * Handle incoming webhook events from Linear
   */
  private async onWebhook(
    request: WebhookRequest,
    projectId: string
  ): Promise<void> {
    // Retrieve secret
    const secret = await this.get<string>(`webhook_secret_${projectId}`);

    if (!secret) {
      console.warn("Linear webhook secret not found, skipping verification");
      return;
    }

    if (!request.rawBody) {
      console.warn("Linear webhook missing raw body");
      return;
    }

    // Verify and parse using SDK
    let payload: LinearWebhookPayload;
    try {
      const client = new LinearWebhookClient(secret);
      const rawBodyBuffer = Buffer.from(request.rawBody, "utf8");
      const signature = request.headers["linear-signature"];

      if (!signature) {
        console.warn("Linear webhook missing signature header");
        return;
      }

      // Verify + parse in one call
      payload = client.parseData(
        rawBodyBuffer,
        signature,
        request.headers["linear-timestamp"]
      );
    } catch (error) {
      console.warn("Linear webhook signature verification failed:", error);
      return;
    }

    // Route by webhook type
    if (payload.type === "Issue") {
      await this.handleIssueWebhook(
        payload as EntityWebhookPayloadWithIssueData,
        projectId
      );
    } else if (payload.type === "Comment") {
      await this.handleCommentWebhook(
        payload as EntityWebhookPayloadWithCommentData,
        projectId
      );
    }
  }

  /**
   * Handle Issue webhook events - only updates issue metadata, not comments
   */
  private async handleIssueWebhook(
    payload: EntityWebhookPayloadWithIssueData,
    projectId: string
  ): Promise<void> {
    const issue = payload.data;
    const issueId = issue.id;

    if (!issueId) {
      console.error("Failed to extract issue ID from Issue webhook:", {
        dataKeys: Object.keys(payload.data || {}),
      });
      return;
    }

    // Use issue data directly from webhook payload
    const creator = issue.creator || null;
    const assignee = issue.assignee || null;

    // Build thread update with only issue fields (no notes)
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (creator?.email) {
      authorContact = {
        email: creator.email,
        name: creator.name,
        avatar: creator.avatarUrl ?? undefined,
      };
    }
    if (assignee?.email) {
      assigneeContact = {
        email: assignee.email,
        name: assignee.name,
        avatar: assignee.avatarUrl ?? undefined,
      };
    }

    // Create partial link update (empty notes = doesn't touch existing notes)
    // Note: webhook payload dates are JSON strings, must convert to Date
    const newLink: NewLinkWithNotes = {
      source: `linear:issue:${issue.id}`,
      type: "issue",
      title: issue.title,
      created: new Date(issue.createdAt),
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: issue.completedAt || issue.canceledAt ? "done" : "open",
      meta: {
        linearId: issue.id,
        projectId,
        syncProvider: "linear",
        syncableId: projectId,
      },
      preview: issue.description || null,
      notes: [],
    };

    await this.tools.integrations.saveLink(newLink);
  }

  /**
   * Handle Comment webhook events - only updates the specific comment
   */
  private async handleCommentWebhook(
    payload: EntityWebhookPayloadWithCommentData,
    projectId: string
  ): Promise<void> {
    const comment = payload.data;
    const commentId = comment.id;
    const issueId = comment.issueId;

    if (!commentId || !issueId) {
      console.error(
        "Failed to extract comment/issue ID from Comment webhook:",
        {
          dataKeys: Object.keys(payload.data || {}),
        }
      );
      return;
    }

    // Extract comment author from webhook payload
    let commentAuthor: NewContact | undefined;
    if (comment.user?.email) {
      commentAuthor = {
        email: comment.user.email,
        name: comment.user.name,
        avatar: comment.user.avatarUrl ?? undefined,
      };
    }

    // Create thread update with single comment note
    // Type is required by NewThread, but upsert will use existing thread's type
    const threadSource = `linear:issue:${issueId}`;
    const newLink: NewLinkWithNotes = {
      source: threadSource,
      type: "issue",
      title: issueId, // Placeholder; upsert by source will preserve existing title
      notes: [
        {
          key: `comment-${comment.id}`,
          content: comment.body,
          created: new Date(comment.createdAt),
          author: commentAuthor,
        } as any,
      ],
      meta: {
        linearId: issueId,
        projectId,
        syncProvider: "linear",
        syncableId: projectId,
      },
    };

    await this.tools.integrations.saveLink(newLink);
  }

  /**
   * Stop syncing a Linear team
   */
  async stopSync(projectId: string): Promise<void> {
    // Remove webhook
    const webhookId = await this.get<string>(`webhook_id_${projectId}`);
    if (webhookId) {
      try {
        const client = await this.getClient(projectId);
        await client.deleteWebhook(webhookId);
      } catch (error) {
        console.warn("Failed to delete Linear webhook:", error);
      }
      await this.clear(`webhook_id_${projectId}`);
    }

    // Cleanup webhook secret
    await this.clear(`webhook_secret_${projectId}`);

    // Cleanup sync state
    await this.clear(`sync_state_${projectId}`);
  }
}

export default Linear;
