import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, updatedSinceCursor } from "./helpers";

const priorityActors = new Hono<{ Bindings: Bindings }>();

// GET /sync/priority-actors - Read-only
priorityActors.get("/sync/priority-actors", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.priority_actor")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("actor_id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("actor_id", sortDir);
    }

    // Composite cursor on (updated_at, actor_id)
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId, "actor_id"));
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

export default priorityActors;
