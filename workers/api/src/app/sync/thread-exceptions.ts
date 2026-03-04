import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { assertThreadAccess } from "./authorize";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync, getPriorityForThread } from "./notify";

const threadExceptions = new Hono<{ Bindings: Bindings }>();

// GET /sync/thread-exceptions
// Uses user.thread_exception view which filters by user access
threadExceptions.get("/sync/thread-exceptions", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, threadId, id, sortBy, sortDir } =
    parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.thread_exception")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (id) { query = query.where("id", "=", id); }
    if (threadId) {
      query = query.where("thread_id", "=", threadId);
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/thread-exceptions - Upsert into thread_exception table
threadExceptions.post("/sync/thread-exceptions", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertThreadAccess(trx, c.var.user.id, body.thread_id);
    return rpcUser(trx, "upsert_thread_exception", {
      user_id: c.var.user.id,
      p_id: body.id || null,
      p_thread_id: body.thread_id,
      p_occurrence: body.occurrence,
      p_archived_at: body.archived_at || null,
      p_updated_by: body.updated_by || 0,
      p_at: body.at || null,
      p_on: body.on || null,
      p_duration: body.duration || null,
      p_done_at: body.done_at || null,
      p_title: body.title || null,
      p_preview: body.preview || null,
      p_meta: body.meta || null,
    });
  });

  const priorityId = await getPriorityForThread(c.var.db, body.thread_id);
  notifySync(c, priorityId);

  return c.json(result as any);
});

export default threadExceptions;
