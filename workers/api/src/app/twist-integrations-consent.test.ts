/**
 * DB-backed vitest tests for the charge-on-enable logic added to the two
 * channel-enable handlers in twist-integrations.ts:
 *   - POST /twist/:id/syncables/:provider/:syncableId/enable  (~line 1182)
 *   - POST /twist/:id/syncables/batch                         (~line 1423)
 *
 * APPROACH
 * --------
 * Real DB (seeded inside a rollback transaction) + stubbed Stripe at the
 * customerHasPaymentMethod / subscriptions level.  twistFactory and
 * enqueueChannelRouter are module-mocked so the handler can complete
 * without real KV/DO infrastructure.
 *
 * Seeding triggers `checkChannelConnectionLimit → addon_required` naturally:
 * a premium connector (twist.premium = true) with premium_connection_addons = 0
 * is always over-limit on the first enable (pendingBillable = 1 > 0 purchased).
 *
 * Tests are skipped when DATABASE_URL is absent (CI without a DB).
 */

import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";

import twistIntegrations from "./twist-integrations";
import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { createStripeClient } from "../stripe/utils";

// ---------------------------------------------------------------------------
// Module-level mocks (hoisted by vitest)
// ---------------------------------------------------------------------------

/** Mock twistFactory so enables don't require real KV / Durable Objects. */
vi.mock("../twist", () => ({
  twistFactory: vi.fn().mockImplementation(() => async () => ({
    callCallback: vi.fn().mockResolvedValue(null),
  })),
}));

/** Mock the background channel-router enqueue — waitUntil is a no-op anyway. */
vi.mock("../state/channel-router", () => ({
  enqueueChannelRouter: vi.fn().mockResolvedValue(undefined),
}));

/**
 * Mock createStripeClient so each test can inject its own Stripe stub.
 * The mock captures `currentStripeMock` by closure reference, which tests
 * set in beforeEach / directly before the call.
 */
let currentStripeMock: ReturnType<typeof makeCardOnFileStripe> | ReturnType<typeof makeNoCardStripe>;

vi.mock("../stripe/utils", () => ({
  createStripeClient: vi.fn().mockImplementation(() => currentStripeMock),
}));

// ---------------------------------------------------------------------------
// Constants and helpers
// ---------------------------------------------------------------------------

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to roll back a seeding transaction cleanly. */
class Rollback extends Error {}

/** Minimal KV config – enough for loadTwistConfig + the linkedin integrationsMap. */
const KV_CONFIG = JSON.stringify({
  providers: [{ provider: "linkedin", scopes: ["messaging"] }],
  integrationsMap: { linkedin: "ConnectorClass:integrations" },
});

/** Stripe stub for the "card on file" path. */
function makeCardOnFileStripe() {
  return {
    customers: {
      retrieve: vi.fn().mockResolvedValue({
        deleted: false,
        invoice_settings: { default_payment_method: "pm_card_test" },
      }),
    },
    paymentMethods: { list: vi.fn() },
    prices: {
      list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon_monthly" }] }),
    },
    subscriptions: {
      create: vi.fn().mockResolvedValue({
        id: "sub_consent_new",
        items: { data: [{ id: "si_consent_new", quantity: 1 }] },
      }),
      update: vi.fn().mockResolvedValue({}),
    },
  };
}

/** Stripe stub for the "no card on file" path. */
function makeNoCardStripe() {
  return {
    customers: {
      retrieve: vi.fn().mockResolvedValue({
        deleted: false,
        invoice_settings: {},
      }),
    },
    paymentMethods: {
      list: vi.fn().mockResolvedValue({ data: [] }),
    },
    prices: {
      list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon_monthly" }] }),
    },
    subscriptions: { create: vi.fn() },
    checkout: {
      sessions: {
        create: vi.fn().mockResolvedValue({
          url: "https://checkout.stripe.com/pay/setup?addon=card_saved",
        }),
      },
    },
  };
}

/**
 * Seed a scenario where `checkChannelConnectionLimit` returns `addon_required`:
 *   - user_subscription on "free" plan, stripe_customer_id set, premium_connection_addons = 0
 *   - twist with premium = true (→ isAddon = true in the gate)
 *   - twist_instance owned by the user (team_id IS NULL)
 *   - twist_instance_connection record for (twist_instance_id, user_id, "linkedin")
 *   - contact row so getCurrentActorId returns non-null
 *   - NO enabled channel rows → pendingBillable = 1 > 0 purchased → addon_required
 *
 * Runs entirely inside a transaction that throws Rollback at the end so the
 * DB is left pristine after each test.
 */
