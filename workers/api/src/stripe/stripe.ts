import { Hono } from "hono";
import type Stripe from "stripe";

import type { Bindings } from "../env";
import {
  createFreeTierBillingCycle,
  createFreeSubscription,
  createStripeClient,
  getBillingCycleDates,
  mapStripeStatus,
  verifyWebhookSignature,
} from "./utils";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";
import { sql, type Kysely } from "kysely";
import { PLAN_LIMITS, type PlanKey } from "../utils/limits";
import { backfillEmbeddings } from "../queue/backfill-embeddings";
import { twistFactory } from "../twist/factory";
import { enforcePersonalPlanLimits } from "../twist/management";
import { disposeRpc } from "../utils/rpc";
import { notifyUserSync } from "../app/sync/notify";
import { expireTrial, handleTrialUpgrade, handleTrialWillEnd } from "../utils/trial";
import type { DB } from "../db-types";

const stripe = new Hono<{ Bindings: Bindings }>();

// POST /webhook - Handle Stripe webhook events
stripe.post("/webhook", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const signature = c.req.header("stripe-signature");
    if (!signature) {
      return new Response("Missing stripe-signature header", { status: 400 });
    }

    // Get raw body for signature verification
    const body = await c.req.text();

    // Verify webhook signature
    const stripeClient = createStripeClient(c.env.STRIPE_SECRET_KEY);
    let event: Stripe.Event;

    try {
      event = await verifyWebhookSignature(
        stripeClient,
        body,
        signature,
        c.env.STRIPE_WEBHOOK_SECRET
      );
    } catch (err) {
      logger.error("Webhook signature verification failed", err as Error);
      return new Response("Invalid signature", { status: 400 });
    }

    // Handle different event types
    switch (event.type) {
      case "customer.subscription.created": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionUpdate(c, subscription);
        await identifyStripeUser(c, subscription.customer as string);
        c.var.tracker.capture("[User] Subscription Created", {
          plan: subscription.metadata.plan ?? "free",
          status: subscription.status,
          stripe_customer_id: subscription.customer as string,
        });
        break;
      }

      case "customer.subscription.updated": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionUpdate(c, subscription);
        await identifyStripeUser(c, subscription.customer as string);
        c.var.tracker.capture("[User] Subscription Updated", {
          plan: subscription.metadata.plan ?? "free",
          status: subscription.status,
          stripe_customer_id: subscription.customer as string,
        });
        break;
      }

      case "customer.subscription.deleted": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionDeleted(c, subscription);
        await identifyStripeUser(c, subscription.customer as string);
        c.var.tracker.capture("[User] Subscription Canceled", {
          plan: subscription.metadata.plan ?? "free",
          stripe_customer_id: subscription.customer as string,
        });
        break;
      }

      case "invoice.payment_succeeded": {
        const invoice = event.data.object as Stripe.Invoice;
        if (invoice.subscription) {
          // Fetch the subscription to get updated billing cycle
          const subscription = await stripeClient.subscriptions.retrieve(
            invoice.subscription as string
          );
          await handleSubscriptionUpdate(c, subscription);
        }
        await identifyStripeUser(c, invoice.customer as string);
        c.var.tracker.capture("[User] Payment Succeeded", {
          amount_cents: invoice.amount_paid,
          currency: invoice.currency,
          stripe_customer_id: invoice.customer as string,
        });
        break;
      }

      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        logger.warn("Payment failed", {
          customer_id: invoice.customer as string,
          subscription_id: invoice.subscription as string,
        });
        await identifyStripeUser(c, invoice.customer as string);
        c.var.tracker.capture("[User] Payment Failed", {
          amount_cents: invoice.amount_due,
          currency: invoice.currency,
          stripe_customer_id: invoice.customer as string,
        });
        // Subscription status will be updated via subscription.updated event
        break;
      }

      case "customer.subscription.trial_will_end": {
        const subscription = event.data.object as Stripe.Subscription;
        const customerId = subscription.customer as string;
        const trialUser = await c.var.db
          .selectFrom("user_subscription")
          .select("user_id")
          .where("stripe_customer_id", "=", customerId)
          .executeTakeFirst();
        if (trialUser) {
          await handleTrialWillEnd(c.var.db, c.env, trialUser.user_id);
        }
        await identifyStripeUser(c, customerId);
        c.var.tracker.capture("[User] Trial Will End", {
          stripe_customer_id: customerId,
        });
        break;
      }

      default:
        logger.info("Unhandled event type", { event_type: event.type });
    }

    return c.json({ received: true });
  } catch (error) {
    logger.error("Error processing Stripe webhook", error as Error);
    if (error instanceof Error) {
      return new Response(`Webhook error: ${error.message}`, { status: 500 });
    }
    return new Response("Internal server error", { status: 500 });
  }
});

