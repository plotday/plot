import {
  type Action,
  ActionType,
  ActorType,
  type Actor,
  type Link,
  type Note,
  type Thread,
  ThreadMeta,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { NewActor, NewContact, NewReactions } from "@plotday/twister/plot";
import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
} from "@plotday/twister/connector";
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
import { Tasks } from "@plotday/twister/tools/tasks";
import { Files } from "@plotday/twister/tools/files";

import * as api from "./asana-api";
import { AsanaSyncTokenError } from "./asana-api";
import type { AsanaTask } from "./asana-api";

type Project = {
  id: string;
  name: string;
  description: string | null;
  key: string | null;
};

type ProjectSyncOptions = {
  timeMin?: Date;
};

type SyncState = {
  // Opaque Asana pagination cursor (`next_page.offset`); null on the first page.
  offset: string | null;
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
};

/**
 * Recurring poll interval for Asana change detection. The webhook handshake is
 * unsupported by the Plot runtime, so each enabled project is polled via the
 * Asana Events API on this cadence.
 */
const POLL_INTERVAL_MS = 5 * 60 * 1000;

/**
 * The single Asana "like" maps to the 👍 reaction in Plot. Asana exposes
 * exactly one heart/like per object (no arbitrary emoji), so the connector's
 * reactionCapabilities are `{ mode: "fixed", allowed: [LIKE_EMOJI] }`.
 */
export const LIKE_EMOJI = "👍";

/** A single Asana like entry as returned via `likes.user.gid/name` opt_fields. */
type AsanaLike = {
  gid?: string;
  user?: { gid?: string; name?: string };
};

/**
 * Convert an Asana `likes[]` array into a {@link NewReactions} map under the
 * single 👍 like emoji. Each like's `user` becomes a {@link NewActor} resolved
 * by its Asana gid (`source.accountId`). Likes without a user gid are skipped.
 *
 * Pure function (unit-tested) — keep free of `this`/IO.
 */
export function buildLikeReactions(
  likes: AsanaLike[] | undefined | null,
): NewReactions {
  if (!likes || likes.length === 0) return {};
  const actors: NewActor[] = [];
  for (const like of likes) {
    const gid = like.user?.gid;
    if (!gid) continue;
    actors.push({
      source: { accountId: gid },
      name: like.user?.name ?? "",
    } as NewActor);
  }
  if (actors.length === 0) return {};
  return { [LIKE_EMOJI]: actors };
}

/** Minimal shape of the fields `mapTaskStatus` reads off an Asana task. */
type TaskStatusFields = {
  completed?: boolean;
  memberships?: Array<{
    project?: { gid?: string } | null;
    section?: { gid?: string } | null;
  }> | null;
};

/**
 * Map an Asana task to a Plot status id for the given project:
 * - `"done"` when the task is completed (terminal),
 * - else the section gid of the task's membership within `projectGid`,
 * - else `"open"` (no section).
 *
 * Pure function (unit-tested) — keep free of `this`/IO.
 */
export function mapTaskStatus(
  task: TaskStatusFields,
  projectGid: string,
): string {
  if (task.completed) return "done";
  for (const m of task.memberships ?? []) {
    if (m.project?.gid === projectGid && m.section?.gid) {
      return m.section.gid;
    }
  }
  return "open";
}

/**
 * opt_fields requested for tasks everywhere we fetch them (sync + poll).
 * Includes section membership (for section-as-status mapping) and like data
 * (for inbound 👍 reactions).
 */
const TASK_OPT_FIELDS = [
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
  "memberships.project.gid",
  "memberships.section.gid",
  "memberships.section.name",
  "liked",
  "num_likes",
  "likes.user.gid",
  "likes.user.name",
].join(",");

/** opt_fields requested for stories (comments) — includes like data. */
const STORY_OPT_FIELDS = [
  "created_at",
  "text",
  "created_by",
  "created_by.email",
  "created_by.name",
  "created_by.photo",
  "liked",
  "num_likes",
  "likes.user.gid",
  "likes.user.name",
].join(",");

