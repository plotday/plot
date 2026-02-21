/**
 * High-level notification sender.
 * Queries user devices and sends push notifications via FCM.
 */

import type { Kysely } from "kysely";
import { createLogger } from "@plotday/worker-util";
import type { DB } from "../db";
import type { Bindings } from "../env";
import { sendPushNotification, type NotificationPayload } from "../utils/fcm";

/**
 * Sends a push notification to all registered devices for a user.
 * Automatically removes stale/invalid tokens.
 */
export async function sendNotificationToUser(
  env: Bindings,
  db: Kysely<DB>,
  userId: string,
  notification: NotificationPayload
): Promise<void> {
  const logger = createLogger({ operation: "sendNotificationToUser" });

  // Get all device tokens for this user
  const devices = await db
    .selectFrom("device")
    .select(["id", "push_token"])
    .where("user_id", "=", userId)
    .execute();

  if (devices.length === 0) {
    return;
  }

  const config = {
    projectId: env.GCP_PROJECT_ID,
    serviceAccountEmail: env.GCP_SERVICE_ACCOUNT_EMAIL,
    serviceAccountKey: env.GCP_SERVICE_ACCOUNT_KEY,
  };

  const staleDeviceIds: string[] = [];

  // Send to all devices in parallel
  const results = await Promise.allSettled(
    devices.map(async (device) => {
      const result = await sendPushNotification(
        config,
        device.push_token,
        notification
      );

      if (result.unregistered) {
        staleDeviceIds.push(device.id);
      } else if (!result.success) {
        logger.warn("FCM send failed", {
          device_id: device.id,
          error: result.error,
        });
      }

      return result;
    })
  );

  // Clean up stale tokens
  if (staleDeviceIds.length > 0) {
    try {
      await db
        .deleteFrom("device")
        .where("id", "in", staleDeviceIds)
        .execute();

      logger.info("Removed stale device tokens", {
        user_id: userId,
        count: staleDeviceIds.length,
      });
    } catch (error) {
      logger.error("Failed to remove stale device tokens", error as Error, {
        user_id: userId,
        device_ids: staleDeviceIds,
      });
    }
  }

  const successCount = results.filter(
    (r) => r.status === "fulfilled" && r.value.success
  ).length;

  if (successCount > 0) {
    logger.info("Notifications sent", {
      user_id: userId,
      sent: successCount,
      total: devices.length,
    });
  }
}