/**
 * Look up user ID from Stripe customer ID, set as tracker distinctId, and
 * push person properties so users who onboarded via Stripe Checkout (without
 * opening the Flutter app) still get a populated PostHog profile.
 */
async function identifyStripeUser(c: any, stripeCustomerId: string) {
  const row = await c.var.db
    .selectFrom("user_subscription")
    .innerJoin("user", "user.id", "user_subscription.user_id")
    .select([
      "user_subscription.user_id",
      "user.email",
      "user.name",
      "user.created_at",
    ])
    .where("user_subscription.stripe_customer_id", "=", stripeCustomerId)
    .executeTakeFirst();

  if (row) {
    c.var.tracker.setDistinctId(row.user_id);
    c.var.tracker.setPersonProperties(
      row.user_id,
      { email: row.email, name: row.name },
      { signup_date: new Date(row.created_at).toISOString() },
    );
  }
}

/**
 * Handle subscription created/updated events
 */
export async function handleSubscriptionUpdate(
  c: any,
  subscription: Stripe.Subscription
) {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  const customerId = subscription.customer as string;

  // Cross-platform guard: if this user has flipped to an active App Store
  // entitlement (e.g. the IAP convert path just cancelled their Stripe sub
  // and Stripe fires both subscription.deleted AND subscription.updated with
  // status='canceled'), do NOT overwrite the apple entitlement row.
  // handleSubscriptionDeleted already guards the same way.
  if (await hasActiveAppStoreEntitlement(c.var.db, customerId)) {
    logger.info(
      "Skipping Stripe subscription.updated — user has an active App Store entitlement",
      { customer_id: customerId, subscription_id: subscription.id }
    );
    return;
  }

  const { start, end } = getBillingCycleDates(subscription);
  const status = mapStripeStatus(subscription.status);

  // Determine plan from subscription metadata, validated against known values
  const validPlans = ["free", "core", "pro", "team"];
  const plan = validPlans.includes(subscription.metadata.plan)
    ? (subscription.metadata.plan as PlanKey)
    : ("free" as PlanKey);
  // Stripe-native trial: trial_end is set while the sub is in `trialing`
  // status, then cleared automatically when the trial converts to active.
  // We mirror it into trial_ends_at so the rest of the app can read trial
  // state from the DB.
  const trialEndsAt = subscription.trial_end
    ? new Date(subscription.trial_end * 1000)
    : null;

  // Read the old plan before updating (for sync history expansion detection)
  const oldUserSub = await c.var.db
    .selectFrom("user_subscription")
    .select(["plan", "user_id", "trial_ends_at"])
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();
  const oldPlan = (oldUserSub?.plan as PlanKey) ?? "free";
  // Detect trial → active conversion: was trialing in DB, now Stripe says
  // trial is over. Used to gate the upgrade celebration.
  const justEndedTrial =
    !!oldUserSub?.trial_ends_at && trialEndsAt === null;

  // Try user_subscription first, then team_subscription
  let isUserSubscription = false;
  try {
    const userResult = await c.var.db
      .updateTable("user_subscription")
      .set({
        stripe_subscription_id: subscription.id,
        plan,
        status,
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
        trial_ends_at: trialEndsAt ? trialEndsAt.toISOString() : null,
      })
      .where("stripe_customer_id", "=", customerId)
      .executeTakeFirst();

    isUserSubscription =
      !!userResult && BigInt(userResult.numUpdatedRows) > 0n;

    if (!isUserSubscription) {
      // Not a user subscription — try team_subscription
      await c.var.db
        .updateTable("team_subscription")
        .set({
          stripe_subscription_id: subscription.id,
          plan,
          status,
          billing_cycle_start: start.toISOString(),
          billing_cycle_end: end.toISOString(),
        })
        .where("stripe_customer_id", "=", customerId)
        .execute();
    }
  } catch (error) {
    logger.error("Failed to update subscription", error as Error, {
      customer_id: customerId,
    });
    throw new Error(`Database update failed: ${(error as Error).message}`);
  }

  // Enforce limits on downgrade
  await enforceDowngradeLimits(
    c.var.db,
    c.env,
    c.executionCtx as ExecutionContext,
    customerId,
    plan,
    logger
  );

  // Cancel any stale personal Stripe subscriptions when a new paid sub lands.
  // Scoped to personal subs: user clicks upgrade again → new Pro sub arrives →
  // cancel the previous one so the customer isn't double-billed. The resulting
  // `customer.subscription.deleted` webhook is a no-op because
  // handleSubscriptionDeleted early-returns when another active sub exists.
  if (plan !== "free" && isUserSubscription) {
    try {
      const stripeClient = createStripeClient(c.env.STRIPE_SECRET_KEY);
      const activeSubscriptions = await stripeClient.subscriptions.list({
        customer: customerId,
        status: "active",
      });

      for (const sub of activeSubscriptions.data) {
        if (sub.id !== subscription.id) {
          await stripeClient.subscriptions.cancel(sub.id);
          logger.info("Canceled stale personal subscription on upgrade", {
            canceled_subscription_id: sub.id,
            canceled_plan: sub.metadata.plan ?? "unknown",
            new_subscription_id: subscription.id,
            customer_id: customerId,
          });
        }
      }
    } catch (error) {
      logger.error("Failed to cancel stale personal subscription", error as Error, {
        customer_id: customerId,
      });
      c.var.tracker.captureException(error as Error, {
        operation: "cancel_stale_personal_subscription",
        customer_id: customerId,
      });
    }
  }

  // Backfill embeddings when upgrading from free to a paid plan
  if (plan !== "free") {
    const upgradeUser = await c.var.db
      .selectFrom("user_subscription")
      .select("user_id")
      .where("stripe_customer_id", "=", customerId)
      .executeTakeFirst();

    if (upgradeUser) {
      c.executionCtx.waitUntil(
        backfillEmbeddings(c.env, upgradeUser.user_id).catch((error) => {
          logger.error("Failed to backfill embeddings on upgrade", error as Error, {
            user_id: upgradeUser.user_id,
          });
        })
      );
    }
  }

  // Trigger historical re-sync when sync history range expands on upgrade
  if (
    PLAN_LIMITS[plan].syncHistoryDays > PLAN_LIMITS[oldPlan].syncHistoryDays &&
    oldUserSub?.user_id
  ) {
    c.executionCtx.waitUntil(
      triggerHistoryResync(
        c.var.db,
        c.env,
        c.executionCtx as ExecutionContext,
        oldUserSub.user_id,
        logger
      ).catch((error) => {
        logger.error("Failed to trigger history re-sync on upgrade", error as Error, {
          user_id: oldUserSub.user_id,
          old_plan: oldPlan,
          new_plan: plan,
        });
      })
    );
  }

  // Detect trial → paid conversion: Stripe just cleared subscription.trial_end
  // (or the user upgraded to a higher plan during the trial). Either way,
  // post the celebration note and complete outstanding trial todos.
  if (plan !== "free" && oldUserSub?.user_id && justEndedTrial) {
    try {
      await handleTrialUpgrade(c.var.db, c.env, oldUserSub.user_id);
    } catch (error) {
      logger.error("Failed to handle trial upgrade", error as Error, {
        customer_id: customerId,
      });
    }
  }

  // Update connection_group_quantity for org subscriptions
  const quantity = subscription.items?.data?.[0]?.quantity ?? 1;
  await c.var.db
    .updateTable("team_subscription")
    .set({ connection_group_quantity: quantity })
    .where("stripe_customer_id", "=", customerId)
    .execute();

  logger.info("Updated subscription for customer", {
    customer_id: customerId,
    plan,
    status,
  });

  // Notify affected users so the Flutter app picks up the plan change.
  // For personal subscriptions, notify the single user.
  // For org subscriptions, notify all org members.
  const syncUser = await c.var.db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();

  if (syncUser) {
    await notifySubscriptionChange(c, [syncUser.user_id]);
  }

  const orgMemberIds = await getOrgMemberUserIds(c.var.db, customerId);
  if (orgMemberIds.length > 0) {
    await notifySubscriptionChange(c, orgMemberIds);
  }
}

