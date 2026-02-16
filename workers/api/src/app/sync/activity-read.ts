import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";

const activityRead = new Hono<{ Bindings: Bindings }>();

// POST /sync/activity-read - Upsert read records
activityRead.post("/sync/activity-read", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;

  await withUserDb(c.var.db, userId, async (trx) => {
    const records = Array.isArray(body) ? body : [body];
    for (const record of records) {
      await rpcUser(trx, "upsert_activity_read", {
        user_id: userId,
        p_activity_id: record.activity_id,
        p_read_at: record.read_at,
      });
    }
  });

  notifyUserSync(c, userId);

  return c.json({ ok: true });
});

// DELETE /sync/activity-read - Delete read records
activityRead.delete("/sync/activity-read", async (c) => {
  const userId = c.var.user.id;
  const activityId = c.req.query("activity_id");

  if (!activityId) {
    return c.json({ error: "activity_id is required" }, 400);
  }

  await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await rpcUser(trx, "delete_activity_read", {
      user_id: userId,
      p_activity_id: activityId,
    });
  });

  notifyUserSync(c, userId);

  return c.json({ ok: true });
});

export default activityRead;
