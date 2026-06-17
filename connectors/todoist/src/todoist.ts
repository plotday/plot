import {
  type Action,
  ActionType,
  type Link,
  type Note,
  type Thread,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import { Connector, type CreateLinkDraft, type NoteWriteBackResult } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Files } from "@plotday/twister/tools/files";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";

import {
  listProjects,
  listTasks,
  listSections,
  listComments,
  getTask,
  createTask,
  updateTask,
  closeTask,
  reopenTask,
  createComment,
  updateComment,
  uploadFile,
  listCollaborators,
  type TodoistTask,
  type TodoistSection,
  type TodoistComment,
  type TodoistCollaborator,
} from "./api";

type SyncState = {
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
  syncHistoryMin?: string;
};

/**
 * Map a Todoist task to a Plot status id.
 *
 * - A completed task is `"done"` regardless of its section (the terminal).
 * - An open task in a section uses the section id as its status (matching the
 *   per-channel statuses emitted in {@link Todoist.getChannels}).
 * - An open task with no section falls back to `"open"`.
 *
 * Pure function — exported for unit testing.
 */
export function mapTaskStatus(
  task: Pick<TodoistTask, "is_completed" | "section_id">
): string {
  if (task.is_completed) return "done";
  if (task.section_id) return task.section_id;
  return "open";
}

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
  readonly channelNoun = { singular: "project", plural: "projects" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly scopes = Todoist.SCOPES;
  readonly access = [
    "Reads and updates your tasks and projects so they stay in sync with Plot",
    "Creates and completes tasks you change in Plot",
  ];
  readonly linkTypes = [
    {
      type: "task",
      label: "Task",
      noteLabel: "Comment",
      sharingModel: "thread" as const,
      composePlaceholder: "Create a Todoist task",
      composeVerb: "Create",
      replyPlaceholder: "Add a comment",
      replyVerb: "Comment",
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/todoist-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/todoist.svg",
      statuses: [
        { status: "open", label: "Open", icon: "todo" as StatusIcon },
        { status: "done", label: "Done", done: true, icon: "done" as StatusIcon },
      ],
      supportsAssignee: true,
      compose: { status: "open" },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.todoist.com/*"] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      files: build(Files),
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
   * Returns available Todoist projects as channels, each with per-project
   * sections surfaced as dynamic statuses (mirroring Linear's per-team
   * workflow states). The status set per project is:
   * `[open, ...sections (status = section.id), done]`, with `compose.status`
   * defaulting to `open`. Section-less projects keep just `open`/`done`.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const projects = await listProjects(token.token);
    return Promise.all(
      projects.map(async (p) => {
        let sections: TodoistSection[] = [];
        try {
          sections = await listSections(token.token, p.id);
        } catch {
          // Section-less projects or no access — fall back to open/done.
        }
        sections.sort((a, b) => a.order - b.order);

        const statuses = [
          { status: "open", label: "Open", icon: "todo" as StatusIcon },
          ...sections.map((s) => ({
            status: s.id,
            label: s.name,
            icon: "todo" as StatusIcon,
          })),
          { status: "done", label: "Done", done: true as const, icon: "done" as StatusIcon },
        ];

        return {
          id: p.id,
          title: p.name,
          linkTypes: [
            {
              type: "task",
              label: "Task",
              noteLabel: "Comment",
              // Channel-level configs fully shadow the twist-level linkTypes
              // in getTypeConfig(), so the sharing model and capability flags
              // must be repeated here — otherwise tasks resolve to defaults
              // and lose assignee/file/compose behavior.
              sharingModel: "thread" as const,
              composePlaceholder: "Create a Todoist task",
              composeVerb: "Create",
              replyPlaceholder: "Add a comment",
              replyVerb: "Comment",
              supportsFileAttachments: true,
              logo: "https://api.iconify.design/logos/todoist-icon.svg",
              logoMono: "https://api.iconify.design/simple-icons/todoist.svg",
              statuses,
              supportsAssignee: true,
              compose: { status: "open" },
            },
          ],
        };
      })
    );
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

    // Register the app-level webhook callback so realtime task/comment events
    // for this project flow to onWebhook. Todoist webhooks are configured once
    // at the app level (a single Console callback URL), so the API worker's
    // /hook/todoist route receives every user's events, verifies the signature,
    // and dispatches here keyed on project id. Storing the callback token under
    // `webhook_callback_<projectId>` is exactly what that route looks up.
    // Idempotent: an onChannelEnabled re-dispatch (auto-enable / recovery) just
    // overwrites the token.
    const webhookCallback = await this.tools.callbacks.createFromParent(
      this.onWebhook,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, webhookCallback);

    await this.startBatchSync(channel.id, syncHistoryMin);
  }

  /**
   * Called when a channel is disabled.
   * Cleans up webhook and archives links.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_callback_${channel.id}`);

    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
    });
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
      // Backfill existing comments as notes on initial sync (webhooks only
      // deliver go-forward comments). Best-effort per task.
      await this.backfillComments(token, task.id, projectId, link, state.initialSync);
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
          await this.backfillComments(token, subtask.id, projectId, link, state.initialSync);
          await this.tools.integrations.saveLink(link);
        }
      }
    }

    // Sync complete
    await this.clear(`sync_state_${projectId}`);
    await this.tools.integrations.channelSyncCompleted(projectId);
  }

  /**
   * Fetch a task's existing comments and append them to the link's notes as
   * `comment-<id>` notes so history backfills on initial sync. Inbound file
   * attachments on comments are emitted as `fileRef` actions.
   *
   * Best-effort: comment listing can fail for shared/limited projects; we log
   * and continue without comment history rather than failing the whole sync.
   */
  private async backfillComments(
    token: string,
    taskId: string,
    projectId: string,
    link: NewLinkWithNotes,
    initialSync: boolean
  ): Promise<void> {
    // History backfill is only needed on the initial sync; go-forward
    // comments arrive via the note:added/note:updated webhook.
    if (!initialSync) return;

    let comments: TodoistComment[] = [];
    try {
      comments = await listComments(token, taskId);
    } catch (error) {
      console.warn("Failed to backfill Todoist comments:", error);
      return;
    }

    const notes = (link.notes ?? []) as any[];
    for (const comment of comments) {
      const note = await this.buildCommentNote(comment, projectId);
      notes.push(note);
    }
    link.notes = notes;
  }

  /**
   * Handle a Todoist webhook event.
   *
   * Dispatched by the API worker's /hook/todoist route, which receives
   * Todoist's single app-level webhook for every connected user, verifies the
   * HMAC signature (the app client secret is server-only — the connector can't
   * see it), and routes here keyed on `event_data.project_id`. We therefore
   * receive the already-parsed event plus the project this connector enabled.
   */
  private async onWebhook(
    event: { eventName: string; eventData: any },
    projectId: string
  ): Promise<void> {
    const { eventName, eventData } = event;
    if (!eventName || !eventData) return;

    // Defensive: the route already keys on event_data.project_id; guard against
    // a mismatched dispatch.
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

        // Handle completion status from webhook. item:completed/uncompleted
        // events override the section-derived status (the fetched task may
        // momentarily lag the webhook's terminal transition).
        if (eventName === "item:completed") {
          link.status = "done";
        } else if (eventName === "item:uncompleted") {
          link.status = mapTaskStatus({ ...task, is_completed: false });
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
    } else if (eventName === "note:added" || eventName === "note:updated") {
      // Comment added to / edited on a task. Both upsert the same
      // `comment-<id>` note keyed by the comment id, so an edit replaces the
      // existing note's content rather than appending a new one.
      try {
        const taskId = eventData.item_id || eventData.task_id;
        if (!taskId) return;

        const source = `todoist:task:${taskId}`;
        const note = await this.buildCommentNote(
          {
            id: eventData.id,
            task_id: taskId,
            content: eventData.content || "",
            posted_at: eventData.posted_at,
            attachment: eventData.file_attachment ?? eventData.attachment ?? null,
          },
          projectId
        );

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
          notes: [note],
        };

        await this.tools.integrations.saveLink(link);
      } catch (error) {
        console.warn("Failed to process Todoist comment webhook:", error);
      }
    }
  }

  /**
   * Build a Plot note for a Todoist comment. Shared by the initial-sync
   * backfill and the `note:added`/`note:updated` webhook paths so both emit
   * an identical note shape (content verbatim as plain text, matching the
   * `externalContent` baseline returned from `onNoteCreated`/`onNoteUpdated`).
   *
   * A file attachment on the comment is emitted as a `fileRef` action and its
   * URL cached under `todoist:att-url:<ref>` so `downloadAttachment` can
   * redirect to it.
   */
  private async buildCommentNote(
    comment: TodoistComment,
    projectId: string
  ): Promise<any> {
    const note: any = {
      key: `comment-${comment.id}`,
      // Verbatim plain text — matches the write-back baseline (Todoist echoes
      // the stored content, which is plain text).
      content: comment.content || "",
      contentType: "text" as const,
      created: comment.posted_at ? new Date(comment.posted_at) : undefined,
    };

    const attachment = comment.attachment;
    if (attachment?.file_url) {
      // Build an opaque fileRef (`<projectId>:<commentId>`); cache the URL so
      // downloadAttachment can redirect to it.
      const ref = `${projectId}:${comment.id}`;
      // Intentionally persisted: downloadAttachment reads this URL later (no
      // request context to refetch it), so this cache is retained across calls.
      await this.set(`todoist:att-url:${ref}`, attachment.file_url);
      note.actions = [
        {
          type: ActionType.fileRef,
          ref,
          fileName: attachment.file_name ?? "attachment",
          fileSize: null,
          mimeType: attachment.file_type ?? "application/octet-stream",
        },
      ];
    }

    return note;
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

    // Description note. Always emit the "description"-keyed note (content null
    // when empty) so description edits from Plot have a note to round-trip
    // through onNoteUpdated, mirroring Linear. Content is verbatim plain text
    // to match the externalContent baseline written back on edit.
    const hasDescription =
      !!task.description && task.description.trim().length > 0;
    notes.push({
      key: "description",
      content: hasDescription ? task.description : null,
      contentType: "text" as const,
      author: authorContact,
    });

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

    // Priority-4 Todoist tasks no longer auto-tag as urgent. The user
    // can react with 🚨 themselves; auto-marking caused noise on
    // priorities the user didn't actually consider urgent.

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
      status: mapTaskStatus(task),
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

      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Build an in-memory email→collaborator-id index for a project by fetching
   * its collaborator list once. NOT persisted across calls: a stale store
   * cache (e.g. after a disable/re-enable or re-auth to a different account)
   * could otherwise resolve an email to a collaborator id from the old
   * account. Collaborator lists are small, so a fresh fetch per write-back is
   * cheap. Returns an empty map if the list can't be fetched.
   */
  private async buildCollaboratorIndex(
    token: string,
    projectId: string
  ): Promise<Map<string, string>> {
    let collaborators: TodoistCollaborator[] = [];
    try {
      collaborators = await listCollaborators(token, projectId);
    } catch {
      return new Map();
    }
    const index = new Map<string, string>();
    for (const c of collaborators) {
      index.set(c.email, c.id);
    }
    return index;
  }

  /**
   * Create a new Todoist task from a Plot thread.
   *
   * `draft.channelId` is the project id; `draft.status` is either a section id
   * (from the dynamic per-channel statuses) or one of the `open`/`done`
   * fallbacks. A new task is always created open (Todoist has no "create
   * completed" path), so `done` is treated as no section; a section id is set
   * via `section_id`.
   */
  async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "task") return null;

    const projectId = draft.channelId;
    const token = await this.getToken(projectId);

    // A status that isn't the open/done fallback is a section id.
    const sectionId =
      draft.status && draft.status !== "open" && draft.status !== "done"
        ? draft.status
        : undefined;

    const description = draft.noteContent
      ? markdownToPlainText(draft.noteContent)
      : undefined;

    const task = await createTask(token, draft.title, {
      project_id: projectId,
      ...(description !== undefined ? { description } : {}),
      ...(sectionId !== undefined ? { section_id: sectionId } : {}),
    });

    const actions: Action[] = [
      {
        type: ActionType.external,
        title: "Open in Todoist",
        url: task.url,
      },
    ];

    return {
      source: `todoist:task:${task.id}`,
      type: "task",
      title: task.content,
      status: draft.status ?? "open",
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
      // Bind the opening note to the task description (the same "description"
      // key sync-in emits) so edits round-trip via onNoteUpdated. The baseline
      // is the description Todoist stored, verbatim, matching transformTask.
      originatingNote: {
        key: "description",
        externalContent: task.description ? task.description : undefined,
      },
    };
  }

  /**
   * Write back link changes (title, assignee, section, completion) to Todoist.
   *
   * Best-effort: a failed external write is reconciled on the next sync-in
   * (Todoist is the source of truth).
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const taskId = link.meta?.taskId as string | undefined;
    const projectId = link.meta?.projectId as string | undefined;
    if (!taskId || !projectId) return;

    try {
      const token = await this.getToken(projectId);
      const isDone = link.status === "done";

      // Write title / assignee / section via task update. `done` is a terminal
      // handled by close/reopen below, not a section, so omit section_id then.
      const fields: Parameters<typeof updateTask>[2] = {};
      if (link.title) fields.content = link.title;

      if (!link.assignee) {
        fields.assignee_id = null;
      } else if (link.assignee.email) {
        // Fetch the collaborator list fresh for this write-back (small list,
        // not persisted) and resolve the email to a current collaborator id.
        const collaboratorIndex = await this.buildCollaboratorIndex(
          token,
          projectId
        );
        const assigneeId = collaboratorIndex.get(link.assignee.email);
        // Only send when we resolved a collaborator; otherwise leave unchanged
        // (Todoist rejects unknown assignee ids).
        if (assigneeId) fields.assignee_id = assigneeId;
      }

      if (link.status && link.status !== "open" && link.status !== "done") {
        fields.section_id = link.status;
      } else if (link.status === "open") {
        // Clearing back to the no-section "open" status removes the section.
        fields.section_id = null;
      }

      if (Object.keys(fields).length > 0) {
        await updateTask(token, taskId, fields);
      }

      // Completion is a separate close/reopen call (REST v2 has no
      // is_completed field on the update endpoint). Only act on a real status:
      // `done` closes; any other non-null status reopens (idempotent). A null
      // status (title/assignee/section-only edit) leaves completion untouched.
      if (isDone) {
        await closeTask(token, taskId);
      } else if (link.status != null) {
        await reopenTask(token, taskId);
      }
    } catch (error) {
      console.error(
        "[todoist] onLinkUpdated write-back failed:",
        error instanceof Error ? error.message : String(error)
      );
    }
  }

  /**
   * Write back new notes as Todoist comments, uploading any file attachments.
   *
   * Returns a {@link NoteWriteBackResult} so the runtime assigns the note's
   * key to `comment-<todoistCommentId>` (matching what sync-in uses) and
   * records the external sync baseline. Todoist stores comment content as
   * plain text; the returned `content` (echoed verbatim by Todoist) lines up
   * with the sync-in path (`buildCommentNote`) so the next incremental sync
   * preserves Plot's (possibly markdown) note instead of overwriting it.
   *
   * File actions are uploaded via Todoist's `/uploads/add` endpoint and
   * attached to the comment. Todoist allows a single `attachment` per comment,
   * so each file is posted as its own comment (the first carries the body).
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const taskId = thread.meta?.taskId as string | undefined;
    const projectId = thread.meta?.projectId as string | undefined;
    if (!taskId || !projectId) return;

    const fileActions = (note.actions ?? []).filter(
      (a): a is Extract<Action, { type: typeof ActionType.file }> =>
        a.type === ActionType.file
    );

    // Nothing to post (empty note with no files).
    if (!note.content && fileActions.length === 0) return;

    const token = await this.getToken(projectId);

    // Todoist stores comments as plain text, so render Plot markdown to
    // readable plain text (renumbered lists, mentions as @Name, etc.).
    const body = note.content ? markdownToPlainText(note.content) : "";

    // Upload files first; each becomes a comment attachment. Todoist permits
    // one attachment per comment, so the first comment carries the text body
    // plus the first file, and subsequent files go in follow-up comments.
    const uploaded: Array<{ file_name: string; file_type: string; file_url: string }> = [];
    for (const action of fileActions) {
      try {
        const file = await this.tools.files.read(action.fileId);
        const att = await uploadFile(token, file.data, file.fileName, file.mimeType);
        uploaded.push({
          file_name: att.file_name ?? file.fileName,
          file_type: att.file_type ?? file.mimeType,
          file_url: att.file_url,
        });
      } catch (e) {
        console.error("Todoist file upload failed", action.fileId, e);
      }
    }

    const firstAttachment = uploaded[0];
    const comment = await createComment(token, taskId, body, firstAttachment);

    // Post any remaining files as additional attachment-only comments.
    for (const att of uploaded.slice(1)) {
      try {
        await createComment(token, taskId, "", att);
      } catch (e) {
        console.error("Todoist follow-up attachment comment failed", e);
      }
    }

    if (!comment?.id) return;

    return {
      key: `comment-${comment.id}`,
      externalContent: comment.content ?? body,
    };
  }

  /**
   * Write back edits from Plot. Handles two note kinds:
   * - `description` → edits the task content (the `description` field).
   * - `comment-<id>` → edits the existing Todoist comment.
   *
   * In both cases `externalContent` is the value Todoist echoes back (verbatim
   * plain text), matching what sync-in emits for that note so the baseline
   * hash lines up and the next sync-in preserves Plot's content.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const taskId = thread.meta?.taskId as string | undefined;
    const projectId = thread.meta?.projectId as string | undefined;
    if (!taskId || !projectId) return;
    if (!note.key) return;

    const token = await this.getToken(projectId);

    // Description edit → update the task's description field.
    if (note.key === "description") {
      const body = note.content ? markdownToPlainText(note.content) : "";
      const updated = await updateTask(token, taskId, { description: body });
      return {
        externalContent: updated.description ? updated.description : undefined,
      };
    }

    const match = note.key.match(/^comment-(.+)$/);
    if (!match) return;
    const commentId = match[1];

    const body = markdownToPlainText(note.content ?? "");
    const comment = await updateComment(token, commentId, body);

    return {
      externalContent: comment?.content ?? body,
    };
  }

  /**
   * Resolve a Todoist comment-attachment `fileRef` to a download URL.
   *
   * The ref (`<projectId>:<commentId>`) is emitted as an `ActionType.fileRef`
   * action during inbound sync in `buildCommentNote`, which also caches the
   * file URL under `todoist:att-url:<ref>`. Todoist attachment URLs are
   * long-lived CDN URLs, so a redirect is safe.
   */
  override async downloadAttachment(ref: string): Promise<{ redirectUrl: string }> {
    const url = await this.get<string>(`todoist:att-url:${ref}`);
    if (!url) {
      throw new Error(
        `Unknown Todoist attachment: ${ref}. ` +
          `The attachment may have been synced before file support was enabled. ` +
          `Try re-syncing the Todoist connection.`
      );
    }
    return { redirectUrl: url };
  }
}

export default Todoist;
