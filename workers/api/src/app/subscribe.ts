import { Hono } from "hono";

import type { Bindings } from "../env";
import { createStripeClient } from "../stripe/utils";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";

const subscribe = new Hono<{ Bindings: Bindings }>();

function planFromLookupKey(key: string): "pro" | "business" {
  if (key.startsWith("business")) return "business";
  return "pro";
}

// GET /subscribe - Get current subscription status
subscribe.get("/subscribe", async (c) => {
  const user = c.var.user;

  const subscription = await c.var.db
    .selectFrom("user_subscription")
    .select(["plan", "status", "billing_cycle_end"])
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!subscription) {
    return c.json({ plan: "free", status: "active", billing_cycle_end: null });
  }

  return c.json({
    plan: subscription.plan,
    status: subscription.status,
    billing_cycle_end: subscription.billing_cycle_end,
  });
});

// POST /subscribe/checkout - Create Stripe Checkout session
subscribe.post("/subscribe/checkout", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);
  const user = c.var.user;

  const body = await c.req.json<{
    priceLookupKey: string;
    quantity?: number;
  }>();

  if (!body.priceLookupKey) {
    return c.json({ error: "priceLookupKey is required" }, 400);
  }

  // Get stripe customer ID
  const subscription = await c.var.db
    .selectFrom("user_subscription")
    .select("stripe_customer_id")
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!subscription?.stripe_customer_id) {
    logger.error("No Stripe customer ID found", undefined, {
      user_id: user.id,
    });
    return c.json({ error: "No billing account found" }, 400);
  }

  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  // Look up price by lookup key
  const prices = await stripe.prices.list({
    lookup_keys: [body.priceLookupKey],
    limit: 1,
  });

  if (prices.data.length === 0) {
    return c.json({ error: "Price not found" }, 400);
  }

  const plan = planFromLookupKey(body.priceLookupKey);

  const session = await stripe.checkout.sessions.create({
    customer: subscription.stripe_customer_id,
    line_items: [
      {
        price: prices.data[0].id,
        quantity: body.quantity || 1,
      },
    ],
    mode: "subscription",
    success_url: `${siteRoot}/subscribe?success=true`,
    cancel_url: `${siteRoot}/subscribe?canceled=true`,
    subscription_data: {
      metadata: { plan },
    },
  });

  if (!session.url) {
    logger.error("Stripe checkout session created without URL", undefined, {
      session_id: session.id,
    });
    return c.json({ error: "Failed to create checkout session" }, 500);
  }

  return c.json({ url: session.url });
});

// POST /subscribe/portal - Create Stripe Customer Portal session
subscribe.post("/subscribe/portal", async (c) => {
  const user = c.var.user;

  const subscription = await c.var.db
    .selectFrom("user_subscription")
    .select("stripe_customer_id")
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!subscription?.stripe_customer_id) {
    return c.json({ error: "No billing account found" }, 400);
  }

  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  const session = await stripe.billingPortal.sessions.create({
    customer: subscription.stripe_customer_id,
    return_url: `${siteRoot}/subscribe`,
  });

  return c.json({ url: session.url });
});

export default subscribe;
