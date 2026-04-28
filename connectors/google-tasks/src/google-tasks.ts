import {
  type Action,
  ActionType,
  type Link,
  type NewLinkWithNotes,
  type Actor,
  type ActorId,
} from "@plotday/twister";
import { Tag } from "@plotday/twister/tag";
import { Connector, type CreateLinkDraft } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import {
  createTask,
  listTaskLists,
  listTasks,
  updateTask,
  type GoogleTask,
} from "./api";

/** 5 minutes in milliseconds */
const POLL_INTERVAL_MS = 5 * 60 * 1000;

type SyncState = {
  pageToken: string | null;
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
  syncHistoryMin?: string;
};

type PeriodicSyncState = {
  pageToken: string | null;
  /** ISO timestamp captured at the start of the cycle. Becomes the next
   * `last_sync_time_<listId>` once every page in the cycle has been processed,
   * so the following cycle picks up anything modified during this one. */
  cycleStart: string;
};

/**
 * Google Tasks connector
 *
 * Syncs Google Tasks lists and tasks with Plot threads.
 * Uses polling (5-minute intervals) since Google Tasks API
 * does not support webhooks.
 */
export class GoogleTasks extends Connector<GoogleTasks> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = ["https://www.googleapis.com/auth/tasks"];

  readonly provider = AuthProvider.Google;
  readonly scopes = GoogleTasks.SCOPES;
  readonly linkTypes = [
    {
      type: "task",
      label: "Task",
      // Logo: full-color SVG from static assets (iconify has no logos/google-tasks)
      // logoMono: monochrome version from simple-icons (works fine on iconify)
      logo: "https://plot.day/assets/logo-google-tasks.svg",
      logoMono: "https://api.iconify.design/simple-icons/googletasks.svg",
      statuses: [
        { status: "open", label: "Open", todo: true, createDefault: true },
        { status: "done", label: "Done", tag: Tag.Done, done: true },
      ],
      supportsAssignee: false,
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://tasks.googleapis.com/*"] }),
      tasks: build(Tasks),
    };
  }

  override async activate(context: {
    auth?: Authorization;
    actor?: Actor;
  }): Promise<void> {
    if (context.actor) {
      await this.set("auth_actor_id", context.actor.id);
    }
  }

  /**
   * Get an access token for a channel (task list).
   */
  private async getToken(channelId: string): Promise<string> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Google Tasks authentication token available");
    }
    return token.token;
  }

  /**
   * Returns available Google Tasks lists as channels.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const lists = await listTaskLists(token.token);
    return lists.map((list) => ({ id: list.id, title: list.title }));
  }

  /**
   * Called when a channel (task list) is enabled.
   * Starts initial sync and schedules periodic polling.
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
    await this.startBatchSync(channel.id, syncHistoryMin);
    await this.schedulePeriodicSync(channel.id);
  }

  /**
   * Called when a channel is disabled.
   * Stops periodic sync and removes state.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`periodic_sync_state_${channel.id}`);
    await this.clear(`last_sync_time_${channel.id}`);

    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
    });
  }

  /**
   * Schedule next periodic sync for a task list.
   */
  private async startBatchSync(listId: string, syncHistoryMin?: Date): Promise<void> {
    await this.set(`sync_state_${listId}`, {
      pageToken: null,
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
      ...(syncHistoryMin ? { syncHistoryMin: syncHistoryMin.toISOString() } : {}),
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, listId);
    await this.tools.tasks.runTask(batchCallback);
  }

  private async schedulePeriodicSync(listId: string): Promise<void> {
    const syncCallback = await this.callback(this.periodicSync, listId);
    await this.tools.tasks.runTask(syncCallback, {
      runAt: new Date(Date.now() + POLL_INTERVAL_MS),
    });
  }

  /**
   * Process a batch of tasks from a Google Tasks list.
   */
  private async syncBatch(listId: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${listId}`);
    if (!state) {
      throw new Error(`Sync state not found for list ${listId}`);
    }

    const token = await this.getToken(listId);
    const authActorId = await this.get<ActorId>("auth_actor_id");

    // Fetch batch of tasks
    const result = await listTasks(token, listId, {
      showCompleted: false,
      pageToken: state.pageToken ?? undefined,
      maxResults: 50,
      updatedMin: state.syncHistoryMin ?? undefined,
    });

    // Separate parent tasks and subtasks
    const parentTasks: GoogleTask[] = [];
    const subtasksByParent = new Map<string, GoogleTask[]>();

    for (const task of result.tasks) {
      if (task.parent) {
        const existing = subtasksByParent.get(task.parent) ?? [];
        existing.push(task);
        subtasksByParent.set(task.parent, existing);
      } else {
        parentTasks.push(task);
      }
    }

    // Process parent tasks with their subtasks
    for (const task of parentTasks) {
      const subtasks = subtasksByParent.get(task.id) ?? [];
      const link = this.transformTask(
        task,
        listId,
        state.initialSync,
        subtasks,
        authActorId
      );
      await this.tools.integrations.saveLink(link);
    }

    // Handle subtasks whose parents weren't in this batch
    for (const [parentId, subtasks] of subtasksByParent) {
      if (!parentTasks.some((t) => t.id === parentId)) {
        // Save subtasks as standalone tasks
        for (const subtask of subtasks) {
          const link = this.transformTask(
            subtask,
            listId,
            state.initialSync,
            [],
            authActorId
          );
          await this.tools.integrations.saveLink(link);
        }
      }
    }

    // Continue to next page if available
    if (result.nextPageToken) {
      await this.set(`sync_state_${listId}`, {
        pageToken: result.nextPageToken,
        batchNumber: state.batchNumber + 1,
        tasksProcessed: state.tasksProcessed + result.tasks.length,
        initialSync: state.initialSync,
      });

      const nextBatch = await this.callback(this.syncBatch, listId);
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Initial sync is complete - cleanup sync state and set last sync time
      await this.clear(`sync_state_${listId}`);
      await this.set(`last_sync_time_${listId}`, new Date().toISOString());
    }
  }

  /**
   * Periodic sync entry point: starts a new cycle and hands off to
   * {@link periodicSyncBatch} so each page is processed in its own task with a
   * fresh runtime request budget.
   */
  private async periodicSync(listId: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${listId}`);
    if (!enabled) return;

    await this.set<PeriodicSyncState>(`periodic_sync_state_${listId}`, {
      pageToken: null,
      cycleStart: new Date().toISOString(),
    });

    const callback = await this.callback(this.periodicSyncBatch, listId);
    await this.tools.tasks.runTask(callback);
  }

  /**
   * Process a single page of incremental updates and either chain to the next
   * page or finish the cycle and reschedule the next periodic run.
   */
  private async periodicSyncBatch(listId: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${listId}`);
    if (!enabled) {
      await this.clear(`periodic_sync_state_${listId}`);
      return;
    }

    const state = await this.get<PeriodicSyncState>(
      `periodic_sync_state_${listId}`
    );
    if (!state) return;

    const lastSync = await this.get<string>(`last_sync_time_${listId}`);
    const token = await this.getToken(listId);
    const authActorId = await this.get<ActorId>("auth_actor_id");

    const result = await listTasks(token, listId, {
      updatedMin: lastSync ?? undefined,
      pageToken: state.pageToken ?? undefined,
      maxResults: 50,
    });

    const parentTasks: GoogleTask[] = [];
    const subtasksByParent = new Map<string, GoogleTask[]>();

    for (const task of result.tasks) {
      if (task.parent) {
        const existing = subtasksByParent.get(task.parent) ?? [];
        existing.push(task);
        subtasksByParent.set(task.parent, existing);
      } else {
        parentTasks.push(task);
      }
    }

    for (const task of parentTasks) {
      const subtasks = subtasksByParent.get(task.id) ?? [];
      const link = this.transformTask(
        task,
        listId,
        false,
        subtasks,
        authActorId
      );
      await this.tools.integrations.saveLink(link);
    }

    for (const [parentId, subtasks] of subtasksByParent) {
      if (!parentTasks.some((t) => t.id === parentId)) {
        for (const subtask of subtasks) {
          const link = this.transformTask(
            subtask,
            listId,
            false,
            [],
            authActorId
          );
          await this.tools.integrations.saveLink(link);
        }
      }
    }

    if (result.nextPageToken) {
      await this.set<PeriodicSyncState>(`periodic_sync_state_${listId}`, {
        ...state,
        pageToken: result.nextPageToken,
      });
      const next = await this.callback(this.periodicSyncBatch, listId);
      await this.tools.tasks.runTask(next);
    } else {
      // Advance lastSync to the cycle's start time so the next cycle catches
      // anything modified during this one, then schedule the next run.
      await this.clear(`periodic_sync_state_${listId}`);
      await this.set(`last_sync_time_${listId}`, state.cycleStart);
      await this.schedulePeriodicSync(listId);
    }
  }

  /**
   * Convert a Google Task to a Plot link with notes.
   */
  private transformTask(
    task: GoogleTask,
    listId: string,
    initialSync: boolean,
    subtasks: GoogleTask[],
    authActorId: ActorId | null
  ): NewLinkWithNotes {
    const source = `google-tasks:task:${task.id}`;
    const taskUrl =
      task.webViewLink ??
      `https://tasks.google.com/task/${encodeURIComponent(task.id)}`;

    const actions: Action[] = [
      {
        type: ActionType.external,
        title: "Open in Google Tasks",
        url: taskUrl,
      },
    ];

    // Build notes
    const notes: any[] = [];

    // Description note
    if (task.notes && task.notes.trim().length > 0) {
      notes.push({
        key: "description",
        content: task.notes,
        contentType: "text" as const,
      });
    }

    // Subtask notes with Todo tag
    for (const subtask of subtasks) {
      const isCompleted = subtask.status === "completed";
      notes.push({
        key: `subtask-${subtask.id}`,
        content: subtask.title,
        tags: {
          add: isCompleted
            ? [Tag.Done]
            : authActorId
            ? [{ id: authActorId }]
            : [Tag.Todo],
        },
        // For Todo tag (when not completed), also add the special Tag.Todo
        ...(isCompleted
          ? {}
          : {
              twistTags: { [Tag.Todo]: true },
            }),
      });
    }

    return {
      source,
      type: "task",
      title: task.title,
      channelId: listId,
      meta: {
        taskId: task.id,
        listId,
        syncProvider: "google-tasks",
        channelId: listId,
      },
      actions,
      sourceUrl: taskUrl,
      assignee: authActorId ? { id: authActorId } : null,
      status: task.status === "completed" ? "done" : "open",
      notes,
      preview: task.notes?.slice(0, 200) || null,
      ...(task.due
        ? {
            schedules: [
              {
                start: task.due.split("T")[0],
              },
            ],
          }
        : {}),
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Create a new Google Task from a Plot thread. The `draft.channelId`
   * is the Google Tasks list id; `draft.status` is "open" or "done".
   */
  async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "task") return null;

    const token = await this.getToken(draft.channelId);
    const authActorId = await this.get<ActorId>("auth_actor_id");

    const task = await createTask(token, draft.channelId, {
      title: draft.title,
      ...(draft.noteContent ? { notes: draft.noteContent } : {}),
      status: draft.status === "done" ? "completed" : "needsAction",
    });

    const taskUrl =
      task.webViewLink ??
      `https://tasks.google.com/task/${encodeURIComponent(task.id)}`;

    const actions: Action[] = [
      {
        type: ActionType.external,
        title: "Open in Google Tasks",
        url: taskUrl,
      },
    ];

    return {
      source: `google-tasks:task:${task.id}`,
      type: "task",
      title: task.title,
      status: draft.status,
      channelId: draft.channelId,
      meta: {
        taskId: task.id,
        listId: draft.channelId,
        syncProvider: "google-tasks",
        channelId: draft.channelId,
      },
      actions,
      sourceUrl: taskUrl,
      assignee: authActorId ? { id: authActorId } : null,
    };
  }

  /**
   * Write back link status changes to Google Tasks.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const taskId = link.meta?.taskId as string | undefined;
    const listId = link.meta?.listId as string | undefined;
    if (!taskId || !listId) return;

    const token = await this.getToken(listId);
    const isDone = link.status === "done";

    await updateTask(token, listId, taskId, {
      status: isDone ? "completed" : "needsAction",
    });
  }
}

export default GoogleTasks;
