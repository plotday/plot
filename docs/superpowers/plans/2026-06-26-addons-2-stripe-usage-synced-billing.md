# Add-ons Plan 2 — Stripe usage-synced billing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bill connection add-ons as a standalone monthly Stripe subscription whose quantity tracks active add-on connections — purchased explicitly (Option A), reconciled down automatically on disable/remove — independent of the plan subscription.

**Architecture:** Add-ons live on their own Stripe subscription (`metadata.type = "addon"`), separate from the plan/free subscription every customer already has. A new `stripe_addon_subscription_id` column tracks it. The webhook routes add-on subscriptions to the credit count only (never the plan). A new billing module (`stripe/addons.ts`) creates/bumps/reconciles that subscription. A new `POST /upgrade/addons/purchase` endpoint provisions one credit (off-session charge if a card is on file, else a Checkout URL). The connection **enable** path is unchanged — it stays a pure entitlement gate (Plan 1); the client calls `purchase` then retries enable. **Disable/remove** auto-reconciles the quantity down (cancel at zero).

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Stripe SDK, Atlas migrations, Vitest. DB-backed tests use `$DATABASE_URL`; Stripe is exercised with `as unknown as Stripe.X` fakes / stub clients (see `stripe/stripe.test.ts`), not deep mocks.

## Global Constraints

- Add-on connectors are exactly `twist.premium = true`. Pricing unchanged: web `$5/mo` (`addon_monthly` Stripe price), Apple tiers untouched.
- The add-on Stripe subscription is **standalone and monthly**, `metadata.type = "addon"`, separate from the plan sub. Never put add-ons as a line item on the plan subscription (that was the old model).
- Charging is **explicit** (Option A): only `POST /upgrade/addons/purchase` charges. The enable endpoint never charges.
- Decreases stop billing **immediately** (prorated); removing the last add-on **cancels** the add-on subscription. `proration_behavior: "always_invoice"` (reuse `ADDON_PRORATION_BEHAVIOR`).
- Apple owns the count when an Apple add-on is active; the Stripe add-on webhook must not clobber an Apple-owned `premium_connection_addons`.
- Worktree: run DB commands/tests with `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres"` (ambient is stale). `@plotday/twister` is built so `pnpm lint` resolves. Commit after each task; every commit message ends with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Schema changes follow the repo workflow: edit `libs/db/schema/`, `pnpm gen-migration -- <name>`, `pnpm apply-migrations` (regens `libs/db/src/types.ts`), commit the regenerated types. Never edit migrations by hand.

## File structure

- `libs/db/schema/50-tables/20-user_subscription.sql`, `13-team_subscription.sql` — new `stripe_addon_subscription_id` column + index; fix stale `premium_connection_addons` comment.
- `libs/db/migrations/*` + `libs/db/src/types.ts` — generated.
- `workers/api/src/stripe/stripe.ts` — `handleSubscriptionUpdate` / `handleSubscriptionDeleted` add-on routing; new `isAddonSubscription` helper.
- `workers/api/src/stripe/addons.ts` (NEW) — billing module: `customerHasPaymentMethod`, `provisionAddonCredit`, `reconcileAddonQuantityDown`, `createAddonCheckoutSession`.
- `workers/api/src/app/upgrade.ts` — new `POST /upgrade/addons/purchase`. (Old `POST /upgrade/addons` left in place; Plan 4 removes it with the site stepper.)
- `workers/api/src/app/twist-integrations.ts` — down-reconcile after disable/remove of a premium connector.
- Tests: `stripe/stripe.test.ts`, `stripe/addons.test.ts` (NEW), `app/upgrade.test.ts`, `app/twist-integrations.test.ts` (or the existing integration test file).

---

### Task 1: Schema — `stripe_addon_subscription_id` column + migration

**Files:**
- Modify: `libs/db/schema/50-tables/20-user_subscription.sql`, `libs/db/schema/50-tables/13-team_subscription.sql`.
- Generate: `libs/db/migrations/<ts>_add_stripe_addon_subscription_id.sql`, `libs/db/migrations/atlas.sum`, `libs/db/src/types.ts`.

