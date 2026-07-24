import type { ActorId, JSONValue } from "@plotday/twister";

import {
  AuthenticationError,
  InvalidSyncTokenError,
  type CalDAVClient,
  type CalDAVResource,
} from "../calendar/caldav";
import { parse } from "../product-channel";
import { parseICSTodos, type ICSTodo } from "./ics-todo-parser";
import { transformTodo } from "./transform";

/**
 * `listId` throughout this file is the NAMESPACED channel id ("reminders:
 * <href>") — the same value `link.channelId`/`archiveLinks({channelId})`
 * must use to correlate with what the platform tracks as "this channel"
 * (mirrors Calendar/Mail: `link.channelId` is always namespaced, e.g. mail's
 * write-back derives `mailChannelRawId = parse(meta.channelId).rawId` at the
 * point of use rather than storing the raw mailbox name). Every actual CalDAV
 * wire call must de-namespace via this helper first — passing the namespaced
 * id straight to `CalDAVClient` would 404 against a nonexistent href.
 */
function rawHref(listId: string): string {
  return parse(listId).rawId;
}

export const REMINDERS_POLL_INTERVAL_MS = 15 * 60 * 1000;
const REMINDERS_CHUNK_SIZE = 50;

/** Per-list incremental-sync cursor state. */
export type RemindersListState = {
  /** RFC 6578 WebDAV-Sync token for the fast incremental path. Null until seeded, or after invalidation. */
  syncToken: string | null;
  /** ctag fallback cursor — consulted only when there's no (or an invalidated) sync token. */
  ctag: string | null;
  /** href -> UID, so a sync-collection delta's deleted/changed href can resolve which link to touch. */
  hrefUid: Record<string, string>;
};

/**
 * Everything the pure reminders-sync functions need from the connector.
 * Mirrors `google/src/tasks/sync.ts`'s `TasksSyncHost` — Reminders' sync
 * shape (simple list, poll-based, no time windowing) is structurally closer
 * to Google Tasks than to Calendar's two-pass windowed sync.
 */
export interface RemindersHost {
  readonly id: string;
  caldav: CalDAVClient;
  set<T>(key: string, value: T): Promise<void>;
  get<T>(key: string): Promise<T | undefined>;
  clear(key: string): Promise<void>;
  setMany<T>(entries: [key: string, value: T][]): Promise<void>;
  tools: {
    integrations: {
      saveLink(link: import("@plotday/twister").NewLinkWithNotes): Promise<string | null>;
      channelSyncCompleted(channelId: string): Promise<void>;
      archiveLinks(filter: {
        channelId?: string;
        type?: string;
        meta?: Record<string, JSONValue>;
      }): Promise<void>;
    };
  };
  scheduler: {
    /** (Re)schedule the durable recurring poll for a reminders list. */
    schedulePoll(listId: string): Promise<void>;
    /** Cancel the durable recurring poll for a reminders list. */
    cancelPoll(listId: string): Promise<void>;
    /**
     * Queue a full VTODO fetch + chunked save as a background task (mirrors
     * how the initial-enable path already queues via `runTask()`). Used for
     * every full-rescan trigger — cold start (no cursor), a lost/invalid
     * token with an unusable ctag fallback, or a ctag-detected change — so a
     * large list's rescan chunks across executions via the SAME
     * `fullSyncFn`/`processSyncChunkFn` continuation chain the initial
     * backfill uses, instead of looping synchronously inside one poll
     * execution (which would blow that execution's request budget on a
     * large list, and which a pure function has no business doing anyway —
     * scheduling stays the connector's job, per this host's whole design).
     */
    queueFullSync(listId: string, initialSync: boolean): Promise<void>;
  };
}

// ---------------------------------------------------------------------------
// Channel enable / disable
// ---------------------------------------------------------------------------

export async function onChannelEnabledFn(
  host: RemindersHost,
  listId: string,
  context?: { recovering?: boolean }
): Promise<void> {
  if (context?.recovering) {
    await host.clear(`list:${listId}`);
    await host.scheduler.cancelPoll(listId);
  }
  await host.set(`enabled:${listId}`, true);
}

export async function onChannelDisabledFn(
  host: RemindersHost,
  listId: string
): Promise<void> {
  await host.scheduler.cancelPoll(listId);
  await host.clear(`enabled:${listId}`);
  await host.clear(`list:${listId}`);
  await host.tools.integrations.archiveLinks({ channelId: listId, type: "reminder" });
}

