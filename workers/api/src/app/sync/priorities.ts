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
import { rpcUser } from "../../rpc";
import { enqueueChannelRouter } from "../../state/channel-router";
import { notifySync, notifyUserSync } from "./notify";

const priorities = new Hono<{ Bindings: Bindings }>();

// GET /sync/priorities
priorities.get("/sync/priorities", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.priority")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc")
        .where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (id) { query = query.where("id", "=", id); }
    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
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

  // Any priority mutation — create, rename, archive — can shift which
  // channel should default to which priority. Enqueue a debounced router
  // run. Safe to fire-and-forget; the DO coalesces repeated calls.
  c.executionCtx.waitUntil(
    enqueueChannelRouter(c.env, userId).catch(() => {
      // Router enqueue failures are non-fatal for the priority upsert.
    })
  );

  return c.json(result as any);
});

export default priorities;