// ---------------------------------------------------------------------------
// App Store entitlement guard — exported for unit testing
// ---------------------------------------------------------------------------

/**
 * Returns true iff the stripe_customer_id currently maps to an active App Store
 * entitlement. A row is considered active when `origin = 'app_store'` AND either
 * `status = 'active'` OR `billing_cycle_end` is in the future (covers
 * cancelled-but-not-yet-expired Apple subscriptions).
 *
 * Used by `handleSubscriptionDeleted` to avoid reverting a user to free when the
 * IAP convert path has already replaced their Stripe sub with an Apple entitlement
 * and then cancelled the Stripe sub (which fires `customer.subscription.deleted`).
 */
export async function hasActiveAppStoreEntitlement(
  db: Kysely<DB>,
  stripeCustomerId: string
): Promise<boolean> {
  const row = await db
    .selectFrom("user_subscription")
    .select(["status", "billing_cycle_end"])
    .where("stripe_customer_id", "=", stripeCustomerId)
    .where("origin", "=", "app_store")
    .executeTakeFirst();
  return (
    row !== undefined &&
    (row.status === "active" ||
      (row.billing_cycle_end != null &&
        new Date(row.billing_cycle_end).getTime() > Date.now()))
  );
}

/**
 * Handle subscription deleted event - revert to free tier
 */
