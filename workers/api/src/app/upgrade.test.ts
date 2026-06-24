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

import { sql, type Kysely } from "kysely";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  ADDON_PRORATION_BEHAVIOR,
  buildAddonItemUpdate,
  hasActivePaidStripeSubscription,
  cancelStripeSubscriptionBestEffort,
} from "./upgrade";

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
