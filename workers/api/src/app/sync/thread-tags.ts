import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
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
    let query = trx
      .selectFrom("user.thread_tags")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc")
        .where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    // Priority filter: prefer ID-based lookup, fall back to path for backward compatibility
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Pagination range filter on the sort column (thread_tags has no
    // schedule range columns, so filter rows by sortBy timestamp).
    if (rangeStart) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
    }
    if (rangeEnd) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
    }

    const fetchedRows = await query.execute();
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

export default threadTags;
