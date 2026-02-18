import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams } from "./helpers";
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
      query = query.orderBy("updated_at", "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (updatedSince) {
      if (cursorId) {
        query = query.where(
          sql<boolean>`(updated_at > ${updatedSince}::timestamptz OR (updated_at = ${updatedSince}::timestamptz AND id > ${cursorId}))`
        );
      } else {
        query = query.where(sql<boolean>`updated_at > ${updatedSince}::timestamptz`);
      }
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

  // Notify users who lost access to this priority (displaced by a move).
  // The DB function already wrote to priority_user + user_sync; fire real-time
  // WebSocket pushes so displaced users don't have to wait for their next poll.
  const displacedUsers = await withUserDb(c.var.db, userId, async (trx) => {
    return trx
      .selectFrom("priority_user")
      .select("user_id")
      .where("priority_id", "=", body.id)
      .where("archived_at", "is not", null)
      .execute();
  });
  for (const row of displacedUsers) {
    notifyUserSync(c, row.user_id);
  }

  return c.json(result as any);
});

export default priorities;
