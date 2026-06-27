import { randomUUID } from "node:crypto";

import { type Kysely, sql } from "kysely";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import twistIntegrations, { reconcileScopeAddonBillingDown } from "./twist-integrations";
import { Integrations } from "../twist/tools/integrations";
import { UnipileApiError } from "../twist/tools/unipile/client";
import { createDb, type DB } from "../db";
import type { Bindings } from "../env";

/**
 * Tests for POST /twist/:id/integrations/auth — specifically that upstream
 * auth-URL generation failures (e.g. a hosted-auth provider's backend like
 * Unipile returning 401, or the provider being down) are translated into a
 * clean 502 instead of bubbling to the global handler as an opaque
 * `500 Internal Server Error`.
 *
 * Dependencies are satisfied with fakes (mirroring files-ref.test.ts):
 *   - `db`: a chainable Kysely-like builder whose executeTakeFirst() returns a
 *     row that satisfies both checkTwistAccess (owner_id/team_id) and
 *     resolveTwistInfo (twistPackageId/version/...).
 *   - `env.TWIST_CONFIG`: KV stub returning a provider config.
 *   - `env.CALLBACKS`: durable-object stub whose create() returns a token.
 *   - `Integrations.GenerateAuthUrl`: spied per-test.
 */

const TEST_USER_ID = "user-uuid-001";
const TEST_TWIST_INSTANCE_ID = "ti-uuid-001";

// One row that satisfies both checkTwistAccess (owner match → { ok: true })
// and resolveTwistInfo (twistPackageId + version drive loadTwistConfig).
const TWIST_ROW = {
  owner_id: TEST_USER_ID,
  team_id: null,
  twistId: "twist-pkg-uuid",
  accountLabel: null,
  teamId: null,
  teamName: null,
  version: "1.0.0",
  environment: "production",
  twistOptions: null,
  shared: false,
  keyOption: null,
  premium: false,
  twistPackageId: "linkedin",
};

function makeDb(row: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const q: any = {};
  q.selectFrom = vi.fn(() => q);
  q.innerJoin = vi.fn(() => q);
  q.leftJoin = vi.fn(() => q);
  q.select = vi.fn(() => q);
  q.where = vi.fn(() => q);
  q.executeTakeFirst = vi.fn(async () => row);
  return q;
}

const KV_CONFIG = JSON.stringify({
  providers: [{ provider: "linkedin", scopes: ["messaging"] }],
  integrationsMap: { linkedin: "ConnectorClass:integrations" },
});

function makeEnv() {
  return {
    TWIST_CONFIG: { get: vi.fn(async () => KV_CONFIG) },
    CALLBACKS: {
      idFromName: vi.fn(() => "callbacks-do-id"),
      get: vi.fn(() => ({ create: vi.fn(async () => "callback-token") })),
    },
    STORAGE: {},
    API_ROOT: "https://api.test",
  };
}

const captureExceptionMock = vi.fn();

