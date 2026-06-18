/**
 * Tests for reinstate-free.ts — reinstateFreeSubscription helper.
 *
 * APPROACH: Real-DB unit tests (vitest node environment) using a rolled-back
 * transaction with SET LOCAL session_replication_role = replica to bypass FK
 * constraints. Stripe is mocked at the module level so no real API calls fire.
 *
 * DB integration tests are skipped when DATABASE_URL is absent (CI without DB).
 */

import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { reinstateFreeSubscription } from "./reinstate-free";

// ---------------------------------------------------------------------------
// Module-level mock: intercept createFreeSubscription so tests never hit
// the real Stripe API. Individual tests may override via vi.spyOn.
// ---------------------------------------------------------------------------

const stripeMockCreate = vi.fn();

vi.mock("./utils", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./utils")>();
  return {
    ...actual,
    createStripeClient: () => ({
      subscriptions: {
        create: stripeMockCreate,
      },
      prices: {
        list: async () => ({ data: [{ id: "price_free_monthly" }] }),
      },
    }),
    createFreeSubscription: vi.fn(async (_stripe: unknown, _opts: unknown) => {
      // Return a stub Stripe.Subscription shape
      return {
        id: "sub_free",
        items: {
          data: [{ current_period_start: 1000, current_period_end: 2000 }],
        },
        current_period_start: 1000,
        current_period_end: 2000,
      };
    }),
  };
});

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

const fakeEnv = {
  STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
} as unknown as Bindings;

// ---------------------------------------------------------------------------
// reinstateFreeSubscription — DB tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "reinstateFreeSubscription",
  () => {
    it("recreates free_monthly and flips the row to stripe/free/active", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep session_replication_role = replica for the entire block so the
          // INSERT and the subsequent UPDATE (in reinstateFreeSubscription) both
          // bypass FK constraints — there is no matching row in the `user` table.
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Seed a pro app_store row (simulates a lapsed Apple sub)
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

          await reinstateFreeSubscription(trx, fakeEnv, userId);

          const row = await trx
            .selectFrom("user_subscription")
            .select([
              "plan",
              "status",
              "origin",
              "stripe_subscription_id",
              "billing_cycle_start",
              "billing_cycle_end",
            ])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          expect(row).toBeDefined();
          expect(row).toMatchObject({
            plan: "free",
            status: "active",
            origin: "stripe",
            stripe_subscription_id: "sub_free",
          });
          // billing cycle dates come from getBillingCycleDates(freeSub):
          // start = 1000 * 1000ms = new Date(1_000_000) ≈ epoch+1s
          // end   = 2000 * 1000ms = new Date(2_000_000) ≈ epoch+2s
          expect(new Date(row!.billing_cycle_start).getTime()).toBe(1_000_000);
          expect(new Date(row!.billing_cycle_end).getTime()).toBe(2_000_000);

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("is a no-op when the user has no stripe_customer_id", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          // Keep replica role for the entire block (no user row in `user` table).
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Seed a row without a stripe_customer_id
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "canceled",
              origin: "app_store",
              stripe_customer_id: null,
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
            })
            .execute();

          // Should return without throwing and without touching the row
          await reinstateFreeSubscription(trx, fakeEnv, userId);

          const row = await trx
            .selectFrom("user_subscription")
            .select(["origin", "plan"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          // Unchanged: still app_store origin, no stripe_subscription_id
          expect(row?.origin).toBe("app_store");
          expect(row?.plan).toBe("free");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("is a no-op when no user_subscription row exists", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      // Should return without throwing
      await reinstateFreeSubscription(db, fakeEnv, userId);
      await db.destroy();
    });
  }
);
