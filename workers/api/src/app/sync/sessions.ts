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

const sessions = new Hono<{ Bindings: Bindings }>();

// GET /sync/sessions
sessions.get("/sync/sessions", async (c) => {
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
      .selectFrom("session")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc");
    } else if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (useSeqCursor) {
      query = query.where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
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

// POST /sync/sessions - Upsert into session table
sessions.post("/sync/sessions", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_session", {
      user_id: userId,
      p_id: body.id || null,
      p_priority_id: body.priority_id,
      p_at: body.at,
      p_precedence: body.precedence || 0,
      p_pomodoro: body.pomodoro || null,
      p_pomodoro_at: body.pomodoro_at || null,
      p_archived_at: body.archived_at || null,
      p_updated_by: body.updated_by || 0,
      p_source: body.source || "active",
      p_schedule_id: body.schedule_id || null,
      p_occurrence_at: body.occurrence_at || null,
      p_explicit: typeof body.explicit === "boolean" ? body.explicit : null,
    });
  });

  notifySync(c, body.priority_id);

  return c.json(result as any);
});

export default sessions;
