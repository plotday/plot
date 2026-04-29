import type { Context } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../../env";

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 1000;

const ALLOWED_SORT_COLUMNS = new Set(["created_at", "updated_at", "activity_at", "agenda_at"]);

/**
 * Build a WHERE clause for the new seq-based incremental sync cursor.
 *
 * `seq` is `xid8` (writing transaction's `pg_current_xact_id()`). The cursor
 * has two pieces:
 *   - `seqSince`  — last horizon advanced past (xid8 as decimal string).
 *                   Filter returns rows in [seqSince, new_horizon).
 *   - `pageSeq`/`pageId` — within-pull pagination tiebreaker. NULL on the
 *                   first page; advances to the (seq, id) of the last row
 *                   returned on subsequent pages.
 *
 * The watermark (`new_horizon`) is `pg_snapshot_xmin(pg_current_snapshot())`,
 * the xid of the oldest in-progress write transaction; anything with
 * `seq < new_horizon` is guaranteed committed and visible to our snapshot.
 *
 * Unlike the legacy `updated_at` cursor, this filter cannot skip rows from
 * long-running transactions: their seq sits at-or-above the horizon while
 * they are in-flight, and re-enters [last_horizon, new_horizon) the moment
 * they commit.
 */
export function seqSinceCursor(
  seqSince: string,
  pageSeq: string | null,
  pageId: string | null,
  cursorIdColumn: string = "id",
) {
  const horizon = sql`seq < pg_snapshot_xmin(pg_current_snapshot())`;
  const lower = sql`seq >= ${seqSince}::xid8`;
  if (pageSeq && pageId) {
    return sql<boolean>`(${horizon} AND ${lower} AND (seq, ${sql.ref(cursorIdColumn)}) > (${pageSeq}::xid8, ${pageId}))`;
  }
  if (pageSeq) {
    return sql<boolean>`(${horizon} AND ${lower} AND seq > ${pageSeq}::xid8)`;
  }
  return sql<boolean>`(${horizon} AND ${lower})`;
}

/** Reads the safe horizon (xid8) inside the current transaction snapshot. */
export async function readSafeHorizon(trx: { execute: (q: any) => any } | any): Promise<string> {
  const result = await sql<{ horizon: string }>`SELECT pg_snapshot_xmin(pg_current_snapshot())::text AS horizon`.execute(trx);
  return result.rows[0]?.horizon ?? "0";
}

/**
 * Build a WHERE clause for cursor-based pagination on updated_at.
 *
 * Uses date_trunc('milliseconds', ...) because JavaScript Date (used by the
 * pg driver) has only millisecond precision. Without truncation, Postgres's
 * microsecond-precision `updated_at > cursor` always matches the same rows
 * (e.g. .220123 > .220000 = true), causing infinite sync loops.
 *
 * @param cursorIdColumn - The secondary cursor column name (e.g. 'id', 'priority_id')
 */
export function updatedSinceCursor(
  updatedSince: string,
  cursorId: string | null,
  cursorIdColumn: string = "id"
) {
  if (cursorId) {
    return sql<boolean>`(date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz OR (date_trunc('milliseconds', updated_at) = ${updatedSince}::timestamptz AND ${sql.ref(cursorIdColumn)} > ${cursorId}))`;
  }
  return sql<boolean>`date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz`;
}

export interface ReadParams {
  updatedSince: string | null;
  cursorId: string | null;
  /** New seq-based cursor (xid8 decimal string). When present, takes precedence over updatedSince. */
  seqSince: string | null;
  /** Within-pull pagination tiebreaker (xid8 decimal string), set by server in next_page. */
  pageSeq: string | null;
  /** Within-pull pagination tiebreaker (uuid), set by server in next_page. */
  pageId: string | null;
  archived: boolean | undefined;
  limit: number;
  priorityId: string | null;
  priorityPath: string | null;
  threadId: string | null;
  rangeStart: string | null;
  rangeEnd: string | null;
  initial: boolean;
  id: string | null;
  sortBy: string;
  sortDir: "asc" | "desc";
}

export function parseReadParams(c: Context<{ Bindings: Bindings }>): ReadParams {
  const limitRaw = c.req.query("limit");
  const limit = limitRaw
    ? Math.min(Math.max(1, parseInt(limitRaw, 10) || DEFAULT_LIMIT), MAX_LIMIT)
    : DEFAULT_LIMIT;

  const archivedRaw = c.req.query("archived");
  const archived =
    archivedRaw === "true" ? true : archivedRaw === "false" ? false : undefined;

  const sortByRaw = c.req.query("sort_by");
  const sortBy = sortByRaw && ALLOWED_SORT_COLUMNS.has(sortByRaw) ? sortByRaw : "updated_at";
  const sortDirRaw = c.req.query("sort_dir");
  const sortDir = sortDirRaw === "desc" ? "desc" : "asc";

  return {
    updatedSince: c.req.query("updated_since") || null,
    cursorId: c.req.query("cursor_id") || null,
    seqSince: c.req.query("seq_since") || null,
    pageSeq: c.req.query("page_seq") || null,
    pageId: c.req.query("page_id") || null,
    archived,
    limit,
    priorityId: c.req.query("priority_id") || null,
    priorityPath: c.req.query("priority_path") || null,
    threadId: c.req.query("thread_id") || null,
    rangeStart: c.req.query("range_start") || null,
    rangeEnd: c.req.query("range_end") || null,
    initial: c.req.query("initial") === "true",
    id: c.req.query("id") || null,
    sortBy,
    sortDir,
  };
}

/**
 * Build the response envelope for a seq-based pull. New clients (those that
 * sent `?seq_since=...`) get `{rows, next_page, next_horizon}`; old clients
 * still get a bare array (callers branch on whether `seqSince` was provided).
 *
 * `next_page` is null when the server returned fewer rows than `limit`,
 * signalling the client that this pull is complete and it's safe to advance
 * `last_horizon` to `next_horizon`.
 */
export function seqEnvelope<T extends { id: string; seq: string }>(
  rows: T[],
  limit: number,
  horizon: string,
): { rows: T[]; next_page: { seq: string; id: string } | null; next_horizon: string } {
  const last = rows[rows.length - 1];
  const more = rows.length >= limit && last !== undefined;
  return {
    rows,
    next_page: more ? { seq: String(last.seq), id: String(last.id) } : null,
    next_horizon: horizon,
  };
}
