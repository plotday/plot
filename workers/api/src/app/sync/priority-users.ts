import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityUsers = new Hono<{ Bindings: Bindings }>();

// GET /sync/priority-users
priorityUsers.get("/sync/priority-users", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("priority_user")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("priority_id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("priority_id", sortDir);
    }

    // priority_user PK is (user_id, priority_id), use priority_id as cursor id
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId, "priority_id"));
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

// POST /sync/priority-users
priorityUsers.post("/sync/priority-users", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority_user", {
      user_id: userId,
      p_priority_id: body.priority_id,
      p_archived_at: body.archived_at || null,
      p_personal: body.personal || false,
    });
  });

  notifySync(c, body.priority_id);

  return c.json(result as any);
});

export default priorityUsers;
