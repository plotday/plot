import { Hono } from "hono";
import type Stripe from "stripe";

import type { Kysely } from "kysely";

import type { Bindings } from "../env";
import {
  createStripeClient,
  createStripeCustomer,
  createFreeTierBillingCycle,
  isCustomerDeletedError,
} from "../stripe/utils";
import {
  customerHasPaymentMethod,
  provisionAddonCredit,
  createAddonCheckoutSession,
  createAddonCardSetupSession,
  setTwistAddonQuantity,
  TWIST_ADDON,
} from "../stripe/addons";
import {
  applyAppleAddonTransactionToUser,
  applyAppleTransactionToUser,
  applyAppleTwistAddonTransactionToUser,
  isAddonProduct,
  isTwistAddonProduct,
  verifyTransaction,
} from "../apple/iap";
import { createLogger, type Logger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";
import { getEffectivePlan } from "../utils/plan";
import { getUsage, twistAddonBlocksNeeded } from "../utils/limits";
import { createTeamSetupTask } from "./team";
import { notifySync } from "./sync/notify";
import type { DB } from "../db-types";

const upgrade = new Hono<{ Bindings: Bindings }>();

function planFromLookupKey(key: string): "pro" | "team" {
  if (key.startsWith("team")) return "team";
  return "pro";
}

// ---------------------------------------------------------------------------
// IAP helpers — exported for unit testing
// ---------------------------------------------------------------------------

/**
 * Returns true iff the user currently holds an active, paid (non-free) Stripe
 * subscription. A trialing or free_monthly Stripe row is convertible to Apple
 * IAP and does NOT trigger the guard.
 */
export async function hasActivePaidStripeSubscription(
  db: Kysely<DB>,
  userId: string
): Promise<boolean> {
  const row = await db
    .selectFrom("user_subscription")
    .select(["origin", "status", "plan"])
    .where("user_id", "=", userId)
    .executeTakeFirst();
  return (
    row !== undefined &&
    row.origin === "stripe" &&
    row.status === "active" &&
    row.plan !== "free"
  );
}

/** Minimal interface for the Stripe client surface we need at cancel time. */
type StripeCancelClient = {
  subscriptions: {
    cancel: (id: string) => Promise<unknown>;
  };
};

/** Minimal tracker interface so tests can pass a simple stub. */
type Tracker = { captureException: (e: Error) => void };

/**
 * Best-effort cancellation of a superseded Stripe subscription.
 *
 * If `stripeSubId` is null, does nothing. If the Stripe API call fails, the
 * error is reported to PostHog via `tracker.captureException` and a warning is
 * logged, but the error is NOT re-thrown — the Apple entitlement has already
 * been applied and must not be rolled back due to a Stripe API hiccup. The
 * `customer.subscription.deleted` webhook guard (Task 3) provides an
 * additional safety net.
 */
export async function cancelStripeSubscriptionBestEffort(
  stripeSubId: string | null,
  stripe: StripeCancelClient,
  tracker: Tracker,
  logger: Pick<Logger, "warn">
): Promise<void> {
  if (!stripeSubId) return;
  try {
    await stripe.subscriptions.cancel(stripeSubId);
  } catch (e) {
    tracker.captureException(e as Error);
    logger.warn(
      "IAP: failed to cancel superseded Stripe subscription",
      { stripe_subscription_id: stripeSubId, error: (e as Error).message }
    );
  }
}

/**
 * How Stripe bills an add-on quantity change. `always_invoice` reconciles the
 * proration on the spot: an increase charges the prorated remainder of the
 * current period immediately, and a decrease banks a prorated credit on the
 * customer balance (applied to future invoices, not refunded to the card).
 * Chosen over `create_prorations` so annual subscribers aren't handed add-ons
 * free until their distant renewal.
 */
export const ADDON_PRORATION_BEHAVIOR = "always_invoice" as const;

/**
 * Build the single subscription-item mutation that sets a customer's add-on
 * connection count. Pure (no Stripe I/O) so the add/remove/delete decision is
 * unit-testable:
 *  - existing add-on item + quantity > 0 → update its quantity
 *  - existing add-on item + quantity 0   → delete the item
 *  - no existing item (adding the first) → attach `newAddonPriceId` at quantity
 */
export function buildAddonItemUpdate(
  existingAddonItemId: string | null,
  quantity: number,
  newAddonPriceId: string | null
): Stripe.SubscriptionUpdateParams.Item {
  if (existingAddonItemId) {
    return quantity > 0
      ? { id: existingAddonItemId, quantity }
      : { id: existingAddonItemId, deleted: true };
  }
  if (!newAddonPriceId) {
    throw new Error(
      "buildAddonItemUpdate: newAddonPriceId required to add a new add-on item"
    );
  }
  return { price: newAddonPriceId, quantity };
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

// POST /upgrade/addons - Set the number of $5/mo connection add-ons on the
// user's (or team's) existing Stripe subscription. The add-on is a separate
// line item on the same subscription; Stripe prorates the quantity change.
// iOS App Store plans manage add-ons via StoreKit instead (see /upgrade/iap/
// verify) and get `manage_in_app` here.
//
// DEPRECATED (pricing model change): add-ons are now usage-synced — provisioned
// per-connection via POST /upgrade/addons/purchase and reconciled down on
// disable, rather than set as an absolute quantity. No current client calls
// this absolute-quantity endpoint (the web upgrade page no longer has a stepper;
// the Flutter app uses /addons/purchase). Kept for backwards compatibility; safe
// to retire in a follow-up once we're confident no old client hits it.
upgrade.post("/upgrade/addons", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);
  const user = c.var.user;

  const body = await c.req.json<{ quantity?: number; teamId?: string }>();
  const quantity = Math.floor(body.quantity ?? 0);
  if (!Number.isFinite(quantity) || quantity < 0) {
    return c.json({ error: "quantity must be a non-negative integer" }, 400);
  }

  // Resolve the target subscription (personal or team).
  let stripeSubscriptionId: string | null = null;
  let plan = "free";
  if (body.teamId) {
    const member = await c.var.db
      .selectFrom("team_user")
      .select("role")
      .where("team_id", "=", body.teamId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();
    if (!member || member.role !== "admin") {
      return c.json({ error: "Must be team admin to change add-ons" }, 403);
    }
    const teamSub = await c.var.db
      .selectFrom("team_subscription")
      .select(["stripe_subscription_id", "plan"])
      .where("team_id", "=", body.teamId)
      .executeTakeFirst();
    stripeSubscriptionId = teamSub?.stripe_subscription_id ?? null;
    plan = teamSub?.plan ?? "free";
  } else {
    const sub = await c.var.db
      .selectFrom("user_subscription")
      .select(["stripe_subscription_id", "plan", "origin"])
      .where("user_id", "=", user.id)
      .executeTakeFirst();
    if (sub?.origin === "app_store") {
      // App Store plans manage add-ons through StoreKit, not Stripe.
      return c.json({ error: "manage_in_app" }, 409);
    }
    stripeSubscriptionId = sub?.stripe_subscription_id ?? null;
    plan = sub?.plan ?? "free";
  }

  if (plan === "free") {
    return c.json({ error: "Add-ons require a paid plan" }, 400);
  }
  if (!stripeSubscriptionId) {
    return c.json({ error: "No active subscription found" }, 400);
  }

  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);

  // Load the subscription to find the plan interval and any existing add-on
  // item. The add-on price must share the plan's interval (Stripe requires all
  // recurring items on a subscription to use the same interval).
  const sub = await stripe.subscriptions.retrieve(stripeSubscriptionId);
  const items = sub.items.data;
  const isAddonItem = (i: Stripe.SubscriptionItem) =>
    (i.price?.lookup_key ?? "").startsWith("addon");
  const planItem = items.find((i) => !isAddonItem(i));
  const addonItem = items.find(isAddonItem);
  const interval =
    planItem?.price?.recurring?.interval === "year" ? "annual" : "monthly";
  const addonLookupKey = `addon_${interval}`;

  if (!addonItem && quantity === 0) {
    return c.json({ addons: 0 });
  }

  // Build the single item mutation: update / delete the existing add-on item,
  // or add a new one resolved by lookup key.
  let itemUpdate: Stripe.SubscriptionUpdateParams.Item;
  if (addonItem) {
    itemUpdate = buildAddonItemUpdate(addonItem.id, quantity, null);
  } else {
    const prices = await stripe.prices.list({
      lookup_keys: [addonLookupKey],
      limit: 1,
    });
    if (prices.data.length === 0) {
      logger.error("Add-on price not configured", undefined, {
        lookup_key: addonLookupKey,
      });
      return c.json({ error: "Add-on price not configured" }, 500);
    }
    itemUpdate = buildAddonItemUpdate(null, quantity, prices.data[0].id);
  }

  // always_invoice: charge an increase's proration now, credit a decrease now —
  // so annual subscribers aren't given add-ons free until renewal.
  await stripe.subscriptions.update(stripeSubscriptionId, {
    items: [itemUpdate],
    proration_behavior: ADDON_PRORATION_BEHAVIOR,
  });

  // Reflect immediately; the subscription.updated webhook re-syncs the same
  // value from the line-item quantity.
  if (body.teamId) {
    await c.var.db
      .updateTable("team_subscription")
      .set({ premium_connection_addons: quantity })
      .where("team_id", "=", body.teamId)
      .execute();
  } else {
    await c.var.db
      .updateTable("user_subscription")
      .set({ premium_connection_addons: quantity })
      .where("user_id", "=", user.id)
      .execute();
  }

  c.var.tracker.capture("[User] Addons Updated", {
    quantity,
    team_id: body.teamId ?? null,
  });

  return c.json({ addons: quantity });
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

  // Defense-in-depth: a genuinely paid Stripe subscriber must manage/upgrade
  // (including add-ons) on the web — the client already hides IAP for them.
  // A trial or free (free_monthly) Stripe row is convertible.
  if (await hasActivePaidStripeSubscription(c.var.db, user.id)) {
    logger.warn("IAP: blocked — active paid Stripe plan, manage on web", {
      user_id: user.id,
    });
    return c.json({ error: "manage_on_web" }, 409);
  }

  // Add-on subscription: update only the add-on credit count; no plan change
  // and no Stripe plan-subscription reconciliation.
  if (isAddonProduct(txn.productId)) {
    const addonResult = await applyAppleAddonTransactionToUser(
      c.var.db,
      user.id,
      txn
    );
    c.var.tracker.capture("[User] Subscription Updated", {
      origin: "app_store",
      apple_product_id: txn.productId,
      addon_count: addonResult.addons,
    });
    return c.json({
      addons: addonResult.addons,
      expires_at: addonResult.expiresAt?.toISOString() ?? null,
      origin: "app_store",
    });
  }

  // Twist add-on subscription: update only the twist add-on count; no plan change
  // and no Stripe plan-subscription reconciliation.
  if (isTwistAddonProduct(txn.productId)) {
    const twistAddonResult = await applyAppleTwistAddonTransactionToUser(
      c.var.db,
      user.id,
      txn
    );
    c.var.tracker.capture("[User] Subscription Updated", {
      origin: "app_store",
      apple_product_id: txn.productId,
      twist_addon_count: twistAddonResult.twistAddons,
    });
    return c.json({
      twist_addons: twistAddonResult.twistAddons,
      expires_at: twistAddonResult.expiresAt?.toISOString() ?? null,
      origin: "app_store",
    });
  }

  const result = await applyAppleTransactionToUser(c.var.db, user.id, txn);

  // Reconcile: cancel the now-superseded Stripe subscription (the Core trial
  // or the free_monthly tracker). The row is already origin=app_store, so the
  // customer.subscription.deleted webhook will defer to it (Task 3).
  const prevSubId = result.previous?.stripeSubscriptionId ?? null;
  if (prevSubId) {
    const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
    await cancelStripeSubscriptionBestEffort(
      prevSubId,
      stripe,
      c.var.tracker,
      logger
    );
  }

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

/**
 * Core purchase logic for one add-on credit. Extracted for unit testability.
 *
 * If the customer has a payment method on file, charges off-session via
 * `provisionAddonCredit` and immediately reflects the new quantity + sub ID in
 * the DB, then returns `{ ok: true, addons }`. Otherwise creates a Stripe
 * Checkout session to capture a card and returns `{ ok: false, checkout_url }`.
 */
export async function purchaseAddonCreditForScope(args: {
  stripe: Stripe;
  db: Kysely<DB>;
  customerId: string;
  addonSubscriptionId: string | null;
  scopeMetadata: Record<string, string>;
  siteRoot: string;
  table: "user_subscription" | "team_subscription";
  idVal: string;
  captureException: (e: unknown) => void;
}): Promise<{ ok: true; addons: number } | { ok: false; checkout_url: string }> {
  const {
    stripe,
    db,
    customerId,
    addonSubscriptionId,
    scopeMetadata,
    siteRoot,
    table,
    idVal,
    captureException,
  } = args;

  if (await customerHasPaymentMethod(stripe, customerId)) {
    const { subscriptionId, quantity } = await provisionAddonCredit({
      stripe,
      customerId,
      addonSubscriptionId,
      scopeMetadata,
    });
    // Reflect immediately; the webhook re-syncs the same values.
    // Wrap in try/catch: a write failure after a successful charge must NOT
    // surface as an error to the caller — the webhook will reconcile the DB.
    try {
      if (table === "team_subscription") {
        await db
          .updateTable("team_subscription")
          .set({
            premium_connection_addons: quantity,
            stripe_addon_subscription_id: subscriptionId,
          })
          .where("team_id", "=", idVal)
          .execute();
      } else {
        await db
          .updateTable("user_subscription")
          .set({
            premium_connection_addons: quantity,
            stripe_addon_subscription_id: subscriptionId,
          })
          .where("user_id", "=", idVal)
          .execute();
      }
    } catch (e) {
      captureException(e);
    }
    return { ok: true, addons: quantity };
  }

  const checkout_url = await createAddonCheckoutSession({
    stripe,
    customerId,
    siteRoot,
    scopeMetadata,
  });
  return { ok: false, checkout_url };
}

/**
 * Charge-on-enable helper for the add-on consent flow.
 *
 * Called when a user has already consented to an add-on charge and is enabling
 * a connection. If the customer has a card on file, charges immediately via
 * `provisionAddonCredit` and writes the new quantity + sub ID to the scope row,
 * returning `{ ok: true, addons }`. Otherwise returns a Stripe Setup session
 * URL (no charge, card capture only) as `{ ok: false, needsCard: true, checkout_url }`.
 */
export async function provisionAddonForConsentedEnable(args: {
  stripe: Stripe;
  db: Kysely<DB>;
  customerId: string;
  addonSubscriptionId: string | null;
  scopeMetadata: Record<string, string>;
  siteRoot: string;
  table: "user_subscription" | "team_subscription";
  idVal: string;
  captureException: (e: unknown) => void;
}): Promise<{ ok: true; addons: number } | { ok: false; needsCard: true; checkout_url: string }> {
  const {
    stripe,
    db,
    customerId,
    addonSubscriptionId,
    scopeMetadata,
    siteRoot,
    table,
    idVal,
    captureException,
  } = args;

  if (await customerHasPaymentMethod(stripe, customerId)) {
    const { subscriptionId, quantity } = await provisionAddonCredit({
      stripe,
      customerId,
      addonSubscriptionId,
      scopeMetadata,
    });
    // Reflect immediately; the webhook re-syncs the same values.
    // Wrap in try/catch: a write failure after a successful charge must NOT
    // surface as an error to the caller — the webhook will reconcile the DB.
    try {
      if (table === "team_subscription") {
        await db
          .updateTable("team_subscription")
          .set({
            premium_connection_addons: quantity,
            stripe_addon_subscription_id: subscriptionId,
          })
          .where("team_id", "=", idVal)
          .execute();
      } else {
        await db
          .updateTable("user_subscription")
          .set({
            premium_connection_addons: quantity,
            stripe_addon_subscription_id: subscriptionId,
          })
          .where("user_id", "=", idVal)
          .execute();
      }
    } catch (e) {
      captureException(e);
    }
    return { ok: true, addons: quantity };
  }

  const checkout_url = await createAddonCardSetupSession({
    stripe,
    customerId,
    siteRoot,
    scopeMetadata,
  });
  return { ok: false, needsCard: true, checkout_url };
}

// POST /upgrade/addons/purchase - Provision one add-on connection credit.
// If the customer has a card on file, charges off-session immediately and
// returns { ok: true, addons }. Otherwise returns { ok: false, checkout_url }
// pointing to a Stripe Checkout session that captures a card and creates the
// add-on subscription in one step.
upgrade.post("/upgrade/addons/purchase", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ teamId?: string }>().catch(
    () => ({} as { teamId?: string })
  );
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  const isTeam = !!body.teamId;

  if (isTeam) {
    const member = await c.var.db
      .selectFrom("team_user")
      .select("role")
      .where("team_id", "=", body.teamId!)
      .where("user_id", "=", user.id)
      .executeTakeFirst();
    if (!member || member.role !== "admin") {
      return c.json({ error: "Must be team admin to purchase add-ons" }, 403);
    }
  }

  const row = isTeam
    ? await c.var.db
        .selectFrom("team_subscription")
        .select(["stripe_customer_id", "stripe_addon_subscription_id"])
        .where("team_id", "=", body.teamId!)
        .executeTakeFirst()
    : await c.var.db
        .selectFrom("user_subscription")
        .select(["stripe_customer_id", "stripe_addon_subscription_id"])
        .where("user_id", "=", user.id)
        .executeTakeFirst();

  if (!row?.stripe_customer_id) {
    return c.json({ error: "No billing account found" }, 400);
  }

  const scopeMetadata: Record<string, string> = isTeam
    ? { team_id: body.teamId! }
    : { user_id: user.id };

  try {
    return c.json(
      await purchaseAddonCreditForScope({
        stripe,
        db: c.var.db,
        customerId: row.stripe_customer_id,
        addonSubscriptionId: row.stripe_addon_subscription_id ?? null,
        scopeMetadata,
        siteRoot,
        table: isTeam ? "team_subscription" : "user_subscription",
        idVal: isTeam ? body.teamId! : user.id,
        captureException: (e) => c.var.tracker.captureException(e as Error),
      })
    );
  } catch (error) {
    c.var.tracker.captureException(error as Error);
    return c.json({ error: "Failed to purchase add-on" }, 500);
  }
});