async function postAuth(
  body: unknown,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  opts?: { env?: any; db?: any; user?: { id: string } | null },
) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const app = new Hono<{ Bindings: any }>();
  app.use("*", async (c, next) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("user", opts?.user ?? { id: TEST_USER_ID });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("db", opts?.db ?? makeDb(TWIST_ROW));
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("tracker", { captureException: captureExceptionMock });
    await next();
  });
  app.route("/", twistIntegrations);

  const req = new Request(
    `http://localhost/twist/${TEST_TWIST_INSTANCE_ID}/integrations/auth`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  return app.fetch(req, opts?.env ?? makeEnv(), {
    waitUntil: () => {},
    passThroughOnException: () => {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any);
}

describe("POST /twist/:id/integrations/auth", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
  });

  it("returns 502 and captures when GenerateAuthUrl throws (e.g. Unipile 401)", async () => {
    vi.spyOn(Integrations, "GenerateAuthUrl").mockRejectedValue(
      new UnipileApiError(
        "Unipile POST /hosted/accounts/link returned 401",
        401,
        "",
      ),
    );

    const res = await postAuth({
      provider: "linkedin",
      redirectUri: "plotday://auth",
    });

    expect(res.status).toBe(502);
    const json = (await res.json()) as { message: string };
    expect(json.message).toMatch(/unavailable/i);
    expect(captureExceptionMock).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({ context: "integrations:auth" }),
    );
  });

  it("returns 200 with the auth URL and callback on success", async () => {
    vi.spyOn(Integrations, "GenerateAuthUrl").mockResolvedValue({
      url: "https://provider.test/oauth",
      clientId: "hosted",
      state: "state-token",
    });

    const res = await postAuth({
      provider: "linkedin",
      redirectUri: "plotday://auth",
    });

    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      url: string;
      callback: string;
      scopes: string[];
    };
    expect(json.url).toBe("https://provider.test/oauth");
    expect(json.callback).toBe("callback-token");
    // The server must echo the resolved scopes so the native Google Sign-In
    // path (which can't read the embedded auth URL) requests exactly the scope
    // groups the user enabled. Without this, native consent falls back to the
    // connector's required scopes and silently drops optional product scopes.
    expect(json.scopes).toEqual(["messaging"]);
    expect(captureExceptionMock).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// reconcileScopeAddonBillingDown — DB integration tests
// ---------------------------------------------------------------------------
//
// These tests call the exported helper directly with a real Kysely connection
// to the worktree DB (DATABASE_URL) and a stubbed Stripe client. They are
// skipped when DATABASE_URL is absent (CI without a DB).
//
// Seeding pattern: roll back via a Rollback sentinel thrown inside the
// transaction, so the DB is left untouched after each test.

const DATABASE_URL_FOR_RECONCILE = process.env.DATABASE_URL;

/** Sentinel thrown to roll back a seeding transaction cleanly. */
class Rollback extends Error {}

/**
 * Minimal Stripe stub for reconcileAddonQuantityDown.
 *
 * By default: retrieve returns quantity=5, update/cancel resolve successfully.
 * Tests override individual methods to simulate specific behaviors.
 */
function makeStripeMock(overrides?: {
  cancelResolve?: object;
  retrieveQuantity?: number;
}) {
  return {
    subscriptions: {
      retrieve: vi.fn().mockResolvedValue({
        items: {
          data: [{ id: "si_test", quantity: overrides?.retrieveQuantity ?? 5 }],
        },
      }),
      update: vi.fn().mockResolvedValue({}),
      cancel: vi.fn().mockResolvedValue(overrides?.cancelResolve ?? {}),
    },
  };
}

/**
 * Seed a personal scope with:
 *   - a user_subscription row with the given plan, stripe_addon_subscription_id
 *     and premium_connection_addons
 *   - `regularInstanceCount` active regular (non-premium) twist_instance rows,
 *     each with one enabled channel
 *   - `premiumInstanceCount` active premium twist_instance rows, each with
 *     one enabled channel
 *
 * Use this to test scenarios where regular connections can be beyond the plan
 * pool (e.g. plan="free" with pool=2 and regularInstanceCount=3 seeds 1 beyond
 * the pool so getBillableConnectionAddonCount returns 1, while the old
 * getPersonalPremiumConnectionCount would return 0 — proving change A is needed).
 *
 * Returns `{ userId, trx }` inside the transaction so the caller can invoke
 * the helper and assert the result, then throws Rollback to clean up.
 */
async function withPersonalAddonScopeExtended(opts: {
  plan: string;
  addonSubscriptionId: string | null;
  premiumConnectionAddons: number;
  regularInstanceCount: number;
  premiumInstanceCount: number;
  test: (args: { userId: string; trx: Kysely<DB> }) => Promise<void>;
}): Promise<void> {
  const db = createDb({ DATABASE_URL: DATABASE_URL_FOR_RECONCILE } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      const userId = randomUUID();
      const billingEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      await trx
        .insertInto("user_subscription")
        .values({
          user_id: userId,
          plan: opts.plan as "free" | "pro" | "team",
          status: "active",
          origin: "stripe",
          stripe_customer_id: "cus_test_ext",
          stripe_subscription_id: "sub_plan_test_ext",
          stripe_addon_subscription_id: opts.addonSubscriptionId,
          premium_connection_addons: opts.premiumConnectionAddons,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: billingEnd,
        })
        .execute();

      // Seed regular (non-premium) twist_instance rows with enabled channels.
      for (let i = 0; i < opts.regularInstanceCount; i++) {
        const tiId = randomUUID();

        const twistResult = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version, is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'Google Calendar', 'gcal', '1.0.0', true, false)
          RETURNING id`.execute(trx);
        const twistId = twistResult.rows[0].id;

        await sql`
          INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${tiId}::uuid, ${twistId}, ${userId}::uuid, 'Google Calendar', null)
        `.execute(trx);

        await sql`
          INSERT INTO channel (twist_instance_id, channel_id, title, enabled)
          VALUES (${tiId}::uuid, ${"reg-ch-" + i}, 'Channel', true)
        `.execute(trx);
      }

      // Seed premium twist_instance rows with enabled channels.
      for (let i = 0; i < opts.premiumInstanceCount; i++) {
        const tiId = randomUUID();

        const twistResult = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version, is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, true)
          RETURNING id`.execute(trx);
        const twistId = twistResult.rows[0].id;

        await sql`
          INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${tiId}::uuid, ${twistId}, ${userId}::uuid, 'LinkedIn', null)
        `.execute(trx);

        await sql`
          INSERT INTO channel (twist_instance_id, channel_id, title, enabled)
          VALUES (${tiId}::uuid, ${"prem-ch-" + i}, 'Channel', true)
        `.execute(trx);
      }

      await opts.test({ userId, trx });

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

/**
 * Seed a personal scope with:
 *   - a user_subscription row with the given stripe_addon_subscription_id
 *     and premium_connection_addons
 *   - `premiumInstanceCount` active premium twist_instance rows, each with
 *     one enabled channel (count as active add-on connections)
 *
 * Returns `{ userId, trx }` inside the transaction so the caller can invoke
 * the helper and assert the result, then throws Rollback to clean up.
 */
async function withPersonalAddonScope(opts: {
  addonSubscriptionId: string | null;
  premiumConnectionAddons: number;
  premiumInstanceCount: number;
  test: (args: { userId: string; trx: Kysely<DB> }) => Promise<void>;
}): Promise<void> {
  const db = createDb({ DATABASE_URL: DATABASE_URL_FOR_RECONCILE } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      const userId = randomUUID();
      const billingEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      // Insert user_subscription with add-on columns set.
      await trx
        .insertInto("user_subscription")
        .values({
          user_id: userId,
          plan: "pro",
          status: "active",
          origin: "stripe",
          stripe_customer_id: "cus_test",
          stripe_subscription_id: "sub_plan_test",
          stripe_addon_subscription_id: opts.addonSubscriptionId,
          premium_connection_addons: opts.premiumConnectionAddons,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: billingEnd,
        })
        .execute();

      // Seed N active premium twist_instance rows with enabled channels.
      for (let i = 0; i < opts.premiumInstanceCount; i++) {
        const tiId = randomUUID();

        const twistResult = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version, is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, true)
          RETURNING id`.execute(trx);
        const twistId = twistResult.rows[0].id;

        await sql`
          INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${tiId}::uuid, ${twistId}, ${userId}::uuid, 'LinkedIn', null)
        `.execute(trx);

        await sql`
          INSERT INTO channel (twist_instance_id, channel_id, title, enabled)
          VALUES (${tiId}::uuid, ${"ch-" + i}, 'Channel', true)
        `.execute(trx);
      }

      // Keep session_replication_role = replica throughout so that the
      // UPDATE inside reconcileScopeAddonBillingDown doesn't trip FK checks
      // on the synthetic userId that has no corresponding user row.
      await opts.test({ userId, trx });

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

/**
 * Seed a team scope with:
 *   - a team row
 *   - a team_subscription row with the given stripe_addon_subscription_id and
 *     premium_connection_addons
 *   - `premiumInstanceCount` active premium twist_instance rows owned by that
 *     team, each with one enabled channel
 *
 * Mirrors withPersonalAddonScope for the team path.
 */
async function withTeamAddonScope(opts: {
  addonSubscriptionId: string | null;
  premiumConnectionAddons: number;
  premiumInstanceCount: number;
  test: (args: { teamId: string; trx: Kysely<DB> }) => Promise<void>;
}): Promise<void> {
  const db = createDb({ DATABASE_URL: DATABASE_URL_FOR_RECONCILE } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      const billingEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      // Insert a team row — team.id is a bigint GENERATED ALWAYS AS IDENTITY
      const teamResult = await sql<{ id: string }>`
        INSERT INTO team (name) VALUES ('Test Team') RETURNING id
      `.execute(trx);
      const teamId = String(teamResult.rows[0].id);

      // Insert team_subscription with add-on columns set.
      await trx
        .insertInto("team_subscription")
        .values({
          team_id: teamId,
          plan: "team",
          status: "active",
          stripe_customer_id: `cus_team_${teamId}`,
          stripe_subscription_id: "sub_team_plan",
          stripe_addon_subscription_id: opts.addonSubscriptionId,
          premium_connection_addons: opts.premiumConnectionAddons,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: billingEnd,
        })
        .execute();

      // Seed N active premium twist_instance rows owned by the team, with
      // enabled channels so getTeamPremiumConnectionCount counts them.
      for (let i = 0; i < opts.premiumInstanceCount; i++) {
        const tiId = randomUUID();

        // Use a synthetic user_id for the twist owner — FK checks are off in replica mode.
        const syntheticUserId = randomUUID();

        const twistResult = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version, is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${syntheticUserId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, true)
          RETURNING id
        `.execute(trx);
        const twistId = twistResult.rows[0].id;

        await sql`
          INSERT INTO twist_instance (id, twist_id, owner_id, team_id, name)
          VALUES (${tiId}::uuid, ${twistId}, ${syntheticUserId}::uuid, ${teamId}, 'LinkedIn')
        `.execute(trx);

        await sql`
          INSERT INTO channel (twist_instance_id, channel_id, title, enabled)
          VALUES (${tiId}::uuid, ${"team-ch-" + i}, 'Channel', true)
        `.execute(trx);
      }

      await opts.test({ teamId, trx });

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL_FOR_RECONCILE)(
  "reconcileScopeAddonBillingDown — team scope",
  () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it(
      "(a) team: 1 remaining active premium connection → reconciles quantity down without canceling",
      async () => {
        const stripe = makeStripeMock({ retrieveQuantity: 2 });
        let capturedAddons: number | undefined;
        let capturedSubId: string | null | undefined;

        await withTeamAddonScope({
          addonSubscriptionId: "sub_team_addon_test",
          premiumConnectionAddons: 2,
          premiumInstanceCount: 1,
          test: async ({ teamId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { teamId } });

            const row = await trx
              .selectFrom("team_subscription")
              .select(["premium_connection_addons", "stripe_addon_subscription_id"])
              .where("team_id", "=", teamId)
              .executeTakeFirstOrThrow();

            capturedAddons = row.premium_connection_addons;
            capturedSubId = row.stripe_addon_subscription_id;
          },
        });

        expect(stripe.subscriptions.cancel).not.toHaveBeenCalled();
        expect(stripe.subscriptions.update).toHaveBeenCalledWith(
          "sub_team_addon_test",
          expect.objectContaining({ items: [expect.objectContaining({ quantity: 1 })] })
        );
        expect(capturedAddons).toBe(1);
        expect(capturedSubId).toBe("sub_team_addon_test");
      }
    );

    it(
      "(b) team: 0 remaining active premium connections → cancels subscription and nulls stripe_addon_subscription_id",
      async () => {
        const stripe = makeStripeMock({ retrieveQuantity: 1 });
        let capturedAddons: number | undefined;
        let capturedSubId: string | null | undefined;

        await withTeamAddonScope({
          addonSubscriptionId: "sub_team_addon_cancel",
          premiumConnectionAddons: 1,
          premiumInstanceCount: 0,
          test: async ({ teamId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { teamId } });

            const row = await trx
              .selectFrom("team_subscription")
              .select(["premium_connection_addons", "stripe_addon_subscription_id"])
              .where("team_id", "=", teamId)
              .executeTakeFirstOrThrow();

            capturedAddons = row.premium_connection_addons;
            capturedSubId = row.stripe_addon_subscription_id;
          },
        });

        expect(stripe.subscriptions.cancel).toHaveBeenCalledWith(
          "sub_team_addon_cancel",
          expect.anything()
        );
        expect(capturedAddons).toBe(0);
        expect(capturedSubId).toBeNull();
      }
    );

    it(
      "(c) team: stripe_addon_subscription_id is null → no-op (Stripe never called)",
      async () => {
        const stripe = makeStripeMock();

        await withTeamAddonScope({
          addonSubscriptionId: null,
          premiumConnectionAddons: 0,
          premiumInstanceCount: 0,
          test: async ({ teamId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { teamId } });
          },
        });

        expect(stripe.subscriptions.retrieve).not.toHaveBeenCalled();
        expect(stripe.subscriptions.update).not.toHaveBeenCalled();
        expect(stripe.subscriptions.cancel).not.toHaveBeenCalled();
      }
    );
  }
);

