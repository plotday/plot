/**
 * DB-backed vitest tests for the charge-on-enable consent gate on the PRIMARY
 * "add a new connection" path:
 *
 *   POST /twist/draft/:id/activate   (twists.ts, ~line 419)
 *
 * This route is what web / DMG / Android use to add a connection (App Store
 * pre-purchases via StoreKit). Finding C1: before the fix it called
 * activateDraft() without ever running checkChannelConnectionLimit or the
 * charge helper, so a billable connection (premium connector, or a regular
 * connection beyond the pool) enabled for free even when the client forwarded
 * `consentAddon`. The fix routes this path through the same
 * `chargeConsentedAddonOrError` gate the two channel-enable handlers use.
 *
 * APPROACH
 * --------
 * Real DB (seeded inside a rollback transaction) + stubbed Stripe at the
 * customerHasPaymentMethod / subscriptions level. `../twist` (twistFactory),
 * `./sync/notify` (notifyUserSync), and `../stripe/utils` (createStripeClient)
 * are module-mocked so the route completes without real KV/DO/Stripe infra.
 *
 * The twistFactory stub exposes `activate`, `sourceProvider`, and a no-op
 * `callCallback`, which is enough for activateDraft's source-activation path to
 * succeed. Because channel enabling is mocked (no real channel rows written),
 * "connection enabled" is verified via the draft → false flip that activateDraft
 * performs only when the gate lets it proceed.
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

import twists from "./twists";
import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { createStripeClient } from "../stripe/utils";

// ---------------------------------------------------------------------------
// Module-level mocks (hoisted by vitest)
// ---------------------------------------------------------------------------

/**
 * Mock twistFactory so activate doesn't require real KV / Durable Objects.
 * activateDraft reads `sourceProvider` and calls `activate(...)` plus
 * `callCallback(...)` on the wrapper.
 */
vi.mock("../twist", () => ({
  twistFactory: vi.fn().mockImplementation(() => async () => ({
    sourceProvider: null,
    activate: vi.fn().mockResolvedValue(undefined),
    callCallback: vi.fn().mockResolvedValue(null),
  })),
}));

/** Mock notifyUserSync — it fires a background sync we don't exercise here. */
vi.mock("./sync/notify", () => ({
  notifyUserSync: vi.fn(),
}));

/**
 * Mock createStripeClient so each test can inject its own Stripe stub.
 * The mock captures `currentStripeMock` by closure reference.
 */
let currentStripeMock:
  | ReturnType<typeof makeCardOnFileStripe>
  | ReturnType<typeof makeNoCardStripe>;

vi.mock("../stripe/utils", () => ({
  createStripeClient: vi.fn().mockImplementation(() => currentStripeMock),
}));

// ---------------------------------------------------------------------------
// Constants and helpers
// ---------------------------------------------------------------------------

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to roll back a seeding transaction cleanly. */
class Rollback extends Error {}

/** Minimal KV config – enough for activateDraft's integrationsMap lookup. */
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
 * Seed a draft (draft = true) premium connection where
 * `checkChannelConnectionLimit` returns `addon_required`:
 *   - user_subscription on "free" plan, stripe_customer_id set,
 *     premium_connection_addons = 0
 *   - twist with premium = true (→ isAddon) and is_source = true
 *   - twist_instance owned by the user, team_id NULL, draft = true
 *   - twist_instance_connection for (twist_instance_id, user_id, "linkedin")
 *   - contact row so getCurrentActorId / activateDraft's owner lookup resolve
 *   - NO enabled channel rows → pendingBillable = 1 > 0 purchased → addon_required
 *
 * Runs entirely inside a transaction that throws Rollback at the end so the DB
 * is left pristine after each test.
 */
