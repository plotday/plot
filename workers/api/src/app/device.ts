import { Hono } from "hono";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";

const device = new Hono<{ Bindings: Bindings }>();

/**
 * PUT /device - Register or update a device for push notifications.
 * Upserts on push_token: if the token already exists (e.g. same device,
 * different user after sign-out/sign-in), updates the user_id.
 */
device.put("/device", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const body = await c.req.json<{
    platform: string;
    pushToken: string;
    appVersion?: string;
  }>();

  if (!body.platform || !body.pushToken) {
    return c.json({ message: "platform and pushToken are required" }, 400);
  }

  if (body.platform !== "ios" && body.platform !== "android") {
    return c.json({ message: "platform must be 'ios' or 'android'" }, 400);
  }

  const logger = createLogger(extractRequestContext(c));

  try {
    await c.var.db
      .insertInto("device")
      .values({
        user_id: user.id,
        platform: body.platform,
        push_token: body.pushToken,
        app_version: body.appVersion ?? null,
      })
      .onConflict((oc) =>
        oc.column("push_token").doUpdateSet({
          user_id: user.id,
          platform: body.platform,
          app_version: body.appVersion ?? null,
        })
      )
      .execute();

    logger.info("Device registered", {
      user_id: user.id,
      platform: body.platform,
    });

    return c.json({ success: true });
  } catch (error) {
    logger.error("Failed to register device", error as Error, {
      user_id: user.id,
    });
    return c.json({ message: "Failed to register device" }, 500);
  }
});

/**
 * DELETE /device - Deregister a device for push notifications.
 * Called on sign-out.
 */
device.delete("/device", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const body = await c.req.json<{ pushToken: string }>();

  if (!body.pushToken) {
    return c.json({ message: "pushToken is required" }, 400);
  }

  const logger = createLogger(extractRequestContext(c));

  try {
    await c.var.db
      .deleteFrom("device")
      .where("push_token", "=", body.pushToken)
      .where("user_id", "=", user.id)
      .execute();

    logger.info("Device deregistered", {
      user_id: user.id,
    });

    return c.json({ success: true });
  } catch (error) {
    logger.error("Failed to deregister device", error as Error, {
      user_id: user.id,
    });
    return c.json({ message: "Failed to deregister device" }, 500);
  }
});

export default device;