/**
 * Asana project management source
 *
 * Implements the ProjectSource interface for syncing Asana projects and tasks
 * with Plot threads, with two-way write-back (create/update/comment/edit,
 * section-as-status, 👍 like reactions, and file attachments).
 *
 * Inbound change detection uses the Asana Events API on a recurring poll (the
 * webhook X-Hook-Secret handshake is unsupported by the Plot runtime).
 */
export class Asana extends Connector<Asana> {
  static readonly PROVIDER = AuthProvider.Asana;
  static readonly SCOPES = ["default"];
  // Required so the runtime dispatches onNoteCreated / onNoteUpdated /
  // onNoteReactionChanged back to this connector.
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Asana;
  readonly channelNoun = { singular: "project", plural: "projects" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly scopes = Asana.SCOPES;
  // Asana models a single like per object; surface it as the 👍 reaction.
  readonly reactionCapabilities = {
    mode: "fixed" as const,
    allowed: [LIKE_EMOJI],
  };
  readonly access = [
    "Reads your tasks, projects, and comments",
    "Creates and updates tasks and posts comments you make in Plot",
    "Keeps Plot up to date as tasks change in Asana",
  ];
  readonly linkTypes = [
    {
      type: "task",
      label: "Task",
      noteLabel: "Comment",
      sharingModel: "channel" as const,
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/asana-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/asana.svg",
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
      // app.asana.com/* is needed for the raw multipart attachment upload.
      network: build(Network, { urls: ["https://app.asana.com/*"] }),
      tasks: build(Tasks),
      files: build(Files),
    };
  }

  /**
   * Fetch the raw Asana access token for a project. The token is passed directly
   * to the `asana-api` raw-fetch helpers (each call authenticates with
   * `Authorization: Bearer <token>`), so there is no client object to build.
   */
  private async getToken(projectId: string): Promise<string> {
    const token = await this.tools.integrations.get(projectId);
    if (!token) {
      throw new Error("No Asana authentication token available");
    }
    return token.token;
  }

  /**
   * Resolve (and cache) the workspace gid for a project. Needed by
   * `createTask` and `getUsersForWorkspace`. Cached under
   * `asana_workspace:<projectId>`.
   */
  private async getWorkspaceGid(
    projectId: string,
    token?: string,
  ): Promise<string | null> {
    const cached = await this.get<string>(`asana_workspace:${projectId}`);
    if (cached) return cached;
    const t = token ?? (await this.getToken(projectId));
    try {
      const project = await api.getProject(t, projectId, "workspace.gid");
      const workspaceGid = project.workspace?.gid as string | undefined;
      if (workspaceGid) {
        await this.set(`asana_workspace:${projectId}`, workspaceGid);
        return workspaceGid;
      }
    } catch (error) {
      console.warn("Failed to resolve Asana workspace gid:", error);
    }
    return null;
  }

  /**
   * Resolve a contact email to an Asana user gid within a workspace, caching
   * the result under `asana_user:<workspaceId>:<email>`.
   */
  private async resolveUserGid(
    workspaceGid: string,
    email: string,
    token: string,
  ): Promise<string | null> {
    const cacheKey = `asana_user:${workspaceGid}:${email.toLowerCase()}`;
    const cached = await this.get<string>(cacheKey);
    if (cached) return cached;

    try {
      const users = await api.getUsersForWorkspace(token, workspaceGid);
      let resolved: string | null = null;
      for (const user of users) {
        if (user.email && user.email.toLowerCase() === email.toLowerCase()) {
          resolved = user.gid;
        }
        // Warm the cache for every user we see, not just the match.
        if (user.email) {
          await this.set(
            `asana_user:${workspaceGid}:${user.email.toLowerCase()}`,
            user.gid,
          );
        }
      }
      return resolved;
    } catch (error) {
      console.warn("Failed to resolve Asana user by email:", error);
      return null;
    }
  }

  /**
   * Returns available Asana projects as channel resources, with per-channel
   * sections exposed as statuses (open + each section + done).
   */
  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const accessToken = token.token;
    const workspaces = await api.getWorkspaces(accessToken);
    const allChannels: Channel[] = [];
    for (const workspace of workspaces) {
      const projects = await api.getProjectsForWorkspace(
        accessToken,
        workspace.gid,
      );
      for (const project of projects) {
        // Cache the workspace gid now so create/user-lookup don't re-fetch it.
        await this.set(`asana_workspace:${project.gid}`, workspace.gid);

        // Build per-channel statuses from the project's sections.
        const statuses: Array<{
          status: string;
          label: string;
          icon: StatusIcon;
          done?: true;
        }> = [{ status: "open", label: "Open", icon: "todo" as StatusIcon }];
        try {
          const sections = await api.getSectionsForProject(
            accessToken,
            project.gid,
          );
          for (const section of sections) {
            statuses.push({
              status: section.gid,
              label: section.name ?? "",
              icon: "todo" as StatusIcon,
            });
          }
        } catch (error) {
          console.warn(
            `Failed to fetch Asana sections for project ${project.gid}:`,
            error,
          );
        }
        statuses.push({
          status: "done",
          label: "Done",
          done: true,
          icon: "done" as StatusIcon,
        });

        allChannels.push({
          id: project.gid,
          title: project.name ?? "",
          linkTypes: [
            {
              type: "task",
              label: "Task",
              noteLabel: "Comment",
              // Channel-level configs fully shadow the twist-level linkTypes,
              // so the sharing model must be repeated here.
              sharingModel: "channel" as const,
              supportsFileAttachments: true,
              logo: "https://api.iconify.design/logos/asana-icon.svg",
              logoMono: "https://api.iconify.design/simple-icons/asana.svg",
              statuses,
              supportsAssignee: true,
              compose: { status: "open" },
            },
          ],
        });
      }
    }
    return allChannels;
  }

