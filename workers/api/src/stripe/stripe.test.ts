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
} from "./stripe";
import type * as stripeUtils from "./utils";

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
