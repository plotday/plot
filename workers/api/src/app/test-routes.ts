import { Hono } from "hono";

import type { Bindings } from "../env";
import { withDb } from "../db";
import { sendDataMessage } from "../utils/fcm";

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

const testRoutes = new Hono<{ Bindings: Bindings }>();

// POST /test/trigger-push - Directly send a sync_wake push to the authenticated user.
// Bypasses the PushNotify DO entirely (tests client-side path).
// Returns per-device FCM results so failures are visible.
// Only available in non-production environments.
testRoutes.post("/test/trigger-push", async (c) => {
  if (typeof ENV !== "undefined" && ENV === "production") {
    return c.json({ error: "Not available in production" }, 404);
  }

  const userId = c.var.user.id;

  const result = await withDb(c.env, async (db) => {
    const devices = await db
      .selectFrom("device")
      .select(["id", "push_token"])
      .where("user_id", "=", userId)
      .where("push_token", "is not", null)
      .$narrowType<{ push_token: string }>()
      .execute();

    const config = {
      projectId: c.env.GCP_PROJECT_ID,
      serviceAccountEmail: c.env.GCP_SERVICE_ACCOUNT_EMAIL,
      serviceAccountKey: c.env.GCP_SERVICE_ACCOUNT_KEY,
    };

    const results = await Promise.all(
      devices.map(async (device) => {
        const r = await sendDataMessage(config, device.push_token, { type: "sync_wake" });
        return { device_id: device.id, token: device.push_token.slice(-12), ...r };
      })
    );

    return results;
  });

  const { sent, failed } = result.reduce(
    (acc, r) => {
      if (r.success) acc.sent++;
      else acc.failed.push(r);
      return acc;
    },
    { sent: 0, failed: [] as typeof result }
  );

  return c.json({
    sent,
    total: result.length,
    ...(failed.length > 0 ? { failures: failed } : {}),
  });
});

export default testRoutes;