async function withActivateDraftScenario(opts: {
  stripeCustomerId: string;
  test: (args: {
    userId: string;
    draftId: string;
    trx: Kysely<DB>;
  }) => Promise<void>;
}): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      // Disable FK checks so we can insert with synthetic IDs.
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      const userId = randomUUID();
      const draftId = randomUUID();
      const contactId = randomUUID();
      const actorId = randomUUID();
      const billingEnd = new Date(
        Date.now() + 30 * 24 * 60 * 60 * 1000
      ).toISOString();

      // user_subscription — gives resolveAddonScope the stripe_customer_id
      await trx
        .insertInto("user_subscription")
        .values({
          user_id: userId,
          plan: "free",
          status: "active",
          origin: "stripe",
          stripe_customer_id: opts.stripeCustomerId,
          stripe_subscription_id: "sub_plan_activate_test",
          stripe_addon_subscription_id: null,
          premium_connection_addons: 0,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: billingEnd,
        })
        .execute();

      // contact — getCurrentActorId / activateDraft owner contact lookup
      await sql`
        INSERT INTO contact (id, user_id) VALUES (${contactId}::uuid, ${userId}::uuid)
      `.execute(trx);

      // twist (premium = true → isAddon; is_source = true → connection)
      const twistResult = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, environment, user_id, name, handle, version, is_source, premium)
        VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
          'LinkedIn', 'linkedin', '1.0.0', true, true)
        RETURNING id
      `.execute(trx);
      const twistId = twistResult.rows[0].id;

      // twist_instance — owned by user, not team-scoped, DRAFT (activate target)
      await sql`
        INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id, draft)
        VALUES (${draftId}::uuid, ${twistId}, ${userId}::uuid, 'LinkedIn', null, true)
      `.execute(trx);

      // twist_instance_connection — without it checkChannelConnectionLimit
      // early-returns { allowed: true } and the gate is a no-op.
      await sql`
        INSERT INTO twist_instance_connection
          (twist_instance_id, user_id, provider, actor_id)
        VALUES (${draftId}::uuid, ${userId}::uuid, 'linkedin', ${actorId}::uuid)
      `.execute(trx);

      // No channel rows → no enabled channel → gate does NOT short-circuit.

      await opts.test({ userId, draftId, trx });

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

/** Build a minimal Hono app backed by the real twists routes. */
function makeApp(db: Kysely<DB>, userId: string) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const app = new Hono<{ Bindings: any }>();
  app.use("*", async (c, next) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("user", { id: userId, email: "test@plot.day" });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("db", db);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("tracker", { captureException: vi.fn(), capture: vi.fn() });
    await next();
  });
  app.route("/", twists);
  return app;
}

/** Mock env — KV + dummy Stripe key + SITE_ROOT + DATABASE_URL (deferred db). */
function makeMockEnv() {
  return {
    TWIST_CONFIG: { get: vi.fn(async () => KV_CONFIG) },
    STRIPE_SECRET_KEY: "sk_test_mock",
    SITE_ROOT: "https://plot.day",
    DATABASE_URL,
    STORAGE: {},
    API_ROOT: "https://api.test",
  };
}

/** POST to the draft activate endpoint. */
async function postActivate(
  app: ReturnType<typeof makeApp>,
  draftId: string,
  body: unknown
) {
  return app.fetch(
    new Request(`http://localhost/twist/draft/${draftId}/activate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    makeMockEnv(),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    { waitUntil: () => {}, passThroughOnException: () => {} } as any
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "activate draft: consent-addon charge-on-enable (POST /twist/draft/:id/activate)",
  () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it("(a) consent + card on file → 200, draft activated + premium_connection_addons incremented", async () => {
      currentStripeMock = makeCardOnFileStripe();

      let status = 0;
      let addons: number | undefined;
      let draft: boolean | undefined;

      await withActivateDraftScenario({
        stripeCustomerId: "cus_activate_card",
        test: async ({ userId, draftId, trx }) => {
          const app = makeApp(trx, userId);
          const res = await postActivate(app, draftId, {
            name: "LinkedIn",
            syncables: [{ provider: "linkedin", syncableId: "ch-activate" }],
            consentAddon: true,
          });
          status = res.status;

          const sub = await trx
            .selectFrom("user_subscription")
            .select("premium_connection_addons")
            .where("user_id", "=", userId)
            .executeTakeFirst();
          addons = sub?.premium_connection_addons;

          const inst = await trx
            .selectFrom("twist_instance")
            .select("draft")
            .where("id", "=", draftId)
            .executeTakeFirst();
          draft = inst?.draft;
        },
      });

      expect(status).toBe(200);
      // Charged: add-on quantity provisioned to 1.
      expect(addons).toBe(1);
      // Activated: draft flipped to false (the gate let activateDraft proceed).
      expect(draft).toBe(false);
      expect(vi.mocked(createStripeClient)).toHaveBeenCalled();
    });

    it("(b) consent + no card → 402 { reason: needs_card, checkout_url }, not activated", async () => {
      currentStripeMock = makeNoCardStripe();

      let status = 0;
      let json: unknown;
      let draft: boolean | undefined;

      await withActivateDraftScenario({
        stripeCustomerId: "cus_activate_nocard",
        test: async ({ userId, draftId, trx }) => {
          const app = makeApp(trx, userId);
          const res = await postActivate(app, draftId, {
            name: "LinkedIn",
            syncables: [{ provider: "linkedin", syncableId: "ch-activate" }],
            consentAddon: true,
          });
          status = res.status;
          json = await res.json();

          const inst = await trx
            .selectFrom("twist_instance")
            .select("draft")
            .where("id", "=", draftId)
            .executeTakeFirst();
          draft = inst?.draft;
        },
      });

      expect(status).toBe(402);
      expect(json).toMatchObject({
        reason: "needs_card",
        checkout_url: expect.stringContaining("checkout.stripe.com"),
      });
      // Not charged through, so the draft must NOT have been activated.
      expect(draft).toBe(true);
    });

    it("(c) no consent (billable) → 403 addon_required, quantity unchanged + not activated", async () => {
      currentStripeMock = makeCardOnFileStripe(); // must not be used

      let status = 0;
      let json: any;
      let addons: number | undefined;
      let draft: boolean | undefined;

      await withActivateDraftScenario({
        stripeCustomerId: "cus_activate_no_consent",
        test: async ({ userId, draftId, trx }) => {
          const app = makeApp(trx, userId);
          // POST with no consentAddon flag (client forwards none).
          const res = await postActivate(app, draftId, {
            name: "LinkedIn",
            syncables: [{ provider: "linkedin", syncableId: "ch-activate" }],
          });
          status = res.status;
          json = await res.json();

          const sub = await trx
            .selectFrom("user_subscription")
            .select("premium_connection_addons")
            .where("user_id", "=", userId)
            .executeTakeFirst();
          addons = sub?.premium_connection_addons;

          const inst = await trx
            .selectFrom("twist_instance")
            .select("draft")
            .where("id", "=", draftId)
            .executeTakeFirst();
          draft = inst?.draft;
        },
      });

      expect(status).toBe(403);
      expect(json?.reason).toBe("addon_required");
      // No charge, no enable.
      expect(vi.mocked(createStripeClient)).not.toHaveBeenCalled();
      expect(addons).toBe(0);
      expect(draft).toBe(true);
    });

    it("(d) abandon (consentAddon explicitly false) → 403, quantity unchanged + not activated (no charge)", async () => {
      currentStripeMock = makeCardOnFileStripe(); // must not be used

      let status = 0;
      let addons: number | undefined;
      let draft: boolean | undefined;

      await withActivateDraftScenario({
        stripeCustomerId: "cus_activate_abandon",
        test: async ({ userId, draftId, trx }) => {
          const app = makeApp(trx, userId);
          // consentAddon=false (user dismissed the dialog).
          const res = await postActivate(app, draftId, {
            name: "LinkedIn",
            syncables: [{ provider: "linkedin", syncableId: "ch-activate" }],
            consentAddon: false,
          });
          status = res.status;

          const sub = await trx
            .selectFrom("user_subscription")
            .select("premium_connection_addons")
            .where("user_id", "=", userId)
            .executeTakeFirst();
          addons = sub?.premium_connection_addons;

          const inst = await trx
            .selectFrom("twist_instance")
            .select("draft")
            .where("id", "=", draftId)
            .executeTakeFirst();
          draft = inst?.draft;
        },
      });

      expect(status).toBe(403);
      expect(vi.mocked(createStripeClient)).not.toHaveBeenCalled();
      expect(addons).toBe(0);
      expect(draft).toBe(true);
    });
  }
);
