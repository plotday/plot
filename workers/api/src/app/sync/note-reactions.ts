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
import { notifySync, getPriorityForNote } from "./notify";

const noteReactions = new Hono<{ Bindings: Bindings }>();

// GET /sync/note-reactions
noteReactions.get("/sync/note-reactions", async (c) => {
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
      ? await fetchNoteReactionsBySeq(trx, {
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
      : await fetchNoteReactionsByView(trx, {
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

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/note-reactions - Upsert into note_reaction table
noteReactions.post("/sync/note-reactions", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_note_reaction", {
      user_id: c.var.user.id,
      p_actor_id: body.actor_id,
      p_note_id: body.note_id,
      p_emoji: body.emoji,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
    });
  });

  const priorityId = await getPriorityForNote(c.var.db, body.note_id, c.var.user.id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

// POST /sync/note-reactions/update - Batch update via update_note_reactions
noteReactions.post("/sync/note-reactions/update", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "update_note_reactions", {
      user_id: c.var.user.id,
      p_note_id: body.note_id,
      p_actor_id: body.actor_id,
      p_client_id: body.client_id,
      p_reaction_updates: body.reaction_updates,
    });
  });

  const priorityId = await getPriorityForNote(c.var.db, body.note_id, c.var.user.id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

// Seq-cursor query mirroring fetchNoteTagsBySeq. The view's `seq` is
// MAX(note_reaction.seq) per note, so the cursor cannot push down through
// the LATERAL aggregate. Pre-filter at note_reaction via idx_note_reaction_seq,
// then re-aggregate only matched notes. MATERIALIZED CTE ensures the
// planner treats the changed set as a hard bound.
async function fetchNoteReactionsBySeq(
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
      ? sql`AND (nr.seq, n.id) > (${pageSeq}::xid8, ${pageId}::uuid)`
      : pageSeq
        ? sql`AND nr.seq > ${pageSeq}::xid8`
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
    ? sql`AND ${sql.ref("nr." + sortBy)} > ${rangeStart}::timestamptz`
    : sql``;
  const rangeEndFilter = rangeEnd
    ? sql`AND ${sql.ref("nr." + sortBy)} < ${rangeEnd}::timestamptz`
    : sql``;

  const result = await sql<any>`
    WITH changed AS MATERIALIZED (
        SELECT DISTINCT note_id
        FROM note_reaction
        WHERE seq >= ${seqSince}::xid8
          AND seq < pg_snapshot_xmin(pg_current_snapshot())
    )
    SELECT
        tp.user_id,
        n.id,
        COALESCE(t.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
        nr.updated_at,
        nr.seq,
        tp.priority_id,
        upe.path AS priority_path,
        nr.reactions
    FROM changed c
    JOIN note n ON n.id = c.note_id
    JOIN thread t ON t.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
    JOIN LATERAL (
        SELECT
            jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (
                WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0
            ) AS reactions,
            MAX(sq.updated_at) AS updated_at,
            MAX(sq.seq) AS seq
        FROM (
            SELECT
                nr.emoji,
                jsonb_agg(nr.actor_id ORDER BY nr.actor_id)
                    FILTER (WHERE nr.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(nr.archived_at, nr.updated_at)) AS updated_at,
                MAX(nr.seq) AS seq
            FROM note_reaction nr
            WHERE nr.note_id = c.note_id
            GROUP BY nr.emoji
        ) sq
        HAVING COUNT(*) > 0
    ) nr ON TRUE
    WHERE (t.draft = FALSE OR t.created_by = tp.user_id)
      AND (
        t.contacts && "user".user_contact_ids(tp.user_id)
        OR t.groups && "user".user_group_ids(tp.user_id)
      )
      AND (n.draft = FALSE OR n.created_by = tp.user_id)
      AND (
        n.created_by = tp.user_id
        OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
        OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id))
      )
      -- The CTE guarantees at least one reaction is in the cursor window;
      -- the row's seq is MAX(all reactions) and can exceed horizon if a
      -- concurrent write is in flight. Exclude those so they land on a
      -- later pull when horizon advances.
      AND nr.seq < pg_snapshot_xmin(pg_current_snapshot())
      AND nr.seq >= ${seqSince}::xid8
      ${pageCursor}
      ${archivedFilter}
      ${priorityFilter}
      ${rangeStartFilter}
      ${rangeEndFilter}
    ORDER BY nr.seq ASC, n.id ASC
    LIMIT ${limit}
  `.execute(trx);
  return result.rows as any[];
}

// View-based fallback for non-seq callers (initial sync / updated_since /
// unbounded sort). Mirrors fetchNoteTagsByView.
async function fetchNoteReactionsByView(
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
    .selectFrom("user.note_reactions" as any)
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

export default noteReactions;
