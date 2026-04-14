import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync, notifyUserSync } from "./notify";

const priorities = new Hono<{ Bindings: Bindings }>();

// GET /sync/priorities
priorities.get("/sync/priorities", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, id, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.priority")
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
    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/priorities - Upsert via the user.priority view (INSTEAD OF trigger)
priorities.post("/sync/priorities", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority", {
      user_id: userId,
      p_priority: body,
    });
  });

  notifySync(c, body.id);

  // In the per-user priority model, priorities are single-owner — no
  // displaced users to notify on move.
  const displacedUsers: { user_id: string }[] = [];
  for (const row of displacedUsers) {
    notifyUserSync(c, row.user_id);
  }

  return c.json(result as any);
});

export default priorities;
