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
import { sql } from "kysely";
import { PLAN_LIMITS, TEAM_CONNECTIONS_PER_GROUP } from "../utils/limits";
import { backfillEmbeddings } from "../queue/backfill-embeddings";
import { notifyUserSync } from "../app/sync/notify";
import { handleTrialUpgrade } from "../utils/trial";

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
        logger.info("Trial ending soon", {
          subscription_id: subscription.id,
          customer_id: subscription.customer as string,
        });
        // Opportunity to send notification to user
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
 * Look up user ID from Stripe customer ID and set as tracker distinctId.
 */
async function identifyStripeUser(c: any, stripeCustomerId: string) {
  const userSub = await c.var.db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", stripeCustomerId)
    .executeTakeFirst();

  if (userSub) {
    c.var.tracker.setDistinctId(userSub.user_id);
  }
}

/**
 * Handle subscription created/updated events
 */
async function handleSubscriptionUpdate(
  c: any,
  subscription: Stripe.Subscription
) {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  const customerId = subscription.customer as string;
  const { start, end } = getBillingCycleDates(subscription);
  const status = mapStripeStatus(subscription.status);

  // Determine plan from subscription metadata, validated against known values
  const validPlans = ["free", "core", "pro", "team"];
  const plan = validPlans.includes(subscription.metadata.plan)
    ? (subscription.metadata.plan as "free" | "core" | "pro" | "team")
    : "free";

  // Try user_subscription first, then organization_subscription
  try {
    const userResult = await c.var.db
      .updateTable("user_subscription")
      .set({
        stripe_subscription_id: subscription.id,
        plan,
        status,
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
      })
      .where("stripe_customer_id", "=", customerId)
      .executeTakeFirst();

    if (!userResult || BigInt(userResult.numUpdatedRows) === 0n) {
      // Not a user subscription — try organization_subscription
      await c.var.db
        .updateTable("organization_subscription")
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
  await enforceDowngradeLimits(c.var.db, customerId, plan, logger);

  // Cancel any old free-tier Stripe subscriptions when upgrading to a paid plan
  if (plan !== "free") {
    try {
      const stripeClient = createStripeClient(c.env.STRIPE_SECRET_KEY);
      const activeSubscriptions = await stripeClient.subscriptions.list({
        customer: customerId,
        status: "active",
      });

      for (const sub of activeSubscriptions.data) {
        if (sub.id !== subscription.id && sub.metadata.plan === "free") {
          await stripeClient.subscriptions.cancel(sub.id);
          logger.info("Canceled old free subscription on upgrade", {
            canceled_subscription_id: sub.id,
            new_subscription_id: subscription.id,
            customer_id: customerId,
          });
        }
      }
    } catch (error) {
      logger.error("Failed to cancel old free subscription", error as Error, {
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

  // Detect mid-trial upgrade: if user was on a reverse trial and just upgraded
  if (plan !== "free") {
    try {
      const trialUser = await c.var.db
        .selectFrom("user_subscription")
        .select(["user_id", "trial_ends_at"])
        .where("stripe_customer_id", "=", customerId)
        .where("trial_ends_at", "is not", null)
        .executeTakeFirst();

      if (trialUser && new Date(trialUser.trial_ends_at!).getTime() > Date.now()) {
        await handleTrialUpgrade(c.var.db, c.env, trialUser.user_id);
      }
    } catch (error) {
      logger.error("Failed to handle trial upgrade", error as Error, {
        customer_id: customerId,
      });
    }
  }

  // Update connection_group_quantity for org subscriptions
  const quantity = subscription.items?.data?.[0]?.quantity ?? 1;
  await c.var.db
    .updateTable("organization_subscription")
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

/**
 * Handle subscription deleted event - revert to free tier
 */
async function handleSubscriptionDeleted(
  c: any,
  subscription: Stripe.Subscription
) {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  const customerId = subscription.customer as string;
  const { start, end } = createFreeTierBillingCycle();

  // Revert to free tier — try user_subscription first, then organization_subscription
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
        .updateTable("organization_subscription")
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
  await enforceDowngradeLimits(c.var.db, customerId, "free", logger);

  // Reinstate a free-tier Stripe subscription so usage limits continue to track
  const deletedUserSub = await c.var.db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();

  if (deletedUserSub) {
    try {
      const stripeClient = createStripeClient(c.env.STRIPE_SECRET_KEY);
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
 * Get all user IDs that belong to an organization (by stripe customer ID).
 */
async function getOrgMemberUserIds(
  db: any,
  stripeCustomerId: string
): Promise<string[]> {
  const orgSub = await db
    .selectFrom("organization_subscription")
    .select("organization_id")
    .where("stripe_customer_id", "=", stripeCustomerId)
    .executeTakeFirst();

  if (!orgSub) return [];

  const members = await db
    .selectFrom("organization_member")
    .select("user_id")
    .where("organization_id", "=", orgSub.organization_id)
    .execute();

  return members.map((m: any) => m.user_id as string);
}

/**
 * After a plan change, delete excess connections and archive excess twists.
 */
async function enforceDowngradeLimits(
  db: any,
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
    // Personal downgrade: trim connections
    if (limits.connections !== Infinity) {
      const excess = await db
        .selectFrom("priority_twist_connection as ptc")
        .innerJoin("priority_twist as pt", "pt.id", "ptc.priority_twist_id")
        .leftJoin("priority as p", "p.id", "pt.priority_id")
        .select(["ptc.priority_twist_id", "ptc.user_id", "ptc.provider"])
        .where("ptc.user_id", "=", userSub.user_id)
        .where((eb: any) =>
          eb.or([
            eb("pt.priority_id", "is", null),
            eb("p.organization_id", "is", null),
          ])
        )
        .orderBy("ptc.connected_at", "desc")
        .offset(limits.connections)
        .execute();

      for (const row of excess) {
        await db
          .deleteFrom("priority_twist_connection")
          .where("priority_twist_id", "=", row.priority_twist_id)
          .where("user_id", "=", row.user_id)
          .where("provider", "=", row.provider)
          .execute();
      }

      if (excess.length > 0) {
        logger.info("Trimmed excess personal connections on downgrade", {
          user_id: userSub.user_id,
          removed: excess.length,
        });
      }
    }

    // Personal downgrade: archive excess twists
    if (limits.twists !== Infinity) {
      const excessTwists = await db
        .selectFrom("priority_twist as pt")
        .innerJoin("twist as t", "t.id", "pt.twist_id")
        .leftJoin("priority as p", "p.id", "pt.priority_id")
        .select("pt.id")
        .where("pt.owner_id", "=", userSub.user_id)
        .where("pt.archived_at", "is", null)
        .where("t.is_source", "=", false)
        .where((eb: any) =>
          eb.or([
            eb("pt.priority_id", "is", null),
            eb("p.organization_id", "is", null),
          ])
        )
        .orderBy("pt.created_at", "desc")
        .offset(limits.twists)
        .execute();

      for (const row of excessTwists) {
        await db
          .updateTable("priority_twist")
          .set({ archived_at: new Date().toISOString() })
          .where("id", "=", row.id)
          .execute();
      }

      if (excessTwists.length > 0) {
        logger.info("Archived excess personal twists on downgrade", {
          user_id: userSub.user_id,
          archived: excessTwists.length,
        });
      }
    }

    return;
  }

  // Check if this is an org subscription
  const orgSub = await db
    .selectFrom("organization_subscription")
    .select(["organization_id", "connection_group_quantity"])
    .where("stripe_customer_id", "=", stripeCustomerId)
    .executeTakeFirst();

  if (orgSub) {
    const orgId = String(orgSub.organization_id);
    const orgLimit = orgSub.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP;

    // For free orgs, limit is 0; for team, use group-based limit
    const effectiveLimit = newPlan === "free" ? 0 : orgLimit;

    const excessOrgConns = await db
      .selectFrom("priority_twist_connection as ptc")
      .innerJoin("priority_twist as pt", "pt.id", "ptc.priority_twist_id")
      .innerJoin("priority as p", "p.id", "pt.priority_id")
      .select(["ptc.priority_twist_id", "ptc.user_id", "ptc.provider"])
      .where("p.organization_id", "=", orgId)
      .orderBy("ptc.connected_at", "desc")
      .offset(effectiveLimit)
      .execute();

    for (const row of excessOrgConns) {
      await db
        .deleteFrom("priority_twist_connection")
        .where("priority_twist_id", "=", row.priority_twist_id)
        .where("user_id", "=", row.user_id)
        .where("provider", "=", row.provider)
        .execute();
    }

    if (excessOrgConns.length > 0) {
      logger.info("Trimmed excess org connections on downgrade", {
        organization_id: orgId,
        removed: excessOrgConns.length,
      });
    }
  }
}

export default stripe;
