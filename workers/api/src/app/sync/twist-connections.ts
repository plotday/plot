import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";

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
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    limit,
    sortBy,
    sortDir,
  } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.twist_connection")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort. When paginating with `updated_since`, we always sort by
    // updated_at asc + twist_instance_id asc to match the cursor semantics
    // in `updatedSinceCursor`.
    if (useSeqCursor) {
      query = query
        .orderBy("seq", "asc")
        .orderBy("twist_instance_id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId, "twist_instance_id"));
    } else if (updatedSince) {
      query = query
        .orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc")
        .orderBy("twist_instance_id", "asc")
        .where(updatedSinceCursor(updatedSince, cursorId, "twist_instance_id"));
    } else {
      query = query
        .orderBy(sql.ref(sortBy), sortDir)
        .orderBy("twist_instance_id", sortDir);
    }

    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  if (useSeqCursor) {
    // user.twist_connection has no `id` column — its primary cursor key is
    // (seq, twist_instance_id). Project twist_instance_id as `id` for
    // seqEnvelope so next_page.id reflects the right tiebreaker; the client
    // echoes it back as `page_id` and we feed it to seqSinceCursor's
    // cursorIdColumn = "twist_instance_id".
    const envelopeRows = rows.map((r: any) => ({ ...r, id: r.twist_instance_id }));
    return c.json(seqEnvelope(envelopeRows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

export default twistConnections;
