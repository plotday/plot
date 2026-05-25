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
import { createSchedule } from "./smart-schedule";
import { stripAnnounceTagActors } from "./viewer";

const noteTags = new Hono<{ Bindings: Bindings }>();

// GET /sync/note-tags
noteTags.get("/sync/note-tags", async (c) => {
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
      ? await fetchNoteTagsBySeq(trx, {
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
      : await fetchNoteTagsByView(trx, {
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

  await stripAnnounceTagActors(c.var.db, userId, rows as any, "note", c.var.apiVersion ?? 0);

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/note-tags - Upsert into note_tag table
noteTags.post("/sync/note-tags", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_note_tag", {
      user_id: c.var.user.id,
      p_actor_id: body.actor_id,
      p_note_id: body.note_id,
      p_tag_id: body.tag_id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
    });
  });

  const priorityId = await getPriorityForNote(c.var.db, body.note_id, c.var.user.id);
  notifySync(c, priorityId);

  // Create task schedule when todo tag is added
  if (body.tag_id === 1 && !body.archived_at) {
    try {
      const contact = await c.var.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", body.actor_id)
        .executeTakeFirst();

      if (contact?.user_id) {
        const note = await c.var.db
          .selectFrom("note")
          .select("thread_id")
          .where("id", "=", body.note_id)
          .executeTakeFirst();

        if (note?.thread_id) {
          await createSchedule(c.var.db, contact.user_id, note.thread_id, 'active');
        }
      }
    } catch (error) {
      console.error("[thread_state] Failed to file thread_state from note tag:", error);
    }
  }

  return c.json(result as any);
});

// POST /sync/note-tags/update - Call update_note_tags RPC
noteTags.post("/sync/note-tags/update", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "update_note_tags", {
      user_id: c.var.user.id,
      p_note_id: body.note_id,
      p_actor_id: body.actor_id,
      p_client_id: body.client_id,
      p_tag_updates: body.tag_updates,
    });
  });

  const priorityId2 = await getPriorityForNote(c.var.db, body.note_id, c.var.user.id);
  notifySync(c, priorityId2);

  // File active=true thread_state when todo tags are added via update
  if (body.tag_updates) {
    const todoEntries = Object.entries(body.tag_updates as Record<string, boolean>)
      .filter(([key, val]) => val === true && key.startsWith('1:'));

    if (todoEntries.length > 0) {
      try {
        const note = await c.var.db
          .selectFrom("note")
          .select("thread_id")
          .where("id", "=", body.note_id)
          .executeTakeFirst();

        if (note?.thread_id) {
          for (const [key] of todoEntries) {
            const actorId = key.split(':')[1];
            const contact = await c.var.db
              .selectFrom("contact")
              .select("user_id")
              .where("id", "=", actorId)
              .executeTakeFirst();
            if (!contact?.user_id) continue;
            await createSchedule(c.var.db, contact.user_id, note.thread_id, 'active');
          }
        }
      } catch (error) {
        console.error("[thread_state] Failed to file thread_state from tag update:", error);
      }
    }
  }

  return c.json(result as any);
});

// Hand-tuned seq-cursor query. See thread-tags.ts for the full rationale —
// the view's `seq` is MAX(note_tag.seq) per note, so the cursor cannot push
// down through the LATERAL aggregate. Pre-filter at note_tag via
// idx_note_tag_seq, then re-aggregate only matched notes. MATERIALIZED CTE
// ensures the planner treats the changed set as a hard bound rather than
// computing it after a full thread/note visibility scan.
async function fetchNoteTagsBySeq(
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
      ? sql`AND (tt.seq, n.id) > (${pageSeq}::xid8, ${pageId}::uuid)`
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
    WITH changed AS MATERIALIZED (
        SELECT DISTINCT note_id
        FROM note_tag
        WHERE seq >= ${seqSince}::xid8
          AND seq < pg_snapshot_xmin(pg_current_snapshot())
    )
    SELECT
        tp.user_id,
        n.id,
        COALESCE(t.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
        tt.updated_at,
        tt.seq,
        tp.priority_id,
        upe.path AS priority_path,
        tt.tags
    FROM changed c
    JOIN note n ON n.id = c.note_id
    JOIN thread t ON t.id = n.thread_id
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
                nt.tag_id,
                jsonb_agg(nt.actor_id ORDER BY nt.actor_id)
                    FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
                MAX(nt.seq) AS seq
            FROM note_tag nt
            WHERE nt.note_id = c.note_id
            GROUP BY nt.tag_id
        ) sq
        HAVING COUNT(*) > 0
    ) tt ON TRUE
    WHERE (t.draft = FALSE OR t.created_by = tp.user_id)
      AND (
        t.contacts && "user".user_contact_ids(tp.user_id)
        OR t.groups && "user".user_group_ids(tp.user_id)
      )
      AND (n.draft = FALSE OR n.created_by = tp.user_id)
      AND (
        n.access_contacts IS NULL
        OR n.created_by = tp.user_id
        OR n.access_contacts && "user".user_contact_ids(tp.user_id)
      )
      -- See thread-tags for rationale: the CTE only guarantees one member
      -- tag is in the cursor window; the row's seq is MAX(all tags) and
      -- can exceed horizon if a concurrent write is in flight. The
      -- view's behaviour excludes those groups so they are returned on a
      -- later pull when horizon advances.
      AND tt.seq < pg_snapshot_xmin(pg_current_snapshot())
      AND tt.seq >= ${seqSince}::xid8
      ${pageCursor}
      ${archivedFilter}
      ${priorityFilter}
      ${rangeStartFilter}
      ${rangeEndFilter}
    ORDER BY tt.seq ASC, n.id ASC
    LIMIT ${limit}
  `.execute(trx);
  return result.rows as any[];
}

// View-based fallback for non-seq callers (initial sync / updated_since /
// unbounded sort). Mirrors the original endpoint behaviour.
async function fetchNoteTagsByView(
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
    .selectFrom("user.note_tags" as any)
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

export default noteTags;