**Interfaces:**
- Produces: `user_subscription.stripe_addon_subscription_id` and `team_subscription.stripe_addon_subscription_id` (`text`, nullable, UNIQUE) — the standalone add-on Stripe subscription id per scope.

- [ ] **Step 1: Add the column to both schema files**

In `20-user_subscription.sql`, after the `"stripe_subscription_id" text UNIQUE,` line add:

```sql
    -- Standalone connection-add-on Stripe subscription (metadata.type='addon'),
    -- SEPARATE from the plan subscription above. Its monthly quantity = the
    -- number of active add-on connections; drives premium_connection_addons.
    "stripe_addon_subscription_id" text UNIQUE,
```

Add an index alongside the other stripe-subscription index:

```sql
CREATE INDEX idx_user_subscription_stripe_addon_subscription_id ON "public"."user_subscription" ("stripe_addon_subscription_id") WHERE "stripe_addon_subscription_id" IS NOT NULL;
```

In `13-team_subscription.sql`, after its `"stripe_subscription_id" text UNIQUE,` line add the same column comment + column, and the matching index (`idx_team_subscription_stripe_addon_subscription_id`).

Also correct the now-stale tail of the `premium_connection_addons` comment in BOTH files: replace "connection add-ons also count against the regular connection pool" / "also count against the team's regular pool (one slot each — they are no longer weighted)" with: "Connection add-ons are billed separately and do NOT count toward the connection pool."

- [ ] **Step 2: Generate the migration**

Run: `cd /Users/kris.braun/code/plot/.claude/worktrees/independent-usage-based-addons && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm gen-migration -- add_stripe_addon_subscription_id`
Expected: a new file under `libs/db/migrations/` adding both columns + indexes, and `atlas.sum` updated.

- [ ] **Step 3: Apply the migration (regens types)**

Run: `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm apply-migrations`
Expected: applies cleanly; `libs/db/src/types.ts` regenerated with `stripe_addon_subscription_id: string | null` on both `UserSubscription` and `TeamSubscription`.

- [ ] **Step 4: Verify schema/migration in sync + types compile**

Run: `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm diff-schema-migrations` → expect no differences.
Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm lint` → 0 errors.

- [ ] **Step 5: Commit**

```bash
git add libs/db/schema/50-tables/20-user_subscription.sql libs/db/schema/50-tables/13-team_subscription.sql libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): add stripe_addon_subscription_id to user/team subscription"
```

---

### Task 2: Webhook routing — add-on subscriptions update the credit count only

**Files:**
- Modify: `workers/api/src/stripe/stripe.ts` — add `isAddonSubscription`; branch in `handleSubscriptionUpdate` and `handleSubscriptionDeleted`.
- Test: `workers/api/src/stripe/stripe.test.ts`.

**Interfaces:**
- Consumes: `parseSubscriptionItemQuantities` (existing), `stripe_addon_subscription_id` (Task 1).
- Produces: `isAddonSubscription(sub: Stripe.Subscription): boolean` = `sub.metadata?.type === "addon"`. An add-on `customer.subscription.created/updated` sets `premium_connection_addons` (= the add-on item quantity) + `stripe_addon_subscription_id`, never touching plan/status; `customer.subscription.deleted` of the add-on sub zeroes the count + clears the id + trims.

- [ ] **Step 1: Write failing tests**

Add to `stripe/stripe.test.ts` (DB-gated like the existing handler tests). Build an add-on subscription fake and assert routing. Use the existing seeding style (insert a `user_subscription` row, call the handler with a fake `Stripe.Subscription`, read the row back).

```typescript
describe.skipIf(!DATABASE_URL)("handleSubscriptionUpdate — add-on subscription routing", () => {
  it("an addon subscription sets premium_connection_addons + id, leaves plan untouched", async () => {
    // seed user_subscription(plan='free', stripe_customer_id=cust, premium_connection_addons=0)
    // call handleSubscriptionUpdate with a fake sub:
    //   { id: "sub_addon1", customer: cust, status: "active",
    //     metadata: { type: "addon", user_id },
    //     items: { data: [{ quantity: 2, price: { lookup_key: "addon_monthly" } }] } }
    // assert row: premium_connection_addons === 2, stripe_addon_subscription_id === "sub_addon1",
    //   plan still 'free', stripe_subscription_id unchanged.
  });

  it("an addon subscription does NOT overwrite an Apple-owned add-on count", async () => {
    // seed row with apple_addon_original_transaction_id set + premium_connection_addons=3
    // call handler with the addon sub (quantity 1) → row stays premium_connection_addons=3.
  });
});

