import { Hono } from "hono";

import type { Kysely } from "../../db";
import { sql, withUserDb } from "../../db";
import type { DB } from "../../db-types";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
} from "./helpers";
import { notifySync, getPriorityForThread } from "./notify";
import { stripAnnounceTagActors } from "./viewer";

const threadTags = new Hono<{ Bindings: Bindings }>();

// GET /sync/thread-tags
threadTags.get("/sync/thread-tags", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    sortBy,
    sortDir,
  } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    const fetchedRows = useSeqCursor
      ? await fetchThreadTagsBySeq(trx, {
          userId,
          seqSince,
          pageSeq,
          pageId,
          limit,
          archived,
          priorityId,
          priorityPath,
          rangeStart,
          rangeEnd,
          sortBy,
        })
      : await fetchThreadTagsByView(trx, {
          userId,
          updatedSince,
          cursorId,
          limit,
          archived,
          priorityId,
          priorityPath,
          rangeStart,
          rangeEnd,
          sortBy,
          sortDir,
        });
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  await stripAnnounceTagActors(c.var.db, userId, rows, "thread", c.var.apiVersion ?? 0);

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/thread-tags - Upsert into thread_tag table
threadTags.post("/sync/thread-tags", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread_tag", {
      user_id: c.var.user.id,
      p_actor_id: body.actor_id,
      p_thread_id: body.thread_id,
      p_occurrence: body.occurrence || null,
      p_tag_id: body.tag_id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
    });
  });

  const priorityId = await getPriorityForThread(c.var.db, body.thread_id, c.var.user.id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

// POST /sync/thread-tags/update - Call update_thread_tags RPC
threadTags.post("/sync/thread-tags/update", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "update_thread_tags", {
      user_id: c.var.user.id,
      p_thread_id: body.thread_id,
      p_actor_id: body.actor_id,
      p_client_id: body.client_id,
      p_tag_updates: body.tag_updates,
      p_occurrence: body.occurrence || null,
    });
  });

  const priorityId2 = await getPriorityForThread(c.var.db, body.thread_id, c.var.user.id);
  notifySync(c, priorityId2);

  return c.json(result as any);
});