// ---------------------------------------------------------------------------
// Full sync (one-shot fetch, chunked save) — used for initial backfill AND
// ctag-fallback full rescans.
// ---------------------------------------------------------------------------

export type PendingResource = { href: string; etag: string; todo: ICSTodo };

function parseResources(resources: CalDAVResource[]): PendingResource[] {
  const pending: PendingResource[] = [];
  for (const r of resources) {
    const [todo] = parseICSTodos(r.icsData);
    if (todo) pending.push({ href: r.href, etag: r.etag, todo });
  }
  return pending;
}

export type SyncBatchResult =
  | { next: { listId: string; remaining: PendingResource[] } }
  | { done: true };

/**
 * Fetch every VTODO in the list (CalDAV has no pagination for calendar-query;
 * the whole result set comes back in one REPORT), seed the sync-token/ctag
 * cursor, and process the first save chunk.
 */
export async function fullSyncFn(
  host: RemindersHost,
  listId: string,
  initialSync: boolean
): Promise<SyncBatchResult> {
  const resources = await host.caldav.fetchTodos(rawHref(listId));
  const pending = parseResources(resources);
  const [ctag, syncToken] = await Promise.all([
    host.caldav.getCalendarCtag(rawHref(listId)),
    host.caldav.getSyncToken(rawHref(listId)),
  ]);
  await host.set(`list:${listId}`, {
    syncToken,
    ctag,
    hrefUid: {},
  } satisfies RemindersListState);
  return processSyncChunkFn(host, listId, pending, initialSync);
}

/**
 * Save one chunk of already-fetched-and-parsed todos, splitting parents from
 * subtasks WITHIN THIS CHUNK ONLY (mirrors Google Tasks' `saveTaskPageFn`
 * same-batch-only nesting limitation) — a subtask whose parent isn't in this
 * chunk is saved standalone. `initialSync` controls unread/archived on new
 * links; pass `false` for a ctag-fallback rescan of an already-synced list.
 */
export async function processSyncChunkFn(
  host: RemindersHost,
  listId: string,
  pending: PendingResource[],
  initialSync: boolean
): Promise<SyncBatchResult> {
  const chunk = pending.slice(0, REMINDERS_CHUNK_SIZE);
  const rest = pending.slice(REMINDERS_CHUNK_SIZE);

  const parents: PendingResource[] = [];
  const subtasksByParent = new Map<string, ICSTodo[]>();
  for (const p of chunk) {
    if (p.todo.relatedTo) {
      const existing = subtasksByParent.get(p.todo.relatedTo) ?? [];
      existing.push(p.todo);
      subtasksByParent.set(p.todo.relatedTo, existing);
    } else {
      parents.push(p);
    }
  }

  const state = (await host.get<RemindersListState>(`list:${listId}`)) ?? {
    syncToken: null,
    ctag: null,
    hrefUid: {},
  };
  const authActorId = (await host.get<ActorId>("auth_actor_id")) ?? null;

  for (const { href, todo } of parents) {
    const subtasks = subtasksByParent.get(todo.uid) ?? [];
    await saveOrArchiveTodo(host, listId, todo, initialSync, subtasks, authActorId);
    state.hrefUid[href] = todo.uid;
  }

  for (const [parentUid, subtasks] of subtasksByParent) {
    if (parents.some((p) => p.todo.uid === parentUid)) continue;
    for (const subtask of subtasks) {
      const resource = chunk.find((p) => p.todo.uid === subtask.uid);
      if (!resource) continue;
      await saveOrArchiveTodo(host, listId, subtask, initialSync, [], authActorId);
      state.hrefUid[resource.href] = subtask.uid;
    }
  }

  await host.set(`list:${listId}`, state);

  if (rest.length > 0) return { next: { listId, remaining: rest } };

  if (initialSync) await host.tools.integrations.channelSyncCompleted(listId);
  return { done: true };
}

async function saveOrArchiveTodo(
  host: RemindersHost,
  listId: string,
  todo: ICSTodo,
  initialSync: boolean,
  subtasks: ICSTodo[],
  authActorId: ActorId | null
): Promise<void> {
  const link = transformTodo(todo, listId, initialSync, subtasks, authActorId);
  if (link) {
    await host.tools.integrations.saveLink(link);
  } else {
    // CANCELLED — archive rather than upsert. See transformTodo's doc.
    await host.tools.integrations.archiveLinks({
      channelId: listId,
      type: "reminder",
      meta: { todoUid: todo.uid },
    });
  }
}

