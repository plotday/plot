import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";

const userSettings = new Hono<{ Bindings: Bindings }>();

// GET /sync/user-settings
userSettings.get("/sync/user-settings", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, seqSince, pageSeq, pageId, limit } =
    parseReadParams(c);

  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user_settings")
      .selectAll()
      .where("user_id", "=", userId);

    if (useSeqCursor) {
      query = query
        .orderBy("seq", "asc")
        .orderBy("user_id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId, "user_id"));
    } else if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId, "user_id"));
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

// POST /sync/user-settings - Upsert into user_settings table
userSettings.post("/sync/user-settings", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_user_settings", {
      user_id: userId,
      p_enter_behavior: body.enter_behavior || null,
    });
  });

  notifyUserSync(c, userId);

  return c.json(result as any);
});

export default userSettings;