describe.skipIf(!DATABASE_URL)("handleSubscriptionDeleted — add-on subscription", () => {
  it("deleting the addon sub zeroes the count and clears the id", async () => {
    // seed row premium_connection_addons=2, stripe_addon_subscription_id="sub_addon1"
    // call handleSubscriptionDeleted with the addon sub (metadata.type='addon', id sub_addon1)
    // assert premium_connection_addons===0, stripe_addon_subscription_id===null, plan unchanged.
  });
});
```

(Match the file's existing `createDb`, seeding, and `Rollback`/cleanup conventions; pass `vi`-stubbed `Bindings`/Stripe where the handlers need them, exactly as the current `handleSubscriptionDeleted` guard test does.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test stripe -- -t "add-on subscription"`
Expected: FAIL — the handler currently treats every sub as a plan sub (would set plan from metadata / not write the addon id).

- [ ] **Step 3: Implement the routing**

In `stripe.ts`, add near `parseSubscriptionItemQuantities`:

```typescript
/** A standalone connection-add-on subscription (separate from the plan sub). */
export function isAddonSubscription(subscription: Stripe.Subscription): boolean {
  return subscription.metadata?.type === "addon";
}
```

At the TOP of `handleSubscriptionUpdate` (after retrieving `customerId`, before plan resolution), add:

```typescript
  if (isAddonSubscription(subscription)) {
    // Apple owns the count when an Apple add-on is active — don't clobber it.
    const { addonQuantity } = parseSubscriptionItemQuantities(subscription);
    const updated = await db
      .updateTable("user_subscription")
      .set({
        premium_connection_addons: addonQuantity,
        stripe_addon_subscription_id: subscription.id,
        updated_at: sql`now()`,
      })
      .where("stripe_customer_id", "=", customerId)
      .where("apple_addon_original_transaction_id", "is", null)
      .executeTakeFirst();
    if (Number(updated.numUpdatedRows) === 0) {
      await db
        .updateTable("team_subscription")
        .set({
          premium_connection_addons: addonQuantity,
          stripe_addon_subscription_id: subscription.id,
          updated_at: sql`now()`,
        })
        .where("stripe_customer_id", "=", customerId)
        .execute();
    }
    return; // never run the plan path for an add-on sub
  }
```

In `handleSubscriptionDeleted`, before the existing "list other active subs" logic, add:

