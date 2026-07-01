/**
 * Tests for /upgrade/iap/verify IAP guard + Stripe-cancel behaviors.
 *
 * APPROACH CHOSEN: Helper-extraction + real-DB unit tests (vitest node
 * environment, same config as iap.test.ts and limits.test.ts).
 *
 * Why NOT a full handler test:
 *   The handler calls `verifyTransaction` which does real Apple JWS
 *   verification (pinned x5c chain). Mocking that at the module level would
 *   require partial-mocking `../apple/iap` via `importActual`, making the
 *   harness fragile and complex. The existing `apple/iap.test.ts` already
 *   fully covers `applyAppleTransactionToUser` (the DB mutation). Task 2 adds
 *   two narrow behaviors: (a) the guard that rejects a paid Stripe user
 *   BEFORE calling `applyAppleTransactionToUser`, and (b) calling
 *   `stripe.subscriptions.cancel` AFTER a successful convert.
 *
 * Why the helper approach works:
 *   Both behaviors are extracted into two small, exported helpers in
 *   upgrade.ts:
 *     - `hasActivePaidStripeSubscription(db, userId)` → boolean
 *     - `cancelStripeSubscriptionBestEffort(stripeSubId, stripe, tracker, logger)` → void
 *   The handler delegates to these, so we can drive each path directly with
 *   a real Kysely connection to the worktree DB and a stubbed Stripe client —
 *   no HTTP layer, no JWS mocking required.
 *
 * DB integration tests are skipped when DATABASE_URL is absent (CI without DB).
 */

import { randomUUID } from "node:crypto";

import { Hono } from "hono";
import { sql, type Kysely } from "kysely";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import upgrade, {
  ADDON_PRORATION_BEHAVIOR,
  buildAddonItemUpdate,
  hasActivePaidStripeSubscription,
  cancelStripeSubscriptionBestEffort,
  purchaseAddonCreditForScope,
  purchaseTwistAddonBlocksForScope,
  provisionAddonForConsentedEnable,
} from "./upgrade";
import { computeTwistBlocksNeeded } from "../utils/limits";
import * as limits from "../utils/limits";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force a seeding transaction to roll back. */
class Rollback extends Error {}

/** Minimal Stripe-client stub — only the surface the cancel helper needs. */
function makeStripeMock() {
  return {
    subscriptions: {
      cancel: vi.fn().mockResolvedValue({}),
    },
  };
}

/** Minimal no-op tracker + logger stubs. */
const noopTracker = { captureException: vi.fn() };
const noopLogger = { warn: vi.fn() };

// ---------------------------------------------------------------------------
// hasActivePaidStripeSubscription — DB tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "hasActivePaidStripeSubscription",
  () => {
    it("returns true when the user has an active paid Stripe plan", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      let result = false;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_paid",
              stripe_subscription_id: "sub_paid",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActivePaidStripeSubscription(trx, userId);

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(true);
    });

    it("returns false when the user is on a Stripe trial (trialing)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      let result = true;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "trialing",
              origin: "stripe",
              stripe_customer_id: "cus_trial",
              stripe_subscription_id: "sub_trial",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActivePaidStripeSubscription(trx, userId);

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(false);
    });

    it("returns false when the user has an active free Stripe plan", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      let result = true;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_free",
              stripe_subscription_id: "sub_free",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActivePaidStripeSubscription(trx, userId);

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(false);
    });

    it("returns false when the user has no subscription row", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      let result = true;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActivePaidStripeSubscription(trx, userId);

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(false);
    });
  }
);

// ---------------------------------------------------------------------------
// cancelStripeSubscriptionBestEffort — pure unit tests (no DB needed)
// ---------------------------------------------------------------------------

describe("cancelStripeSubscriptionBestEffort", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("calls stripe.subscriptions.cancel with the subscription ID", async () => {
    const stripe = makeStripeMock();
    await cancelStripeSubscriptionBestEffort(
      "sub_x",
      stripe,
      noopTracker,
      noopLogger
    );
    expect(stripe.subscriptions.cancel).toHaveBeenCalledWith("sub_x");
  });

  it("does nothing when stripeSubId is null", async () => {
    const stripe = makeStripeMock();
    await cancelStripeSubscriptionBestEffort(
      null,
      stripe,
      noopTracker,
      noopLogger
    );
    expect(stripe.subscriptions.cancel).not.toHaveBeenCalled();
  });

  it("swallows the error and calls captureException on Stripe failure", async () => {
    const stripe = makeStripeMock();
    const err = new Error("Stripe API error");
    stripe.subscriptions.cancel.mockRejectedValueOnce(err);

    const tracker = { captureException: vi.fn() };
    const logger = { warn: vi.fn() };

    // Must not throw
    await expect(
      cancelStripeSubscriptionBestEffort("sub_fail", stripe, tracker, logger)
    ).resolves.toBeUndefined();

    expect(tracker.captureException).toHaveBeenCalledWith(err);
    expect(logger.warn).toHaveBeenCalled();
  });
});

