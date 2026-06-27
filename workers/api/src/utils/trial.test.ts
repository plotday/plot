/**
 * Tests for trial.ts — expireTrial guard / behavior and buildReminderContent copy.
 *
 * TDD tests written BEFORE implementing Task 2 changes so they start RED
 * and turn GREEN after the changes are applied.
 *
 * DB integration tests are skipped when DATABASE_URL is absent (CI without DB).
 */

import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { expireTrial, buildReminderContent } from "./trial";
import { enforcePersonalPlanLimits } from "../twist/management";

// ---------------------------------------------------------------------------
// Module-level mocks — prevent real Stripe/twist calls from firing.
// vi.mock is hoisted, so factories must not reference variables from outer scope.
// ---------------------------------------------------------------------------

vi.mock("../twist/factory", () => ({
  twistFactory: vi.fn(() => async () => ({})),
}));

// We reference the mock fn via import after vi.mock is set up.
vi.mock("../twist/management", () => ({
  enforcePersonalPlanLimits: vi.fn(async () => {}),
}));

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

// ---------------------------------------------------------------------------
// buildReminderContent — copy no longer mentions "Core"
// ---------------------------------------------------------------------------

describe("buildReminderContent — connections trial copy", () => {
  it("does NOT mention 'Core' in the reminder copy", () => {
    const content = buildReminderContent(3, [], [], "https://plot.day");
    expect(content).not.toMatch(/Core/);
  });

  it("mentions the trial ending", () => {
    const content = buildReminderContent(3, [], [], "https://plot.day");
    expect(content).toMatch(/trial ends in/i);
  });

  it("includes an upgrade link", () => {
    const content = buildReminderContent(3, [], [], "https://plot.day");
    expect(content).toContain("https://plot.day/upgrade");
  });
});

// ---------------------------------------------------------------------------
// expireTrial — guard behavior
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)("expireTrial — guard: only trial_ends_at matters (not plan)", () => {
  const fakeEnv = {
    SITE_ROOT: "https://plot.day",
    SYNC_NOTIFY: {
      idFromName: () => "fake-do-id",
      get: () => ({
        fetch: vi.fn(async () => new Response("ok")),
      }),
    },
    USER_SYNC: {
      idFromName: () => "fake-do-id",
      get: () => ({
        fetch: vi.fn(async () => new Response("ok")),
      }),
    },
  } as unknown as Bindings;

  const fakeCtx = {
    waitUntil: vi.fn(),
  } as unknown as ExecutionContext;

  it("no-ops when trial_ends_at is NULL (regardless of plan)", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();

    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        // Keep replica mode throughout: expireTrial writes to user_sync which
        // has an FK on user_id — no real user row exists in our rollback tx.
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            stripe_customer_id: `cus_trial_test_${userId.slice(0, 8)}`,
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            // trial_ends_at intentionally omitted (NULL)
          })
          .execute();

        vi.mocked(enforcePersonalPlanLimits).mockClear();
        await expireTrial(trx, fakeEnv, fakeCtx, userId, null);

        // enforcePersonalPlanLimits must NOT have been called — guard should have exited early
        expect(vi.mocked(enforcePersonalPlanLimits)).not.toHaveBeenCalled();

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
  });

  it("runs enforcement when trial_ends_at is set (plan='free')", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const pastDate = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        // Keep replica mode throughout: expireTrial writes to user_sync which
        // has an FK on user_id — no real user row exists in our rollback tx.
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            stripe_customer_id: `cus_trial_exp_${userId.slice(0, 8)}`,
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            trial_ends_at: pastDate,
          })
          .execute();

        vi.mocked(enforcePersonalPlanLimits).mockClear();
        await expireTrial(trx, fakeEnv, fakeCtx, userId, null);

        // enforcePersonalPlanLimits MUST have been called — trial eligible
        expect(vi.mocked(enforcePersonalPlanLimits)).toHaveBeenCalledOnce();

        // plan must still be 'free' after expiry (no downgrade write needed)
        const after = await trx
          .selectFrom("user_subscription")
          .select("plan")
          .where("user_id", "=", userId)
          .executeTakeFirst();
        expect(after?.plan).toBe("free");

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
  });

  it("plan column stays 'free' after expiry (no spurious plan write)", async () => {
    // Regression guard: Task 2 removes the redundant plan='free' UPDATE.
    // This test confirms the column is never altered by expireTrial.
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const pastDate = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        // Keep replica mode throughout to bypass FK on user_sync write.
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            stripe_customer_id: `cus_plan_check_${userId.slice(0, 8)}`,
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            trial_ends_at: pastDate,
          })
          .execute();

        await expireTrial(trx, fakeEnv, fakeCtx, userId, null);

        const after = await trx
          .selectFrom("user_subscription")
          .select("plan")
          .where("user_id", "=", userId)
          .executeTakeFirst();

        expect(after?.plan).toBe("free");

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
  });
});