  /**
   * Called when a channel is enabled for syncing. Schedules the initial
   * backfill and starts the recurring change poll (Asana Events API).
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

    await this.startBatchSync(
      channel.id,
      syncHistoryMin ? { timeMin: syncHistoryMin } : undefined,
    );

    // Start the recurring change poll. Idempotent: overwrite the stored task
    // token so re-dispatch (auto-enable / recovery) never stacks loops.
    await this.schedulePoll(channel.id);
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
   * Called when a link's status, assignee, or title is changed from the app.
   * Delegates to updateIssue. Best-effort: a failed external write is
   * reconciled on the next sync-in.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const taskGid = link.meta?.taskGid as string | undefined;
    const projectId = link.meta?.projectId as string | undefined;
    if (!taskGid || !projectId) return;

    try {
      await this.updateIssue(link);
    } catch (error) {
      console.error(
        "[asana] onLinkUpdated write-back failed:",
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  /**
   * Create a new Asana task from a Plot thread. `draft.channelId` is the
   * Asana project gid; `draft.status` is either a section gid (from the
   * per-project dynamic statuses) or one of the symbolic ids "open"/"done".
   */
  async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "task") return null;

    const projectId = draft.channelId;
    const token = await this.getToken(projectId);

    // A section-gid status places the task in that section via memberships.
    const sectionGid =
      draft.status && draft.status !== "open" && draft.status !== "done"
        ? draft.status
        : null;

    const data: Record<string, unknown> = {
      name: draft.title,
      projects: [projectId],
    };
    // Asana `html_notes` must be valid Asana-flavored HTML; `draft.noteContent`
    // is markdown/plain text, so use plain `notes` to avoid 400s.
    if (draft.noteContent) {
      data.notes = draft.noteContent;
    }
    if (sectionGid) {
      data.memberships = [{ project: projectId, section: sectionGid }];
    }
    if (draft.status === "done") {
      data.completed = true;
    }

    const task = await api.createTask(token, data, "name,notes,created_at");
    if (!task?.gid) return null;

    const taskUrl = `https://app.asana.com/0/${projectId}/${task.gid}`;
    const threadActions: Action[] = [
      { type: ActionType.external, title: "Open in Asana", url: taskUrl },
    ];

    return {
      source: `asana:task:${task.gid}`,
      type: "task",
      title: task.name,
      status: draft.status ?? "open",
      created: task.created_at ? new Date(task.created_at) : undefined,
      channelId: projectId,
      meta: {
        taskGid: task.gid,
        projectId,
        syncProvider: "asana",
        syncableId: projectId,
      },
      actions: threadActions,
      sourceUrl: taskUrl,
      // Bind the opening note to the task notes (the same "description" key
      // sync-in emits) so edits round-trip via onNoteUpdated. externalContent
      // is the notes as Asana stored them — matching convertTaskToLink.
      originatingNote: {
        key: "description",
        externalContent: task.notes ?? undefined,
      },
    };
  }

  /**
   * Get list of Asana projects
   */
  async getProjects(projectId: string): Promise<Project[]> {
    const token = await this.getToken(projectId);

    // Get user's workspaces first
    const workspaces = await api.getWorkspaces(token);

    const allProjects: Project[] = [];

    // Get projects from each workspace
    for (const workspace of workspaces) {
      const projects = await api.getProjectsForWorkspace(token, workspace.gid);

      for (const project of projects) {
        allProjects.push({
          id: project.gid,
          name: project.name ?? "",
          description: null, // Asana doesn't return description in list
          key: null, // Asana doesn't have project keys
        });
      }
    }

    return allProjects;
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
      offset: null,
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
    });

    // Record the poll baseline now so the first modified_since delta (used when
    // the events sync token is missing/invalid) doesn't skip anything created
    // during the initial backfill.
    await this.set(`last_poll_${projectId}`, new Date().toISOString());

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

    const token = await this.getToken(projectId);

    // Fetch one page of tasks for the project. The raw API paginates via the
    // opaque `next_page.offset` cursor returned with each page.
    const batchSize = 50;
    const tasksResult = await api.getTasksForProject(token, projectId, {
      limit: batchSize,
      optFields: TASK_OPT_FIELDS,
      offset: state.offset ?? undefined,
    });
    const tasks = tasksResult.data ?? [];

    // Process each task
    for (const task of tasks) {
      // Optionally filter by time
      if (options?.timeMin) {
        const created = new Date(task.created_at ?? 0);
        if (created < options.timeMin) {
          continue;
        }
      }

      const linkWithNotes = await this.convertTaskToLink(
        task,
        projectId,
        token,
      );
      // Set unread based on sync type (false for initial sync to avoid notification overload)
      linkWithNotes.unread = !state.initialSync;
      // Unarchive on initial sync only (preserve user's archive state on incremental syncs)
      if (state.initialSync) {
        linkWithNotes.archived = false;
      }
      await this.tools.integrations.saveLink(linkWithNotes);
    }

    // More pages remain when Asana returns a next_page cursor.
    const nextOffset = tasksResult.next_page?.offset ?? null;
    const hasMore = nextOffset !== null;

    if (hasMore) {
      await this.set(`sync_state_${projectId}`, {
        offset: nextOffset,
        batchNumber: state.batchNumber + 1,
        tasksProcessed: state.tasksProcessed + tasks.length,
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
      // Initial sync is complete - cleanup sync state and notify the runtime.
      await this.clear(`sync_state_${projectId}`);
      await this.tools.integrations.channelSyncCompleted(projectId);
    }
  }

  /**
   * Convert an Asana task to a Plot Link
   */
  private async convertTaskToLink(
    task: AsanaTask,
    projectId: string,
    token?: string,
  ): Promise<NewLinkWithNotes> {
    const t = token ?? (await this.getToken(projectId));
    const createdBy = task.created_by;
    const assignee = task.assignee;

    // Prepare author and assignee contacts - will be passed directly as NewContact
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (createdBy) {
      authorContact = {
        ...(createdBy.email ? { email: createdBy.email } : {}),
        name: createdBy.name ?? "",
        avatar: createdBy.photo?.image_128x128,
        ...(createdBy.gid ? { source: { accountId: createdBy.gid } } : {}),
      };
    }
    if (assignee) {
      assigneeContact = {
        ...(assignee.email ? { email: assignee.email } : {}),
        name: assignee.name ?? "",
        avatar: assignee.photo?.image_128x128,
        ...(assignee.gid ? { source: { accountId: assignee.gid } } : {}),
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

    // Inbound file attachments → fileRef actions. Cache the attachment→project
    // mapping so downloadAttachment can resolve the right client/token.
    try {
      const attachments = await api.getAttachmentsForObject(t, task.gid);
      for (const att of attachments) {
        await this.set(`asana:att-project:${att.gid}`, projectId);
        threadActions.push({
          type: ActionType.fileRef,
          ref: att.gid,
          fileName: att.name ?? "attachment",
          fileSize: null,
          mimeType: "application/octet-stream",
        } as any);
      }
    } catch (error) {
      console.warn("Failed to fetch Asana task attachments:", error);
    }

    // Create initial note with description (actions moved to thread level).
    // Attach task-level likes as 👍 reactions on the description note.
    notes.push({
      key: "description",
      content: description,
      created: task.created_at ? new Date(task.created_at) : undefined,
      // Attribute the task body to its creator, matching the link author —
      // without this the description note falls back to the connector itself.
      ...(authorContact ? { author: authorContact } : {}),
      ...(task.likes ? { reactions: buildLikeReactions(task.likes) } : {}),
    });

    // Backfill the task's stories (comments) so history syncs on initial load.
    try {
      const stories = await api.getStoriesForTask(t, task.gid, STORY_OPT_FIELDS);
      for (const story of stories) {
        // Only comment stories carry user-authored text; skip system stories.
        if (!story.text) continue;
        let storyAuthor: NewContact | undefined;
        const author = story.created_by;
        if (author) {
          storyAuthor = {
            ...(author.email ? { email: author.email } : {}),
            name: author.name ?? "",
            avatar: author.photo?.image_128x128,
            ...(author.gid ? { source: { accountId: author.gid } } : {}),
          };
        }
        notes.push({
          key: `story-${story.gid}`,
          content: story.text,
          created: story.created_at ? new Date(story.created_at) : undefined,
          author: storyAuthor,
          ...(story.likes ? { reactions: buildLikeReactions(story.likes) } : {}),
        });
      }
    } catch (error) {
      console.warn("Failed to backfill Asana stories:", error);
    }

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
      status: mapTaskStatus(task, projectId),
      notes,
      preview: description || null,
    };
  }

  /**
   * Update task with new values from the app
   */
  async updateIssue(link: Link): Promise<void> {
    const taskGid = link.meta?.taskGid as string | undefined;
    if (!taskGid) {
      throw new Error("Asana task GID not found in link meta");
    }
    const projectId = link.meta?.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Asana project ID not found in link meta");
    }

    const token = await this.getToken(projectId);
    const updateFields: Record<string, unknown> = {};

    // Handle title
    if (link.title) {
      updateFields.name = link.title;
    }

    // Handle assignee — resolve the Plot actor's email to an Asana user gid.
    if (!link.assignee) {
      // Explicit unassign.
      updateFields.assignee = null;
    } else {
      const email = link.assignee.email;
      if (email) {
        const workspaceGid = await this.getWorkspaceGid(projectId, token);
        if (workspaceGid) {
          const userGid = await this.resolveUserGid(
            workspaceGid,
            email,
            token,
          );
          if (userGid) {
            updateFields.assignee = userGid;
          } else {
            console.warn(
              `No Asana user found for email ${email}, skipping assignee update`,
            );
          }
        }
      } else {
        console.warn("No email on assignee actor, skipping assignee update");
      }
    }

    // Handle status. "done" → completed; a section gid → move to that section;
    // "open" → ensure not completed.
    const status = link.status;
    const isDone = status === "done" || status === "closed" || status === "completed";
    if (isDone) {
      updateFields.completed = true;
    } else if (status === "open") {
      updateFields.completed = false;
    } else if (status) {
      // A section gid: move the task into that section. Reopen first if needed.
      updateFields.completed = false;
      try {
        await api.addTaskToSection(token, status, taskGid);
      } catch (error) {
        console.warn("Failed to move Asana task to section:", error);
      }
    }

    if (Object.keys(updateFields).length > 0) {
      await api.updateTask(token, taskGid, updateFields);
    }
  }

  /**
   * Called when a note is created on a thread owned by this connector.
   * Posts the note as an Asana comment (story) and returns a baseline.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const fileActions = (note.actions ?? []).filter(
      (a): a is Extract<Action, { type: typeof ActionType.file }> =>
        a.type === ActionType.file,
    );
    return this.addIssueComment(thread.meta ?? {}, note.content ?? "", fileActions);
  }

  /**
   * Push a local note edit back to Asana.
   *
   * Only the task description (`note.key === "description"`) is editable —
   * Asana stories (comments) are immutable (the Stories API has no update
   * method for text), so `story-*` keys return void.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    if (!note.key) return;

    const taskGid = thread.meta?.taskGid as string | undefined;
    const projectId = thread.meta?.projectId as string | undefined;
    if (!taskGid || !projectId) return;

    if (note.key === "description") {
      const body = note.content ?? "";
      const token = await this.getToken(projectId);
      // Use plain `notes` (not html_notes) — Plot content is markdown/plain,
      // and Asana's html_notes requires valid Asana-flavored HTML.
      const updated = await api.updateTask(
        token,
        taskGid,
        { notes: body },
        "notes",
      );
      return { externalContent: updated.notes ?? body };
    }

    // Asana comments (stories) text is immutable: the Stories API exposes no
    // text-update method, so a local edit to a `story-*` note cannot be pushed
    // back. Leave the Plot edit in place; the next sync-in re-ingests the
    // original (unchanged) story text.
    return;
  }

  /**
   * Push a single 👍 like add/remove back to Asana. The runtime dispatches this
   * to the reacting user's own connector instance, so the like is attributed to
   * them. Asana only supports a single like (no arbitrary emoji), so we ignore
   * any emoji other than 👍 (the only one in reactionCapabilities). Likes on
   * the description note map to the task; likes on a `story-*` note map to that
   * story.
   */
  async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    actor: Actor,
    _emoji: string,
    added: boolean,
  ): Promise<void> {
    // Don't echo the twist's own reactions back (loop prevention).
    if (actor.type === ActorType.Twist) return;
    if (!note.key) return;

    const taskGid = thread.meta?.taskGid as string | undefined;
    const projectId = thread.meta?.projectId as string | undefined;
    if (!taskGid || !projectId) return;

    try {
      const token = await this.getToken(projectId);
      if (note.key === "description") {
        await api.updateTask(token, taskGid, { liked: added });
        return;
      }
      const storyMatch = note.key.match(/^story-(.+)$/);
      if (storyMatch) {
        const storyGid = storyMatch[1];
        await api.updateStory(token, storyGid, { liked: added });
      }
    } catch (error) {
      console.warn(
        `[asana] like ${added ? "add" : "remove"} failed for ${note.key}:`,
        error,
      );
    }
  }

  /**
   * Add a comment (story) to an Asana task, optionally uploading file
   * attachments. Returns a {@link NoteWriteBackResult} so the runtime sets the
   * note key (`story-<gid>`) and records the sync baseline (the story text).
   *
   * Note: Asana attaches files to the TASK, not the comment — there is no
   * comment-scoped attachment endpoint, so uploaded files land on the task and
   * surface as task attachments on the next sync.
   *
   * @param meta - Thread metadata containing taskGid and projectId
   * @param body - Comment text (plain — Asana stories are plain text)
   * @param fileActions - Optional file actions to upload as task attachments
   */
  async addIssueComment(
    meta: ThreadMeta,
    body: string,
    fileActions: Array<Extract<Action, { type: typeof ActionType.file }>> = [],
  ): Promise<NoteWriteBackResult | void> {
    const taskGid = meta.taskGid as string | undefined;
    if (!taskGid) {
      throw new Error("Asana task GID not found in thread meta");
    }
    const projectId = meta.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Asana project ID not found in thread meta");
    }
    const token = await this.getToken(projectId);

    // Upload any file actions to the task (Asana has no comment-scoped upload).
    // Asana's attachment endpoint is multipart (FormData), so uploadAttachment
    // posts a raw fetch with a Blob part rather than going through the JSON path.
    if (fileActions.length > 0) {
      for (const action of fileActions) {
        try {
          const file = await this.tools.files.read(action.fileId);
          const blob = new Blob([file.data as unknown as BlobPart], {
            type: file.mimeType,
          });
          await api.uploadAttachment(token, taskGid, blob, file.fileName);
        } catch (e) {
          console.error("Asana file upload failed", action.fileId, e);
        }
      }
    }

    const story = await api.createStory(token, taskGid, body, "text");

    if (story?.gid) {
      return {
        key: `story-${story.gid}`,
        // Asana stores the comment as plain `text`; sync-in emits story.text
        // verbatim, so use it as the baseline (fall back to body if missing).
        externalContent: story.text ?? body,
      };
    }
  }

  /**
   * Schedule (or reschedule) the recurring change poll for a project.
   *
   * Singleton scheduled task: re-scheduling under this key atomically replaces
   * any pending poll, so the self-rescheduling loop can never stack — even if
   * onChannelEnabled is re-dispatched (auto-enable / recovery).
   */
  private async schedulePoll(projectId: string): Promise<void> {
    const callback = await this.callback(this.pollChanges, projectId);
    await this.scheduleRecurring(`change-poll:${projectId}`, callback, {
      intervalMs: POLL_INTERVAL_MS,
      firstRunAt: new Date(Date.now() + POLL_INTERVAL_MS),
    });
  }

  /**
   * Poll Asana for changes to a project's tasks and re-sync any that changed.
   *
   * Uses the Asana Events API (`/events?resource=<project>&sync=<token>`):
   * - First run (no token) or a 412 "sync token invalid" → reset and fall back
   *   to a `modified_since` delta via getTasks, then store the fresh token.
   * - Otherwise apply each task-touching event by re-fetching the full task.
   *
   * Re-schedules the next poll at the end (self-rescheduling loop). Only runs
   * while the channel is still enabled.
   */
  private async pollChanges(projectId: string): Promise<void> {
    // Stop the loop if the channel was disabled (token cleared on disable).
    const enabled = await this.get<boolean>(`sync_enabled_${projectId}`);
    if (!enabled) return;

    try {
      const token = await this.getToken(projectId);
      const syncToken = await this.get<string>(`events_sync_${projectId}`);

      if (!syncToken) {
        // No token yet → establish one and do a modified_since delta. Asana
        // returns a usable `sync` token alongside the (often 412) response.
        await this.pollViaDelta(projectId, token);
      } else {
        try {
          const result = await api.getEvents(token, projectId, syncToken);
          if (result.sync) {
            await this.set(`events_sync_${projectId}`, result.sync);
          }
          await this.applyEvents(projectId, result.data, token);
        } catch (error) {
          // 412 → sync token expired/invalid. Asana includes a fresh token in
          // the error body; capture it and fall back to a modified_since delta.
          if (error instanceof AsanaSyncTokenError) {
            if (error.sync) {
              await this.set(`events_sync_${projectId}`, error.sync);
            } else {
              await this.clear(`events_sync_${projectId}`);
            }
            await this.pollViaDelta(projectId, token);
          } else {
            throw error;
          }
        }
      }

      await this.set(`last_poll_${projectId}`, new Date().toISOString());
    } catch (error) {
      console.warn(`[asana] poll failed for project ${projectId}:`, error);
    } finally {
      // Self-reschedule only while still enabled.
      const stillEnabled = await this.get<boolean>(`sync_enabled_${projectId}`);
      if (stillEnabled) {
        await this.schedulePoll(projectId);
      }
    }
  }

  /**
   * Fallback delta: fetch tasks modified since the last poll and re-sync them.
   * Used on the first poll and whenever the events sync token is invalid.
   * Also (re)establishes the events sync token for subsequent incremental polls.
   */
  private async pollViaDelta(
    projectId: string,
    token: string,
  ): Promise<void> {
    const lastPollIso = await this.get<string>(`last_poll_${projectId}`);
    const modifiedSince =
      lastPollIso ??
      new Date(Date.now() - POLL_INTERVAL_MS * 2).toISOString();

    // Establish/refresh the events sync token so future polls can go
    // incremental. The initial getEvents call with no token returns 412 with a
    // fresh `sync` token in the body — capture it.
    if (!(await this.get<string>(`events_sync_${projectId}`))) {
      try {
        const result = await api.getEvents(token, projectId);
        if (result.sync) {
          await this.set(`events_sync_${projectId}`, result.sync);
        }
      } catch (error) {
        if (error instanceof AsanaSyncTokenError && error.sync) {
          await this.set(`events_sync_${projectId}`, error.sync);
        }
      }
    }

    const tasksResult = await api.getTasksForProject(token, projectId, {
      modifiedSince,
      optFields: TASK_OPT_FIELDS,
      limit: 100,
    });
    for (const task of tasksResult.data ?? []) {
      await this.syncTaskIncremental(task.gid, projectId, token);
    }
  }

  /**
   * Apply a batch of Asana events. Each task-touching event triggers a full
   * re-fetch + incremental saveLink of the affected task.
   */
  private async applyEvents(
    projectId: string,
    events: api.AsanaEvent[],
    token: string,
  ): Promise<void> {
    // De-dupe by task gid: many events can touch the same task in one window.
    const taskGids = new Set<string>();
    for (const event of events) {
      const resource = event?.resource;
      if (!resource) continue;
      if (resource.resource_type === "task" && resource.gid) {
        taskGids.add(resource.gid);
      } else if (
        resource.resource_type === "story" &&
        event?.parent?.resource_type === "task" &&
        event.parent.gid
      ) {
        // Comment (story) event → re-fetch the parent task (pulls stories too).
        taskGids.add(event.parent.gid);
      }
    }
    for (const gid of taskGids) {
      await this.syncTaskIncremental(gid, projectId, token);
    }
  }

  /**
   * Re-fetch a single task by gid (with full opt_fields) and save it as an
   * incremental link update (no unread/archived overrides).
   */
  private async syncTaskIncremental(
    taskGid: string,
    projectId: string,
    token: string,
  ): Promise<void> {
    try {
      const task = await api.getTask(token, taskGid, TASK_OPT_FIELDS);
      if (!task?.gid) return;
      const link = await this.convertTaskToLink(task, projectId, token);
      // Incremental: omit unread/archived so user state is preserved.
      await this.tools.integrations.saveLink(link);
    } catch (error) {
      console.warn(
        `[asana] failed to sync task ${taskGid} for project ${projectId}:`,
        error,
      );
    }
  }

  /**
   * Download an Asana attachment identified by its gid (`ref`).
   *
   * The ref is emitted as an `ActionType.fileRef` action during inbound sync.
   * We resolve the projectId from the store cache, fetch the attachment's
   * `download_url`, and redirect the client there.
   */
  override async downloadAttachment(ref: string): Promise<{ redirectUrl: string }> {
    const projectId = await this.get<string>(`asana:att-project:${ref}`);
    if (!projectId) {
      throw new Error(
        `Unknown Asana attachment: ${ref}. The attachment may have been ` +
          `synced before file support was enabled. Try re-syncing the Asana connection.`,
      );
    }

    const token = await this.getToken(projectId);
    const attachment = await api.getAttachment(token, ref);
    const downloadUrl = attachment.download_url;
    if (!downloadUrl) {
      throw new Error(`Asana attachment ${ref} has no download URL`);
    }
    return { redirectUrl: downloadUrl };
  }

  /**
   * Stop syncing an Asana project: cancel the recurring poll and clear all
   * per-channel state.
   */
  async stopSync(projectId: string): Promise<void> {
    // Cancel the recurring change poll (singleton keyed task).
    await this.cancelScheduledTask(`change-poll:${projectId}`);

    // Cleanup poll + sync state.
    await this.clear(`events_sync_${projectId}`);
    await this.clear(`last_poll_${projectId}`);
    await this.clear(`sync_state_${projectId}`);
  }
}

export default Asana;