describe("add-on quantity changes", () => {
  it("bills add-on changes immediately (always_invoice)", () => {
    // Annual subscribers must not get add-ons free until renewal; an increase
    // charges the prorated remainder now and a decrease credits it now.
    expect(ADDON_PRORATION_BEHAVIOR).toBe("always_invoice");
  });

  it("updates the quantity of an existing add-on item", () => {
    expect(buildAddonItemUpdate("si_addon", 3, null)).toEqual({
      id: "si_addon",
      quantity: 3,
    });
  });

  it("deletes the add-on item when the new quantity is 0", () => {
    expect(buildAddonItemUpdate("si_addon", 0, null)).toEqual({
      id: "si_addon",
      deleted: true,
    });
  });

  it("attaches a new add-on item by price when none exists yet", () => {
    expect(buildAddonItemUpdate(null, 2, "price_addon_monthly")).toEqual({
      price: "price_addon_monthly",
      quantity: 2,
    });
  });

  it("throws if asked to add a new add-on item without a price", () => {
    expect(() => buildAddonItemUpdate(null, 1, null)).toThrow();
  });
});

// ---------------------------------------------------------------------------
// purchaseAddonCreditForScope — DB + stub Stripe tests
// ---------------------------------------------------------------------------

/**
 * Build a minimal Stripe stub for purchaseAddonCreditForScope tests.
 * `hasCard` controls whether the customer has a default payment method.
 */
function makeStripeAddonMock(hasCard: boolean) {
  return {
    customers: {
      retrieve: vi.fn().mockResolvedValue(
        hasCard
          ? { deleted: false, invoice_settings: { default_payment_method: "pm_card" } }
          : { deleted: false, invoice_settings: {} }
      ),
    },
    paymentMethods: {
      list: vi.fn().mockResolvedValue({ data: [] }),
    },
    prices: {
      list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon_monthly" }] }),
    },
    subscriptions: {
      create: vi.fn().mockResolvedValue({
        id: "sub_new",
        items: { data: [{ id: "si_1", quantity: 1 }] },
      }),
      retrieve: vi.fn(),
      update: vi.fn(),
    },
    checkout: {
      sessions: {
        create: vi.fn().mockResolvedValue({ url: "https://checkout.stripe.com/pay/test" }),
      },
    },
  };
}

// ---------------------------------------------------------------------------
// purchaseAddonCreditForScope — write-back atomicity (pure unit, no DB needed)
// ---------------------------------------------------------------------------

