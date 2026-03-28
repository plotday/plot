import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { parseReadParams, updatedSinceCursor } from "./helpers";

const threadAssociations = new Hono<{ Bindings: Bindings }>();

// GET /sync/thread-associations
threadAssociations.get("/sync/thread-associations", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    id,
    sortBy: _sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.thread_association" as any)
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy("updated_at", sortDir).orderBy("id", sortDir);
    }

    query = query.limit(limit);

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Archived filter
    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/thread-associations - Upsert via upsert_thread_association() RPC
threadAssociations.post("/sync/thread-associations", async (c) => {
  const body = await c.req.json();
  const association = body.association || body;

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread_association", {
      user_id: c.var.user.id,
      p_association: association as any,
    });
  });

  return c.json(result as any);
});

export default threadAssociations;
