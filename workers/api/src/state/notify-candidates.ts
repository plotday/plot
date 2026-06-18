import { sql, type Kysely } from "kysely";

import type { DB } from "../db";

/** Importance below this value never triggers a push or scheduling on its own. */
export const IMPORTANCE_NOTIFY_THRESHOLD = 50;

/** One unread thread eligible to wake the user's clients with a push. */
export type NotifyCandidate = {
  thread_id: string;
  urgent: boolean;
};

/**
 * Select the unread threads that are currently eligible to wake the user's
 * clients (data-only `sync_wake`). Shared by both PushNotify candidate checks
 * (handleNotify's "is there anything / is any urgent" and the alarm's
 * "are there still candidates") so the eligibility predicate lives in one place.
 *
 * Eligibility mirrors the notification-content query (the device fetches that
 * for display): unread, importance >= threshold OR urgent, not muted, visible,
 * not in the muted FYI focus, and not already suppressed by either the
 * per-focus high-water mark (priority.notification_cleared_at) or the
 * per-thread high-water mark (thread_notify_state.notified_at).
 *
 * The per-thread mark is what makes a moved thread stay quiet: a move bumps
 * thread_priority (re-filing it under a possibly-uncleared focus) but NOT
 * thread_state, so ts.updated_at does not advance past the mark and the thread
 * is suppressed. A genuine reply bumps ts.updated_at and re-qualifies.
 *
 * `db` may be a Kysely instance or a transaction handle.
 */
export async function selectNotifyCandidates(
  db: Kysely<DB>,
  userId: string
): Promise<NotifyCandidate[]> {
  const result = await sql<NotifyCandidate>`
    SELECT t.id::text AS thread_id, ts.urgent
    FROM thread_state ts
    JOIN thread t ON t.id = ts.thread_id
    JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
    JOIN priority p ON p.id = tp.priority_id
    JOIN priority focus ON focus.user_id = p.user_id
      AND focus.path = subpath(p.path, 0, LEAST(2, nlevel(p.path)))
    -- Per-thread notification high-water mark; follows the thread across moves.
    LEFT JOIN public.thread_notify_state tns
      ON tns.user_id = ts.user_id AND tns.thread_id = t.id
    WHERE ts.user_id = ${userId}::uuid
      AND ts.read_at IS NULL
      AND (ts.importance >= ${IMPORTANCE_NOTIFY_THRESHOLD} OR ts.urgent = TRUE)
      -- Skip muted threads (seed + every thread matched to the rule). A new
      -- reply re-marks a muted thread unread, so read-state suppression alone
      -- would let it wake the client.
      AND tp.mute_by_thread_id IS NULL
      -- Per-focus re-notify suppression (does NOT follow a thread across moves).
      AND (
        focus.notification_cleared_at IS NULL
        OR date_trunc('milliseconds', ts.updated_at) > focus.notification_cleared_at
      )
      -- Per-thread re-notify suppression (follows a thread across focus moves):
      -- a thread already notified at its current content version is not re-woken
      -- just because it moved to an uncleared focus.
      AND (
        tns.notified_at IS NULL
        OR date_trunc('milliseconds', ts.updated_at) > tns.notified_at
      )
      -- FYI is a muted, low-signal focus — never wake the client for it.
      AND focus.is_fyi = FALSE
      AND t.archived_at IS NULL
      AND (t.draft = false OR t.created_by = ${userId}::uuid)
      AND (
        t.contacts && "user".user_contact_ids(${userId}::uuid)
        OR t.groups && "user".user_group_ids(${userId}::uuid)
      )
  `.execute(db);
  return result.rows;
}

/**
 * Of the given thread IDs, return the subset that is NOT yet suppressed by the
 * per-thread notification mark — i.e. eligible to be (re-)notified. Used by
 * /notification-summary, which is handed a client-built batch and must drop
 * threads the user was already notified about (e.g. one they moved to another
 * focus) before summarizing. Same gate as selectNotifyCandidates; scoped to the
 * caller's own thread_state rows, so unknown/foreign IDs simply don't return.
 */