async function withConsentEnableScenario(opts: {
  stripeCustomerId: string;
  test: (args: {
    userId: string;
    twistInstanceId: string;
    contactId: string;
    trx: Kysely<DB>;
  }) => Promise<void>;
}): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      // Disable FK checks so we can insert with synthetic IDs.
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      const userId = randomUUID();
      const twistInstanceId = randomUUID();
      const contactId = randomUUID();
      const actorId = randomUUID();
      const billingEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      // user_subscription — gives resolveAddonScope the stripe_customer_id
      await trx
        .insertInto("user_subscription")
        .values({
          user_id: userId,
          plan: "free",
          status: "active",
          origin: "stripe",
          stripe_customer_id: opts.stripeCustomerId,
          stripe_subscription_id: "sub_plan_consent_test",
          stripe_addon_subscription_id: null,
          premium_connection_addons: 0,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: billingEnd,
        })
        .execute();

      // contact — gives getCurrentActorId a non-null result
      await sql`
        INSERT INTO contact (id, user_id) VALUES (${contactId}::uuid, ${userId}::uuid)
      `.execute(trx);

      // twist (premium = true → isAddon = true in checkChannelConnectionLimit)
      const twistResult = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, environment, user_id, name, handle, version, is_source, premium)
        VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
          'LinkedIn', 'linkedin', '1.0.0', true, true)
        RETURNING id
      `.execute(trx);
      const twistId = twistResult.rows[0].id;

      // twist_instance — owned by user, not team-scoped
      await sql`
        INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
        VALUES (${twistInstanceId}::uuid, ${twistId}, ${userId}::uuid, 'LinkedIn', null)
      `.execute(trx);

      // twist_instance_connection — required by checkChannelConnectionLimit to proceed;
      // without it the gate early-returns { allowed: true }.
      await sql`
        INSERT INTO twist_instance_connection
          (twist_instance_id, user_id, provider, actor_id)
        VALUES (${twistInstanceId}::uuid, ${userId}::uuid, 'linkedin', ${actorId}::uuid)
      `.execute(trx);

      // No channel rows inserted → no enabled channel → gate does NOT short-circuit.

      await opts.test({ userId, twistInstanceId, contactId, trx });

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

/** Build a minimal Hono app backed by the real twistIntegrations routes. */
function makeApp(db: Kysely<DB>, userId: string) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const app = new Hono<{ Bindings: any }>();
  app.use("*", async (c, next) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("user", { id: userId });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("db", db);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("tracker", { captureException: vi.fn() });
    await next();
  });
  app.route("/", twistIntegrations);
  return app;
}

/** Mock env — KV + dummy Stripe key + SITE_ROOT. */
function makeMockEnv() {
  return {
    TWIST_CONFIG: { get: vi.fn(async () => KV_CONFIG) },
    STRIPE_SECRET_KEY: "sk_test_mock",
    SITE_ROOT: "https://plot.day",
    CALLBACKS: {
      idFromName: vi.fn(() => "cb-do-id"),
      get: vi.fn(() => ({ create: vi.fn(async () => "callback-token") })),
    },
    STORAGE: {},
    API_ROOT: "https://api.test",
  };
}

/** POST to the single-channel enable endpoint. */
async function postEnable(
  app: ReturnType<typeof makeApp>,
  twistInstanceId: string,
  body: unknown,
) {
  return app.fetch(
    new Request(
      `http://localhost/twist/${twistInstanceId}/syncables/linkedin/ch-test/enable`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    ),
    makeMockEnv(),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    { waitUntil: () => {}, passThroughOnException: () => {} } as any,
  );
}

