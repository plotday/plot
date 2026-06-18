import { sql, type Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import {
  createFreeSubscription,
  createStripeClient,
  getBillingCycleDates,
} from "./utils";

/**
 * Reinstate a `free_monthly` Stripe subscription for usage tracking and flip
 * the user's row back to stripe/free/active.
 *
 * Called when an App Store entitlement lapses (EXPIRED / REVOKED / REFUNDED)
 * so that free-tier usage limits continue to be enforced via Stripe metering
 * even after the Apple sub ends.
 *
 * No-op when the user has no `stripe_customer_id` (edge case: users who
 * subscribed via Apple on a device that was never connected to Stripe).
 */
export async function reinstateFreeSubscription(
  db: Kysely<DB>,
  env: Bindings,
  userId: string
): Promise<void> {
  const row = await db
    .selectFrom("user_subscription")
    .select(["stripe_customer_id"])
    .where("user_id", "=", userId)
    .executeTakeFirst();

  if (!row?.stripe_customer_id) return;

  const stripe = createStripeClient(env.STRIPE_SECRET_KEY);
  const freeSub = await createFreeSubscription(stripe, {
    customerId: row.stripe_customer_id,
    userId,
  });
  const { start, end } = getBillingCycleDates(freeSub);

  await db
    .updateTable("user_subscription")
    .set({
      plan: "free",
      status: "active",
      origin: "stripe",
      stripe_subscription_id: freeSub.id,
      billing_cycle_start: start.toISOString(),
      billing_cycle_end: end.toISOString(),
      updated_at: sql`now()`,
    })
    .where("user_id", "=", userId)
    .execute();
}
