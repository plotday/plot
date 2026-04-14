import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, updatedSinceCursor } from "./helpers";

const topics = new Hono<{ Bindings: Bindings }>();

// GET /sync/topics - Read-only
topics.get("/sync/topics", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.topic")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

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

    return query.execute();
  });

  return c.json(rows as any);
});

export default topics;
