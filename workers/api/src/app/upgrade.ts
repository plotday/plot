import { Hono } from "hono";

import type { Bindings } from "../env";
import { createStripeClient, createFreeTierBillingCycle } from "../stripe/utils";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";
import { getEffectivePlan } from "../utils/plan";
import { getUsage } from "../utils/limits";
import { createOrgPriority } from "./organization";
import { notifySync } from "./sync/notify";

const upgrade = new Hono<{ Bindings: Bindings }>();

function planFromLookupKey(key: string): "pro" | "business" {
  if (key.startsWith("business")) return "business";
  return "pro";
}

// GET /upgrade - Get current subscription status with effective plan
upgrade.get("/upgrade", async (c) => {
  const user = c.var.user;

  const subscription = await c.var.db
    .selectFrom("user_subscription")
    .select(["plan", "status", "billing_cycle_end"])
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  const effective = await getEffectivePlan(c.var.db, user.id);

  const base = subscription
    ? {
        plan: subscription.plan,
        status: subscription.status,
        billing_cycle_end: subscription.billing_cycle_end,
      }
    : { plan: "free", status: "active", billing_cycle_end: null };

  return c.json({
    ...base,
    effective_plan: effective.plan,
    effective_source: effective.source,
    organization: effective.source === "organization"
      ? {
          id: effective.organizationId,
          name: effective.organizationName,
        }
      : null,
  });
});

// GET /upgrade/usage - Get connection and twist usage counts
upgrade.get("/upgrade/usage", async (c) => {
  const user = c.var.user;
  const usage = await getUsage(c.var.db, user.id, c.env);
  return c.json(usage);
});

// POST /upgrade/checkout - Create Stripe Checkout session
upgrade.post("/upgrade/checkout", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);
  const user = c.var.user;

  const body = await c.req.json<{
    priceLookupKey: string;
    quantity?: number;
    organizationId?: string;
    organizationName?: string;
    domainAutoJoin?: boolean;
  }>();

  if (!body.priceLookupKey) {
    return c.json({ error: "priceLookupKey is required" }, 400);
  }

  const plan = planFromLookupKey(body.priceLookupKey);
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  // Business plan: route through organization
  if (plan === "business") {
    let orgId = body.organizationId;

    if (!orgId) {
      // Auto-create org
      const orgName = body.organizationName?.trim();
      if (!orgName) {
        return c.json({ error: "organizationName is required for business plan" }, 400);
      }

      const org = await c.var.db
        .insertInto("organization")
        .values({ name: orgName })
        .returning(["id"])
        .executeTakeFirstOrThrow();

      orgId = String(org.id);

      // Add user as admin
      await c.var.db
        .insertInto("organization_member")
        .values({
          organization_id: org.id,
          user_id: user.id,
          role: "admin",
        })
        .execute();

      // Link user's email domain with auto_join if requested
      const domainAutoJoin = body.domainAutoJoin !== false; // default true
      const emailDomain = user.email.split("@")[1]?.toLowerCase();
      if (emailDomain) {
        await c.var.db
          .insertInto("domain")
          .values({
            name: emailDomain,
            organization_id: org.id,
            auto_join: domainAutoJoin,
          })
          .onConflict((oc) =>
            oc.column("name").doUpdateSet({
              organization_id: org.id,
              auto_join: domainAutoJoin,
            })
          )
          .execute();
      }

      // Create org-linked priority
      const priorityId = await createOrgPriority(c.var.db, org.id, orgName, user.id);
      notifySync(c, priorityId);

      logger.info("Created organization for business checkout", {
        organization_id: orgId,
        user_id: user.id,
      });
    } else {
      // Verify user is admin of existing org
      const member = await c.var.db
        .selectFrom("organization_member")
        .select("role")
        .where("organization_id", "=", orgId)
        .where("user_id", "=", user.id)
        .executeTakeFirst();

      if (!member || member.role !== "admin") {
        return c.json({ error: "Must be org admin to subscribe" }, 403);
      }
    }

    // Get or create org Stripe customer
    let orgSub = await c.var.db
      .selectFrom("organization_subscription")
      .select("stripe_customer_id")
      .where("organization_id", "=", orgId)
      .executeTakeFirst();

    let stripeCustomerId = orgSub?.stripe_customer_id;

    if (!stripeCustomerId) {
      const orgRow = await c.var.db
        .selectFrom("organization")
        .select("name")
        .where("id", "=", orgId)
        .executeTakeFirstOrThrow();

      const customer = await stripe.customers.create({
        name: orgRow.name,
        email: user.email,
        metadata: { organization_id: orgId },
      });
      stripeCustomerId = customer.id;

      const { start, end } = createFreeTierBillingCycle();
      await c.var.db
        .insertInto("organization_subscription")
        .values({
          organization_id: orgId as any,
          stripe_customer_id: stripeCustomerId,
          plan: "free",
          status: "active",
          billing_cycle_start: start.toISOString(),
          billing_cycle_end: end.toISOString(),
        })
        .onConflict((oc) =>
          oc.column("organization_id").doUpdateSet({
            stripe_customer_id: stripeCustomerId!,
          })
        )
        .execute();
    }

    // Look up price
    const prices = await stripe.prices.list({
      lookup_keys: [body.priceLookupKey],
      limit: 1,
    });

    if (prices.data.length === 0) {
      return c.json({ error: "Price not found" }, 400);
    }

    const session = await stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      line_items: [{ price: prices.data[0].id, quantity: body.quantity || 1 }],
      mode: "subscription",
      success_url: `${siteRoot}/upgrade?success=true&org=${orgId}`,
      cancel_url: `${siteRoot}/upgrade?canceled=true`,
      subscription_data: {
        metadata: { plan: "business", organization_id: orgId },
      },
    });

    if (!session.url) {
      logger.error("Stripe checkout session created without URL", undefined, {
        session_id: session.id,
      });
      return c.json({ error: "Failed to create checkout session" }, 500);
    }

    return c.json({ url: session.url, organizationId: orgId });
  }

  // Pro plan: use personal subscription
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

  // Look up price by lookup key
  const prices = await stripe.prices.list({
    lookup_keys: [body.priceLookupKey],
    limit: 1,
  });

  if (prices.data.length === 0) {
    return c.json({ error: "Price not found" }, 400);
  }

  const session = await stripe.checkout.sessions.create({
    customer: subscription.stripe_customer_id,
    line_items: [
      {
        price: prices.data[0].id,
        quantity: body.quantity || 1,
      },
    ],
    mode: "subscription",
    success_url: `${siteRoot}/upgrade?success=true`,
    cancel_url: `${siteRoot}/upgrade?canceled=true`,
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

// POST /upgrade/portal - Create Stripe Customer Portal session
upgrade.post("/upgrade/portal", async (c) => {
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
    return_url: `${siteRoot}/upgrade`,
  });

  return c.json({ url: session.url });
});

export default upgrade;
