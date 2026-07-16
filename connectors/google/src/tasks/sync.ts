/**
 * Reusable Google Tasks sync functions extracted from the GoogleTasks connector.
 *
 * These functions implement the per-list initial backfill, the periodic
 * polling cycle (Google Tasks has no push/webhooks), and the outbound
 * create/update write-back — without any connector-level scheduling. They
 * accept a {@link TasksSyncHost} instead of `this` so they can be invoked from
 * both the standalone GoogleTasks connector and the combined Google connector
 * (which wraps `this` in a key-namespaced host).
 *
 * Scheduler operations (this.callback / this.tools.tasks.runTask /
 * this.tools.tasks.scheduleRecurring / this.tools.tasks.cancelScheduledTask)
 * are intentionally NOT performed inline. Where a function genuinely needs to
 * schedule work, it either returns a descriptor and lets the caller own the
 * scheduling, or it invokes `host.scheduler.*` — a thin set of bound references
 * back to the concrete connector's instance methods — so the connector stays
 * the single owner of scheduling.
 */

import {
  type Action,
  ActionType,
  type Link,
  type NewLinkWithNotes,
  type ActorId,
} from "@plotday/twister";
import { Tag } from "@plotday/twister/tag";
import type { CreateLinkDraft } from "@plotday/twister/connector";

import {
  createTask,
  isNotFoundError,
  listTasks,
  updateTask,
  type GoogleTask,
} from "./api";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** 5 minutes in milliseconds. */
export const POLL_INTERVAL_MS = 5 * 60 * 1000;

/** Recurring-poll cadence (1h). The first run is offset by POLL_INTERVAL_MS. */
export const POLL_RECURRING_INTERVAL_MS = 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Persisted state shapes (shared with the connector)
// ---------------------------------------------------------------------------

export type SyncState = {
  pageToken: string | null;
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
  syncHistoryMin?: string;
};

export type PeriodicSyncState = {
  pageToken: string | null;
  /** ISO timestamp captured at the start of the cycle. Becomes the next
   * `last_sync_time_<listId>` once every page in the cycle has been processed,
   * so the following cycle picks up anything modified during this one. */
  cycleStart: string;
};

// ---------------------------------------------------------------------------
// Host interface
// ---------------------------------------------------------------------------

/**
 * Minimal interface that a Google Tasks sync host must satisfy. Both
 * GoogleTasks (using `this` directly via public wrappers) and the combined
 * Google connector (using a key-namespaced host) implement this.
 *
 * `scheduler` carries the operations that CANNOT be extracted — creating
 * callbacks and scheduling/cancelling tasks live on the concrete connector
 * (they reference its own callback methods and durable-task keys). Extracted
 * functions invoke them through these bound references so the connector stays
 * the single owner of scheduling.
 */
export interface TasksSyncHost {
  /** The twist-instance id, used purely for log context. */
  readonly id: string;

  /** Persist a value under a connector-scoped key. */
  set(key: string, value: unknown): Promise<void>;
  /** Retrieve a previously persisted value. Returns null if absent. */
  get<T>(key: string): Promise<T | null>;
  /** Delete a persisted value. */
  clear(key: string): Promise<void>;

  tools: {
    integrations: {
      /** Read the OAuth token for a channel (task list). */
      get(
        channelId: string
      ): Promise<{ token: string; scopes: string[] } | null>;
      /** Persist a link (upsert by source). Returns the saved thread id (or null if filtered). */
      saveLink(link: NewLinkWithNotes): Promise<string | null>;
      /** Signal that the initial backfill for a channel has finished. */
      channelSyncCompleted(channelId: string): Promise<void>;
      /** Archive every link previously synced for a channel. */
      archiveLinks(filter: { channelId?: string; type?: string }): Promise<void>;
    };
  };

