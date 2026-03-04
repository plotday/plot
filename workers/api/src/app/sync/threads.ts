import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { notifySync } from "./notify";

const threads = new Hono<{ Bindings: Bindings }>();

// GET /sync/threads
threads.get("/sync/threads", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityPath,
    rangeStart,
    rangeEnd,
    initial,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.thread")
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort: use custom sort when not doing cursor pagination
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    // Don't apply limit for initial pulls
    if (!initial) {
      query = query.limit(limit);
    }

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination (uses date_trunc to match JS Date millisecond precision)
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Initial pull: fetch unread non-archived threads
    if (initial && archived !== true) {
      query = query.where(
        sql<boolean>`(archived_at IS NULL AND draft = false AND unread = true)`
      );
    } else {
      // Archived filter (only when not initial)
      if (archived === true) {
        query = query.where("archived_at", "is not", null);
      } else if (archived === false) {
        query = query.where("archived_at", "is", null);
      }
    }

    // Priority path filter
    if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Range filtering (for pullTo pagination by sortBy column)
    if (rangeStart) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
    }
    if (rangeEnd) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/threads - Upsert via upsert_thread() RPC
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread", {
      user_id: c.var.user.id,
      p_thread: (body.thread || body) as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  const threadData = body.thread || body;
  notifySync(c, threadData.priority_id);

  return c.json(result as any);
});

export default threads;