```typescript
  if (isAddonSubscription(subscription)) {
    await db
      .updateTable("user_subscription")
      .set({ premium_connection_addons: 0, stripe_addon_subscription_id: null, updated_at: sql`now()` })
      .where("stripe_addon_subscription_id", "=", subscription.id)
      .execute();
    await db
      .updateTable("team_subscription")
      .set({ premium_connection_addons: 0, stripe_addon_subscription_id: null, updated_at: sql`now()` })
      .where("stripe_addon_subscription_id", "=", subscription.id)
      .execute();
    return; // do not revert the plan to free for an add-on sub deletion
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test stripe`
Expected: PASS (new add-on routing tests + existing stripe tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/stripe/stripe.ts workers/api/src/stripe/stripe.test.ts
git commit -m "feat(stripe): route standalone add-on subscriptions to the credit count only"
```

---

### Task 3: Billing module `stripe/addons.ts`

**Files:**
- Create: `workers/api/src/stripe/addons.ts`, `workers/api/src/stripe/addons.test.ts`.

**Interfaces:**
- Produces:
  - `customerHasPaymentMethod(stripe: Stripe, customerId: string): Promise<boolean>` — true if the customer has a default payment method or any saved card.
  - `provisionAddonCredit(args: { stripe: Stripe; customerId: string; addonSubscriptionId: string | null; scopeMetadata: Record<string,string> }): Promise<{ subscriptionId: string; quantity: number }>` — bump the existing add-on sub quantity by 1, or create a new monthly add-on sub at quantity 1 (off-session, `proration_behavior: "always_invoice"`, `metadata.type="addon"` + scope metadata). Returns the new id+quantity.
  - `reconcileAddonQuantityDown(args: { stripe: Stripe; addonSubscriptionId: string; activeCount: number }): Promise<{ canceled: boolean; quantity: number }>` — set the add-on item quantity to `activeCount`; if `activeCount === 0`, cancel the subscription. Never increases (down-only safety).
  - `createAddonCheckoutSession(args: { stripe: Stripe; customerId: string; siteRoot: string; scopeMetadata: Record<string,string> }): Promise<string>` — a `mode:"subscription"` Checkout session for `addon_monthly` qty 1, `subscription_data.metadata.type="addon"` + scope metadata; returns `session.url`.

- [ ] **Step 1: Write failing tests with a stub Stripe client**

Create `addons.test.ts`. Build a minimal stub Stripe whose methods are `vi.fn()` returning canned objects, and assert the orchestration. Example for the core decisions:

```typescript
import { describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";
import { provisionAddonCredit, reconcileAddonQuantityDown, customerHasPaymentMethod } from "./addons";

function stubStripe(over: Record<string, unknown> = {}) {
  return {
    customers: { retrieve: vi.fn().mockResolvedValue({ invoice_settings: { default_payment_method: "pm_1" } }) },
    paymentMethods: { list: vi.fn().mockResolvedValue({ data: [{ id: "pm_1" }] }) },
    prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon" }] }) },
    subscriptions: {
      create: vi.fn().mockResolvedValue({ id: "sub_new", items: { data: [{ id: "si_1", quantity: 1 }] } }),
      retrieve: vi.fn().mockResolvedValue({ id: "sub_x", items: { data: [{ id: "si_1", quantity: 1, price: { lookup_key: "addon_monthly" } }] } }),
      update: vi.fn().mockResolvedValue({ id: "sub_x", items: { data: [{ id: "si_1", quantity: 2 }] } }),
      cancel: vi.fn().mockResolvedValue({ id: "sub_x", status: "canceled" }),
    },
    ...over,
  } as unknown as Stripe;
}

it("customerHasPaymentMethod true when a default PM exists", async () => {
  expect(await customerHasPaymentMethod(stubStripe(), "cus_1")).toBe(true);
});

it("provisionAddonCredit creates a monthly add-on sub at qty 1 when none exists", async () => {
  const s = stubStripe();
  const r = await provisionAddonCredit({ stripe: s, customerId: "cus_1", addonSubscriptionId: null, scopeMetadata: { user_id: "u1" } });
  expect(r).toEqual({ subscriptionId: "sub_new", quantity: 1 });
  expect((s.subscriptions.create as any)).toHaveBeenCalledWith(expect.objectContaining({
    customer: "cus_1",
    metadata: expect.objectContaining({ type: "addon", user_id: "u1" }),
    proration_behavior: "always_invoice",
  }));
});

it("provisionAddonCredit bumps an existing add-on sub by 1", async () => {
  const s = stubStripe();
  const r = await provisionAddonCredit({ stripe: s, customerId: "cus_1", addonSubscriptionId: "sub_x", scopeMetadata: { user_id: "u1" } });
  expect(r.quantity).toBe(2);
  expect((s.subscriptions.update as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({
    items: [{ id: "si_1", quantity: 2 }], proration_behavior: "always_invoice",
  }));
});

it("reconcileAddonQuantityDown cancels the sub at activeCount 0", async () => {
  const s = stubStripe();
  const r = await reconcileAddonQuantityDown({ stripe: s, addonSubscriptionId: "sub_x", activeCount: 0 });
  expect(r).toEqual({ canceled: true, quantity: 0 });
  expect((s.subscriptions.cancel as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({ prorate: true }));
});

it("reconcileAddonQuantityDown sets quantity to activeCount when > 0", async () => {
  const s = stubStripe();
  const r = await reconcileAddonQuantityDown({ stripe: s, addonSubscriptionId: "sub_x", activeCount: 1 });
  expect(r).toEqual({ canceled: false, quantity: 1 });
  expect((s.subscriptions.update as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({
    items: [{ id: "si_1", quantity: 1 }],
  }));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test addons`
Expected: FAIL — `./addons` does not exist.

- [ ] **Step 3: Implement `addons.ts`**

```typescript
import type Stripe from "stripe";

const ADDON_LOOKUP_KEY = "addon_monthly";
const ADDON_PRORATION = "always_invoice" as const;

export async function customerHasPaymentMethod(stripe: Stripe, customerId: string): Promise<boolean> {
  const customer = await stripe.customers.retrieve(customerId);
  if (!customer.deleted && customer.invoice_settings?.default_payment_method) return true;
  const pms = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
  return pms.data.length > 0;
}

async function addonPriceId(stripe: Stripe): Promise<string> {
  const prices = await stripe.prices.list({ lookup_keys: [ADDON_LOOKUP_KEY], limit: 1 });
  if (prices.data.length === 0) throw new Error("addon_monthly price not configured");
  return prices.data[0].id;
}

export async function provisionAddonCredit(args: {
  stripe: Stripe; customerId: string; addonSubscriptionId: string | null;
  scopeMetadata: Record<string, string>;
}): Promise<{ subscriptionId: string; quantity: number }> {
  const { stripe, customerId, addonSubscriptionId, scopeMetadata } = args;
  if (addonSubscriptionId) {
    const sub = await stripe.subscriptions.retrieve(addonSubscriptionId);
    const item = sub.items.data[0];
    const quantity = (item.quantity ?? 1) + 1;
    await stripe.subscriptions.update(addonSubscriptionId, {
      items: [{ id: item.id, quantity }],
      proration_behavior: ADDON_PRORATION,
    });
    return { subscriptionId: addonSubscriptionId, quantity };
  }
  const price = await addonPriceId(stripe);
  const sub = await stripe.subscriptions.create({
    customer: customerId,
    items: [{ price, quantity: 1 }],
    proration_behavior: ADDON_PRORATION,
    metadata: { type: "addon", ...scopeMetadata },
  });
  return { subscriptionId: sub.id, quantity: 1 };
}

export async function reconcileAddonQuantityDown(args: {
  stripe: Stripe; addonSubscriptionId: string; activeCount: number;
}): Promise<{ canceled: boolean; quantity: number }> {
  const { stripe, addonSubscriptionId, activeCount } = args;
  if (activeCount <= 0) {
    await stripe.subscriptions.cancel(addonSubscriptionId, { prorate: true });
    return { canceled: true, quantity: 0 };
  }
  const sub = await stripe.subscriptions.retrieve(addonSubscriptionId);
  const item = sub.items.data[0];
  await stripe.subscriptions.update(addonSubscriptionId, {
    items: [{ id: item.id, quantity: activeCount }],
    proration_behavior: ADDON_PRORATION,
  });
  return { canceled: false, quantity: activeCount };
}

export async function createAddonCheckoutSession(args: {
  stripe: Stripe; customerId: string; siteRoot: string; scopeMetadata: Record<string, string>;
}): Promise<string> {
  const { stripe, customerId, siteRoot, scopeMetadata } = args;
  const price = await addonPriceId(stripe);
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    line_items: [{ price, quantity: 1 }],
    mode: "subscription",
    success_url: `${siteRoot}/upgrade?addon=success`,
    cancel_url: `${siteRoot}/upgrade?addon=canceled`,
    subscription_data: { metadata: { type: "addon", ...scopeMetadata } },
  });
  if (!session.url) throw new Error("Checkout session has no url");
  return session.url;
}
```

(If `pnpm lint` flags `customer.invoice_settings` as possibly-deleted, narrow with the `!customer.deleted` guard already present, or `@ts-ignore` with a one-line comment per the repo convention.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test addons` → PASS.
Run: `pnpm lint` → 0 errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/stripe/addons.ts workers/api/src/stripe/addons.test.ts
git commit -m "feat(stripe): add-on billing module (provision/reconcile/checkout)"
```

---

### Task 4: `POST /upgrade/addons/purchase` endpoint

**Files:**
- Modify: `workers/api/src/app/upgrade.ts` — add the route (personal + team).
- Test: `workers/api/src/app/upgrade.test.ts`.

**Interfaces:**
- Consumes: `customerHasPaymentMethod`, `provisionAddonCredit`, `createAddonCheckoutSession` (Task 3); `stripe_addon_subscription_id` (Task 1).
- Produces: `POST /upgrade/addons/purchase` with optional `{ teamId?: string }` body. Returns `{ ok: true, addons: number }` when charged off-session, or `{ ok: false, checkout_url: string }` when a card must be captured first.

- [ ] **Step 1: Write failing tests**

Follow `upgrade.test.ts`'s existing route-test harness (it builds the Hono app and injects a stubbed Stripe via `createStripeClient`). Two cases:

```typescript
it("purchase with a card on file provisions a credit (ok:true)", async () => {
  // stub Stripe: customer has default PM; subscriptions.create → sub_new qty 1
  // seed user_subscription(stripe_customer_id, stripe_addon_subscription_id=null)
  // POST /upgrade/addons/purchase → { ok: true, addons: 1 }; row.stripe_addon_subscription_id set
});

it("purchase with no card returns a checkout_url (ok:false)", async () => {
  // stub Stripe: no default PM, paymentMethods.list → []; checkout.sessions.create → { url }
  // POST /upgrade/addons/purchase → { ok: false, checkout_url: "https://..." }
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test upgrade -- -t "purchase"` → FAIL (route 404).

- [ ] **Step 3: Implement the route**

Add to `upgrade.ts` (mirror the `/upgrade/addons` scope-resolution: personal `user_subscription`, or team after an admin check). Pseudocode-faithful implementation:

```typescript
upgrade.post("/upgrade/addons/purchase", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ teamId?: string }>().catch(() => ({}));
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);

  // Resolve scope row (customer id + current add-on sub id). Team requires admin.
  const isTeam = !!body.teamId;
  const row = isTeam
    ? await c.var.db.selectFrom("team_subscription").select(["stripe_customer_id", "stripe_addon_subscription_id"]).where("team_id", "=", body.teamId!).executeTakeFirst()
    : await c.var.db.selectFrom("user_subscription").select(["stripe_customer_id", "stripe_addon_subscription_id"]).where("user_id", "=", user.id).executeTakeFirst();
  if (isTeam) { /* assert admin via isTeamAdmin; 403 if not */ }
  if (!row?.stripe_customer_id) return c.json({ error: "No billing account found" }, 400);

  const scopeMetadata = isTeam ? { team_id: body.teamId! } : { user_id: user.id };

  if (await customerHasPaymentMethod(stripe, row.stripe_customer_id)) {
    const { subscriptionId, quantity } = await provisionAddonCredit({
      stripe, customerId: row.stripe_customer_id,
      addonSubscriptionId: row.stripe_addon_subscription_id, scopeMetadata,
    });
    // Reflect immediately; the webhook re-syncs the same values.
    const table = isTeam ? "team_subscription" : "user_subscription";
    const idCol = isTeam ? "team_id" : "user_id";
    const idVal = isTeam ? body.teamId! : user.id;
    await c.var.db.updateTable(table as any).set({
      premium_connection_addons: quantity, stripe_addon_subscription_id: subscriptionId,
    }).where(idCol as any, "=", idVal).execute();
    return c.json({ ok: true, addons: quantity });
  }

  const url = await createAddonCheckoutSession({
    stripe, customerId: row.stripe_customer_id, siteRoot: c.env.SITE_ROOT ?? Env.siteRoot, scopeMetadata,
  });
  return c.json({ ok: false, checkout_url: url });
});
```

(Use the file's actual `createStripeClient`, site-root binding, and `isTeamAdmin` import — match how `/upgrade/addons` does these. Wrap DB writes per the repo's `safeQuery`/await conventions.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test upgrade` → PASS. `pnpm lint` → 0 errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/upgrade.ts workers/api/src/app/upgrade.test.ts
git commit -m "feat(api): POST /upgrade/addons/purchase — provision one add-on credit"
```

---

### Task 5: Down-reconcile on disable/remove of a premium connector

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts` — after a premium connector's channel is disabled (single + batch disable endpoints) and after `removeAuth`/account removal, reconcile the add-on quantity down.
- Test: the existing integration test file for that route (or `app/twist-integrations.test.ts`).

**Interfaces:**
- Consumes: `reconcileAddonQuantityDown` (Task 3), `getPersonalPremiumConnectionCount` / team equivalent (limits.ts), `stripe_addon_subscription_id` (Task 1).
- Produces: after a premium connection is disabled/removed for a Stripe-billed scope, the add-on subscription quantity is set to the new active premium count (canceled at 0).

- [ ] **Step 1: Write a failing integration test**

Seed a personal scope with a Stripe add-on sub (`stripe_addon_subscription_id`, `premium_connection_addons=1`) and one enabled premium connection; stub Stripe. Hit the disable endpoint for that connector; assert `reconcileAddonQuantityDown` was driven with `activeCount = 0` (sub canceled) and the row's `premium_connection_addons` becomes 0. Follow the route-test harness used by the other `twist-integrations` tests.

- [ ] **Step 2: Run to verify it fails**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test twist-integrations -- -t "reconcile"` → FAIL.

- [ ] **Step 3: Implement the hook**

Add a small helper in `twist-integrations.ts` (or import one) that, given the user/team scope after a disable/remove:
- looks up the scope's `stripe_addon_subscription_id`; if null → no-op (Apple-billed or no add-ons).
- counts active premium connections (`getPersonalPremiumConnectionCount(db, userId)` / `getTeamPremiumConnectionCount(db, teamId)`).
- calls `reconcileAddonQuantityDown({ stripe, addonSubscriptionId, activeCount })`.
- writes `premium_connection_addons = activeCount` (and clears `stripe_addon_subscription_id` when canceled) to the row.

Call it after the `disableSync` callback returns in the single disable endpoint (after twist-integrations.ts:1164), in the batch endpoint's disable loop completion, and after the `removeAuth` callback in the `DELETE /twist/:id/integrations/:provider/:actorId` handler — but ONLY when the affected connector is `twist.premium = true`. Run it via `c.executionCtx.waitUntil(...)` with a freshly-created `db` + Stripe client (do NOT use the request-scoped `c.var.db` inside `waitUntil` — see AGENTS.md), capturing `userId`/`teamId`/`twistInstanceId` into locals first.

- [ ] **Step 4: Run to verify it passes**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" pnpm test twist-integrations` → PASS. `pnpm lint` → 0 errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/twist-integrations.ts workers/api/src/app/twist-integrations.test.ts
git commit -m "feat(api): reconcile add-on billing down when a premium connection is disabled/removed"
```

---

## Self-Review

**Spec coverage (Plan 2 slice):** standalone add-on subscription + `stripe_addon_subscription_id` (T1); webhook routes add-on subs to the count only, Apple-guarded (T2); billing module create/bump/reconcile/checkout (T3); explicit purchase endpoint, off-session-or-Checkout (T4, Option A); auto down-reconcile on disable/remove (T5). The enable path is intentionally unchanged (Option A — the client calls purchase then retries enable; the existing 403 `addon_required` is the trigger). The old `POST /upgrade/addons` (line-item-on-plan-sub) is intentionally left for Plan 4 to remove with the site stepper, since nothing deploys mid-feature.

**Deferred to later plans:** Flutter confirm/purchase/checkout orchestration + retrying enable (Plan 3); removing the site stepper + old endpoint, pricing copy/footnote (Plan 4). The up-direction reconcile is via the explicit purchase endpoint, not the enable path.

**Placeholder note:** Tasks 4–5 give faithful pseudocode plus the exact interfaces, helper names, and harness to follow, because the precise Hono route/test-harness wiring must match the patterns already in `upgrade.ts` / `twist-integrations.ts` (the implementer reads those). All pure logic (T2 routing, T3 module) is complete verbatim code. If an implementer finds the harness diverges, it should follow the existing file's pattern over the pseudocode and note it.

**Type consistency:** `provisionAddonCredit` returns `{ subscriptionId, quantity }` (used by T4); `reconcileAddonQuantityDown` returns `{ canceled, quantity }` (used by T5); `isAddonSubscription` / `customerHasPaymentMethod` / `createAddonCheckoutSession` signatures are referenced consistently across T2–T5.
