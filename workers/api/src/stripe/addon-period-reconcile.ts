import type Stripe from "stripe";
import { createLogger } from "@plotday/worker-util";
import type { Kysely, DB } from "../db";
import { reconcileScopeAddonBillingDown } from "../app/twist-integrations";

const logger = createLogger({ operation: "addon-period-reconcile" });

// Conservative per-run cap on how many add-on subscriptions this cron will
// scan/retrieve-from-Stripe in a single invocation, to bound Workers
// subrequest usage as add-on adoption grows. No pagination yet — if a run
// hits the cap, we log a warning so we know to add pagination; subscriptions
// not scanned this run should still fall in the window on a later run.
const RECONCILE_SCAN_LIMIT = 250;

/**
 * Period-boundary reconcile: for every scope with an add-on subscription whose
 * Stripe billing period ends within [nowMs, nowMs+windowMs], set the add-on
 * quantity down to the scope's currently-active billable add-on connections
 * (canceling at zero). Down-only — never charges without consent. Keeps unused
 * credits reusable WITHIN a period; drops them at the boundary.
 */
export async function reconcileAddonsAtPeriodEnd(args: {
  db: Kysely<DB>;
  stripe: Stripe;
  nowMs: number;
  windowMs: number;
}): Promise<{ reconciled: number }> {
  const { db, stripe, nowMs, windowMs } = args;

  const userSubs = await db
    .selectFrom("user_subscription")
    .select(["user_id", "stripe_addon_subscription_id"])
    .where("stripe_addon_subscription_id", "is not", null)
    .limit(RECONCILE_SCAN_LIMIT)
    .execute();
  const teamSubs = await db
    .selectFrom("team_subscription")
    .select(["team_id", "stripe_addon_subscription_id"])
    .where("stripe_addon_subscription_id", "is not", null)
    .limit(RECONCILE_SCAN_LIMIT)
    .execute();

  if (userSubs.length === RECONCILE_SCAN_LIMIT) {
    logger.warn("user_subscription scan hit RECONCILE_SCAN_LIMIT; some subscriptions may not have been checked this run", {
      limit: RECONCILE_SCAN_LIMIT,
    });
  }
  if (teamSubs.length === RECONCILE_SCAN_LIMIT) {
    logger.warn("team_subscription scan hit RECONCILE_SCAN_LIMIT; some subscriptions may not have been checked this run", {
      limit: RECONCILE_SCAN_LIMIT,
    });
  }

  const targets: { subId: string; scope: { userId: string } | { teamId: string } }[] = [
    ...userSubs.map((r) => ({ subId: r.stripe_addon_subscription_id as string, scope: { userId: r.user_id } })),
    ...teamSubs.map((r) => ({ subId: r.stripe_addon_subscription_id as string, scope: { teamId: r.team_id } })),
  ];

  let reconciled = 0;
  for (const t of targets) {
    try {
      const sub = await stripe.subscriptions.retrieve(t.subId);
      // `current_period_end` relies on the pinned Stripe apiVersion: createStripeClient
      // pins "2025-02-24.acacia", where current_period_end is top-level on the
      // subscription. If the apiVersion is ever bumped to basil+ this field moves
      // onto subscription items and this read would silently return undefined.
      const periodEndMs = ((sub as any).current_period_end ?? 0) * 1000;
      if (periodEndMs < nowMs || periodEndMs > nowMs + windowMs) continue;
      await reconcileScopeAddonBillingDown({ db, stripe, scope: t.scope });
      reconciled += 1;
    } catch (error) {
      logger.error("Failed to reconcile add-on target", error as Error, {
        sub_id: t.subId,
        scope: t.scope,
      });
    }
  }
  return { reconciled };
}