describe("purchaseAddonCreditForScope write-back atomicity", () => {
  it("returns ok:true and calls captureException when write-back fails after a successful charge", async () => {
    const stripe = makeStripeAddonMock(true) as unknown as Stripe;
    const captureException = vi.fn();

    // No active credits — currentAddons:0 keeps the idempotency short-circuit
    // from firing (0 > 0 is false), so this still exercises the charge path.
    vi.spyOn(limits, "getBillableConnectionAddonCount").mockResolvedValue(0);

    // Minimal DB stub whose write path always rejects — simulates a transient
    // DB failure after the Stripe charge has already been processed.
    const failingDb = {
      updateTable: () => ({
        set: () => ({
          where: () => ({
            execute: () => Promise.reject(new Error("simulated write failure")),
          }),
        }),
      }),
    } as unknown as Kysely<DB>;

    const result = await purchaseAddonCreditForScope({
      stripe,
      db: failingDb,
      customerId: "cus_write_fail",
      addonSubscriptionId: null,
      currentAddons: 0,
      scope: { userId: "user_write_fail" },
      scopeMetadata: { user_id: "user_write_fail" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "user_write_fail",
      captureException,
    });

    // The charge succeeded; must report ok despite the write failure.
    expect(result).toEqual({ ok: true, addons: 1 });
    // The write failure must be captured so it surfaces in error tracking.
    expect(captureException).toHaveBeenCalledWith(expect.any(Error));
  });
});

describe.skipIf(!DATABASE_URL)(
  "purchaseAddonCreditForScope",
  () => {
    it("purchase with a card on file provisions a credit (ok:true)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const stripe = makeStripeAddonMock(true) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof purchaseAddonCreditForScope>> | undefined;
      let updatedRow:
        | { stripe_addon_subscription_id: string | null; premium_connection_addons: number }
        | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_test_purchase",
              stripe_subscription_id: "sub_plan_purchase",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          // No active credits for this fresh synthetic user — currentAddons:0
          // keeps the idempotency short-circuit from firing.
          // Keep replica mode so the helper's UPDATE doesn't re-trigger FK
          // checks on the synthetic userId (no matching row in the user table).
          result = await purchaseAddonCreditForScope({
            stripe,
            db: trx,
            customerId: "cus_test_purchase",
            addonSubscriptionId: null,
            currentAddons: 0,
            scope: { userId },
            scopeMetadata: { user_id: userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          updatedRow = await trx
            .selectFrom("user_subscription")
            .select(["stripe_addon_subscription_id", "premium_connection_addons"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toEqual({ ok: true, addons: 1 });
      expect(updatedRow?.stripe_addon_subscription_id).toBe("sub_new");
    });

    it("purchase with no card returns a checkout_url (ok:false)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const stripe = makeStripeAddonMock(false) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof purchaseAddonCreditForScope>> | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_test_nopay",
              stripe_subscription_id: "sub_plan_nopay",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          // No active credits for this fresh synthetic user — currentAddons:0
          // keeps the idempotency short-circuit from firing.
          // Keep replica mode so the helper's Stripe call (no DB writes on
          // no-card path) doesn't trigger FK checks on the synthetic userId.
          result = await purchaseAddonCreditForScope({
            stripe,
            db: trx,
            customerId: "cus_test_nopay",
            addonSubscriptionId: null,
            currentAddons: 0,
            scope: { userId },
            scopeMetadata: { user_id: userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toEqual({ ok: false, checkout_url: "https://checkout.stripe.com/pay/test" });
      expect((stripe as any).subscriptions.create).not.toHaveBeenCalled();
    });
  }
);

// ---------------------------------------------------------------------------
// provisionAddonForConsentedEnable — DB + stub Stripe tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "provisionAddonForConsentedEnable",
  () => {
    it("consented enable with card on file provisions a credit and writes the row", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const stripe = makeStripeAddonMock(true) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof provisionAddonForConsentedEnable>> | undefined;
      let updatedRow:
        | { stripe_addon_subscription_id: string | null; premium_connection_addons: number }
        | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_consented_card",
              stripe_subscription_id: "sub_plan_consented_card",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          result = await provisionAddonForConsentedEnable({
            stripe,
            db: trx,
            customerId: "cus_consented_card",
            addonSubscriptionId: null,
            scopeMetadata: { user_id: userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          updatedRow = await trx
            .selectFrom("user_subscription")
            .select(["stripe_addon_subscription_id", "premium_connection_addons"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toEqual({ ok: true, addons: 1 });
      expect(updatedRow?.premium_connection_addons).toBe(1);
      expect(updatedRow?.stripe_addon_subscription_id).toBe("sub_new");
    });

    it("consented enable with no card returns needsCard + coupon checkout url and does not charge", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      // Use a custom stub for the no-card path: since Task 2 this now routes
      // through createAddonCheckoutSession (mode:"subscription",
      // allow_promotion_codes:true) instead of the removed card-setup-only
      // session, so coupons work even on the enable-gate path.
      const stripe = {
        customers: {
          retrieve: vi.fn().mockResolvedValue({ deleted: false, invoice_settings: {} }),
        },
        paymentMethods: {
          list: vi.fn().mockResolvedValue({ data: [] }),
        },
        prices: {
          list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon" }] }),
        },
        subscriptions: {
          create: vi.fn(),
        },
        checkout: {
          sessions: {
            create: vi.fn().mockResolvedValue({
              url: "https://checkout.stripe.com/pay/cs_coupon?addon=success",
            }),
          },
        },
      } as unknown as Stripe;

      let result: Awaited<ReturnType<typeof provisionAddonForConsentedEnable>> | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_consented_nocard",
              stripe_subscription_id: "sub_plan_consented_nocard",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 60 * 60 * 1000
              ).toISOString(),
            })
            .execute();

          result = await provisionAddonForConsentedEnable({
            stripe,
            db: trx,
            customerId: "cus_consented_nocard",
            addonSubscriptionId: null,
            scopeMetadata: { user_id: userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toEqual({
        ok: false,
        needsCard: true,
        checkout_url: expect.stringContaining("addon=success"),
      });
      expect((stripe as any).subscriptions.create).not.toHaveBeenCalled();
      expect((stripe as any).checkout.sessions.create.mock.calls[0][0]).toMatchObject({
        mode: "subscription",
        allow_promotion_codes: true,
      });
    });
  }
);

// ---------------------------------------------------------------------------
// computeTwistBlocksNeeded — pure math tests (no DB needed)
// ---------------------------------------------------------------------------

describe("computeTwistBlocksNeeded", () => {
  it("returns 0 when weightSum equals base (no overflow)", () => {
    expect(computeTwistBlocksNeeded(1, 1)).toBe(0);
  });

  it("returns 0 when weightSum is less than base", () => {
    expect(computeTwistBlocksNeeded(0, 1)).toBe(0);
  });

  it("returns 4 when weightSum exceeds base by exactly 20 (Free base=1, weightSum=21, block_size=5)", () => {
    // overflow=20, ceil(20/5)=4 blocks
    expect(computeTwistBlocksNeeded(21, 1)).toBe(4);
  });

  it("returns 8 when weightSum exceeds base by exactly 40 (Free base=1, weightSum=41, block_size=5)", () => {
    // overflow=40, ceil(40/5)=8 blocks
    expect(computeTwistBlocksNeeded(41, 1)).toBe(8);
  });

  it("rounds up: 1 block for any overflow 1–20 above base", () => {
    // weightSum=2, base=1 → overflow=1 → ceil(1/20)=1
    expect(computeTwistBlocksNeeded(2, 1)).toBe(1);
  });

  it("uses team base of 10*blocks — weightSum=1, base=10 → 0 blocks", () => {
    expect(computeTwistBlocksNeeded(1, 10)).toBe(0);
  });

  it("needs 1 block when weightSum=11 and team base=10", () => {
    // overflow=1, ceil(1/20)=1
    expect(computeTwistBlocksNeeded(11, 10)).toBe(1);
  });

  // pendingWeight tests — ensures blocked candidate weight is factored in
  it("pendingWeight: Free base=1, weightSum=1, pending=2 → 1 block (ceil((1+2-1)/20))", () => {
    expect(computeTwistBlocksNeeded(1, 1, 2)).toBe(1);
  });

  it("pendingWeight: weightSum=0, base=1, pending=1 → 0 blocks (no overflow)", () => {
    // (0 + 1 - 1) = 0 → ceil(0/20) = 0
    expect(computeTwistBlocksNeeded(0, 1, 1)).toBe(0);
  });

  it("pendingWeight: weightSum=1, base=1, pending=20 → 4 blocks (ceil(20/5))", () => {
    expect(computeTwistBlocksNeeded(1, 1, 20)).toBe(4);
  });

  it("pendingWeight: weightSum=21, base=1, pending=0 → 4 blocks (ceil(20/5), unchanged no-arg behavior)", () => {
    expect(computeTwistBlocksNeeded(21, 1, 0)).toBe(4);
  });
});

// ---------------------------------------------------------------------------
// purchaseTwistAddonBlocksForScope — write-back atomicity (no DB needed)
// ---------------------------------------------------------------------------

/**
 * Build a minimal Stripe stub for purchaseTwistAddonBlocksForScope tests.
 * `hasCard` controls whether the customer has a default payment method.
 */
function makeTwistStripeAddonMock(hasCard: boolean) {
  return {
    customers: {
      retrieve: vi.fn().mockResolvedValue(
        hasCard
          ? { deleted: false, invoice_settings: { default_payment_method: "pm_card" } }
          : { deleted: false, invoice_settings: {} }
      ),
    },
    paymentMethods: {
      list: vi.fn().mockResolvedValue({ data: [] }),
    },
    prices: {
      list: vi.fn().mockResolvedValue({ data: [{ id: "price_twist_addon_monthly" }] }),
    },
    subscriptions: {
      create: vi.fn().mockResolvedValue({
        id: "sub_twist_new",
        items: { data: [{ id: "si_t1", quantity: 1 }] },
      }),
      retrieve: vi.fn(),
      update: vi.fn(),
    },
    checkout: {
      sessions: {
        create: vi.fn().mockResolvedValue({ url: "https://checkout.stripe.com/pay/twist_test" }),
      },
    },
  };
}

describe("purchaseTwistAddonBlocksForScope write-back atomicity", () => {
  it("returns ok:true and calls captureException when write-back fails after a successful charge", async () => {
    const stripe = makeTwistStripeAddonMock(true) as unknown as Stripe;
    const captureException = vi.fn();

    // Chainable Kysely stub — every chaining method returns `self` so the deep
    // .where().where()... calls in getPersonalTwistWeightSum are satisfied.
    // The two terminal `executeTakeFirst()` calls return their respective stubs:
    //   • user_subscription → plan=free (base=1)
    //   • twist_instance join → weight=21 → target = ceil(20/20) = 1
    function makeChainable(result: unknown): unknown {
      const self: Record<string, unknown> = {};
      const ret = () => makeChainable(result);
      self.select = ret;
      self.where = ret;
      self.innerJoin = ret;
      self.executeTakeFirst = () => Promise.resolve(result);
      self.executeTakeFirstOrThrow = () => Promise.resolve(result);
      return self;
    }

    const failingDb = {
      selectFrom: (table: string) =>
        table === "user_subscription"
          ? makeChainable({ plan: "free", status: "active", twist_addon_count: null })
          : makeChainable({ weight: "21" }),
      updateTable: () => ({
        set: () => ({
          where: () => ({
            execute: () => Promise.reject(new Error("simulated write failure")),
          }),
        }),
      }),
    } as unknown as Kysely<DB>;

    const result = await purchaseTwistAddonBlocksForScope({
      stripe,
      db: failingDb,
      customerId: "cus_twist_write_fail",
      twistAddonSubscriptionId: null,
      currentTwistAddonCount: 0,
      scope: { userId: "user_twist_write_fail" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "user_twist_write_fail",
      captureException,
    });

    // target=4 (weightSum=21, base=1, block_size=5 → ceil(20/5)=4); charge
    // succeeded even though write failed.
    expect(result).toEqual({ ok: true, twist_addons: 4 });
    // The write failure must be captured so it surfaces in error tracking.
    expect(captureException).toHaveBeenCalledWith(expect.any(Error));
  });
});

describe.skipIf(!DATABASE_URL)(
  "purchaseTwistAddonBlocksForScope",
  () => {
    it("already enough headroom — idempotent, no Stripe call", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const stripe = makeTwistStripeAddonMock(true) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof purchaseTwistAddonBlocksForScope>> | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_twist_idem",
              stripe_subscription_id: "sub_twist_idem",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
              // Already 5 blocks purchased — more than enough for a user with
              // no installed non-draft twists (weightSum=0, target=0).
              twist_addon_count: 5,
            })
            .execute();

          result = await purchaseTwistAddonBlocksForScope({
            stripe,
            db: trx,
            customerId: "cus_twist_idem",
            twistAddonSubscriptionId: "sub_twist_existing",
            currentTwistAddonCount: 5,
            scope: { userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      // No Stripe charge — already within capacity.
      expect(result).toEqual({ ok: true, twist_addons: 5 });
      expect((stripe as any).subscriptions.create).not.toHaveBeenCalled();
      expect((stripe as any).subscriptions.update).not.toHaveBeenCalled();
    });

    it("purchase with a card on file sets twist quantity and writes twist_addon_count", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      // Has card; subscriptions.create returns sub_twist_new with quantity=1.
      const stripe = makeTwistStripeAddonMock(true) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof purchaseTwistAddonBlocksForScope>> | undefined;
      let updatedRow:
        | { stripe_twist_addon_subscription_id: string | null; twist_addon_count: number }
        | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Seed a non-source, non-builtin twist with capacity_weight=21.
          // Free plan base=1, so weightSum=21 → target=ceil(20/20)=1 block needed.
          const twistRow = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium, capacity_weight)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              'TestTwist', 'testtwist', '1.0.0', false, false, 21)
            RETURNING id`.execute(trx);
          const twistId = twistRow.rows[0].id;

          // Seed an active (non-draft) personal twist_instance for that twist.
          await sql`
            INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
            VALUES (${randomUUID()}::uuid, ${twistId}, ${userId}::uuid,
              'TestTwist', false)`.execute(trx);

          // Seed the user subscription (Free plan, no existing twist add-on blocks).
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_twist_card",
              stripe_subscription_id: "sub_twist_plan",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
            })
            .execute();

          // Keep replica mode so the helper's UPDATE doesn't re-trigger FK
          // checks on the synthetic userId.
          result = await purchaseTwistAddonBlocksForScope({
            stripe,
            db: trx,
            customerId: "cus_twist_card",
            twistAddonSubscriptionId: null,
            currentTwistAddonCount: 0,
            scope: { userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          updatedRow = await trx
            .selectFrom("user_subscription")
            .select(["stripe_twist_addon_subscription_id", "twist_addon_count"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      // target=4 (weightSum=21, base=1, block_size=5 → ceil(20/5)=4 blocks).
      expect(result).toEqual({ ok: true, twist_addons: 4 });
      expect(updatedRow?.stripe_twist_addon_subscription_id).toBe("sub_twist_new");
      // Fix 1: verify twist_addon_count is written back correctly.
      expect(updatedRow?.twist_addon_count).toBe(4);
      // Fix 2: verify Stripe received the absolute target quantity (not +1 delta).
      expect((stripe as any).subscriptions.create).toHaveBeenCalledWith(
        expect.objectContaining({
          items: expect.arrayContaining([
            expect.objectContaining({ quantity: 4 }),
          ]),
        })
      );
    });

    it("purchase with no card returns a checkout_url", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const stripe = makeTwistStripeAddonMock(false) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof purchaseTwistAddonBlocksForScope>> | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Seed a non-source twist with capacity_weight=21 so target=1 (> 0 current).
          const twistRow2 = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium, capacity_weight)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              'TestTwist2', 'testtwist2', '1.0.0', false, false, 21)
            RETURNING id`.execute(trx);
          const twistId2 = twistRow2.rows[0].id;

          await sql`
            INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
            VALUES (${randomUUID()}::uuid, ${twistId2}, ${userId}::uuid,
              'TestTwist2', false)`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_twist_nocard",
              stripe_subscription_id: "sub_twist_nocard_plan",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
            })
            .execute();

          // target=1 (ceil(20/20)), currentTwistAddonCount=0 → triggers purchase.
          // No card on file → checkout_url returned.
          result = await purchaseTwistAddonBlocksForScope({
            stripe,
            db: trx,
            customerId: "cus_twist_nocard",
            twistAddonSubscriptionId: null,
            currentTwistAddonCount: 0,
            scope: { userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
          });

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toEqual({ ok: false, checkout_url: "https://checkout.stripe.com/pay/twist_test" });
      expect((stripe as any).subscriptions.create).not.toHaveBeenCalled();
    });
  }
);

// ---------------------------------------------------------------------------
// purchaseTwistAddonBlocksForScope — candidateWeight regression
//
// Regression: before the fix, calling the purchase endpoint for a Free user
// at capacity (installedWeightSum=base, currentAddons=0) with a blocked
// candidateWeight would compute target=0 (installed-only) and immediately
// early-return { ok:true, twist_addons:0 } without charging. The fix threads
// pendingWeight into twistAddonBlocksNeeded so target accounts for the
// candidate, forcing a charge.
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "purchaseTwistAddonBlocksForScope — candidateWeight regression",
  () => {
    it("charges when installedWeightSum=base but candidateWeight would overflow", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const stripe = makeTwistStripeAddonMock(true) as unknown as Stripe;

      let result: Awaited<ReturnType<typeof purchaseTwistAddonBlocksForScope>> | undefined;
      let updatedRow:
        | { stripe_twist_addon_subscription_id: string | null; twist_addon_count: number }
        | undefined;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Seed a weight-1 installed twist (Free plan base=1, so weightSum=1 is
          // exactly at capacity, currentAddons=0). The candidate has weight=2, which
          // would overflow: (1+2-1)=2 → ceil(2/20)=1 block needed.
          const twistRow = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium, capacity_weight)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              'InstalledTwist', 'installedtwist', '1.0.0', false, false, 1)
            RETURNING id`.execute(trx);
          const twistId = twistRow.rows[0].id;

          await sql`
            INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
            VALUES (${randomUUID()}::uuid, ${twistId}, ${userId}::uuid,
              'InstalledTwist', false)`.execute(trx);

          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_twist_candidate",
              stripe_subscription_id: "sub_twist_candidate_plan",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
              // No twist add-on blocks purchased yet.
              twist_addon_count: 0,
            })
            .execute();

          // Call with candidateWeight=2: installed(1) + pending(2) − base(1) = 2
          // → ceil(2/20) = 1 block needed. Before the fix this returned { ok:true,
          // twist_addons:0 } (early-return). After the fix it must charge.
          result = await purchaseTwistAddonBlocksForScope({
            stripe,
            db: trx,
            customerId: "cus_twist_candidate",
            twistAddonSubscriptionId: null,
            currentTwistAddonCount: 0,
            scope: { userId },
            siteRoot: "https://plot.day",
            table: "user_subscription",
            idVal: userId,
            captureException: vi.fn(),
            pendingWeight: 2,
          });

          updatedRow = await trx
            .selectFrom("user_subscription")
            .select(["stripe_twist_addon_subscription_id", "twist_addon_count"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      // Must charge: target=1, not 0.
      expect(result).toEqual({ ok: true, twist_addons: 1 });
      expect(updatedRow?.stripe_twist_addon_subscription_id).toBe("sub_twist_new");
      expect(updatedRow?.twist_addon_count).toBe(1);
    });
  }
);

// ---------------------------------------------------------------------------
// POST /upgrade/twist-addons/purchase — HTTP route: team scope rejected
// (twist add-ons are personal-only; the old admin gate is superseded)
// ---------------------------------------------------------------------------

describe("POST /upgrade/twist-addons/purchase — team admin gate (now superseded)", () => {
  it("returns 400 twist_add_ons_personal_only for any team member (admin check removed)", async () => {
    // The handler now rejects ALL team requests before reaching the admin check.
    // A non-admin member still gets 400 (not 403), because the early-exit fires first.
    function makeChainableDb(result: unknown) {
      const chain: Record<string, unknown> = {};
      const ret = () => chain;
      chain.selectFrom = ret;
      chain.select = ret;
      chain.where = ret;
      chain.innerJoin = ret;
      chain.executeTakeFirst = () => Promise.resolve(result);
      chain.executeTakeFirstOrThrow = () => Promise.resolve(result);
      return chain;
    }

    const app = new Hono<any>();
    app.use("*", async (c: any, next: any) => {
      c.set("user", { id: "test-user-id" });
      c.set("db", makeChainableDb({ role: "member" }));
      c.set("tracker", { captureException: vi.fn() });
      await next();
    });
    app.route("/", upgrade);

    const res = await app.request(
      "/upgrade/twist-addons/purchase",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ teamId: "team-123" }),
      },
      { STRIPE_SECRET_KEY: "sk_test_dummy", SITE_ROOT: "https://plot.day" }
    );

    expect(res.status).toBe(400);
    const body = await res.json() as { error: string };
    expect(body.error).toBe("twist_add_ons_personal_only");
  });
});

// ---------------------------------------------------------------------------
// POST /upgrade/twist-addons/purchase — team scope must be rejected (personal-only)
// ---------------------------------------------------------------------------

describe("POST /upgrade/twist-addons/purchase — team scope rejected", () => {
  it("returns 400 twist_add_ons_personal_only for any teamId request (even as admin)", async () => {
    // Stub a DB that would return an admin role — the handler must reject before
    // ever reaching the admin check or team_subscription query.
    function makeChainableDb(result: unknown) {
      const chain: Record<string, unknown> = {};
      const ret = () => chain;
      chain.selectFrom = ret;
      chain.select = ret;
      chain.where = ret;
      chain.innerJoin = ret;
      chain.executeTakeFirst = () => Promise.resolve(result);
      chain.executeTakeFirstOrThrow = () => Promise.resolve(result);
      return chain;
    }

    const app = new Hono<any>();
    app.use("*", async (c: any, next: any) => {
      c.set("user", { id: "test-user-id" });
      // Would succeed as admin — but the handler must reject before this matters.
      c.set("db", makeChainableDb({ role: "admin" }));
      c.set("tracker", { captureException: vi.fn() });
      await next();
    });
    app.route("/", upgrade);

    const res = await app.request(
      "/upgrade/twist-addons/purchase",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ teamId: "team-abc" }),
      },
      { STRIPE_SECRET_KEY: "sk_test_dummy", SITE_ROOT: "https://plot.day" }
    );

    expect(res.status).toBe(400);
    const body = await res.json() as { error: string };
    expect(body.error).toBe("twist_add_ons_personal_only");
  });
});

describe("purchaseAddonCreditForScope idempotency", () => {
  it("reuses an unused credit without charging when purchased > active", async () => {
    vi.spyOn(limits, "getBillableConnectionAddonCount").mockResolvedValue(0);
    const stripe = {
      customers: { retrieve: vi.fn() },
      subscriptions: { update: vi.fn(), create: vi.fn(), retrieve: vi.fn() },
      checkout: { sessions: { create: vi.fn() } },
      paymentMethods: { list: vi.fn() },
    } as any;

    const res = await purchaseAddonCreditForScope({
      stripe,
      db: {} as any,
      customerId: "cus_1",
      addonSubscriptionId: "sub_addon_1",
      currentAddons: 1, // one purchased, zero active → unused credit
      scope: { userId: "u1" },
      scopeMetadata: { user_id: "u1" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "u1",
      captureException: () => {},
    });

    expect(res).toEqual({ ok: true, addons: 1 });
    expect(stripe.subscriptions.update).not.toHaveBeenCalled();
    expect(stripe.subscriptions.create).not.toHaveBeenCalled();
    expect(stripe.checkout.sessions.create).not.toHaveBeenCalled();
  });

  it("returns a coupon-capable checkout_url when a new credit is needed and no card is on file", async () => {
    vi.spyOn(limits, "getBillableConnectionAddonCount").mockResolvedValue(1);
    const sessionCreate = vi
      .fn()
      .mockResolvedValue({ url: "https://checkout.test/cs_coupon" });
    const stripe = {
      customers: { retrieve: vi.fn().mockResolvedValue({ deleted: false, invoice_settings: {} }) },
      paymentMethods: { list: vi.fn().mockResolvedValue({ data: [] }) },
      prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon" }] }) },
      subscriptions: { update: vi.fn(), create: vi.fn() },
      checkout: { sessions: { create: sessionCreate } },
    } as any;

    const res = await purchaseAddonCreditForScope({
      stripe,
      db: {} as any,
      customerId: "cus_1",
      addonSubscriptionId: null,
      currentAddons: 1, // one purchased, one active → need a new credit
      scope: { userId: "u1" },
      scopeMetadata: { user_id: "u1" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "u1",
      captureException: () => {},
    });

    expect(res).toEqual({ ok: false, checkout_url: "https://checkout.test/cs_coupon" });
    expect(sessionCreate.mock.calls[0][0]).toMatchObject({
      mode: "subscription",
      allow_promotion_codes: true,
    });
  });
});

describe("provisionAddonForConsentedEnable — live-Stripe idempotency", () => {
  it("reuses a spare live-Stripe credit without charging when the DB count is stale", async () => {
    // Simulates: a confirm-time charge succeeded (Stripe qty bumped to N+1)
    // but the DB write for it failed, so getBillableConnectionAddonCount
    // (derived from the DB) still reports N. The enable gate must NOT charge
    // a second time — it should see the live Stripe quantity already covers
    // one more than active and reuse it.
    vi.spyOn(limits, "getBillableConnectionAddonCount").mockResolvedValue(2);
    const subscriptionsRetrieve = vi.fn().mockResolvedValue({
      items: { data: [{ quantity: 3 }] },
    });
    const stripe = {
      customers: { retrieve: vi.fn() },
      paymentMethods: { list: vi.fn() },
      subscriptions: {
        retrieve: subscriptionsRetrieve,
        update: vi.fn(),
        create: vi.fn(),
      },
      checkout: { sessions: { create: vi.fn() } },
    } as any;

    const res = await provisionAddonForConsentedEnable({
      stripe,
      db: {} as any,
      customerId: "cus_1",
      addonSubscriptionId: "sub_addon_1",
      scopeMetadata: { user_id: "u1" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "u1",
      captureException: () => {},
    });

    expect(res).toEqual({ ok: true, addons: 3 });
    expect(subscriptionsRetrieve).toHaveBeenCalledWith("sub_addon_1");
    expect(stripe.subscriptions.update).not.toHaveBeenCalled();
    expect(stripe.subscriptions.create).not.toHaveBeenCalled();
    expect(stripe.checkout.sessions.create).not.toHaveBeenCalled();
  });
});
