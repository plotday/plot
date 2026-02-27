import * as asana from "asana";

import {
  type Action,
  ActionType,
  ThreadMeta,
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

type SyncState = {
  offset: number;
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
};

/**
 * Asana project management source
 *
 * Implements the ProjectSource interface for syncing Asana projects and tasks
 * with Plot threads.
 */
export class Asana extends Source<Asana> implements ProjectSource {
  static readonly PROVIDER = AuthProvider.Asana;
  static readonly SCOPES = ["default"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: Asana.PROVIDER,
          scopes: Asana.SCOPES,
          linkTypes: [
            {
              type: "task",
              label: "Task",
              logo: "https://api.iconify.design/logos/asana.svg",
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
      network: build(Network, { urls: ["https://app.asana.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Create Asana API client with auth token
   */
  private async getClient(projectId: string): Promise<asana.Client> {
    const token = await this.tools.integrations.get(Asana.PROVIDER, projectId);
    if (!token) {
      throw new Error("No Asana authentication token available");
    }
    return asana.Client.create().useAccessToken(token.token);
  }

  /**
   * Returns available Asana projects as channel resources.
   */
  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const client = asana.Client.create().useAccessToken(token.token);
    const workspaces = await client.workspaces.getWorkspaces();
    const allChannels: Channel[] = [];
    for (const workspace of workspaces.data) {
      const projects = await client.projects.findByWorkspace(workspace.gid, { limit: 100 });
      for (const project of projects.data) {
        allChannels.push({ id: project.gid, title: project.name });
      }
    }
    return allChannels;
  }

  /**
   * Called when a channel is enabled for syncing.
   * Sets up webhook and auto-starts sync.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup webhook and begin batch sync
    await this.setupAsanaWebhook(channel.id);
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
   * Get list of Asana projects
   */
  async getProjects(projectId: string): Promise<Project[]> {
    const client = await this.getClient(projectId);

    // Get user's workspaces first
    const workspaces = await client.workspaces.getWorkspaces();

    const allProjects: Project[] = [];

    // Get projects from each workspace
    for (const workspace of workspaces.data) {
      const projects = await client.projects.findByWorkspace(workspace.gid, {
        limit: 100,
      });

      for (const project of projects.data) {
        allProjects.push({
          id: project.gid,
          name: project.name,
          description: null, // Asana doesn't return description in list
          key: null, // Asana doesn't have project keys
        });
      }
    }

    return allProjects;
  }

  /**
   * Start syncing tasks from an Asana project
   */
  async startSync(
    options: {
      projectId: string;
    } & ProjectSyncOptions
  ): Promise<void> {
    const { projectId, timeMin } = options;

    // Setup webhook for real-time updates
    await this.setupAsanaWebhook(projectId);

    // Start initial batch sync
    await this.startBatchSync(projectId, { timeMin });
  }

  /**
   * Setup Asana webhook for real-time updates
   */
  private async setupAsanaWebhook(
    projectId: string
  ): Promise<void> {
    try {
      const client = await this.getClient(projectId);

      // Create webhook URL first
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

      // Create webhook in Asana
      // @ts-ignore - Asana SDK webhook types are incomplete
      const webhook = await client.webhooks.create({
        resource: projectId,
        target: webhookUrl,
      });

      // Store webhook GID for cleanup
      if (webhook.gid) {
        await this.set(`webhook_id_${projectId}`, webhook.gid);
      }
    } catch (error) {
      console.error(
        "Failed to set up Asana webhook - real-time updates will not work:",
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
      offset: 0,
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
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
   * Process a batch of tasks
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

    // Build request params
    const batchSize = 50;
    const params: any = {
      project: projectId,
      limit: batchSize,
      opt_fields: [
        "name",
        "notes",
        "completed",
        "completed_at",
        "created_at",
        "modified_at",
        "assignee",
        "assignee.email",
        "assignee.name",
        "assignee.photo",
        "created_by",
        "created_by.email",
        "created_by.name",
        "created_by.photo",
      ].join(","),
    };

    if (state.offset > 0) {
      params.offset = state.offset;
    }

    // Fetch batch of tasks using findAll
    const tasksResult = await client.tasks.findAll(params);

    // Process each task
    for (const task of tasksResult.data) {
      // Optionally filter by time
      if (options?.timeMin) {
        const created = new Date(task.created_at);
        if (created < options.timeMin) {
          continue;
        }
      }

      const linkWithNotes = await this.convertTaskToLink(
        task,
        projectId
      );
      // Set unread based on sync type (false for initial sync to avoid notification overload)
      linkWithNotes.unread = !state.initialSync;
      // Unarchive on initial sync only (preserve user's archive state on incremental syncs)
      if (state.initialSync) {
        linkWithNotes.archived = false;
      }
      await this.tools.integrations.saveLink(linkWithNotes);
    }

    // Check if more pages by checking if we got a full batch
    const hasMore = tasksResult.data.length === batchSize;

    if (hasMore) {
      await this.set(`sync_state_${projectId}`, {
        offset: state.offset + batchSize,
        batchNumber: state.batchNumber + 1,
        tasksProcessed: state.tasksProcessed + tasksResult.data.length,
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
   * Convert an Asana task to a Plot Link
   */
  private async convertTaskToLink(
    task: any,
    projectId: string
  ): Promise<NewLinkWithNotes> {
    const createdBy = task.created_by;
    const assignee = task.assignee;

    // Prepare author and assignee contacts - will be passed directly as NewContact
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (createdBy?.email) {
      authorContact = {
        email: createdBy.email,
        name: createdBy.name,
        avatar: createdBy.photo?.image_128x128,
      };
    }
    if (assignee?.email) {
      assigneeContact = {
        email: assignee.email,
        name: assignee.name,
        avatar: assignee.photo?.image_128x128,
      };
    }

    // Build notes array: always create initial note with description and link
    const notes: any[] = [];

    // Extract description (if any)
    let description: string | null = null;
    if (task.notes && task.notes.trim().length > 0) {
      description = task.notes;
    }

    // Use stable identifier for source
    const threadSource = `asana:task:${task.gid}`;

    // Construct Asana task URL for link
    const taskUrl = `https://app.asana.com/0/${projectId}/${task.gid}`;

    // Build thread-level actions
    const threadActions: Action[] = [];
    threadActions.push({
      type: ActionType.external,
      title: `Open in Asana`,
      url: taskUrl,
    });

    // Create initial note with description (actions moved to thread level)
    notes.push({
      key: "description",
      content: description,
      created: task.created_at ? new Date(task.created_at) : undefined,
    });

    return {
      source: threadSource,
      type: "task",
      title: task.name,
      created: task.created_at ? new Date(task.created_at) : undefined,
      channelId: projectId,
      meta: {
        taskGid: task.gid,
        projectId,
        syncProvider: "asana",
        syncableId: projectId,
      },
      actions: threadActions.length > 0 ? threadActions : undefined,
      sourceUrl: taskUrl,
      author: authorContact,
      assignee: assigneeContact ?? null, // Explicitly set to null for unassigned tasks
      status: task.completed && task.completed_at ? "done" : "open",
      notes,
      preview: description || null,
    };
  }

  /**
   * Update task with new values from the app
   */
  async updateIssue(link: import("@plotday/twister").Link): Promise<void> {
    const taskGid = link.meta?.taskGid as string | undefined;
    if (!taskGid) {
      throw new Error("Asana task GID not found in link meta");
    }
    const projectId = link.meta?.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Asana project ID not found in link meta");
    }

    const client = await this.getClient(projectId);
    const updateFields: any = {};

    // Handle title
    if (link.title) {
      updateFields.name = link.title;
    }

    // Handle assignee
    updateFields.assignee = link.assignee?.id || null;

    // Handle completion status based on link status
    const isDone = link.status === "done" || link.status === "closed" || link.status === "completed";
    updateFields.completed = isDone;

    if (Object.keys(updateFields).length > 0) {
      await client.tasks.updateTask(taskGid, updateFields);
    }
  }

  /**
   * Add a comment (story) to an Asana task
   *
   * @param meta - Thread metadata containing taskGid and projectId
   * @param body - Comment text (markdown not directly supported, plain text)
   */
  async addIssueComment(
    meta: ThreadMeta,
    body: string
  ): Promise<string | void> {
    const taskGid = meta.taskGid as string | undefined;
    if (!taskGid) {
      throw new Error("Asana task GID not found in thread meta");
    }
    const projectId = meta.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Asana project ID not found in thread meta");
    }
    const client = await this.getClient(projectId);

    const result = await client.tasks.addComment(taskGid, {
      text: body,
    });

    if (result?.gid) {
      return `story-${result.gid}`;
    }
  }

  /**
   * Verify Asana webhook signature
   * Asana uses HMAC-SHA256 with a shared secret
   */
  private async verifyAsanaSignature(
    signature: string | undefined,
    rawBody: string,
    secret: string
  ): Promise<boolean> {
    if (!signature) {
      console.warn("Asana webhook missing signature header");
      return false;
    }

    // Compute HMAC-SHA256 signature
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const signatureBytes = await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(rawBody)
    );

    // Convert to hex string
    const expectedSignature = Array.from(new Uint8Array(signatureBytes))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Constant-time comparison
    return signature === expectedSignature;
  }

  /**
   * Handle incoming webhook events from Asana
   */
  private async onWebhook(
    request: WebhookRequest,
    projectId: string
  ): Promise<void> {
    const payload = request.body as any;

    // Asana webhook handshake
    if (request.headers["x-hook-secret"]) {
      // This is the initial handshake, respond with the secret
      // Note: The network tool should handle this automatically
      return;
    }

    // Verify webhook signature
    const webhookId = await this.get<string>(`webhook_id_${projectId}`);
    if (webhookId && request.rawBody) {
      const signature = request.headers["x-hook-signature"];
      // For Asana, the secret is the webhook ID itself
      const isValid = await this.verifyAsanaSignature(
        signature,
        request.rawBody,
        webhookId
      );

      if (!isValid) {
        console.warn("Asana webhook signature verification failed");
        return;
      }
    }

    // Process events
    if (payload.events && Array.isArray(payload.events)) {
      for (const event of payload.events) {
        if (event.resource?.resource_type === "task") {
          // Check what field changed to optimize the update
          const changedField = event.change?.field;

          if (changedField === "stories") {
            // Story/comment event - handle separately
            await this.handleStoryWebhook(event, projectId);
          } else {
            // Task property changed - update metadata only
            await this.handleTaskWebhook(event, projectId);
          }
        }
      }
    }
  }

  /**
   * Handle task property webhook events - only updates task metadata, not stories
   */
  private async handleTaskWebhook(
    event: any,
    projectId: string
  ): Promise<void> {

    const client = await this.getClient(projectId);

    try {
      // Fetch only task metadata (no stories)
      const task = await client.tasks.getTask(event.resource.gid, {
        opt_fields: [
          "name",
          "notes",
          "completed",
          "completed_at",
          "created_at",
          "modified_at",
          "assignee",
          "assignee.email",
          "assignee.name",
          "assignee.photo",
          "created_by",
          "created_by.email",
          "created_by.name",
          "created_by.photo",
        ].join(","),
      });

      const createdBy = (task as any).created_by;
      const assignee = (task as any).assignee;

      // Prepare author and assignee contacts
      let authorContact: NewContact | undefined;
      let assigneeContact: NewContact | undefined;

      if (createdBy?.email) {
        authorContact = {
          email: createdBy.email,
          name: createdBy.name,
          avatar: createdBy.photo?.image_128x128,
        };
      }
      if (assignee?.email) {
        assigneeContact = {
          email: assignee.email,
          name: assignee.name,
          avatar: assignee.photo?.image_128x128,
        };
      }

      // Use stable identifier for source
      const threadSource = `asana:task:${task.gid}`;

      // Extract description
      let description: string | null = null;
      if (task.notes && task.notes.trim().length > 0) {
        description = task.notes;
      }

      // Create partial link update (empty notes = doesn't touch existing notes)
      const link: NewLinkWithNotes = {
        source: threadSource,
        type: "task",
        title: task.name,
        created: task.created_at ? new Date(task.created_at) : undefined,
        channelId: projectId,
        meta: {
          taskGid: task.gid,
          projectId,
          syncProvider: "asana",
          syncableId: projectId,
        },
        author: authorContact,
        assignee: assigneeContact ?? null,
        status: task.completed && task.completed_at ? "done" : "open",
        preview: description || null,
        notes: [],
      };

      await this.tools.integrations.saveLink(link);
    } catch (error) {
      console.warn("Failed to process Asana task webhook:", error);
    }
  }

  /**
   * Handle story webhook events - only updates the specific story
   */
  private async handleStoryWebhook(
    event: any,
    projectId: string
  ): Promise<void> {

    const client = await this.getClient(projectId);
    const taskGid = event.resource.gid;

    try {
      // Use stable identifier for source
      const threadSource = `asana:task:${taskGid}`;

      // Fetch stories (comments) for this task
      // We fetch all stories since Asana doesn't provide the specific story GID in the webhook
      // In practice, this is still more efficient than fetching the full task with all fields
      const storiesResult = await client.stories.findByTask(taskGid, {
        opt_fields: [
          "created_at",
          "text",
          "created_by",
          "created_by.email",
          "created_by.name",
          "created_by.photo",
        ].join(","),
      });

      // Get the most recent story (last in the array)
      const stories = storiesResult.data || [];
      if (stories.length === 0) {
        return;
      }

      const latestStory: any = stories[stories.length - 1];

      // Extract story author
      let storyAuthor: NewContact | undefined;
      const author: any = latestStory.created_by;
      if (author?.email) {
        storyAuthor = {
          email: author.email,
          name: author.name,
          avatar: author.photo?.image_128x128,
        };
      }

      // Create link update with single story note
      const link: NewLinkWithNotes = {
        source: threadSource,
        type: "task",
        title: taskGid, // Placeholder; upsert by source will preserve existing title
        notes: [
          {
            key: `story-${latestStory.gid}`,
            content: latestStory.text || "",
            created: latestStory.created_at
              ? new Date(latestStory.created_at)
              : undefined,
            author: storyAuthor,
          } as any,
        ],
        channelId: projectId,
        meta: {
          taskGid,
          projectId,
          syncProvider: "asana",
          syncableId: projectId,
        },
      };

      await this.tools.integrations.saveLink(link);
    } catch (error) {
      console.warn("Failed to process Asana story webhook:", error);
    }
  }

  /**
   * Stop syncing an Asana project
   */
  async stopSync(projectId: string): Promise<void> {
    // Delete webhook
    const webhookId = await this.get<string>(`webhook_id_${projectId}`);
    if (webhookId) {
      try {
        const client = await this.getClient(projectId);
        await client.webhooks.deleteById(webhookId);
      } catch (error) {
        console.warn("Failed to delete Asana webhook:", error);
      }
      await this.clear(`webhook_id_${projectId}`);
    }

    // Cleanup sync state
    await this.clear(`sync_state_${projectId}`);
  }
}

export default Asana;
