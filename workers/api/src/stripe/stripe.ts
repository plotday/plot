import { Hono } from "hono";
import type Stripe from "stripe";

import type { Bindings } from "../env";
import {
  createFreeTierBillingCycle,
  createStripeClient,
  getBillingCycleDates,
  mapStripeStatus,
  verifyWebhookSignature,
} from "./utils";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";

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
      event = verifyWebhookSignature(
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
      case "customer.subscription.created":
      case "customer.subscription.updated": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionUpdate(c, subscription);
        break;
      }

      case "customer.subscription.deleted": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionDeleted(c, subscription);
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
        break;
      }

      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        logger.warn("Payment failed", {
          customer_id: invoice.customer as string,
          subscription_id: invoice.subscription as string,
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
  const validPlans = ["free", "pro", "business"];
  const plan = validPlans.includes(subscription.metadata.plan)
    ? (subscription.metadata.plan as "free" | "pro" | "business")
    : "free";

  // Update user_subscription record
  try {
    await c.var.db
      .updateTable("user_subscription")
      .set({
        stripe_subscription_id: subscription.id,
        plan,
        status,
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
      })
      .where("stripe_customer_id", "=", customerId)
      .execute();
  } catch (error) {
    logger.error("Failed to update user_subscription", error as Error, {
      customer_id: customerId,
    });
    throw new Error(`Database update failed: ${(error as Error).message}`);
  }

  logger.info("Updated subscription for customer", {
    customer_id: customerId,
    plan,
    status,
  });
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

  // Revert to free tier
  try {
    await c.var.db
      .updateTable("user_subscription")
      .set({
        stripe_subscription_id: null,
        plan: "free",
        status: "active",
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
      })
      .where("stripe_customer_id", "=", customerId)
      .execute();
  } catch (error) {
    logger.error("Failed to update user_subscription", error as Error, {
      customer_id: customerId,
    });
    throw new Error(`Database update failed: ${(error as Error).message}`);
  }

  logger.info("Reverted customer to free tier", {
    customer_id: customerId,
  });
}

export default stripe;