// Hand-tuned seq-cursor query. The view's `seq` column is MAX(thread_tag.seq)
// grouped by (thread_id, occurrence) so the cursor predicate cannot push down
// to idx_thread_tag_seq through the LATERAL aggregate — every visible thread
// gets its tags re-aggregated each pull even when nothing changed.
//
// This query inverts the join: filter thread_tag by seq first (one index range
// scan), then re-aggregate the current tag state only for matched
// (thread_id, occurrence) groups. Empty pulls collapse to the CTE returning
// zero rows; downstream joins are never executed.
async function fetchThreadTagsBySeq(
  trx: Kysely<DB>,
  params: {
    userId: string;
    seqSince: string;
    pageSeq: string | null;
    pageId: string | null;
    limit: number;
    archived: boolean | undefined;
    priorityId: string | null;
    priorityPath: string | null;
    rangeStart: string | null;
    rangeEnd: string | null;
    sortBy: string;
  },
): Promise<any[]> {
  const {
    userId,
    seqSince,
    pageSeq,
    pageId,
    limit,
    archived,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    sortBy,
  } = params;

  const pageCursor =
    pageSeq && pageId
      ? sql`AND (tt.seq, t.id) > (${pageSeq}::xid8, ${pageId}::uuid)`
      : pageSeq
        ? sql`AND tt.seq > ${pageSeq}::xid8`
        : sql``;

  const archivedFilter =
    archived === true
      ? sql`AND COALESCE(t.archived_at, tp.archived_at, upe.archived_at) IS NOT NULL`
      : archived === false
        ? sql`AND COALESCE(t.archived_at, tp.archived_at, upe.archived_at) IS NULL`
        : sql``;

  const priorityFilter = priorityId
    ? sql`AND tp.priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
    : priorityPath
      ? sql`AND upe.path <@ ${priorityPath}::ltree`
      : sql``;

  const rangeStartFilter = rangeStart
    ? sql`AND ${sql.ref("tt." + sortBy)} > ${rangeStart}::timestamptz`
    : sql``;
  const rangeEndFilter = rangeEnd
    ? sql`AND ${sql.ref("tt." + sortBy)} < ${rangeEnd}::timestamptz`
    : sql``;

  const result = await sql<any>`
    WITH changed AS (
        SELECT DISTINCT thread_id, occurrence
        FROM thread_tag
        WHERE seq >= ${seqSince}::xid8
          AND seq < pg_snapshot_xmin(pg_current_snapshot())
    )
    SELECT
        tp.user_id,
        t.id,
        COALESCE(t.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
        c.occurrence,
        tt.updated_at,
        tt.seq,
        tp.priority_id,
        upe.path AS priority_path,
        tt.tags
    FROM changed c
    JOIN thread t ON t.id = c.thread_id
    JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
    JOIN LATERAL (
        SELECT
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (
                WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0
            ) AS tags,
            MAX(sq.updated_at) AS updated_at,
            MAX(sq.seq) AS seq
        FROM (
            SELECT
                at.tag_id,
                jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
                MAX(at.seq) AS seq
            FROM thread_tag at
            WHERE at.thread_id = c.thread_id
              AND at.occurrence IS NOT DISTINCT FROM c.occurrence
            GROUP BY at.tag_id
        ) sq
    ) tt ON TRUE
    WHERE (t.draft = FALSE OR t.created_by = tp.user_id)
      AND (
        t.contacts && "user".user_contact_ids(tp.user_id)
        OR t.groups && "user".user_group_ids(tp.user_id)
      )
      -- Re-apply the cursor bounds on the aggregated seq. The CTE only
      -- guarantees at least one member tag falls in [seqSince, horizon);
      -- the row's published seq is MAX(all tags), which could exceed
      -- horizon when a concurrent transaction has written a newer tag
      -- but not yet committed. Excluding those groups here preserves the
      -- view's behaviour: the group will be returned on a later pull,
      -- once horizon advances past the in-flight write.
      AND tt.seq < pg_snapshot_xmin(pg_current_snapshot())
      AND tt.seq >= ${seqSince}::xid8
      ${pageCursor}
      ${archivedFilter}
      ${priorityFilter}
      ${rangeStartFilter}
      ${rangeEndFilter}
    ORDER BY tt.seq ASC, t.id ASC
    LIMIT ${limit}
  `.execute(trx);
  return result.rows as any[];
}

// View-based fallback for non-seq callers (initial sync / updated_since /
// unbounded sort). Mirrors the original endpoint behaviour.
async function fetchThreadTagsByView(
  trx: Kysely<DB>,
  params: {
    userId: string;
    updatedSince: string | null;
    cursorId: string | null;
    limit: number;
    archived: boolean | undefined;
    priorityId: string | null;
    priorityPath: string | null;
    rangeStart: string | null;
    rangeEnd: string | null;
    sortBy: string;
    sortDir: "asc" | "desc";
  },
): Promise<any[]> {
  const {
    userId,
    updatedSince,
    cursorId,
    limit,
    archived,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    sortBy,
    sortDir,
  } = params;

  let query = trx
    .selectFrom("user.thread_tags")
    .selectAll()
    .where("user_id", "=", userId)
    .limit(limit);

  if (updatedSince) {
    query = query
      .orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc")
      .orderBy("id", "asc");
    if (cursorId) {
      query = query.where(
        sql<boolean>`(date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz OR (date_trunc('milliseconds', updated_at) = ${updatedSince}::timestamptz AND id > ${cursorId}))`,
      );
    } else {
      query = query.where(
        sql<boolean>`date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz`,
      );
    }
  } else {
    query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
  }

  if (archived === true) {
    query = query.where("archived_at", "is not", null);
  } else if (archived === false) {
    query = query.where("archived_at", "is", null);
  }

  if (priorityId) {
    query = query.where(
      sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`,
    );
  } else if (priorityPath) {
    query = query.where(sql<boolean>`priority_path <@ ${priorityPath}::ltree`);
  }

  if (rangeStart) {
    query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
  }
  if (rangeEnd) {
    query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
  }

  return (await query.execute()) as any[];
}

export default threadTags;
