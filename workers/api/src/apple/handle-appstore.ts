import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import type { createLogger } from "@plotday/worker-util";
import { applyAppleTransactionToUser } from "./iap";
import type {
  JwsNotificationPayload,
  JwsRenewalInfoPayload,
  JwsTransactionPayload,
} from "./iap";
import { reinstateFreeSubscription } from "../stripe/reinstate-free";

/**
 * Process an App Store Server Notification after JWS decoding.
 *
 * Extracted from the route handler so it can be unit-tested with literal
 * notif/txn objects — no need to mock JWS signature verification.
 *
 * Returns `{ grace: true }` when the notification is a billing-retry grace
 * period (no downgrade); returns `{ ok: true }` otherwise.
 */
export async function handleAppStoreTransaction(
  db: Kysely<DB>,
  env: Bindings,
  userId: string,
  notif: JwsNotificationPayload,
  txn: JwsTransactionPayload,
  renewal: JwsRenewalInfoPayload | null,
  tracker: {
    capture: (event: string, props?: Record<string, unknown>) => void;
    captureException: (error: Error) => void;
  },
  logger: ReturnType<typeof createLogger>
): Promise<{ ok: boolean; grace?: boolean }> {
  // Grace period (billing retry): Apple still entitles the user even though
  // expiresDate has passed. Skip the downgrade entirely.
  const inGracePeriod =
    notif.notificationType === "DID_FAIL_TO_RENEW" &&
    notif.subtype === "GRACE_PERIOD";

  if (inGracePeriod) {
    return { ok: true, grace: true };
  }

  const applied = await applyAppleTransactionToUser(db, userId, txn);

  tracker.capture("[User] Subscription Updated", {
    plan: txn.productId,
    origin: "app_store",
    notification_type: notif.notificationType,
    subtype: notif.subtype ?? null,
    auto_renew_status: renewal?.autoRenewStatus ?? null,
  });

  // Entitlement lapsed (expire / refund / revoke) — restore free-tier
  // usage tracking via a fresh free_monthly Stripe sub.
  if (applied.plan === "free") {
    try {
      await reinstateFreeSubscription(db, env, userId);
    } catch (e) {
      tracker.captureException(e as Error);
      logger.warn("AppStore webhook: failed to reinstate free subscription", {
        user_id: userId,
        error: (e as Error).message,
      });
    }
  }

  return { ok: true };
}