/**
 * Core purchase logic for a twist-add-on block set. Extracted for unit testability.
 *
 * Computes the target block count (`twistAddonBlocksNeeded`) for the scope,
 * including any `pendingWeight` for a blocked candidate twist not yet installed.
 * If the scope already has enough purchased blocks, returns `{ ok: true,
 * twist_addons: currentTwistAddonCount }` without touching Stripe (idempotent).
 *
 * If the customer has a payment method on file, sets the Stripe twist-add-on
 * subscription to the target quantity off-session and immediately reflects the
 * new count + sub ID in the DB, then returns `{ ok: true, twist_addons }`.
 * Otherwise creates a Stripe Checkout session to capture a card and returns
 * `{ ok: false, checkout_url }`.
 *
 * `pendingWeight` (default 0): the capacity_weight of the blocked candidate
 * twist. Pass the `candidate_weight` from the `twist_addon_required` 403 error
 * so the target accounts for the twist that is waiting to be enabled.
 */
export async function purchaseTwistAddonBlocksForScope(args: {
  stripe: Stripe;
  db: Kysely<DB>;
  customerId: string;
  twistAddonSubscriptionId: string | null;
  currentTwistAddonCount: number;
  scope: { userId: string } | { teamId: string };
  siteRoot: string;
  table: "user_subscription" | "team_subscription";
  idVal: string;
  captureException: (e: unknown) => void;
  pendingWeight?: number;
}): Promise<{ ok: true; twist_addons: number } | { ok: false; checkout_url: string }> {
  const {
    stripe,
    db,
    customerId,
    twistAddonSubscriptionId,
    currentTwistAddonCount,
    scope,
    siteRoot,
    table,
    idVal,
    captureException,
    pendingWeight = 0,
  } = args;

  const target = await twistAddonBlocksNeeded(db, scope, pendingWeight);

  // Already have enough headroom — idempotent, no charge.
  if (target <= currentTwistAddonCount) {
    return { ok: true, twist_addons: currentTwistAddonCount };
  }

  const scopeMetadata: Record<string, string> =
    "userId" in scope ? { user_id: scope.userId } : { team_id: scope.teamId };

  if (await customerHasPaymentMethod(stripe, customerId)) {
    const { subscriptionId, quantity } = await setTwistAddonQuantity({
      stripe,
      customerId,
      twistAddonSubscriptionId,
      scopeMetadata,
      quantity: target,
    });
    // Reflect immediately; the webhook re-syncs the same values.
    // Wrap in try/catch: a write failure after a successful charge must NOT
    // surface as an error to the caller — the webhook will reconcile the DB.
    try {
      if (table === "team_subscription") {
        await db
          .updateTable("team_subscription")
          .set({
            twist_addon_count: quantity,
            stripe_twist_addon_subscription_id: subscriptionId,
          })
          .where("team_id", "=", idVal)
          .execute();
      } else {
        await db
          .updateTable("user_subscription")
          .set({
            twist_addon_count: quantity,
            stripe_twist_addon_subscription_id: subscriptionId,
          })
          .where("user_id", "=", idVal)
          .execute();
      }
    } catch (e) {
      captureException(e);
    }
    return { ok: true, twist_addons: quantity };
  }

  const checkout_url = await createAddonCheckoutSession({
    kind: TWIST_ADDON,
    stripe,
    customerId,
    siteRoot,
    scopeMetadata,
  });
  return { ok: false, checkout_url };
}

