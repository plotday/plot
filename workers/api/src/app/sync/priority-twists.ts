import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { assertPriorityAccess } from "./authorize";
import { parseReadParams } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityTwists = new Hono<{ Bindings: Bindings }>();

// GET /sync/priority-twists
// priority_twist table doesn't have user_id; filter by user's accessible priorities
priorityTwists.get("/sync/priority-twists", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.twist")
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

    return query.execute();
  });

  return c.json(rows as any);
});

// POST /sync/priority-twists
priorityTwists.post("/sync/priority-twists", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertPriorityAccess(trx, c.var.user.id, body.priority_id);
    return rpcUser(trx, "upsert_priority_twist", {
      user_id: c.var.user.id,
      p_id: body.id,
      p_priority_id: body.priority_id,
      p_twist_id: body.twist_id,
      p_owner_id: body.owner_id,
      p_name: body.name || null,
      p_config: body.config || null,
      p_archived_at: body.archived_at || null,
    });
  });

  notifySync(c, body.priority_id);

  return c.json(result as any);
});

export default priorityTwists;
