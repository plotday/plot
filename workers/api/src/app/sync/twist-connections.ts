import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, updatedSinceCursor } from "./helpers";

const twistConnections = new Hono<{ Bindings: Bindings }>();

// GET /sync/twist-connections
//
// Read-only sync endpoint for the `user.twist_connection` view. The view has
// no `archived_at` column (a connection is considered "gone" once the
// underlying twist_instance_connection row is deleted, which propagates
// through the user_sync trigger), so the archived filter logic from
// twist-instances is intentionally dropped here.
//
// Cursor pagination: the natural composite key is (twist_instance_id,
// provider, actor_id), but `updatedSinceCursor` only supports a single
// secondary cursor column. We use `twist_instance_id` -- collisions within
// the same `updated_at` millisecond + same instance are extremely rare
// (would require two providers / actors flipping state in the same
// microsecond) and the row count per user is tiny (one per connected
// account), so duplicate or skipped rows are not a practical concern.
twistConnections.get("/sync/twist-connections", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.twist_connection")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort. When paginating with `updated_since`, we always sort by
    // updated_at asc + twist_instance_id asc to match the cursor semantics
    // in `updatedSinceCursor`.
    if (updatedSince) {
      query = query
        .orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc")
        .orderBy("twist_instance_id", "asc");
    } else {
      query = query
        .orderBy(sql.ref(sortBy), sortDir)
        .orderBy("twist_instance_id", sortDir);
    }

    if (updatedSince) {
      query = query.where(
        updatedSinceCursor(updatedSince, cursorId, "twist_instance_id"),
      );
    }

    return query.execute();
  });

  return c.json(rows as any);
});

export default twistConnections;