export async function selectUnsuppressedThreadIds(
  db: Kysely<DB>,
  userId: string,
  threadIds: string[]
): Promise<Set<string>> {
  if (threadIds.length === 0) return new Set();
  const idList = sql.join(threadIds.map((id) => sql`${id}::uuid`));
  const result = await sql<{ thread_id: string }>`
    SELECT t.id::text AS thread_id
    FROM thread_state ts
    JOIN thread t ON t.id = ts.thread_id
    LEFT JOIN public.thread_notify_state tns
      ON tns.user_id = ts.user_id AND tns.thread_id = ts.thread_id
    WHERE ts.user_id = ${userId}::uuid
      AND ts.thread_id IN (${idList})
      AND (
        tns.notified_at IS NULL
        OR date_trunc('milliseconds', ts.updated_at) > tns.notified_at
      )
  `.execute(db);
  return new Set(result.rows.map((r) => r.thread_id));
}

/**
 * Advance the per-thread notification high-water mark for the given threads to
 * their current thread_state.updated_at. Call after deciding to show a
 * notification for them, so a later wake/summary (or a move to another focus)
 * does not re-announce the same content. Stamps directly from thread_state in
 * SQL (no JS round-trip), and GREATEST-guards against an older value racing in.
 */
export async function stampThreadsNotified(
  db: Kysely<DB>,
  userId: string,
  threadIds: string[]
): Promise<void> {
  if (threadIds.length === 0) return;
  const idList = sql.join(threadIds.map((id) => sql`${id}::uuid`));
  await sql`
    INSERT INTO thread_notify_state (user_id, thread_id, notified_at)
    SELECT ts.user_id, ts.thread_id, ts.updated_at
    FROM thread_state ts
    WHERE ts.user_id = ${userId}::uuid
      AND ts.thread_id IN (${idList})
    ON CONFLICT (user_id, thread_id) DO UPDATE
      SET notified_at = GREATEST(thread_notify_state.notified_at, EXCLUDED.notified_at)
  `.execute(db);
}

/** Author context for laying out a notification: the thread originator, the
 * authors of currently-unread notes (the repliers), and whether the user has
 * read the thread before. */
export type NotificationAuthors = {
  original_author_name: string | null;
  unread_author_names: string | null;
  has_been_read: boolean;
};

/**
 * Resolve notification author context for a set of threads, keyed by thread id.
 *
 * The foreground push path (`/notification-summary`) builds its batches from
 * the client's local data, which carries no author — so it calls this to fill
 * in the same author fields `/notification-content` computes inline, keeping
 * both paths' notification layout identical. `original_author_name` is the
 * thread's credited author (now the human sender, not the connection — see
 * `selectThreadAuthorSpec`), with the first note's author as a legacy fallback
 * for any pre-backfill thread whose `author_id` was never set.
 *
 * `db` may be a Kysely instance or a transaction handle.
 */
export async function loadNotificationAuthors(
  db: Kysely<DB>,
  userId: string,
  threadIds: string[]
): Promise<Map<string, NotificationAuthors>> {
  const map = new Map<string, NotificationAuthors>();
  if (threadIds.length === 0) return map;
  const idList = sql.join(threadIds.map((id) => sql`${id}::uuid`));
  const result = await sql<{
    thread_id: string;
    original_author_name: string | null;
    unread_author_names: string | null;
    has_been_read: boolean;
  }>`
    SELECT
      t.id::text AS thread_id,
      EXISTS (
        SELECT 1 FROM thread_read tr
        WHERE tr.thread_id = t.id AND tr.user_id = ${userId}::uuid
      ) AS has_been_read,
      (
        SELECT a.name FROM actor a
        WHERE a.id = COALESCE(
          t.author_id,
          (
            SELECT n.author_id FROM note n
            WHERE n.thread_id = t.id AND n.archived_at IS NULL
            ORDER BY n.created_at ASC LIMIT 1
          )
        )
      ) AS original_author_name,
      (
        SELECT string_agg(DISTINCT COALESCE(a.name, 'Someone'), ',')
        FROM note n
        JOIN actor a ON a.id = n.author_id
        LEFT JOIN thread_read tr ON tr.thread_id = t.id AND tr.user_id = ${userId}::uuid
        WHERE n.thread_id = t.id
          AND n.archived_at IS NULL
          AND n.draft = false
          AND NOT (n.author_id = ANY("user".user_contact_ids(${userId}::uuid)))
          AND (tr.read_at IS NULL OR n.created_at > tr.read_at)
      ) AS unread_author_names
    FROM thread t
    WHERE t.id IN (${idList})
  `.execute(db);
  for (const row of result.rows) {
    map.set(row.thread_id, {
      original_author_name: row.original_author_name,
      unread_author_names: row.unread_author_names,
      has_been_read: row.has_been_read,
    });
  }
  return map;
}