// ---------------------------------------------------------------------------
// Incremental poll
// ---------------------------------------------------------------------------

/**
 * Poll a reminders list for changes: the RFC 6578 WebDAV-Sync fast path when
 * a sync token is trusted, falling back to a ctag-diff check (never removed)
 * when there's no token or the server rejected it as invalid/expired.
 * Mirrors Calendar's proven design, including the Batch-7 fix of never
 * re-checking ctag once a sync token is in play — the fast-path REPORT
 * already IS the O(1) change check.
 *
 * Every full-rescan trigger below routes through `host.scheduler.queueFullSync`
 * rather than calling `fullSyncFn` inline. This is load-bearing, not a style
 * preference: `fullSyncFn` seeds a FRESH sync token/ctag from a REPORT taken
 * after the full fetch, so if this function only saved the first chunk and
 * returned, every later incremental poll would take the fast path against
 * that fresh token and correctly report "nothing changed" — permanently
 * hiding whatever the chunker didn't get to. Queuing lets a large list's
 * rescan chunk across executions via the SAME `remindersInit`/
 * `remindersSyncBatch` continuation chain the initial backfill already uses.
 */
export async function pollFn(host: RemindersHost, listId: string): Promise<void> {
  const enabled = await host.get<boolean>(`enabled:${listId}`);
  if (!enabled) {
    await host.scheduler.cancelPoll(listId);
    return;
  }

  const state = await host.get<RemindersListState>(`list:${listId}`);
  if (!state) {
    // No cursor at all — treat as a fresh/recovery backfill (mirrors
    // Calendar's `recovering` semantics) so a flood of already-existing
    // reminders doesn't surface as freshly-unread.
    await host.scheduler.queueFullSync(listId, true);
    return;
  }

  if (state.syncToken) {
    try {
      const delta = await host.caldav.getCollectionChanges(rawHref(listId), state.syncToken);
      await applyDelta(host, listId, state, delta);
      await host.scheduler.schedulePoll(listId);
      return;
    } catch (error) {
      if (error instanceof InvalidSyncTokenError) {
        await host.set(`list:${listId}`, { ...state, syncToken: null });
        state.syncToken = null; // fall through to the ctag fallback below
      } else if (error instanceof AuthenticationError) {
        console.error(`Reminders auth error for list ${listId}:`, error);
        await host.scheduler.schedulePoll(listId);
        return;
      } else {
        throw error;
      }
    }
  }

  const ctag = await host.caldav.getCalendarCtag(rawHref(listId));
  if (ctag && ctag === state.ctag) {
    await host.scheduler.schedulePoll(listId);
    return; // Nothing changed since the last pass.
  }

  // Something changed since last ctag — queue a full rescan (chunked,
  // non-initial: preserves already-synced items' read/archived state).
  await host.scheduler.queueFullSync(listId, false);
}

/**
 * Apply one WebDAV-Sync delta: archive deletions, save/archive changes.
 *
 * KNOWN LIMITATION (documented, not fixed here): does not re-derive the
 * whole list's parent/subtask graph — a changed subtask (or a change to an
 * item that has subtasks) is saved/archived as its own standalone item.
 * Nesting is only fully accurate immediately after a full sync. See the
 * design spec.
 */
async function applyDelta(
  host: RemindersHost,
  listId: string,
  state: RemindersListState,
  delta: {
    token: string;
    changed: { href: string; etag: string }[];
    deletedHrefs: string[];
  }
): Promise<void> {
  const nextState: RemindersListState = {
    ...state,
    syncToken: delta.token,
    hrefUid: { ...state.hrefUid },
  };

  for (const href of delta.deletedHrefs) {
    const uid = nextState.hrefUid[href];
    if (uid) {
      await host.tools.integrations.archiveLinks({
        channelId: listId,
        type: "reminder",
        meta: { todoUid: uid },
      });
      delete nextState.hrefUid[href];
    }
  }

  if (delta.changed.length > 0) {
    const resources = await host.caldav.fetchEventsByHref(
      rawHref(listId),
      delta.changed.map((c) => c.href)
    );
    const pending = parseResources(resources);
    const authActorId = (await host.get<ActorId>("auth_actor_id")) ?? null;

    for (const { href, todo } of pending) {
      await saveOrArchiveTodo(host, listId, todo, false, [], authActorId);
      nextState.hrefUid[href] = todo.uid;
    }
  }

  await host.set(`list:${listId}`, nextState);
}