/** POST to the batch syncables endpoint. */
async function postBatch(
  app: ReturnType<typeof makeApp>,
  twistInstanceId: string,
  body: unknown,
) {
  return app.fetch(
    new Request(
      `http://localhost/twist/${twistInstanceId}/syncables/batch`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    ),
    makeMockEnv(),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    { waitUntil: () => {}, passThroughOnException: () => {} } as any,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "channel-enable: consent-addon charge-on-enable",
  () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it(
      "(a) consent + card on file → 200 enabled + premium_connection_addons incremented",
      async () => {
        currentStripeMock = makeCardOnFileStripe();

        let status = 0;
        let addons: number | undefined;

        await withConsentEnableScenario({
          stripeCustomerId: "cus_consent_card",
          test: async ({ userId, twistInstanceId, trx }) => {
            const app = makeApp(trx, userId);
            const res = await postEnable(app, twistInstanceId, { consentAddon: true });
            status = res.status;

            const row = await trx
              .selectFrom("user_subscription")
              .select("premium_connection_addons")
              .where("user_id", "=", userId)
              .executeTakeFirst();
            addons = row?.premium_connection_addons;
          },
        });

        expect(status).toBe(200);
        expect(addons).toBe(1);
        // Stripe subscription was created to provision the add-on
        expect(vi.mocked(createStripeClient)).toHaveBeenCalled();
      },
    );

    it(
      "(b) consent + no card → 402 { reason: needs_card, checkout_url }",
      async () => {
        currentStripeMock = makeNoCardStripe();

        let status = 0;
        let json: unknown;

        await withConsentEnableScenario({
          stripeCustomerId: "cus_consent_nocard",
          test: async ({ userId, twistInstanceId, trx }) => {
            const app = makeApp(trx, userId);
            const res = await postEnable(app, twistInstanceId, { consentAddon: true });
            status = res.status;
            json = await res.json();
          },
        });

        expect(status).toBe(402);
        expect(json).toMatchObject({
          reason: "needs_card",
          checkout_url: expect.stringContaining("checkout.stripe.com"),
        });
      },
    );

    it(
      "(c) no consent (billable) → 403 addon_required, quantity unchanged",
      async () => {
        currentStripeMock = makeCardOnFileStripe(); // should not be called

        let status = 0;
        let addons: number | undefined;

        await withConsentEnableScenario({
          stripeCustomerId: "cus_no_consent",
          test: async ({ userId, twistInstanceId, trx }) => {
            const app = makeApp(trx, userId);
            // POST with no consentAddon flag
            const res = await postEnable(app, twistInstanceId, {});
            status = res.status;

            const row = await trx
              .selectFrom("user_subscription")
              .select("premium_connection_addons")
              .where("user_id", "=", userId)
              .executeTakeFirst();
            addons = row?.premium_connection_addons;
          },
        });

        expect(status).toBe(403);
        // Stripe must NOT have been called (no consent, no charge)
        expect(vi.mocked(createStripeClient)).not.toHaveBeenCalled();
        // Quantity stays at 0
        expect(addons).toBe(0);
      },
    );

    it(
      "(d) abandon (consentAddon explicitly false) → 403, quantity unchanged (no charge)",
      async () => {
        currentStripeMock = makeCardOnFileStripe(); // should not be called

        let status = 0;
        let addons: number | undefined;

        await withConsentEnableScenario({
          stripeCustomerId: "cus_abandon",
          test: async ({ userId, twistInstanceId, trx }) => {
            const app = makeApp(trx, userId);
            // POST with consentAddon=false (user dismissed the dialog)
            const res = await postEnable(app, twistInstanceId, { consentAddon: false });
            status = res.status;

            const row = await trx
              .selectFrom("user_subscription")
              .select("premium_connection_addons")
              .where("user_id", "=", userId)
              .executeTakeFirst();
            addons = row?.premium_connection_addons;
          },
        });

        expect(status).toBe(403);
        expect(vi.mocked(createStripeClient)).not.toHaveBeenCalled();
        expect(addons).toBe(0);
      },
    );
  },
);

describe.skipIf(!DATABASE_URL)(
  "batch syncables: consent-addon charge-on-enable (POST /twist/:id/syncables/batch)",
  () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it(
      "consent + card on file via batch → 200 + premium_connection_addons incremented",
      async () => {
        currentStripeMock = makeCardOnFileStripe();

        let status = 0;
        let addons: number | undefined;

        await withConsentEnableScenario({
          stripeCustomerId: "cus_batch_consent",
          test: async ({ userId, twistInstanceId, trx }) => {
            const app = makeApp(trx, userId);
            const res = await postBatch(app, twistInstanceId, {
              enable: [{ provider: "linkedin", syncableId: "ch-batch-test" }],
              consentAddon: true,
            });
            status = res.status;

            const row = await trx
              .selectFrom("user_subscription")
              .select("premium_connection_addons")
              .where("user_id", "=", userId)
              .executeTakeFirst();
            addons = row?.premium_connection_addons;
          },
        });

        expect(status).toBe(200);
        expect(addons).toBe(1);
        expect(vi.mocked(createStripeClient)).toHaveBeenCalled();
      },
    );
  },
);