export async function handleSubscriptionDeleted(
  c: any,
  subscription: Stripe.Subscription
) {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  const customerId = subscription.customer as string;

  // If the customer still has other active Stripe subscriptions, skip the
  // revert-to-free flow. This prevents a race where cancelling a stale Free
  // sub during an upgrade silently downgrades the just-upgraded paid plan and
  // spawns a replacement Free sub. The still-active sub's own webhooks govern
  // the DB state.
  const stripeClient = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const activeSubs = await stripeClient.subscriptions.list({
    customer: customerId,
    status: "active",
  });
  const otherActive = activeSubs.data.filter((s) => s.id !== subscription.id);
  if (otherActive.length > 0) {
    logger.info(
      "Skipping free-revert — customer has other active subscriptions",
      {
        customer_id: customerId,
        deleted_subscription_id: subscription.id,
        active_subscription_ids: otherActive.map((s) => s.id),
      }
    );
    return;
  }

  // Cross-platform guard: if this user has flipped to an active App Store
  // entitlement (e.g. the IAP convert path just cancelled their Stripe trial /
  // free_monthly sub), do NOT revert to free or recreate a free Stripe sub.
  // The Apple subscription is the source of truth now.
  if (await hasActiveAppStoreEntitlement(c.var.db, customerId)) {
    logger.info("Skipping free-revert — user has an active App Store entitlement", {
      customer_id: customerId,
      deleted_subscription_id: subscription.id,
    });
    return;
  }

  // Trial cancellation path: Stripe is firing this because the trial ended
  // without a payment method (trial_settings.end_behavior='cancel'). Run
  // expireTrial first to post the expiry note, complete trial todos, and
  // archive excess connections/twists. Safe no-op if the user wasn't on a
  // trial — expireTrial guards on plan='core' && trial_ends_at.
  if (subscription.metadata.plan === "core" || subscription.trial_end) {
    const trialUser = await c.var.db
      .selectFrom("user_subscription")
      .select(["user_id"])
      .where("stripe_customer_id", "=", customerId)
      .executeTakeFirst();
    if (trialUser) {
      try {
        await expireTrial(
          c.var.db,
          c.env,
          c.executionCtx as ExecutionContext,
          trialUser.user_id,
          customerId
        );
      } catch (error) {
        logger.error("Failed to expire trial on subscription delete", error as Error, {
          customer_id: customerId,
        });
      }
    }
  }

  const { start, end } = createFreeTierBillingCycle();

  // Revert to free tier — try user_subscription first, then team_subscription
  try {
    const userResult = await c.var.db
      .updateTable("user_subscription")
      .set({
        stripe_subscription_id: null,
        plan: "free",
        status: "active",
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
      })
      .where("stripe_customer_id", "=", customerId)
      .executeTakeFirst();

    if (!userResult || BigInt(userResult.numUpdatedRows) === 0n) {
      await c.var.db
        .updateTable("team_subscription")
        .set({
          stripe_subscription_id: null,
          plan: "free",
          status: "active",
          billing_cycle_start: start.toISOString(),
          billing_cycle_end: end.toISOString(),
        })
        .where("stripe_customer_id", "=", customerId)
        .execute();
    }
  } catch (error) {
    logger.error("Failed to update subscription", error as Error, {
      customer_id: customerId,
    });
    throw new Error(`Database update failed: ${(error as Error).message}`);
  }

  // Enforce limits after reverting to free tier
  await enforceDowngradeLimits(
    c.var.db,
    c.env,
    c.executionCtx as ExecutionContext,
    customerId,
    "free",
    logger
  );

  // Reinstate a free-tier Stripe subscription so usage limits continue to track
  const deletedUserSub = await c.var.db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();

  if (deletedUserSub) {
    try {
      const freeSub = await createFreeSubscription(stripeClient, {
        customerId,
        userId: deletedUserSub.user_id,
      });
      const freeDates = getBillingCycleDates(freeSub);

      await c.var.db
        .updateTable("user_subscription")
        .set({
          stripe_subscription_id: freeSub.id,
          billing_cycle_start: freeDates.start.toISOString(),
          billing_cycle_end: freeDates.end.toISOString(),
        })
        .where("stripe_customer_id", "=", customerId)
        .execute();

      logger.info("Reinstated free Stripe subscription after cancellation", {
        customer_id: customerId,
        free_subscription_id: freeSub.id,
      });
    } catch (error) {
      logger.error("Failed to reinstate free subscription", error as Error, {
        customer_id: customerId,
      });
    }
  }

  logger.info("Reverted customer to free tier", {
    customer_id: customerId,
  });

  // Notify affected users so the Flutter app picks up the plan change.
  const syncUser = await c.var.db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();

  if (syncUser) {
    await notifySubscriptionChange(c, [syncUser.user_id]);
  }

  const orgMemberIds = await getOrgMemberUserIds(c.var.db, customerId);
  if (orgMemberIds.length > 0) {
    await notifySubscriptionChange(c, orgMemberIds);
  }
}

