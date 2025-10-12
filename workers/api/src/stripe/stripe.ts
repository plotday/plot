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

const stripe = new Hono<{ Bindings: Bindings }>();

// POST /webhook - Handle Stripe webhook events
stripe.post("/webhook", async (c) => {
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
      console.error("Webhook signature verification failed:", err);
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
        console.warn(
          `Payment failed for customer ${invoice.customer}, subscription ${invoice.subscription}`
        );
        // Subscription status will be updated via subscription.updated event
        break;
      }

      case "customer.subscription.trial_will_end": {
        const subscription = event.data.object as Stripe.Subscription;
        console.log(
          `Trial ending soon for subscription ${subscription.id}, customer ${subscription.customer}`
        );
        // Opportunity to send notification to user
        break;
      }

      default:
        console.log(`Unhandled event type: ${event.type}`);
    }

    return c.json({ received: true });
  } catch (error) {
    console.error("Error processing Stripe webhook:", error);
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
  const customerId = subscription.customer as string;
  const { start, end } = getBillingCycleDates(subscription);
  const status = mapStripeStatus(subscription.status);

  // Determine plan from subscription metadata or price
  const plan = subscription.metadata.plan as any;

  // Update user_subscription record
  const { error } = await c.var.supabase
    .from("user_subscription")
    .update({
      stripe_subscription_id: subscription.id,
      plan,
      status,
      billing_cycle_start: start.toISOString(),
      billing_cycle_end: end.toISOString(),
    })
    .eq("stripe_customer_id", customerId);

  if (error) {
    console.error("Failed to update user_subscription:", error);
    throw new Error(`Database update failed: ${error.message}`);
  }

  console.log(
    `Updated subscription for customer ${customerId}: plan=${plan}, status=${status}`
  );
}

/**
 * Handle subscription deleted event - revert to free tier
 */
async function handleSubscriptionDeleted(
  c: any,
  subscription: Stripe.Subscription
) {
  const customerId = subscription.customer as string;
  const { start, end } = createFreeTierBillingCycle();

  // Revert to free tier
  const { error } = await c.var.supabase
    .from("user_subscription")
    .update({
      stripe_subscription_id: null,
      plan: "free",
      status: "active",
      billing_cycle_start: start.toISOString(),
      billing_cycle_end: end.toISOString(),
    })
    .eq("stripe_customer_id", customerId);

  if (error) {
    console.error("Failed to update user_subscription:", error);
    throw new Error(`Database update failed: ${error.message}`);
  }

  console.log(`Reverted customer ${customerId} to free tier`);
}

export default stripe;