describe.skipIf(!DATABASE_URL_FOR_RECONCILE)(
  "reconcileScopeAddonBillingDown",
  () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it(
      "(a) 1 remaining active premium connection → reconciles quantity down without canceling",
      async () => {
        const stripe = makeStripeMock({ retrieveQuantity: 2 });
        let capturedAddons: number | undefined;
        let capturedSubId: string | null | undefined;

        await withPersonalAddonScope({
          addonSubscriptionId: "sub_addon_test",
          premiumConnectionAddons: 2,
          // After "disabling" one the remaining active count is 1
          premiumInstanceCount: 1,
          test: async ({ userId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { userId } });

            const row = await trx
              .selectFrom("user_subscription")
              .select(["premium_connection_addons", "stripe_addon_subscription_id"])
              .where("user_id", "=", userId)
              .executeTakeFirstOrThrow();

            capturedAddons = row.premium_connection_addons;
            capturedSubId = row.stripe_addon_subscription_id;
          },
        });

        // quantity should have been reduced to 1 (the remaining active count)
        expect(stripe.subscriptions.cancel).not.toHaveBeenCalled();
        expect(stripe.subscriptions.update).toHaveBeenCalledWith(
          "sub_addon_test",
          expect.objectContaining({ items: [expect.objectContaining({ quantity: 1 })] })
        );
        expect(capturedAddons).toBe(1);
        // sub ID unchanged (not canceled)
        expect(capturedSubId).toBe("sub_addon_test");
      }
    );

    it(
      "(b) 0 remaining active premium connections → cancels subscription and nulls stripe_addon_subscription_id",
      async () => {
        const stripe = makeStripeMock({ retrieveQuantity: 1 });
        let capturedAddons: number | undefined;
        let capturedSubId: string | null | undefined;

        await withPersonalAddonScope({
          addonSubscriptionId: "sub_addon_cancel",
          premiumConnectionAddons: 1,
          // 0 active premium connections after the last one is disabled
          premiumInstanceCount: 0,
          test: async ({ userId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { userId } });

            const row = await trx
              .selectFrom("user_subscription")
              .select(["premium_connection_addons", "stripe_addon_subscription_id"])
              .where("user_id", "=", userId)
              .executeTakeFirstOrThrow();

            capturedAddons = row.premium_connection_addons;
            capturedSubId = row.stripe_addon_subscription_id;
          },
        });

        // subscription must be canceled
        expect(stripe.subscriptions.cancel).toHaveBeenCalledWith(
          "sub_addon_cancel",
          expect.anything()
        );
        expect(capturedAddons).toBe(0);
        // stripe_addon_subscription_id must be cleared
        expect(capturedSubId).toBeNull();
      }
    );

    it(
      "(c) stripe_addon_subscription_id is null → no-op (Stripe never called)",
      async () => {
        const stripe = makeStripeMock();

        await withPersonalAddonScope({
          addonSubscriptionId: null,
          premiumConnectionAddons: 0,
          premiumInstanceCount: 0,
          test: async ({ userId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { userId } });
          },
        });

        expect(stripe.subscriptions.retrieve).not.toHaveBeenCalled();
        expect(stripe.subscriptions.update).not.toHaveBeenCalled();
        expect(stripe.subscriptions.cancel).not.toHaveBeenCalled();
      }
    );

    it(
      "(d) regular connections beyond the pool → reconciles to billable count, not premium-only count",
      async () => {
        // Scenario: user on Free plan (pool=2). Had 4 regular connections (2 beyond
        // pool) → purchased 2 add-on credits. Disabled 1 beyond-pool regular; now 3
        // regular remain (still 1 beyond pool). Reconcile should set quantity to 1.
        //
        // OLD behavior (getPersonalPremiumConnectionCount): premiumCount=0 →
        //   activeCount=0 → cancel → premium_connection_addons=0. WRONG.
        // NEW behavior (getBillableConnectionAddonCount): max(0,3-2)+0=1 →
        //   activeCount=1 → update quantity to 1. CORRECT.
        const stripe = makeStripeMock({ retrieveQuantity: 2 });
        let capturedAddons: number | undefined;
        let capturedSubId: string | null | undefined;

        await withPersonalAddonScopeExtended({
          plan: "free", // pool = PLAN_LIMITS["free"].connections = 2
          addonSubscriptionId: "sub_regular_overpool",
          premiumConnectionAddons: 2,
          regularInstanceCount: 3, // 3 remain after 1 disabled; still 1 beyond pool
          premiumInstanceCount: 0,
          test: async ({ userId, trx }) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            await reconcileScopeAddonBillingDown({ db: trx, stripe: stripe as any, scope: { userId } });

            const row = await trx
              .selectFrom("user_subscription")
              .select(["premium_connection_addons", "stripe_addon_subscription_id"])
              .where("user_id", "=", userId)
              .executeTakeFirstOrThrow();

            capturedAddons = row.premium_connection_addons;
            capturedSubId = row.stripe_addon_subscription_id;
          },
        });

        // NEW code: 3 regular with pool=2 → billable=1 → update quantity to 1
        expect(stripe.subscriptions.cancel).not.toHaveBeenCalled();
        expect(stripe.subscriptions.update).toHaveBeenCalledWith(
          "sub_regular_overpool",
          expect.objectContaining({ items: [expect.objectContaining({ quantity: 1 })] })
        );
        expect(capturedAddons).toBe(1);
        expect(capturedSubId).toBe("sub_regular_overpool");
        // OLD code would have set premium_connection_addons=0 and canceled (wrong).
      }
    );
  }
);