/**
 * Notify one or more users that their subscription has changed by writing to
 * user_sync and poking their UserSync DO.
 */
async function notifySubscriptionChange(
  c: any,
  userIds: string[]
) {
  for (const userId of userIds) {
    await c.var.db
      .insertInto("user_sync")
      .values({
        user_id: userId,
        entity: "subscription",
        last_update_at: sql`now()`,
      })
      .onConflict((oc: any) =>
        oc.columns(["user_id", "entity"]).doUpdateSet({
          last_update_at: sql`now()`,
        })
      )
      .execute();
    notifyUserSync(c, userId);
  }
}

/**
 * Get all user IDs that belong to a team (by stripe customer ID).
 */
async function getOrgMemberUserIds(
  db: any,
  stripeCustomerId: string
): Promise<string[]> {
  const orgSub = await db
    .selectFrom("team_subscription")
    .select("team_id")
    .where("stripe_customer_id", "=", stripeCustomerId)
    .executeTakeFirst();

  if (!orgSub) return [];

  const members = await db
    .selectFrom("team_user")
    .select("user_id")
    .where("team_id", "=", orgSub.team_id)
    .execute();

  return members.map((m: any) => m.user_id as string);
}

/**
 * After a plan change, trim excess connections and twists to match the new
 * plan's limits. Connections go through `removeAuth` and twists through
 * `archiveAndDeleteTwist` so the connector/twist lifecycle callbacks run
 * and threads/links are archived — matching what happens when the user
 * performs the same action in the app.
 */
