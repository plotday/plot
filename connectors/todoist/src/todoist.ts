import {
  type Action,
  ActionType,
  type Link,
  type Note,
  type NoteWriteBackResult,
  type Thread,
  ThreadMeta,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import { Connector } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";

import {
  listProjects,
  listTasks,
  getTask,
  closeTask,
  reopenTask,
  createComment,
  updateComment,
  listCollaborators,
  verifyWebhookSignature,
  type TodoistTask,
  type TodoistCollaborator,
} from "./api";

type SyncState = {
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
  syncHistoryMin?: string;
};

/**
 * Todoist connector
 *
 * Syncs Todoist projects and tasks with Plot threads.
 * Uses webhooks for real-time updates.
 */
export class Todoist extends Connector<Todoist> {
  static readonly PROVIDER = AuthProvider.Todoist;
  static readonly SCOPES = ["data:read_write"];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Todoist;
  readonly scopes = Todoist.SCOPES;
  readonly linkTypes = [
    {
      type: "task",
      label: "Task",
      logo: "https://api.iconify.design/logos/todoist-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/todoist.svg",
      statuses: [
        { status: "open", label: "Open", todo: true },
        { status: "done", label: "Done", tag: Tag.Done, done: true },
      ],
      supportsAssignee: true,
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.todoist.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Get an access token for a channel (project).
   */
  private async getToken(channelId: string): Promise<string> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Todoist authentication token available");
    }
    return token.token;
  }

  /**
   * Returns available Todoist projects as channels.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const projects = await listProjects(token.token);
    return projects.map((p) => ({ id: p.id, title: p.name }));
  }

  /**
   * Called when a channel (project) is enabled.
   * Sets up webhook and starts initial sync.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
        return; // Already synced with wider range
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue webhook setup as a separate task to avoid blocking the HTTP response
    const webhookCallback = await this.callback(
      this.setupWebhook,
      channel.id
    );
    await this.runTask(webhookCallback);

    await this.startBatchSync(channel.id, syncHistoryMin);
  }

  /**
   * Called when a channel is disabled.
   * Cleans up webhook and archives links.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_secret_${channel.id}`);

    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
    });
  }

  /**
   * Set up webhook for real-time updates from Todoist.
   */
  async setupWebhook(projectId: string): Promise<void> {
    try {
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

      // Store webhook URL — Todoist app webhooks are configured at the app level,
      // not per-project. The webhook handler filters by project_id.
      await this.set(`webhook_url_${projectId}`, webhookUrl);
    } catch (error) {
      console.error(
        "Failed to set up Todoist webhook - real-time updates will not work:",
        error
      );
    }
  }

  /**
   * Initialize batch sync process for a project.
   */
  private async startBatchSync(projectId: string, syncHistoryMin?: Date): Promise<void> {
    await this.set(`sync_state_${projectId}`, {
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
      ...(syncHistoryMin ? { syncHistoryMin: syncHistoryMin.toISOString() } : {}),
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, projectId);
    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process tasks from a Todoist project.
   * Todoist REST API returns all tasks at once (no cursor pagination),
   * so we fetch all and process in a single batch.
   */
  private async syncBatch(projectId: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${projectId}`);
    if (!state) {
      throw new Error(`Sync state not found for project ${projectId}`);
    }

    const token = await this.getToken(projectId);

    // Fetch all active tasks for the project
    const tasks = await listTasks(token, projectId);

    // Fetch collaborators for assignee resolution
    let collaborators: TodoistCollaborator[] = [];
    try {
      collaborators = await listCollaborators(token, projectId);
    } catch {
      // Shared project collaborators may not be accessible
    }

    // Separate parent tasks and subtasks
    const parentTasks: TodoistTask[] = [];
    const subtasksByParent = new Map<string, TodoistTask[]>();

    for (const task of tasks) {
      if (task.parent_id) {
        const existing = subtasksByParent.get(task.parent_id) ?? [];
        existing.push(task);
        subtasksByParent.set(task.parent_id, existing);
      } else {
        parentTasks.push(task);
      }
    }

    // Process parent tasks with their subtasks
    for (const task of parentTasks) {
      const subtasks = subtasksByParent.get(task.id) ?? [];
      const link = this.transformTask(
        task,
        projectId,
        state.initialSync,
        subtasks,
        collaborators
      );
      await this.tools.integrations.saveLink(link);
    }

    // Handle subtasks whose parents are completed (not in active list)
    for (const [parentId, subtasks] of subtasksByParent) {
      if (!parentTasks.some((t) => t.id === parentId)) {
        for (const subtask of subtasks) {
          const link = this.transformTask(
            subtask,
            projectId,
            state.initialSync,
            [],
            collaborators
          );
          await this.tools.integrations.saveLink(link);
        }
      }
    }

    // Sync complete
    await this.clear(`sync_state_${projectId}`);
  }

  /**
   * Handle incoming webhook events from Todoist.
   */
  private async onWebhook(
    request: WebhookRequest,
    projectId: string
  ): Promise<void> {
    // Verify webhook signature if we have a client secret
    const webhookSecret = await this.get<string>(
      `webhook_secret_${projectId}`
    );
    if (webhookSecret && request.rawBody) {
      const signature = request.headers["x-todoist-hmac-sha256"];
      const isValid = await verifyWebhookSignature(
        webhookSecret,
        request.rawBody,
        signature
      );
      if (!isValid) {
        console.warn("Todoist webhook signature verification failed");
        return;
      }
    }

    const payload = request.body as any;
    if (!payload?.event_name || !payload?.event_data) return;

    const eventName: string = payload.event_name;
    const eventData = payload.event_data;

    // Filter by project
    if (eventData.project_id && eventData.project_id !== projectId) return;

    // Check sync is still enabled
    const enabled = await this.get<boolean>(`sync_enabled_${projectId}`);
    if (!enabled) return;

    const token = await this.getToken(projectId);

    if (
      eventName === "item:added" ||
      eventName === "item:updated" ||
      eventName === "item:completed" ||
      eventName === "item:uncompleted"
    ) {
      try {
        // Fetch full task data
        const task = await getTask(token, eventData.id);

        let collaborators: TodoistCollaborator[] = [];
        try {
          collaborators = await listCollaborators(token, projectId);
        } catch {
          // May not have access
        }

        const link = this.transformTask(
          task,
          projectId,
          false,
          [],
          collaborators
        );

        // Handle completion status from webhook
        if (eventName === "item:completed") {
          link.status = "done";
        } else if (eventName === "item:uncompleted") {
          link.status = "open";
        }

        await this.tools.integrations.saveLink(link);
      } catch (error) {
        console.warn("Failed to process Todoist task webhook:", error);
      }
    } else if (eventName === "item:deleted") {
      // Archive the link for deleted tasks
      await this.tools.integrations.archiveLinks({
        meta: { taskId: eventData.id },
      });
    } else if (eventName === "note:added") {
      // Comment added to a task
      try {
        const taskId = eventData.item_id || eventData.task_id;
        if (!taskId) return;

        const source = `todoist:task:${taskId}`;

        const link: NewLinkWithNotes = {
          source,
          type: "task",
          title: taskId, // Placeholder; upsert by source preserves existing title
          channelId: projectId,
          meta: {
            taskId,
            projectId,
            syncProvider: "todoist",
            channelId: projectId,
          },
          notes: [
            {
              key: `comment-${eventData.id}`,
              content: eventData.content || "",
              contentType: "text" as const,
              created: eventData.posted_at
                ? new Date(eventData.posted_at)
                : undefined,
            } as any,
          ],
        };

        await this.tools.integrations.saveLink(link);
      } catch (error) {
        console.warn("Failed to process Todoist comment webhook:", error);
      }
    }
  }

  /**
   * Convert a Todoist task to a Plot link with notes.
   */
  private transformTask(
    task: TodoistTask,
    projectId: string,
    initialSync: boolean,
    subtasks: TodoistTask[],
    collaborators: TodoistCollaborator[]
  ): NewLinkWithNotes {
    const source = `todoist:task:${task.id}`;

    const actions: Action[] = [
      {
        type: ActionType.external,
        title: "Open in Todoist",
        url: task.url,
      },
    ];

    // Resolve assignee
    let assigneeContact: NewContact | undefined;
    if (task.assignee_id) {
      const collaborator = collaborators.find(
        (c) => c.id === task.assignee_id
      );
      if (collaborator) {
        assigneeContact = {
          email: collaborator.email,
          name: collaborator.name,
        };
      }
    }

    // Resolve creator
    let authorContact: NewContact | undefined;
    const creator = collaborators.find((c) => c.id === task.creator_id);
    if (creator) {
      authorContact = {
        email: creator.email,
        name: creator.name,
      };
    }

    // Build notes
    const notes: any[] = [];

    // Description note
    if (task.description && task.description.trim().length > 0) {
      notes.push({
        key: "description",
        content: task.description,
        contentType: "text" as const,
      });
    }

    // Subtask notes with Todo tag and assignee
    for (const subtask of subtasks) {
      const subtaskNote: any = {
        key: `subtask-${subtask.id}`,
        content: subtask.content,
        tags: {
          add: subtask.is_completed ? [Tag.Done] : [Tag.Todo],
        },
      };

      // Add assignee mention if subtask has an assignee
      if (subtask.assignee_id) {
        const subtaskAssignee = collaborators.find(
          (c) => c.id === subtask.assignee_id
        );
        if (subtaskAssignee) {
          subtaskNote.author = {
            email: subtaskAssignee.email,
            name: subtaskAssignee.name,
          };
        }
      }

      notes.push(subtaskNote);
    }

    // Build tags for priority
    const tags: Tag[] = [];
    if (task.priority === 4) {
      tags.push(Tag.Urgent);
    }

    return {
      source,
      type: "task",
      title: task.content,
      created: task.created_at ? new Date(task.created_at) : undefined,
      channelId: projectId,
      meta: {
        taskId: task.id,
        projectId,
        syncProvider: "todoist",
        channelId: projectId,
      },
      actions,
      sourceUrl: task.url,
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: task.is_completed ? "done" : "open",
      notes,
      preview: task.description?.slice(0, 200) || null,
      ...(task.due
        ? {
            schedules: [
              {
                start: task.due.datetime ?? task.due.date,
              },
            ],
          }
        : {}),
      ...(tags.length > 0 ? { tags: { add: tags } } : {}),
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Write back link status changes to Todoist.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const taskId = link.meta?.taskId as string | undefined;
    const projectId = link.meta?.projectId as string | undefined;
    if (!taskId || !projectId) return;

    const token = await this.getToken(projectId);
    const isDone = link.status === "done";

    if (isDone) {
      await closeTask(token, taskId);
    } else {
      await reopenTask(token, taskId);
    }
  }

  /**
   * Write back new notes as Todoist comments.
   *
   * Returns a {@link NoteWriteBackResult} so the runtime assigns the note's
   * key to `comment-<todoistCommentId>` (matching what sync-in uses) and
   * records the external sync baseline. Todoist stores comment content as
   * plain text; hashing the returned `content` as `"text"` lines up with the
   * sync-in path (webhook `note:added`) so the next incremental sync
   * preserves Plot's (possibly markdown) note instead of overwriting it.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const taskId = thread.meta?.taskId as string | undefined;
    const projectId = thread.meta?.projectId as string | undefined;
    if (!taskId || !projectId || !note.content) return;

    // Todoist stores comments as plain text, so render Plot markdown to
    // readable plain text (renumbered lists, mentions as @Name, etc.).
    // Baseline round-trips through Todoist's echoed `content`.
    const body = markdownToPlainText(note.content);
    const token = await this.getToken(projectId);
    const comment = await createComment(token, taskId, body);
    if (!comment?.id) return;

    return {
      key: `comment-${comment.id}`,
      externalContent: comment.content ?? body,
    };
  }

  /**
   * Write back edits to existing Todoist comments.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const taskId = thread.meta?.taskId as string | undefined;
    const projectId = thread.meta?.projectId as string | undefined;
    if (!taskId || !projectId) return;
    if (!note.key) return;

    const match = note.key.match(/^comment-(.+)$/);
    if (!match) return;
    const commentId = match[1];

    const body = markdownToPlainText(note.content ?? "");
    const token = await this.getToken(projectId);
    const comment = await updateComment(token, commentId, body);

    return {
      externalContent: comment?.content ?? body,
    };
  }
}

export default Todoist;