// POST /upgrade/twist-addons/purchase - Purchase twist-add-on blocks.
// Computes the target block count for the scope and, if the customer has a
// card on file, charges off-session and returns { ok: true, twist_addons }.
// Otherwise returns { ok: false, checkout_url } for a Stripe Checkout session.
//
// Optional body field `candidateWeight` (non-negative finite number, default
// 0): the capacity_weight of the blocked candidate twist that triggered the
// purchase flow. Echo the `candidate_weight` from the `twist_addon_required`
// 403 error payload so the target block count includes the pending twist's
// weight, not just the already-installed weight sum.
upgrade.post("/upgrade/twist-addons/purchase", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ teamId?: string; candidateWeight?: unknown }>().catch(
    () => ({} as { teamId?: string; candidateWeight?: unknown })
  );
  // Validate candidateWeight: must be a non-negative finite number; default 0
  // if absent, null, or invalid so existing callers without the field are unaffected.
  const rawCandidateWeight = body.candidateWeight;
  const candidateWeight =
    typeof rawCandidateWeight === "number" &&
    Number.isFinite(rawCandidateWeight) &&
    rawCandidateWeight >= 0
      ? rawCandidateWeight
      : 0;
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  const isTeam = !!body.teamId;

  if (isTeam) {
    // Twist add-ons are personal-only; teams scale via 50-slot capacity blocks.
    return c.json({ error: "twist_add_ons_personal_only" }, 400);
  }

  const row = await c.var.db
    .selectFrom("user_subscription")
    .select([
      "stripe_customer_id",
      "stripe_twist_addon_subscription_id",
      "twist_addon_count",
    ])
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!row?.stripe_customer_id) {
    return c.json({ error: "No billing account found" }, 400);
  }

  const scope = { userId: user.id };

  try {
    return c.json(
      await purchaseTwistAddonBlocksForScope({
        stripe,
        db: c.var.db,
        customerId: row.stripe_customer_id,
        twistAddonSubscriptionId: row.stripe_twist_addon_subscription_id ?? null,
        currentTwistAddonCount: row.twist_addon_count ?? 0,
        scope,
        siteRoot,
        table: "user_subscription",
        idVal: user.id,
        captureException: (e) => c.var.tracker.captureException(e as Error),
        pendingWeight: candidateWeight,
      })
    );
  } catch (error) {
    c.var.tracker.captureException(error as Error);
    return c.json({ error: "Failed to purchase twist add-on" }, 500);
  }
});

export default upgrade;
