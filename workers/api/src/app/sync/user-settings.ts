import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";

const userSettings = new Hono<{ Bindings: Bindings }>();

// GET /sync/user-settings
userSettings.get("/sync/user-settings", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user_settings")
      .selectAll()
      .where("user_id", "=", userId);

    if (updatedSince) {
      query = query.where(sql<boolean>`date_trunc('milliseconds', updated_at) > ${updatedSince}::timestamptz`);
    }

    return query.execute();
  });

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
