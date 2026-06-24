/**
 * Tests for the Apple App Store webhook handler behavior.
 *
 * APPROACH: We test the extracted `handleAppStoreTransaction` function which
 * receives already-decoded notif/txn objects — this avoids mocking real JWS
 * signature verification (which requires a valid Apple certificate chain).
 *
 * Two behaviors covered:
 * 1. GRACE_PERIOD: DID_FAIL_TO_RENEW + GRACE_PERIOD subtype → no downgrade,
 *    row origin stays "app_store".
 * 2. EXPIRED lapse: after applyAppleTransactionToUser sets plan=free,
 *    reinstateFreeSubscription fires and flips the row to stripe/free.
 *
 * DB integration tests are skipped when DATABASE_URL is absent.
 */

import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "./db";
import type { Bindings } from "./env";
import type { JwsNotificationPayload, JwsTransactionPayload } from "./apple/iap";
import { handleAppStoreTransaction } from "./apple/handle-appstore";
import type * as stripeUtils from "./stripe/utils";

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

// ---------------------------------------------------------------------------
// Module-level mocks
// ---------------------------------------------------------------------------

// Mock Stripe utils so reinstateFreeSubscription never hits the real API.
// createFreeSubscription returns a stub sub; getBillingCycleDates (actual
// implementation) converts current_period_start/end × 1000 → Date objects.
vi.mock("./stripe/utils", async (importOriginal) => {
  const actual = await importOriginal<typeof stripeUtils>();
  return {
    ...actual,
    createStripeClient: () => ({
      subscriptions: {
        create: vi.fn(),
      },
      prices: {
        list: async () => ({ data: [{ id: "price_free_monthly" }] }),
      },
    }),
    createFreeSubscription: vi.fn(async (_stripe: unknown, _opts: unknown) => ({
      id: "sub_reinstated_free",
      // getBillingCycleDates reads current_period_start/end (Unix seconds)
      current_period_start: 1000,
      current_period_end: 2000,
      items: { data: [] },
    })),
  };
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const DATABASE_URL = process.env.DATABASE_URL;

const fakeEnv = {
  STRIPE_SECRET_KEY: "sk_test_fakekeyfortesting",
} as unknown as Bindings;

const fakeTracker = {
  capture: vi.fn(),
  captureException: vi.fn(),
  setDistinctId: vi.fn(),
  setPersonProperties: vi.fn(),
};

const fakeLogger = {
  info: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
  debug: vi.fn(),
};

/** Build a minimal Apple transaction payload for a given originalTransactionId. */
function makeTxn(
  originalTransactionId: string,
  expiresDate: number = Date.now() - 1000
): JwsTransactionPayload {
  return {
    transactionId: `txn_${randomUUID()}`,
    originalTransactionId,
    bundleId: "day.plot.app",
    productId: "day.plot.app.core_monthly",
    purchaseDate: Date.now() - 60_000,
    originalPurchaseDate: Date.now() - 60_000,
    expiresDate,
  };
}

/** Build a notification payload. */
function makeNotif(
  notificationType: string,
  subtype?: string
): JwsNotificationPayload {
  return {
    notificationType,
    subtype,
    notificationUUID: randomUUID(),
    version: "2.0",
    signedDate: Date.now(),
    data: {
      bundleId: "day.plot.app",
      environment: "Sandbox",
    },
  };
}

/**
 * Seed a user_subscription row inside a transaction.
 *
 * Keeps `session_replication_role = replica` active for the lifetime of
 * the transaction so all subsequent writes (seed + code under test) bypass
 * FK constraints — there is no matching row in the `user` table for the
 * random userId used in tests.
 */
async function seedSubscription(
  trx: Kysely<DB>,
  opts: {
    userId: string;
    plan?: string;
    status?: string;
    origin?: string;
    appleOriginalTransactionId?: string;
    stripeCustomerId?: string;
  }
) {
  await sql`SET LOCAL session_replication_role = replica`.execute(trx);
  await trx
    .insertInto("user_subscription")
    .values({
      user_id: opts.userId,
      plan: (opts.plan ?? "core") as "free" | "core" | "pro",
      status: (opts.status ?? "active") as
        | "active"
        | "canceled"
        | "past_due"
        | "trialing"
        | "incomplete"
        | "incomplete_expired"
        | "unpaid",
      origin: opts.origin ?? "app_store",
      apple_original_transaction_id: opts.appleOriginalTransactionId ?? null,
      stripe_customer_id: opts.stripeCustomerId ?? null,
      billing_cycle_start: new Date().toISOString(),
      billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
    })
    .execute();
  // Keep session_replication_role = replica for the caller — the code under
  // test may also write rows (INSERT/UPDATE) that would fail FK checks
  // against the missing user row.
}

// ---------------------------------------------------------------------------
// handleAppStoreTransaction — behavior tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "handleAppStoreTransaction",
  () => {
    it("returns grace:true and does NOT downgrade on GRACE_PERIOD", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const otxId = `otx_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await seedSubscription(trx, {
            userId,
            plan: "core",
            status: "active",
            origin: "app_store",
            appleOriginalTransactionId: otxId,
            stripeCustomerId: "cus_x",
          });

          const notif = makeNotif("DID_FAIL_TO_RENEW", "GRACE_PERIOD");
          const txn = makeTxn(otxId);

          const result = await handleAppStoreTransaction(
            trx,
            fakeEnv,
            userId,
            notif,
            txn,
            null,
            fakeTracker as any,
            fakeLogger as any
          );

          // Must signal grace (early return before downgrade)
          expect(result).toMatchObject({ grace: true });

          // Row origin must still be app_store — no downgrade
          const row = await trx
            .selectFrom("user_subscription")
            .select(["origin", "plan", "status"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          expect(row?.origin).toBe("app_store");
          expect(row?.plan).toBe("core");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("reinstates free Stripe sub on EXPIRED lapse (result.plan === free)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();
      const otxId = `otx_${randomUUID().slice(0, 8)}`;

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await seedSubscription(trx, {
            userId,
            plan: "core",
            status: "active",
            origin: "app_store",
            appleOriginalTransactionId: otxId,
            stripeCustomerId: "cus_x",
          });

          const notif = makeNotif("EXPIRED");
          // Expired: expiresDate in the past
          const txn = makeTxn(otxId, Date.now() - 5000);

          await handleAppStoreTransaction(
            trx,
            fakeEnv,
            userId,
            notif,
            txn,
            null,
            fakeTracker as any,
            fakeLogger as any
          );

          // After reinstatement: origin must flip to stripe, plan free, active
          const row = await trx
            .selectFrom("user_subscription")
            .select(["origin", "plan", "status", "stripe_subscription_id"])
            .where("user_id", "=", userId)
            .executeTakeFirst();

          expect(row?.origin).toBe("stripe");
          expect(row?.plan).toBe("free");
          expect(row?.status).toBe("active");
          expect(row?.stripe_subscription_id).toBe("sub_reinstated_free");

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
