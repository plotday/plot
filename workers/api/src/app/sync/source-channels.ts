import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, updatedSinceCursor } from "./helpers";

const sourceChannels = new Hono<{ Bindings: Bindings }>();

// GET /sync/source-channels
sourceChannels.get("/sync/source-channels", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.source_channel")
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

    return query.execute();
  });

  return c.json(rows as any);
});

export default sourceChannels;
