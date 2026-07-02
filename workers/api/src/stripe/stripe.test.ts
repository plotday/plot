/**
 * Tests for stripe.ts — `hasActiveAppStoreEntitlement` helper and the
 * `handleSubscriptionDeleted` app-store guard.
 *
 * APPROACH: Helper-extraction + real-DB unit tests (vitest node environment),
 * plus a handler-level integration test that proves the guard fires inside
 * `handleSubscriptionDeleted` (the helper-only tests would pass even if the
 * guard call were deleted from the handler).
 *
 * DB integration tests are skipped when DATABASE_URL is absent (CI without DB).
 */

import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  handleSubscriptionDeleted,
  handleSubscriptionUpdate,
  hasActiveAppStoreEntitlement,
  isTwistAddonSubscription,
  parseSubscriptionItemQuantities,
} from "./stripe";
import type Stripe from "stripe";
import type * as stripeUtils from "./utils";

// ---------------------------------------------------------------------------
// parseSubscriptionItemQuantities — pure split of plan vs add-on line items.
// ---------------------------------------------------------------------------
describe("parseSubscriptionItemQuantities", () => {
  const sub = (
    items: { lookup_key: string | null; quantity?: number }[]
  ): Stripe.Subscription =>
    ({
      items: {
        data: items.map((i) => ({
          quantity: i.quantity,
          price: { lookup_key: i.lookup_key },
        })),
      },
    }) as unknown as Stripe.Subscription;

  it("reads the plan quantity and defaults add-ons to 0", () => {
    expect(
      parseSubscriptionItemQuantities(
        sub([{ lookup_key: "team_monthly", quantity: 2 }])
      )
    ).toEqual({ planQuantity: 2, addonQuantity: 0 });
  });

  it("splits a plan item and an add-on item regardless of order", () => {
    expect(
      parseSubscriptionItemQuantities(
        sub([
          { lookup_key: "addon_monthly", quantity: 3 },
          { lookup_key: "core_monthly", quantity: 1 },
        ])
      )
    ).toEqual({ planQuantity: 1, addonQuantity: 3 });
  });

  it("recognizes the annual add-on lookup key", () => {
    expect(
      parseSubscriptionItemQuantities(
        sub([
          { lookup_key: "pro_annual", quantity: 1 },
          { lookup_key: "addon_annual", quantity: 4 },
        ])
      )
    ).toEqual({ planQuantity: 1, addonQuantity: 4 });
  });
});

// ---------------------------------------------------------------------------
// Module-level mock: intercept createStripeClient so the handler never hits
// the real Stripe API. subscriptions.list returns no active subs (so the
// "other active sub" guard passes and execution reaches the app_store guard).
// ---------------------------------------------------------------------------

vi.mock("./utils", async (importOriginal) => {
  const actual = await importOriginal<typeof stripeUtils>();
  return {
    ...actual,
    createStripeClient: () => ({
      subscriptions: {
        list: async () => ({ data: [] }),
      },
    }),
  };
});

// Also stub modules that are only reachable when the guard does NOT fire
// (i.e. the revert-to-free path). If the guard fires correctly these are
// never called, but the module still needs to import cleanly.
vi.mock("../twist/factory", () => ({
  twistFactory: vi.fn(() => async () => ({})),
}));

vi.mock("../twist/management", () => ({
  enforcePersonalPlanLimits: vi.fn(async () => {}),
}));

vi.mock("../app/sync/notify", () => ({
  notifyUserSync: vi.fn(),
}));

vi.mock("../utils/trial", () => ({
  expireTrial: vi.fn(async () => {}),
  handleTrialUpgrade: vi.fn(async () => {}),
  handleTrialWillEnd: vi.fn(async () => {}),
}));

vi.mock("../queue/backfill-embeddings", () => ({
  backfillEmbeddings: vi.fn(async () => {}),
}));

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