  /**
   * Scheduler boundary — operations that must stay on the concrete connector.
   * These route to the connector's own instance methods, so extracting the
   * logic that calls them does not move scheduling off the connector.
   */
  scheduler: {
    /** Queue the per-list initial backfill batch as a fresh task. */
    queueSyncBatch(listId: string): Promise<void>;
    /** Queue the next periodic-sync page as a fresh task. */
    queuePeriodicSyncBatch(listId: string): Promise<void>;
    /** (Re)schedule the durable recurring poll for a task list. */
    schedulePeriodicSync(listId: string): Promise<void>;
    /** Cancel the durable recurring poll for a task list. */
    cancelScheduledTask(key: string): Promise<void>;
  };
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

/**
 * Get an access token for a channel (task list).
 * Throws if the token is absent.
 */
export async function getTokenFn(
  host: TasksSyncHost,
  channelId: string
): Promise<string> {
  const token = await host.tools.integrations.get(channelId);
  if (!token) {
    throw new Error("No Google Tasks authentication token available");
  }
  return token.token;
}

// ---------------------------------------------------------------------------
// Channel enable / disable (data-plane state)
// ---------------------------------------------------------------------------

/**
 * Return type for {@link onChannelEnabledFn}.
 *
 * - `start`: seed the initial-backfill cursor and start syncing this list.
 * - `skip`: nothing to do (already synced with an equal/wider range).
 */
export type ChannelEnableResult =
  | { start: { listId: string; syncHistoryMin?: Date } }
  | { skip: true };

/**
 * Decide whether a newly-enabled channel (task list) needs syncing and seed
 * the persisted state. Returns a descriptor telling the caller whether to kick
 * off the initial backfill + periodic poll; the caller owns the scheduling.
 *
 * Mirrors the original `onChannelEnabled` body: it short-circuits when a prior
 * sync already covered an equal-or-wider `syncHistoryMin` (unless recovering),
 * records the new window, marks the channel enabled, and seeds `sync_state`.
 */
export async function onChannelEnabledFn(
  host: TasksSyncHost,
  channelId: string,
  context?: { syncHistoryMin?: Date; recovering?: boolean }
): Promise<ChannelEnableResult> {
  // Check if we've already synced with a wider or equal range
  const syncHistoryMin = context?.syncHistoryMin;
  if (syncHistoryMin) {
    const storedMin = await host.get<string>(`sync_history_min_${channelId}`);
    if (
      storedMin &&
      new Date(storedMin) <= syncHistoryMin &&
      !context?.recovering
    ) {
      return { skip: true }; // Already synced with wider range
    }
    await host.set(
      `sync_history_min_${channelId}`,
      syncHistoryMin.toISOString()
    );
  }

  await host.set(`sync_enabled_${channelId}`, true);

  // Seed the initial-backfill cursor (was startBatchSync's first half).
  await host.set(`sync_state_${channelId}`, {
    pageToken: null,
    batchNumber: 1,
    tasksProcessed: 0,
    initialSync: true,
    ...(syncHistoryMin
      ? { syncHistoryMin: syncHistoryMin.toISOString() }
      : {}),
  } satisfies SyncState);

  return { start: { listId: channelId, syncHistoryMin } };
}

/**
 * Tear down all per-channel state for a disabled task list and archive its
 * synced links. The recurring poll cancellation routes through
 * `host.scheduler`; everything else is data-plane.
 */
export async function onChannelDisabledFn(
  host: TasksSyncHost,
  channelId: string
): Promise<void> {
  // Cancel the recurring poll so it stops once the channel is disabled
  // (keyed singleton — no stored token to chase).
  await host.scheduler.cancelScheduledTask(`poll:${channelId}`);

  await host.clear(`sync_enabled_${channelId}`);
  await host.clear(`sync_state_${channelId}`);
  await host.clear(`periodic_sync_state_${channelId}`);
  await host.clear(`last_sync_time_${channelId}`);

  await host.tools.integrations.archiveLinks({ channelId });
}

// ---------------------------------------------------------------------------
// Sync state machine
// ---------------------------------------------------------------------------

/**
 * Return type for {@link syncBatchFn}.
 *
 * - `next`: more pages remain; the caller schedules another initial-backfill
 *   batch for `listId`.
 * - `done`: backfill complete; nothing more to schedule.
 */
export type SyncBatchResult = { next: { listId: string } } | { done: true };

/**
 * Per-list initial backfill. Walks `tasks.list?showCompleted=false` paginated
 * and processes results. Used the FIRST time a channel is enabled; ongoing
 * changes flow through {@link periodicSyncBatchFn} instead.
 *
 * Returns `{ next }` when more pages remain (caller schedules the next batch)
 * and `{ done: true }` when the backfill is complete.
 */
export async function syncBatchFn(
  host: TasksSyncHost,
  listId: string
): Promise<SyncBatchResult> {
  const state = await host.get<SyncState>(`sync_state_${listId}`);
  if (!state) {
    throw new Error(`Sync state not found for list ${listId}`);
  }

  const token = await getTokenFn(host, listId);
  const authActorId = await host.get<ActorId>("auth_actor_id");

  // Fetch batch of tasks
  let result;
  try {
    result = await listTasks(token, listId, {
      showCompleted: false,
      pageToken: state.pageToken ?? undefined,
      maxResults: 50,
      updatedMin: state.syncHistoryMin ?? undefined,
    });
  } catch (error) {
    if (isNotFoundError(error)) {
      // The task list was deleted on Google's side while still enabled in
      // Plot. A 404 here is permanent, so tear the channel down exactly like a
      // disable (cancel the poll, clear state, archive its links) instead of
      // throwing — otherwise every retry pages error tracking and the message
      // eventually dead-letters.
      await onChannelDisabledFn(host, listId);
      return { done: true };
    }
    throw error;
  }

  await saveTaskPageFn(host, result.tasks, listId, state.initialSync, authActorId);

  // Continue to next page if available
  if (result.nextPageToken) {
    await host.set(`sync_state_${listId}`, {
      pageToken: result.nextPageToken,
      batchNumber: state.batchNumber + 1,
      tasksProcessed: state.tasksProcessed + result.tasks.length,
      initialSync: state.initialSync,
    } satisfies SyncState);
    return { next: { listId } };
  } else {
    // Initial sync is complete - cleanup sync state and set last sync time
    await host.clear(`sync_state_${listId}`);
    await host.set(`last_sync_time_${listId}`, new Date().toISOString());
    return { done: true };
  }
}

/**
 * Periodic sync entry point: starts a new cycle (records `cycleStart`) and
 * returns whether the caller should hand off to {@link periodicSyncBatchFn}.
 * Returns `false` when the channel was disabled between scheduling and run.
 */
export async function periodicSyncFn(
  host: TasksSyncHost,
  listId: string
): Promise<boolean> {
  const enabled = await host.get<boolean>(`sync_enabled_${listId}`);
  if (!enabled) return false;

  await host.set(`periodic_sync_state_${listId}`, {
    pageToken: null,
    cycleStart: new Date().toISOString(),
  } satisfies PeriodicSyncState);

  return true;
}

/**
 * Return type for {@link periodicSyncBatchFn}.
 *
 * - `next`: another page remains in this cycle; the caller schedules the next
 *   periodic-sync batch for `listId`.
 * - `reschedule`: the cycle finished; the caller (re)schedules the next
 *   recurring poll for `listId`.
 * - `done`: nothing to do (channel disabled, or no cycle state).
 */
export type PeriodicSyncBatchResult =
  | { next: { listId: string } }
  | { reschedule: { listId: string } }
  | { done: true };

/**
 * Process a single page of incremental updates and report whether the caller
 * should chain to the next page or finish the cycle and reschedule the next
 * periodic run.
 */
export async function periodicSyncBatchFn(
  host: TasksSyncHost,
  listId: string
): Promise<PeriodicSyncBatchResult> {
  const enabled = await host.get<boolean>(`sync_enabled_${listId}`);
  if (!enabled) {
    await host.clear(`periodic_sync_state_${listId}`);
    return { done: true };
  }

  const state = await host.get<PeriodicSyncState>(
    `periodic_sync_state_${listId}`
  );
  if (!state) return { done: true };

  const lastSync = await host.get<string>(`last_sync_time_${listId}`);
  const token = await getTokenFn(host, listId);
  const authActorId = await host.get<ActorId>("auth_actor_id");

  let result;
  try {
    result = await listTasks(token, listId, {
      updatedMin: lastSync ?? undefined,
      pageToken: state.pageToken ?? undefined,
      maxResults: 50,
    });
  } catch (error) {
    if (isNotFoundError(error)) {
      // List deleted on Google's side — stop polling it for good. Tearing down
      // here (cancel poll, clear state, archive links) matches the disable path
      // and prevents the hourly poll from re-throwing the same 404 forever.
      await onChannelDisabledFn(host, listId);
      return { done: true };
    }
    throw error;
  }

  await saveTaskPageFn(host, result.tasks, listId, false, authActorId);

  if (result.nextPageToken) {
    await host.set(`periodic_sync_state_${listId}`, {
      ...state,
      pageToken: result.nextPageToken,
    } satisfies PeriodicSyncState);
    return { next: { listId } };
  } else {
    // Advance lastSync to the cycle's start time so the next cycle catches
    // anything modified during this one, then schedule the next run.
    await host.clear(`periodic_sync_state_${listId}`);
    await host.set(`last_sync_time_${listId}`, state.cycleStart);
    return { reschedule: { listId } };
  }
}

/**
 * Split a page of tasks into parents + subtasks and upsert each as a Plot
 * link. Shared verbatim between the initial backfill and the periodic cycle.
 *
 * Parent tasks carry their subtasks as Todo/Done-tagged notes; subtasks whose
 * parents are absent from this page are saved as standalone tasks.
 */
export async function saveTaskPageFn(
  host: TasksSyncHost,
  tasks: GoogleTask[],
  listId: string,
  initialSync: boolean,
  authActorId: ActorId | null
): Promise<void> {
  // Separate parent tasks and subtasks
  const parentTasks: GoogleTask[] = [];
  const subtasksByParent = new Map<string, GoogleTask[]>();

  for (const task of tasks) {
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
    const link = transformTask(task, listId, initialSync, subtasks, authActorId);
    await host.tools.integrations.saveLink(link);
  }

  // Handle subtasks whose parents weren't in this batch
  for (const [parentId, subtasks] of subtasksByParent) {
    if (!parentTasks.some((t) => t.id === parentId)) {
      // Save subtasks as standalone tasks
      for (const subtask of subtasks) {
        const link = transformTask(subtask, listId, initialSync, [], authActorId);
        await host.tools.integrations.saveLink(link);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Transform
// ---------------------------------------------------------------------------

/**
 * Convert a Google Task to a Plot link with notes.
 */
export function transformTask(
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
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
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
    // The Google Tasks API exposes no creation timestamp, so use `updated` as
    // the link's source time. The link upsert sets source_created_at on INSERT
    // only (ON CONFLICT never overwrites it), so this is captured once at first
    // import and does NOT drift forward when the task is later edited — the
    // thread keeps sorting at the task's original import time, not "just now".
    created: new Date(task.updated),
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
    // Google Tasks are the user's personal to-dos, never calendar events:
    // surface an open task as the connection owner's to-do (per-user
    // thread_state), with the due date as its to-do date when present. A
    // link `schedules` entry is wrong here — it creates a *shared* schedule
    // with calendar-event semantics, which renders the task in the agenda.
    // Completed tasks need nothing: the "done" status already clears the
    // assignee's to-do state via the platform's done-status handling.
    ...(task.status !== "completed"
      ? {
          todo: true,
          ...(task.due ? { todoDate: task.due.split("T")[0] } : {}),
        }
      : {}),
    ...(initialSync ? { unread: false } : {}),
    ...(initialSync ? { archived: false } : {}),
  };
}

// ---------------------------------------------------------------------------
// Outbound: create / update
// ---------------------------------------------------------------------------

/**
 * Create a new Google Task from a Plot thread. The `draft.channelId`
 * is the Google Tasks list id; `draft.status` is "open" or "done".
 *
 * Returns `null` for any non-`task` draft so the combined Google connector can
 * route `onCreateLink` across Mail + Tasks by type without double-handling.
 */
export async function onCreateLinkFn(
  host: TasksSyncHost,
  draft: CreateLinkDraft
): Promise<NewLinkWithNotes | null> {
  if (draft.type !== "task") return null;

  const token = await getTokenFn(host, draft.channelId);
  const authActorId = await host.get<ActorId>("auth_actor_id");

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
 * Write back link status changes to Google Tasks. No-ops for links that carry
 * no `taskId`/`listId` meta (i.e. links this connector didn't create).
 */
export async function onLinkUpdatedFn(
  host: TasksSyncHost,
  link: Link
): Promise<void> {
  const taskId = link.meta?.taskId as string | undefined;
  const listId = link.meta?.listId as string | undefined;
  if (!taskId || !listId) return;

  const token = await getTokenFn(host, listId);
  const isDone = link.status === "done";

  try {
    await updateTask(token, listId, taskId, {
      status: isDone ? "completed" : "needsAction",
    });
  } catch (error) {
    // The task or its list was deleted on Google's side — there is nothing to
    // write back. A 404 is permanent, so swallow it rather than throwing
    // (which would retry on the queue and eventually page / dead-letter).
    if (isNotFoundError(error)) return;
    throw error;
  }
}
