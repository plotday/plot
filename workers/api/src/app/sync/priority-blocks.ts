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
import { notifySync } from "./notify";

const priorityBlocks = new Hono<{ Bindings: Bindings }>();

// GET /sync/priority-blocks
priorityBlocks.get("/sync/priority-blocks", async (c) => {
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
      .selectFrom("user.priority_block")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    if (useSeqCursor) {
      query = query
        .orderBy("seq", "asc")
        .orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query
        .orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc")
        .orderBy("id", "asc")
        .where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    if (id) {
      query = query.where("id", "=", id);
    }

    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/priority-blocks - Upsert a priority_block row.
//
// Body shape mirrors the user.priority_block view's columns. The SQL
// helper upserts on (priority_id, effective_at); clients send
// `effective_at = 1970-01-01T00:00:00Z` for the canonical "current" row
// (one per priority) and a future timestamp for planned changes.
priorityBlocks.post("/sync/priority-blocks", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority_block", {
      user_id: userId,
      p_block: body,
    });
  });

  if (body.priority_id) {
    notifySync(c, body.priority_id);
  }

  return c.json(result as any);
});

export default priorityBlocks;