async function enforceDowngradeLimits(
  db: any,
  env: Bindings,
  ctx: ExecutionContext,
  stripeCustomerId: string,
  newPlan: string,
  logger: any
) {
  const limits = PLAN_LIMITS[newPlan as keyof typeof PLAN_LIMITS] ?? PLAN_LIMITS.free;

  // Check if this is a user subscription
  const userSub = await db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", stripeCustomerId)
    .executeTakeFirst();

  if (userSub) {
    const factory = twistFactory({ env, ctx, db });
    await enforcePersonalPlanLimits({
      db,
      env,
      twistFactory: factory,
      userId: userSub.user_id,
      limits,
    });
    return;
  }

  // Team downgrades: team ownership of twist_instance has not landed yet,
  // so there's nothing to trim for org subscriptions.
  void logger;
}

/**
 * Triggers re-sync for all enabled channels on a user's twist instances
 * when their plan's sync history range expands. Calls enableSync on each
 * channel, which dispatches onChannelEnabled with the updated syncHistoryMin.
 * Connectors handle idempotency by comparing their stored sync_history_min
 * with the new limit and only re-syncing if the range actually expanded.
 */
async function triggerHistoryResync(
  db: any,
  env: Bindings,
  ctx: ExecutionContext,
  userId: string,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  // Find all enabled channels for twist instances owned by this user
  const channels = await db
    .selectFrom("channel as c")
    .innerJoin("twist_instance as ti", "ti.id", "c.twist_instance_id")
    .select([
      "c.twist_instance_id",
      "c.channel_id",
    ])
    .where("ti.owner_id", "=", userId)
    .where("ti.archived_at", "is", null)
    .where("c.enabled", "=", true)
    .execute();

  if (channels.length === 0) return;

  logger.info("Triggering history re-sync for plan upgrade", {
    user_id: userId,
    channel_count: channels.length,
  });

  const factory = twistFactory({ env, ctx, db });

  // Group channels by twist_instance_id so we load config once per twist
  const byInstance = new Map<string, string[]>();
  for (const ch of channels) {
    const existing = byInstance.get(ch.twist_instance_id) ?? [];
    existing.push(ch.channel_id);
    byInstance.set(ch.twist_instance_id, existing);
  }

  for (const [twistInstanceId, channelIds] of byInstance) {
    try {
      // Resolve twist metadata to load config
      const twistInfo = await db
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .select([
          "twist.twist_package_id as twistPackageId",
          "twist.version",
        ])
        .where("twist_instance.id", "=", twistInstanceId)
        .executeTakeFirst();
      if (!twistInfo) continue;

      const configRaw = await env.TWIST_CONFIG.get(
        `${twistInfo.twistPackageId}:${twistInfo.version}`
      );
      if (!configRaw) continue;

      const config = JSON.parse(configRaw);
      const integrationsMap: Record<string, string> = config.integrationsMap ?? {};
      const integrationsPath = Object.values(integrationsMap)[0];
      if (!integrationsPath) continue;

      // Get the provider from the connection or source provider config
      const connection = await db
        .selectFrom("twist_instance_connection")
        .select("provider")
        .where("twist_instance_id", "=", twistInstanceId)
        .limit(1)
        .executeTakeFirst();
      const provider = connection?.provider ?? config.sourceProvider?.provider;
      if (!provider) continue;

      const twistWrapper = await factory({ twistInstanceId });

      for (const channelId of channelIds) {
        try {
          const result = await twistWrapper.callCallback(
            integrationsPath.split(":"),
            "enableSync",
            provider,
            channelId,
            userId,
            undefined // title
          );
          disposeRpc(result);
        } catch (error) {
          logger.error("Failed to re-sync channel on upgrade", error as Error, {
            twist_instance_id: twistInstanceId,
            channel_id: channelId,
          });
        }
      }
    } catch (error) {
      logger.error("Failed to process twist for re-sync", error as Error, {
        twist_instance_id: twistInstanceId,
      });
    }
  }
}

export default stripe;
