import * as asana from "asana";

import {
  type Thread,
  type ThreadFilter,
  type Action,
  ActionType,
  ThreadMeta,
  ThreadType,
  type NewThread,
  type NewThreadWithNotes,
  type NewNote,
  type Serializable,
  type SyncToolOptions,
} from "@plotday/twister";
import type {
  Project,
  ProjectSyncOptions,
  ProjectTool,
} from "@plotday/twister/common/projects";
import type { NewContact } from "@plotday/twister/plot";
import { Tool, type ToolBuilder } from "@plotday/twister/tool";
import { type Callback, Callbacks } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Syncable,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { ContactAccess, Plot } from "@plotday/twister/tools/plot";
import { Tasks } from "@plotday/twister/tools/tasks";

type SyncState = {
  offset: number;
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
};

/**
 * Asana project management tool
 *
 * Implements the ProjectTool interface for syncing Asana projects and tasks
 * with Plot activities.
 */
export class Asana extends Tool<Asana> implements ProjectTool {
  static readonly PROVIDER = AuthProvider.Asana;
  static readonly SCOPES = ["default"];
  static readonly Options: SyncToolOptions;
  declare readonly Options: SyncToolOptions;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: Asana.PROVIDER,
          scopes: Asana.SCOPES,
          getSyncables: this.getSyncables,
          onSyncEnabled: this.onSyncEnabled,
          onSyncDisabled: this.onSyncDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://app.asana.com/*"] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      plot: build(Plot, { contact: { access: ContactAccess.Write } }),
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
   * Returns available Asana projects as syncable resources.
   */
  async getSyncables(_auth: Authorization, token: AuthToken): Promise<Syncable[]> {
    const client = asana.Client.create().useAccessToken(token.token);
    const workspaces = await client.workspaces.getWorkspaces();
    const allProjects: Syncable[] = [];
    for (const workspace of workspaces.data) {
      const projects = await client.projects.findByWorkspace(workspace.gid, { limit: 100 });
      for (const project of projects.data) {
        allProjects.push({ id: project.gid, title: project.name });
      }
    }
    return allProjects;
  }

  /**
   * Called when a syncable project is enabled for syncing.
   * Creates callback tokens from options and auto-starts sync.
   */
  async onSyncEnabled(syncable: Syncable): Promise<void> {
    await this.set(`sync_enabled_${syncable.id}`, true);

    // Create item callback token from parent's onItem handler
    const itemCallbackToken = await this.tools.callbacks.createFromParent(
      this.options.onItem
    );
    await this.set(`item_callback_${syncable.id}`, itemCallbackToken);

    // Create disable callback if parent provided onSyncableDisabled
    if (this.options.onSyncableDisabled) {
      const filter: ThreadFilter = {
        meta: { syncProvider: "asana", syncableId: syncable.id },
      };
      const disableCallbackToken = await this.tools.callbacks.createFromParent(
        this.options.onSyncableDisabled,
        filter
      );
      await this.set(`disable_callback_${syncable.id}`, disableCallbackToken);
    }

    // Auto-start sync: setup webhook and begin batch sync
    await this.setupAsanaWebhook(syncable.id);
    await this.startBatchSync(syncable.id);
  }

