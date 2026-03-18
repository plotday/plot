import { Hono } from "hono";

import type { Bindings } from "../env";
import { withDb } from "../db";
import { sendDataNotificationToUser } from "../notifications/send";

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

const testRoutes = new Hono<{ Bindings: Bindings }>();

// POST /test/trigger-push - Directly send a sync_wake push to the authenticated user.
// Bypasses the PushNotify DO entirely (tests client-side path).
// Only available in non-production environments.
testRoutes.post("/test/trigger-push", async (c) => {
  if (typeof ENV !== "undefined" && ENV === "production") {
    return c.json({ error: "Not available in production" }, 404);
  }

  const userId = c.var.user.id;

  const result = await withDb(c.env, async (db) => {
    await sendDataNotificationToUser(c.env, db, userId, { type: "sync_wake" });

    const devices = await db
      .selectFrom("device")
      .select(["push_token"])
      .where("user_id", "=", userId)
      .execute();

    return devices.map((d) => d.push_token);
  });

  return c.json({ sent: result.length, devices: result });
});

export default testRoutes;