// ---------------------------------------------------------------------------
// hasActiveAppStoreEntitlement — DB tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "hasActiveAppStoreEntitlement",
  () => {
    it("returns true when the customer has an active app_store entitlement", async () => {
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
              plan: "pro",
              status: "active",
              origin: "app_store",
              stripe_customer_id: "cus_x",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
            })
            .execute();

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActiveAppStoreEntitlement(trx, "cus_x");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(true);
    });

    it("returns true when status is non-active but billing_cycle_end is in the future", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      let result = false;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Simulates a cancelled Apple sub that still has time remaining
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "core",
              status: "canceled",
              origin: "app_store",
              stripe_customer_id: "cus_y",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
            })
            .execute();

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActiveAppStoreEntitlement(trx, "cus_y");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(true);
    });

    it("returns false when the customer has a stripe-origin row (not app_store)", async () => {
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
              status: "active",
              origin: "stripe",
              stripe_customer_id: "cus_stripe",
              stripe_subscription_id: "sub_stripe",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
            })
            .execute();

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActiveAppStoreEntitlement(trx, "cus_stripe");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }

      expect(result).toBe(false);
    });

    it("returns false when there is no matching subscription row", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);

      let result = true;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          result = await hasActiveAppStoreEntitlement(trx, "cus_nonexistent");

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
// handleSubscriptionDeleted — guard fires when app_store entitlement exists
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionDeleted — app_store guard",
  () => {
    /**
     * Build a minimal fake Hono context that satisfies everything
     * handleSubscriptionDeleted reads before the app_store early-return.
     *
     * extractRequestContext reads: c.var.requestId, c.req.path/method/url
     * (all wrapped in try/catch so undefined is safe).
     * The handler also reads: c.env.STRIPE_SECRET_KEY, c.var.db,
     * c.var.tracker, c.executionCtx.waitUntil.
     */
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("skips free-revert when customer has an active app_store entitlement", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_appstore_${randomUUID().slice(0, 8)}`;
      const paidPlan = "pro";

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Seed an app_store row with a paid plan and future billing end
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: paidPlan,
              status: "active",
              origin: "app_store",
              stripe_customer_id: customerId,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            })
            .execute();
          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          // Call the handler with the seeded row in the same transaction
          const fakeC = buildFakeContext(trx);
          await handleSubscriptionDeleted(fakeC, {
            id: "sub_old_stripe",
            customer: customerId,
            metadata: {},
            trial_end: null,
          } as any);

          // Assert: the row must be UNCHANGED — still app_store + paid plan.
          // If the guard were absent, the handler would set plan='free'.
          const after = await trx
            .selectFrom("user_subscription")
            .select(["origin", "plan", "status"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.origin).toBe("app_store");
          expect(after!.plan).toBe(paidPlan);
          expect(after!.status).toBe("active");

          // Roll back so the seed row doesn't persist
          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// handleSubscriptionUpdate — add-on subscription routing
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionUpdate — add-on subscription routing",
  () => {
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("an addon subscription sets premium_connection_addons + id, leaves plan untouched", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_addon_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica mode throughout: the add-on UPDATE would otherwise
          // re-validate the FK for the seeded fake user_id and fail.
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_addon1",
            customer: customerId,
            status: "active",
            metadata: { type: "addon" },
            trial_end: null,
            items: {
              data: [{ quantity: 2, price: { lookup_key: "addon_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end:
              Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select([
              "plan",
              "stripe_subscription_id",
              "premium_connection_addons",
              "stripe_addon_subscription_id",
            ])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.premium_connection_addons).toBe(2);
          expect(after!.stripe_addon_subscription_id).toBe("sub_addon1");
          expect(after!.plan).toBe("free");
          expect(after!.stripe_subscription_id).toBeNull();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("an addon subscription notifies the customer's user (subscription broadcast)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_addonnotify_${randomUUID().slice(0, 8)}`;
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
              stripe_customer_id: customerId,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_addon_notify",
            customer: customerId,
            status: "active",
            metadata: { type: "addon" },
            trial_end: null,
            items: {
              data: [{ quantity: 1, price: { lookup_key: "addon_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end:
              Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const sync = await trx
            .selectFrom("user_sync")
            .select(["user_id", "entity"])
            .where("user_id", "=", userId)
            .where("entity", "=", "subscription")
            .executeTakeFirst();
          expect(sync).toBeDefined();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("a PLAN subscription does NOT clobber a standalone add-on count (regression: fix1)", async () => {
      // Regression guard: before Fix 1, the plan path set premium_connection_addons
      // to addonQuantity (0 for a plan sub with no add-on line item), zeroing the
      // standalone add-on count on every renewal. After Fix 1 the plan path must
      // leave premium_connection_addons and stripe_addon_subscription_id untouched.
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_plan_noreset_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica mode throughout so that the UPDATE in the plan path
          // doesn't re-validate the FK for the synthetic user_id and fail.
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              stripe_subscription_id: "sub_plan_existing",
              stripe_addon_subscription_id: "sub_addon",
              premium_connection_addons: 2,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          // Simulate a monthly plan renewal (no add-on line item)
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_plan_renewal",
            customer: customerId,
            status: "active",
            metadata: { plan: "pro" },
            trial_end: null,
            items: {
              data: [{ quantity: 1, price: { lookup_key: "pro_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end:
              Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select([
              "plan",
              "premium_connection_addons",
              "stripe_addon_subscription_id",
            ])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          // premium_connection_addons must NOT be clobbered to 0 by the plan renewal
          expect(after!.premium_connection_addons).toBe(2);
          // stripe_addon_subscription_id must remain set
          expect(after!.stripe_addon_subscription_id).toBe("sub_addon");
          // plan should have updated normally
          expect(after!.plan).toBe("pro");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("an addon subscription does NOT overwrite an Apple-owned add-on count", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_apple_addon_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica mode: add-on branch may attempt an UPDATE on the row
          // (which would re-validate the FK for the fake user_id otherwise).
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "app_store",
              stripe_customer_id: customerId,
              apple_addon_original_transaction_id: "txn_apple_123",
              premium_connection_addons: 3,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_addon_stripe",
            customer: customerId,
            status: "active",
            metadata: { type: "addon" },
            trial_end: null,
            items: {
              data: [{ quantity: 1, price: { lookup_key: "addon_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end:
              Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select(["premium_connection_addons", "stripe_addon_subscription_id"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.premium_connection_addons).toBe(3);

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// handleSubscriptionDeleted — add-on subscription
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionDeleted — add-on subscription",
  () => {
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("deleting the addon sub zeroes the count and clears the id", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_addon_del_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica mode: the add-on deletion UPDATE would re-validate
          // the FK for the fake user_id if we reset to DEFAULT.
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              stripe_addon_subscription_id: "sub_addon1",
              premium_connection_addons: 2,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionDeleted(fakeC, {
            id: "sub_addon1",
            customer: customerId,
            status: "canceled",
            metadata: { type: "addon" },
            trial_end: null,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select([
              "premium_connection_addons",
              "stripe_addon_subscription_id",
              "plan",
            ])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.premium_connection_addons).toBe(0);
          expect(after!.stripe_addon_subscription_id).toBeNull();
          expect(after!.plan).toBe("pro");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// isTwistAddonSubscription — pure predicate
// ---------------------------------------------------------------------------

describe("isTwistAddonSubscription", () => {
  it("returns true for metadata.type === twist_addon", () => {
    expect(
      isTwistAddonSubscription({ metadata: { type: "twist_addon" } } as any)
    ).toBe(true);
  });

  it("returns false for metadata.type === addon (connection add-on)", () => {
    expect(
      isTwistAddonSubscription({ metadata: { type: "addon" } } as any)
    ).toBe(false);
  });

  it("returns false when metadata.type is a plan", () => {
    expect(
      isTwistAddonSubscription({ metadata: { plan: "pro" } } as any)
    ).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// handleSubscriptionUpdate — twist add-on subscription routing
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionUpdate — twist add-on subscription routing",
  () => {
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("a twist_addon subscription sets twist_addon_count + id, leaves plan/premium_connection_addons untouched", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_twaddon_${randomUUID().slice(0, 8)}`;

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
              stripe_customer_id: customerId,
              premium_connection_addons: 1,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_twaddon1",
            customer: customerId,
            status: "active",
            metadata: { type: "twist_addon" },
            trial_end: null,
            items: {
              data: [{ quantity: 3, price: { lookup_key: "twist_addon_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select([
              "plan",
              "stripe_subscription_id",
              "twist_addon_count",
              "stripe_twist_addon_subscription_id",
              "premium_connection_addons",
            ])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.twist_addon_count).toBe(3);
          expect(after!.stripe_twist_addon_subscription_id).toBe("sub_twaddon1");
          expect(after!.plan).toBe("free");
          expect(after!.stripe_subscription_id).toBeNull();
          expect(after!.premium_connection_addons).toBe(1); // untouched

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("a twist_addon subscription does NOT overwrite an Apple-owned twist add-on count", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_apple_twaddon_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "app_store",
              stripe_customer_id: customerId,
              apple_twist_addon_original_transaction_id: "txn_twist_apple_123",
              twist_addon_count: 3,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_twist_addon_stripe",
            customer: customerId,
            status: "active",
            metadata: { type: "twist_addon" },
            trial_end: null,
            items: {
              data: [{ quantity: 1, price: { lookup_key: "twist_addon_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select(["twist_addon_count", "stripe_twist_addon_subscription_id"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.twist_addon_count).toBe(3); // not overwritten by Stripe
          expect(after!.stripe_twist_addon_subscription_id).toBeNull(); // guard blocked BOTH writes

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("a PLAN subscription does NOT clobber twist_addon_count", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_plan_notw_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              stripe_subscription_id: "sub_plan_existing",
              stripe_twist_addon_subscription_id: "sub_twaddon",
              twist_addon_count: 2,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_plan_renewal",
            customer: customerId,
            status: "active",
            metadata: { plan: "pro" },
            trial_end: null,
            items: {
              data: [{ quantity: 1, price: { lookup_key: "pro_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select(["plan", "twist_addon_count", "stripe_twist_addon_subscription_id"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.twist_addon_count).toBe(2); // untouched by plan renewal
          expect(after!.stripe_twist_addon_subscription_id).toBe("sub_twaddon"); // untouched
          expect(after!.plan).toBe("pro"); // updated normally

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("a connection add-on (metadata.type:addon) does NOT set twist_addon_count", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_conn_notw_${randomUUID().slice(0, 8)}`;

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
              stripe_customer_id: customerId,
              twist_addon_count: 0,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_conn_addon",
            customer: customerId,
            status: "active",
            metadata: { type: "addon" },
            trial_end: null,
            items: {
              data: [{ quantity: 2, price: { lookup_key: "addon_monthly" } }],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select(["twist_addon_count", "premium_connection_addons"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.twist_addon_count).toBe(0); // untouched by connection add-on event
          expect(after!.premium_connection_addons).toBe(2); // updated by connection add-on

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("a twist-addon subscription notifies the customer's user (subscription broadcast)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_twistnotify_${randomUUID().slice(0, 8)}`;
      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_twistaddon_notify",
            customer: customerId,
            status: "active",
            metadata: { type: "twist_addon" },
            trial_end: null,
            items: {
              data: [
                { quantity: 1, price: { lookup_key: "twist_addon_monthly" } },
              ],
            },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end:
              Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as unknown as Stripe.Subscription);

          const sync = await trx
            .selectFrom("user_sync")
            .select(["user_id", "entity"])
            .where("user_id", "=", userId)
            .where("entity", "=", "subscription")
            .executeTakeFirst();
          expect(sync).toBeDefined();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// handleSubscriptionDeleted — twist add-on subscription
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionDeleted — twist add-on subscription",
  () => {
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("deleting the twist_addon sub zeroes twist_addon_count and clears the id", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_twaddon_del_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              stripe_twist_addon_subscription_id: "sub_twaddon1",
              twist_addon_count: 2,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          await handleSubscriptionDeleted(fakeC, {
            id: "sub_twaddon1",
            customer: customerId,
            status: "canceled",
            metadata: { type: "twist_addon" },
            trial_end: null,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select([
              "twist_addon_count",
              "stripe_twist_addon_subscription_id",
              "plan",
            ])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.twist_addon_count).toBe(0);
          expect(after!.stripe_twist_addon_subscription_id).toBeNull();
          expect(after!.plan).toBe("pro"); // untouched

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// handleSubscriptionUpdate — guard fires when app_store entitlement exists
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionUpdate — app_store guard",
  () => {
    /**
     * Minimal fake context that satisfies handleSubscriptionUpdate.
     * Mirrors the buildFakeContext above; reproduced here so the two test
     * suites remain independently readable.
     */
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("skips user_subscription update when customer has an active App Store entitlement", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_appstore_upd_${randomUUID().slice(0, 8)}`;
      const paidPlan = "pro";

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Seed an app_store row with a paid plan, no stripe_subscription_id
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: paidPlan,
              status: "active",
              origin: "app_store",
              stripe_customer_id: customerId,
              stripe_subscription_id: null,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            })
            .execute();
          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          // Simulate the subscription.updated webhook Stripe fires after the
          // IAP-convert path cancels the Stripe sub — status='canceled', which
          // would otherwise overwrite the row with plan from metadata + new
          // stripe_subscription_id.
          const fakeC = buildFakeContext(trx);
          await handleSubscriptionUpdate(fakeC, {
            id: "sub_x",
            customer: customerId,
            status: "canceled",
            metadata: { plan: "core" },
            trial_end: null,
            items: { data: [{ quantity: 1 }] },
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
          } as any);

          // Assert: the row must be UNCHANGED — still app_store origin, paid
          // plan, and stripe_subscription_id must still be null.
          // If the guard were absent, the handler would set origin stays stripe,
          // plan='core', status='canceled', and stripe_subscription_id='sub_x'.
          const after = await trx
            .selectFrom("user_subscription")
            .select(["origin", "plan", "status", "stripe_subscription_id"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          expect(after!.origin).toBe("app_store");
          expect(after!.plan).toBe(paidPlan);
          expect(after!.status).toBe("active");
          expect(after!.stripe_subscription_id).toBeNull();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// handleSubscriptionDeleted — twist add-on Apple guard
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionDeleted — twist add-on Apple guard",
  () => {
    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("deleting a twist_addon Stripe sub does NOT zero twist_addon_count when Apple owns the entitlement", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_tw_apple_del_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          // Seed: user has Apple-owned twist add-on entitlement.
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "active",
              origin: "app_store",
              stripe_customer_id: customerId,
              // Match the deleted sub's id so the first WHERE clause selects
              // this row — the Apple guard is then the ONLY thing preventing the
              // zero, which is exactly what this test must exercise.
              stripe_twist_addon_subscription_id: "sub_tw_stripe_stale",
              apple_twist_addon_original_transaction_id: "txn_abc",
              twist_addon_count: 2,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 30 * 24 * 3600 * 1000
              ).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          // Stripe fires a twist_addon delete — Apple guard must block the zero.
          await handleSubscriptionDeleted(fakeC, {
            id: "sub_tw_stripe_stale",
            customer: customerId,
            status: "canceled",
            metadata: { type: "twist_addon" },
            trial_end: null,
          } as unknown as Stripe.Subscription);

          const after = await trx
            .selectFrom("user_subscription")
            .select(["twist_addon_count", "plan"])
            .where("stripe_customer_id", "=", customerId)
            .executeTakeFirst();

          expect(after).toBeDefined();
          // Apple entitlement not clobbered by the Stripe delete.
          expect(after!.twist_addon_count).toBe(2);
          expect(after!.plan).toBe("pro");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

// ---------------------------------------------------------------------------
// Trial detection: Task 2 — detected via trial_end only, NOT plan='core'
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleSubscriptionDeleted — trial detection uses trial_end (not plan='core')",
  () => {
    // expireTrial is already mocked module-level above (vi.mock("../utils/trial"))
    // We need access to the spy to assert call counts.
    let expireTrialSpy: ReturnType<typeof vi.fn>;

    function buildFakeContext(db: Kysely<DB>) {
      return {
        var: {
          db,
          requestId: "test-request-id",
          tracker: {
            capture: vi.fn(),
            captureException: vi.fn(),
            setDistinctId: vi.fn(),
            setPersonProperties: vi.fn(),
          },
        },
        req: {
          path: "/stripe/webhook",
          method: "POST",
          url: "http://localhost/stripe/webhook",
        },
        env: {
          STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
        },
        executionCtx: {
          waitUntil: (_p: Promise<unknown>) => {},
        },
      } as any;
    }

    it("calls expireTrial when trial_end is set on the subscription", async () => {
      const { expireTrial } = await import("../utils/trial");
      expireTrialSpy = expireTrial as ReturnType<typeof vi.fn>;
      expireTrialSpy.mockClear();

      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_trd_set_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica mode throughout — handleSubscriptionDeleted's revert
          // path inserts a fresh user_subscription row and would hit FK otherwise.
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          // subscription with trial_end set — must invoke expireTrial
          await handleSubscriptionDeleted(fakeC, {
            id: "sub_trial_ending",
            customer: customerId,
            status: "canceled",
            metadata: { plan: "free" },
            trial_end: Math.floor(Date.now() / 1000), // trial just ended
          } as unknown as Stripe.Subscription);

          expect(expireTrialSpy).toHaveBeenCalledOnce();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("does NOT call expireTrial when trial_end is null (plain subscription delete)", async () => {
      const { expireTrial } = await import("../utils/trial");
      expireTrialSpy = expireTrial as ReturnType<typeof vi.fn>;
      expireTrialSpy.mockClear();

      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const customerId = `cus_trd_null_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica mode throughout to bypass FK on the revert path.
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "stripe",
              stripe_customer_id: customerId,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            })
            .execute();

          const fakeC = buildFakeContext(trx);
          // No trial_end set — plain cancellation, expireTrial must not be called
          await handleSubscriptionDeleted(fakeC, {
            id: "sub_plain_cancel",
            customer: customerId,
            status: "canceled",
            metadata: { plan: "free" },
            trial_end: null,
          } as unknown as Stripe.Subscription);

          expect(expireTrialSpy).not.toHaveBeenCalled();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);