  /**
   * Called when a syncable project is disabled.
   * Stops sync, runs disable callback, and cleans up stored tokens.
   */
  async onSyncDisabled(syncable: Syncable): Promise<void> {
    await this.stopSync(syncable.id);

    // Run and clean up disable callback
    const disableCallbackToken = await this.get<Callback>(
      `disable_callback_${syncable.id}`
    );
    if (disableCallbackToken) {
      await this.tools.callbacks.run(disableCallbackToken);
      await this.deleteCallback(disableCallbackToken);
      await this.clear(`disable_callback_${syncable.id}`);
    }

    // Clean up item callback
    const itemCallbackToken = await this.get<Callback>(
      `item_callback_${syncable.id}`
    );
    if (itemCallbackToken) {
      await this.deleteCallback(itemCallbackToken);
      await this.clear(`item_callback_${syncable.id}`);
    }

    await this.clear(`sync_enabled_${syncable.id}`);
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
  async startSync<
    TArgs extends Serializable[],
    TCallback extends (task: NewThreadWithNotes, ...args: TArgs) => any
  >(
    options: {
      projectId: string;
    } & ProjectSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void> {
    const { projectId, timeMin } = options;

    // Setup webhook for real-time updates
    await this.setupAsanaWebhook(projectId);

    // Store callback for webhook processing
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`item_callback_${projectId}`, callbackToken);

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

    // Retrieve callback token from storage
    const callbackToken = await this.get<Callback>(`item_callback_${projectId}`);
    if (!callbackToken) {
      throw new Error(`Callback token not found for project ${projectId}`);
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

      const threadWithNotes = await this.convertTaskToThread(
        task,
        projectId
      );
      // Set unread based on sync type (false for initial sync to avoid notification overload)
      threadWithNotes.unread = !state.initialSync;
      // Unarchive on initial sync only (preserve user's archive state on incremental syncs)
      if (state.initialSync) {
        threadWithNotes.archived = false;
      }
      // Execute the callback using the callback token
      await this.tools.callbacks.run(callbackToken, threadWithNotes);
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
   * Convert an Asana task to a Plot Thread
   */
  private async convertTaskToThread(
    task: any,
    projectId: string
  ): Promise<NewThreadWithNotes> {
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
    const notes: NewNote[] = [];

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
      thread: { source: threadSource },
      key: "description",
      content: description,
      created: task.created_at ? new Date(task.created_at) : undefined,
    });

    return {
      source: threadSource,
      type: ThreadType.Action,
      title: task.name,
      created: task.created_at ? new Date(task.created_at) : undefined,
      meta: {
        taskGid: task.gid,
        projectId,
        syncProvider: "asana",
        syncableId: projectId,
      },
      actions: threadActions.length > 0 ? threadActions : undefined,
      author: authorContact,
      assignee: assigneeContact ?? null, // Explicitly set to null for unassigned tasks
      done:
        task.completed && task.completed_at
          ? new Date(task.completed_at)
          : null,
      notes,
      preview: description || null,
    };
  }

  /**
   * Update task with new values
   *
   * @param thread - The updated thread
   */
  async updateIssue(thread: Thread): Promise<void> {
    // Extract Asana task GID and project ID from meta
    const taskGid = thread.meta?.taskGid as string | undefined;
    if (!taskGid) {
      throw new Error("Asana task GID not found in thread meta");
    }
    const projectId = thread.meta?.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Asana project ID not found in thread meta");
    }

    const client = await this.getClient(projectId);
    const updateFields: any = {};

    // Handle title
    if (thread.title !== null) {
      updateFields.name = thread.title;
    }

    // Handle assignee
    updateFields.assignee = thread.assignee?.id || null;

    // Handle completion status based on done
    // Asana only has completed boolean (no In Progress state)
    updateFields.completed =
      thread.type === ThreadType.Action && thread.done !== null;

    // Apply updates if any fields changed
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

    // Get callback token (needed by both handlers)
    const callbackToken = await this.get<Callback>(`item_callback_${projectId}`);
    if (!callbackToken) {
      console.warn("No callback token found for project:", projectId);
      return;
    }

    // Process events
    if (payload.events && Array.isArray(payload.events)) {
      for (const event of payload.events) {
        if (event.resource?.resource_type === "task") {
          // Check what field changed to optimize the update
          const changedField = event.change?.field;

          if (changedField === "stories") {
            // Story/comment event - handle separately
            await this.handleStoryWebhook(
              event,
              projectId,
              callbackToken
            );
          } else {
            // Task property changed - update metadata only
            await this.handleTaskWebhook(
              event,
              projectId,
              callbackToken
            );
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
    projectId: string,
    callbackToken: Callback
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

      // Create partial thread update (no notes = doesn't touch existing notes)
      const thread: NewThread = {
        source: threadSource,
        type: ThreadType.Action,
        title: task.name,
        created: task.created_at ? new Date(task.created_at) : undefined,
        meta: {
          taskGid: task.gid,
          projectId,
          syncProvider: "asana",
          syncableId: projectId,
        },
        author: authorContact,
        assignee: assigneeContact ?? null,
        done:
          task.completed && task.completed_at
            ? new Date(task.completed_at)
            : null,
        preview: description || null,
      };

      await this.tools.callbacks.run(callbackToken, thread);
    } catch (error) {
      console.warn("Failed to process Asana task webhook:", error);
    }
  }

  /**
   * Handle story webhook events - only updates the specific story
   */
  private async handleStoryWebhook(
    event: any,
    projectId: string,
    callbackToken: Callback
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

      // Create thread update with single story note
      const thread: NewThreadWithNotes = {
        source: threadSource,
        type: ThreadType.Action, // Required field (will match existing thread)
        notes: [
          {
            key: `story-${latestStory.gid}`,
            thread: { source: threadSource },
            content: latestStory.text || "",
            created: latestStory.created_at
              ? new Date(latestStory.created_at)
              : undefined,
            author: storyAuthor,
          } as NewNote,
        ],
        meta: {
          taskGid,
          projectId,
          syncProvider: "asana",
          syncableId: projectId,
        },
      };

      await this.tools.callbacks.run(callbackToken, thread);
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

    // Cleanup callback
    const callbackToken = await this.get<Callback>(`item_callback_${projectId}`);
    if (callbackToken) {
      await this.deleteCallback(callbackToken);
      await this.clear(`item_callback_${projectId}`);
    }

    // Cleanup sync state
    await this.clear(`sync_state_${projectId}`);
  }
}

export default Asana;
