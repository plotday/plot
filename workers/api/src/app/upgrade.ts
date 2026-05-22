import { Hono } from "hono";

import type { Bindings } from "../env";
import {
  createStripeClient,
  createStripeCustomer,
  createFreeTierBillingCycle,
  isCustomerDeletedError,
} from "../stripe/utils";
import {
  applyAppleTransactionToUser,
  verifyTransaction,
} from "../apple/iap";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";
import { getEffectivePlan } from "../utils/plan";
import { getUsage } from "../utils/limits";
import { createTeamSetupTask } from "./team";
import { notifySync } from "./sync/notify";

const upgrade = new Hono<{ Bindings: Bindings }>();

function planFromLookupKey(key: string): "core" | "pro" | "team" {
  if (key.startsWith("team")) return "team";
  if (key.startsWith("core")) return "core";
  return "pro";
}

// GET /upgrade - Get current subscription status with effective plan
upgrade.get("/upgrade", async (c) => {
  const user = c.var.user;

  const subscription = await c.var.db
    .selectFrom("user_subscription")
    .select([
      "plan",
      "status",
      "billing_cycle_end",
      "trial_ends_at",
      "origin",
    ])
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  const effective = await getEffectivePlan(c.var.db, user.id);

  const base = subscription
    ? {
        plan: subscription.plan,
        status: subscription.status,
        billing_cycle_end: subscription.billing_cycle_end,
        trial_ends_at: subscription.trial_ends_at,
        // Only surface origin to the client when the user has a paid
        // plan — free users have origin='stripe' by default but the
        // app cares about it for routing "Manage subscription".
        origin: subscription.plan !== "free" ? subscription.origin : null,
      }
    : {
        plan: "free",
        status: "active",
        billing_cycle_end: null,
        trial_ends_at: null,
        origin: null,
      };

  // Fetch all orgs the user belongs to with subscription info
  const orgs = await c.var.db
    .selectFrom("team_user as om")
    .innerJoin("team as o", "o.id", "om.team_id")
    .leftJoin(
      "team_subscription as os",
      "os.team_id",
      "om.team_id"
    )
    .select([
      "o.id",
      "o.name",
      "om.role",
      "os.plan",
      "os.status",
    ])
    .where("om.user_id", "=", user.id)
    .execute();

  const orgIds = orgs.map((o) => o.id);
  let memberCounts: Record<string, number> = {};
  if (orgIds.length > 0) {
    const counts = await c.var.db
      .selectFrom("team_user")
      .select(["team_id"])
      .select((eb: any) => eb.fn.count("id").as("count"))
      .where("team_id", "in", orgIds)
      .groupBy("team_id")
      .execute();

    for (const row of counts as any[]) {
      memberCounts[String(row.team_id)] = Number(row.count);
    }
  }

  return c.json({
    ...base,
    effective_plan: effective.plan,
    effective_source: effective.source,
    teams: orgs.map((o) => ({
      id: String(o.id),
      name: o.name,
      role: o.role,
      plan: o.plan ?? "free",
      status: o.status ?? "active",
      memberCount: memberCounts[String(o.id)] ?? 0,
    })),
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
    teamId?: string;
    teamName?: string;
    domainAutoJoin?: boolean;
  }>();

  if (!body.priceLookupKey) {
    return c.json({ error: "priceLookupKey is required" }, 400);
  }

  const plan = planFromLookupKey(body.priceLookupKey);
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  // Team plan: route through team
  if (plan === "team") {
    let orgId = body.teamId;

    if (!orgId) {
      const orgName = body.teamName?.trim();
      if (!orgName) {
        return c.json({ error: "teamName is required for team plan" }, 400);
      }

      // Reuse org from a previous incomplete checkout attempt (has subscription record with free plan)
      const pendingOrg = await c.var.db
        .selectFrom("team_user as om")
        .innerJoin("team_subscription as os", "os.team_id", "om.team_id")
        .innerJoin("team as o", "o.id", "om.team_id")
        .select(["o.id", "o.name"])
        .where("om.user_id", "=", user.id)
        .where("om.role", "=", "admin")
        .where("os.plan", "=", "free")
        .executeTakeFirst();

      if (pendingOrg) {
        orgId = String(pendingOrg.id);

        // Update org name if the user changed it
        if (pendingOrg.name !== orgName) {
          await c.var.db
            .updateTable("team")
            .set({ name: orgName })
            .where("id", "=", pendingOrg.id)
            .execute();
        }

        logger.info("Reusing pending team for team checkout", {
          team_id: orgId,
          user_id: user.id,
        });
      } else {
        // Create new org
        const org = await c.var.db
          .insertInto("team")
          .values({ name: orgName })
          .returning(["id"])
          .executeTakeFirstOrThrow();

        orgId = String(org.id);

        // Add user as admin
        await c.var.db
          .insertInto("team_user")
          .values({
            team_id: org.id,
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
              team_id: org.id,
              auto_join: domainAutoJoin,
            })
            .onConflict((oc) =>
              oc.column("name").doUpdateSet({
                team_id: org.id,
                auto_join: domainAutoJoin,
              })
            )
            .execute();
        }

        // Create a task thread guiding the user to set up team priorities
        const priorityId = await createTeamSetupTask(c.var.db, orgName, user.id);
        if (priorityId) notifySync(c, priorityId);

        logger.info("Created team for team checkout", {
          team_id: orgId,
          user_id: user.id,
        });
      }
    } else {
      // Verify user is admin of existing org
      const member = await c.var.db
        .selectFrom("team_user")
        .select("role")
        .where("team_id", "=", orgId)
        .where("user_id", "=", user.id)
        .executeTakeFirst();

      if (!member || member.role !== "admin") {
        return c.json({ error: "Must be team admin to subscribe" }, 403);
      }
    }

    // Get or create org Stripe customer
    let orgSub = await c.var.db
      .selectFrom("team_subscription")
      .select("stripe_customer_id")
      .where("team_id", "=", orgId)
      .executeTakeFirst();

    let stripeCustomerId = orgSub?.stripe_customer_id;

    if (!stripeCustomerId) {
      const orgRow = await c.var.db
        .selectFrom("team")
        .select(["name", "billing_email"])
        .where("id", "=", orgId)
        .executeTakeFirstOrThrow();

      const customer = await stripe.customers.create({
        name: orgRow.name,
        email: orgRow.billing_email || user.email,
        metadata: { team_id: orgId },
      });
      stripeCustomerId = customer.id;

      const { start, end } = createFreeTierBillingCycle();
      await c.var.db
        .insertInto("team_subscription")
        .values({
          team_id: orgId as any,
          stripe_customer_id: stripeCustomerId,
          plan: "free",
          status: "active",
          billing_cycle_start: start.toISOString(),
          billing_cycle_end: end.toISOString(),
        })
        .onConflict((oc) =>
          oc.column("team_id").doUpdateSet({
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

    const createTeamCheckoutSession = () =>
      stripe.checkout.sessions.create({
        customer: stripeCustomerId!,
        line_items: [{ price: prices.data[0].id, quantity: body.quantity || 1 }],
        mode: "subscription",
        success_url: `${siteRoot}/upgrade?success=true&org=${orgId}`,
        cancel_url: `${siteRoot}/upgrade?canceled=true`,
        allow_promotion_codes: true,
        billing_address_collection: "required",
        tax_id_collection: { enabled: true },
        customer_update: { address: "auto", name: "auto" },
        subscription_data: {
          metadata: { plan: "team", team_id: orgId },
        },
      });

    let session;
    try {
      session = await createTeamCheckoutSession();
    } catch (error) {
      if (!isCustomerDeletedError(error)) throw error;

      logger.info("Stripe org customer deleted, recreating", {
        team_id: orgId,
      });
      const orgRow = await c.var.db
        .selectFrom("team")
        .select(["name", "billing_email"])
        .where("id", "=", orgId)
        .executeTakeFirstOrThrow();

      const newCustomer = await stripe.customers.create({
        name: orgRow.name,
        email: orgRow.billing_email || user.email,
        metadata: { team_id: orgId },
      });
      stripeCustomerId = newCustomer.id;

      await c.var.db
        .updateTable("team_subscription")
        .set({ stripe_customer_id: stripeCustomerId! })
        .where("team_id", "=", orgId)
        .execute();

      session = await createTeamCheckoutSession();
    }

    if (!session.url) {
      logger.error("Stripe checkout session created without URL", undefined, {
        session_id: session.id,
      });
      return c.json({ error: "Failed to create checkout session" }, 500);
    }

    c.var.tracker.capture("[User] Checkout Started", {
      plan: "team",
      price_lookup_key: body.priceLookupKey,
      team_id: orgId,
    });

    return c.json({ url: session.url, teamId: orgId });
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

  let customerId = subscription.stripe_customer_id;

  const createCheckoutSession = () =>
    stripe.checkout.sessions.create({
      customer: customerId,
      line_items: [
        {
          price: prices.data[0].id,
          quantity: body.quantity || 1,
        },
      ],
      mode: "subscription",
      allow_promotion_codes: true,
      success_url: `${siteRoot}/upgrade?success=true`,
      cancel_url: `${siteRoot}/upgrade?canceled=true`,
      subscription_data: {
        metadata: { plan },
      },
    });

  let session;
  try {
    session = await createCheckoutSession();
  } catch (error) {
    if (!isCustomerDeletedError(error)) throw error;

    logger.info("Stripe customer deleted, recreating", { user_id: user.id });
    const newCustomer = await createStripeCustomer(stripe, {
      userId: user.id,
      email: user.email,
    });
    customerId = newCustomer.id;

    await c.var.db
      .updateTable("user_subscription")
      .set({ stripe_customer_id: customerId })
      .where("user_id", "=", user.id)
      .execute();

    session = await createCheckoutSession();
  }

  if (!session.url) {
    logger.error("Stripe checkout session created without URL", undefined, {
      session_id: session.id,
    });
    return c.json({ error: "Failed to create checkout session" }, 500);
  }

  c.var.tracker.capture("[User] Checkout Started", {
    plan,
    price_lookup_key: body.priceLookupKey,
  });

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

  let customerId = subscription.stripe_customer_id;

  try {
    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: `${siteRoot}/upgrade`,
    });
    return c.json({ url: session.url });
  } catch (error) {
    if (!isCustomerDeletedError(error)) throw error;

    const newCustomer = await createStripeCustomer(stripe, {
      userId: user.id,
      email: user.email,
    });
    customerId = newCustomer.id;

    await c.var.db
      .updateTable("user_subscription")
      .set({ stripe_customer_id: customerId })
      .where("user_id", "=", user.id)
      .execute();

    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: `${siteRoot}/upgrade`,
    });
    return c.json({ url: session.url });
  }
});

// POST /upgrade/iap/verify - Validate an Apple StoreKit transaction and
// apply the resulting entitlement to the current user. Called from the
// Flutter IAP service after StoreKit returns `purchased` or `restored`.
//
// Body: { product_id: string, source: string, purchase_id: string|null,
//         transaction_data: string }
// `transaction_data` is the StoreKit 2 signedTransaction JWS for iOS
// 15+ / macOS 12+ devices. For StoreKit 1 fallback it's a base64 receipt;
// not currently supported — clients must run on StoreKit 2.
upgrade.post("/upgrade/iap/verify", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);
  const user = c.var.user;

  const body = await c.req.json<{
    product_id?: string;
    source?: string;
    purchase_id?: string | null;
    transaction_data?: string;
  }>();

  if (body.source !== "app_store") {
    return c.json({ error: "Unsupported IAP source" }, 400);
  }
  if (!body.transaction_data) {
    return c.json({ error: "transaction_data is required" }, 400);
  }

  let txn;
  try {
    txn = await verifyTransaction(body.transaction_data);
  } catch (e) {
    logger.warn("IAP: failed to verify Apple transaction", {
      error: (e as Error).message,
      user_id: user.id,
    });
    return c.json({ error: "Invalid Apple transaction" }, 400);
  }

  // Cross-check: client-reported productId should match the JWS payload.
  // The JWS is the source of truth — if they disagree, log and proceed
  // with the JWS value.
  if (body.product_id && body.product_id !== txn.productId) {
    logger.warn(
      "IAP: client productId disagrees with JWS payload",
      {
        client_product_id: body.product_id,
        jws_product_id: txn.productId,
        user_id: user.id,
      }
    );
  }

  const result = await applyAppleTransactionToUser(c.var.db, user.id, txn);

  c.var.tracker.capture("[User] Subscription Created", {
    plan: result.plan,
    origin: "app_store",
    apple_product_id: txn.productId,
  });

  return c.json({
    plan: result.plan,
    expires_at: result.expiresAt?.toISOString() ?? null,
    origin: "app_store",
  });
});

export default upgrade;
