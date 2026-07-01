# Coupon-or-card Add-ons with Period-Reconciled Credits — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a no-card (e.g. 100%-off coupon) user add a premium connection add-on via a Checkout that accepts a coupon OR a card, charge once at confirm (idempotently), and reconcile unused credits down at each billing period.

**Architecture:** Move the add-on charge to the existing `POST /upgrade/addons/purchase` endpoint (called by the client at confirm), make that purchase idempotent by reusing an unused credit (`premium_connection_addons > getBillableConnectionAddonCount`), and switch the no-card branch to a `mode: subscription` Stripe Checkout with `allow_promotion_codes: true`. Replace the three immediate disable-time reconciles with a single period-boundary reconcile cron. The enable path is unchanged: with a credit pre-bought, `checkChannelConnectionLimit` already returns `allowed` and no second charge occurs.

**Tech Stack:** Cloudflare Workers (Hono, TypeScript, Kysely, vitest, real local Postgres for tests), Stripe SDK, Flutter (Dart, Bloc, forui).

## Global Constraints

- **Worktree + DB:** Do schema-free billing work in an isolated worktree if concurrent agents are active. No schema changes in this plan (`premium_connection_addons`, `stripe_addon_subscription_id` already exist). Server tests need `$DATABASE_URL` pointing at the worktree DB — verify with `psql "$DATABASE_URL" -tAc "show port;"` before running.
- **Twister build:** No `public/` submodule changes in this plan.
- **Error capture:** Every new `catch` for an unexpected error calls `tracker.captureException(e)` (server) / `Tracker.captureException(e, st)` (Flutter). Do NOT capture expected errors.
- **DB rule:** Never fire-and-forget Kysely; always `await` and let errors propagate or handle explicitly. Use `withDb(env, ...)` for background/cron DB access (request-scoped `c.var.db` is destroyed after the response).
- **Backward compatibility:** The no-card server response stays `402` with `reason: "needs_card"` and a `checkout_url` field. Do NOT rename or remove `checkout_url`. Old Flutter clients (which only open `checkout_url` on `needs_card`) must keep working.
- **Flutter analyze:** Run `cd apps/plot && flutter pub run build_runner build` before `flutter analyze` in a worktree (Drift codegen), or `twist.dart` shows false generated-symbol errors.
- **UI text:** sentence case. **forui only** (`forui/forui.dart` + `flutter/widgets.dart`; never `flutter/material.dart`). Modals via the project `Modal`/`ConfirmModal` framework.

## Key existing symbols (verified 2026-06-30)

- `getBillableConnectionAddonCount(db, scope)` — `workers/api/src/utils/limits.ts:235`. `scope: {userId}|{teamId}`. Returns CURRENTLY-enabled billable add-on connections (team: premium count; personal: over-pool + premium). This is "active".
- `purchaseAddonCreditForScope(args)` — `workers/api/src/app/upgrade.ts:877`. Returns `{ok:true,addons}|{ok:false,checkout_url}`. **Not yet idempotent** (always bumps).
- `purchaseTwistAddonBlocksForScope(args)` — `workers/api/src/app/upgrade.ts:1107`. **Reference implementation for idempotency** (short-circuits `{ok:true,...}` when enough blocks purchased).
- `POST /upgrade/addons/purchase` handler — `workers/api/src/app/upgrade.ts:1027`.
- `provisionAddonForConsentedEnable(args)` — `workers/api/src/app/upgrade.ts:954`. Enable-gate charge helper; no-card branch uses `createAddonCardSetupSession` (card-only).
- `createAddonCheckoutSession(args)` — `workers/api/src/stripe/addons.ts:122` (`mode:"subscription"`; **no** `allow_promotion_codes`).
- `createAddonCardSetupSession(args)` — `workers/api/src/stripe/addons.ts:107` (`mode:"setup"`, card-only).
- `reconcileScopeAddonBillingDown({db,stripe,scope})` — `workers/api/src/app/twist-integrations.ts:306`. Down-only; no-ops without an addon sub; uses `getBillableConnectionAddonCount`.
- `reconcileAddonQuantityDown({stripe,addonSubscriptionId,activeCount})` — `workers/api/src/stripe/addons.ts:61`. Cancels at `activeCount<=0`.
- Immediate disable reconciles to remove — `twist-integrations.ts:1461` (disable), `:1678` (batch-disable), `:2072` (removeAuth).
- `scheduled()` — `workers/api/src/index.ts:286`. Cron dispatch; add a new `try`/`withDb` block.
- `UpgradeApi.purchaseAddon({teamId})` — `apps/plot/lib/api/upgrade_api.dart:348`. Returns `AddonPurchase(ok, addons, checkoutUrl)`. **Currently orphaned (no callers).**
- `BuyAddonCommand._consent(context)` — `apps/plot/lib/command/upgrade.dart:211`. Web/team confirm point; returns `CommandAddonConsented`.
- `CommandAddonConsented` — `apps/plot/lib/command/base.dart:42`.

---

## Task 1: Add `allow_promotion_codes` to the connection add-on Checkout

**Files:**
- Modify: `workers/api/src/stripe/addons.ts:122-138` (`createAddonCheckoutSession`)
- Test: `workers/api/src/stripe/addons.test.ts` (create if absent)

**Interfaces:**
- Consumes: nothing new.
- Produces: `createAddonCheckoutSession` still returns `Promise<string>`; the created session now has `allow_promotion_codes: true`.

- [ ] **Step 1: Write the failing test**

Create/extend `workers/api/src/stripe/addons.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { createAddonCheckoutSession, CONNECTION_ADDON } from "./addons";

describe("createAddonCheckoutSession", () => {
  it("allows promotion codes so coupon-only customers can apply a coupon", async () => {
    const create = vi.fn().mockResolvedValue({ url: "https://checkout.test/cs_1" });
    const stripe = {
      prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon" }] }) },
      checkout: { sessions: { create } },
    } as any;

    const url = await createAddonCheckoutSession({
      kind: CONNECTION_ADDON,
      stripe,
      customerId: "cus_1",
      siteRoot: "https://plot.day",
      scopeMetadata: { user_id: "u1" },
    });

    expect(url).toBe("https://checkout.test/cs_1");
    expect(create).toHaveBeenCalledTimes(1);
    expect(create.mock.calls[0][0]).toMatchObject({
      mode: "subscription",
      allow_promotion_codes: true,
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && npx vitest run src/stripe/addons.test.ts`
Expected: FAIL — `allow_promotion_codes` is not present in the create call args.

- [ ] **Step 3: Implement**

In `workers/api/src/stripe/addons.ts`, inside `createAddonCheckoutSession`, add the flag to the `sessions.create` object (after `mode: "subscription"`):

```ts
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    line_items: [{ price, quantity: 1 }],
    mode: "subscription",
    allow_promotion_codes: true,
    success_url: `${siteRoot}/upgrade?${param}=success`,
    cancel_url: `${siteRoot}/upgrade?${param}=canceled`,
    subscription_data: { metadata: { type: kind.metadataType, ...scopeMetadata } },
  });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd workers/api && npx vitest run src/stripe/addons.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/stripe/addons.ts workers/api/src/stripe/addons.test.ts
git commit -m "feat(api): allow promotion codes on connection add-on Checkout"
```

---

## Task 2: Make the add-on purchase idempotent + route no-card to the coupon Checkout

Charge once at confirm: if the scope already has an unused credit (`premium_connection_addons > active`), return `{ok:true}` without touching Stripe. Also switch the enable-gate's no-card branch to the same coupon Checkout so coupons work on every path.

**Files:**
- Modify: `workers/api/src/app/upgrade.ts` — `purchaseAddonCreditForScope` (877), the `/upgrade/addons/purchase` handler (1027), and `provisionAddonForConsentedEnable` (954).
- Test: `workers/api/src/app/upgrade.test.ts`

**Interfaces:**
- Consumes: `getBillableConnectionAddonCount` (limits.ts:235); `createAddonCheckoutSession` (Task 1).
- Produces: `purchaseAddonCreditForScope` gains two params — `scope: {userId}|{teamId}` and `currentAddons: number` — and returns `{ok:true,addons}` with NO Stripe call when `currentAddons > active`. Return shape unchanged otherwise.

- [ ] **Step 1: Write the failing tests**

Add to `workers/api/src/app/upgrade.test.ts`:

```ts
import { purchaseAddonCreditForScope } from "./upgrade";
import * as limits from "../utils/limits";

describe("purchaseAddonCreditForScope idempotency", () => {
  it("reuses an unused credit without charging when purchased > active", async () => {
    vi.spyOn(limits, "getBillableConnectionAddonCount").mockResolvedValue(0);
    const stripe = {
      customers: { retrieve: vi.fn() },
      subscriptions: { update: vi.fn(), create: vi.fn(), retrieve: vi.fn() },
      checkout: { sessions: { create: vi.fn() } },
      paymentMethods: { list: vi.fn() },
    } as any;

    const res = await purchaseAddonCreditForScope({
      stripe,
      db: {} as any,
      customerId: "cus_1",
      addonSubscriptionId: "sub_addon_1",
      currentAddons: 1, // one purchased, zero active → unused credit
      scope: { userId: "u1" },
      scopeMetadata: { user_id: "u1" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "u1",
      captureException: () => {},
    });

    expect(res).toEqual({ ok: true, addons: 1 });
    expect(stripe.subscriptions.update).not.toHaveBeenCalled();
    expect(stripe.subscriptions.create).not.toHaveBeenCalled();
    expect(stripe.checkout.sessions.create).not.toHaveBeenCalled();
  });

  it("returns a coupon-capable checkout_url when a new credit is needed and no card is on file", async () => {
    vi.spyOn(limits, "getBillableConnectionAddonCount").mockResolvedValue(1);
    const sessionCreate = vi
      .fn()
      .mockResolvedValue({ url: "https://checkout.test/cs_coupon" });
    const stripe = {
      customers: { retrieve: vi.fn().mockResolvedValue({ deleted: false, invoice_settings: {} }) },
      paymentMethods: { list: vi.fn().mockResolvedValue({ data: [] }) },
      prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon" }] }) },
      subscriptions: { update: vi.fn(), create: vi.fn() },
      checkout: { sessions: { create: sessionCreate } },
    } as any;

    const res = await purchaseAddonCreditForScope({
      stripe,
      db: {} as any,
      customerId: "cus_1",
      addonSubscriptionId: null,
      currentAddons: 1, // one purchased, one active → need a new credit
      scope: { userId: "u1" },
      scopeMetadata: { user_id: "u1" },
      siteRoot: "https://plot.day",
      table: "user_subscription",
      idVal: "u1",
      captureException: () => {},
    });

    expect(res).toEqual({ ok: false, checkout_url: "https://checkout.test/cs_coupon" });
    expect(sessionCreate.mock.calls[0][0]).toMatchObject({
      mode: "subscription",
      allow_promotion_codes: true,
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd workers/api && npx vitest run src/app/upgrade.test.ts -t "idempotency"`
Expected: FAIL — `purchaseAddonCreditForScope` does not accept `scope`/`currentAddons` and always calls Stripe.

- [ ] **Step 3: Implement idempotency in `purchaseAddonCreditForScope`**

In `workers/api/src/app/upgrade.ts`, update the signature and add the short-circuit at the top of the body (mirrors `purchaseTwistAddonBlocksForScope`). Import the count helper at the top of the file if not already imported: `import { getBillableConnectionAddonCount } from "../utils/limits";`

```ts
export async function purchaseAddonCreditForScope(args: {
  stripe: Stripe;
  db: Kysely<DB>;
  customerId: string;
  addonSubscriptionId: string | null;
  currentAddons: number;
  scope: { userId: string } | { teamId: string };
  scopeMetadata: Record<string, string>;
  siteRoot: string;
  table: "user_subscription" | "team_subscription";
  idVal: string;
  captureException: (e: unknown) => void;
}): Promise<{ ok: true; addons: number } | { ok: false; checkout_url: string }> {
  const {
    stripe, db, customerId, addonSubscriptionId, currentAddons, scope,
    scopeMetadata, siteRoot, table, idVal, captureException,
  } = args;

  // Idempotent: if the scope already has an unused credit (purchased > active),
  // reuse it — no Stripe call, no charge. Handles confirm→back-out→retry and
  // archive-one-add-another within a billing period.
  const active = await getBillableConnectionAddonCount(db, scope);
  if (currentAddons > active) {
    return { ok: true, addons: currentAddons };
  }

  if (await customerHasPaymentMethod(stripe, customerId)) {
    const { subscriptionId, quantity } = await provisionAddonCredit({
      stripe, customerId, addonSubscriptionId, scopeMetadata,
    });
    try {
      if (table === "team_subscription") {
        await db.updateTable("team_subscription")
          .set({ premium_connection_addons: quantity, stripe_addon_subscription_id: subscriptionId })
          .where("team_id", "=", idVal).execute();
      } else {
        await db.updateTable("user_subscription")
          .set({ premium_connection_addons: quantity, stripe_addon_subscription_id: subscriptionId })
          .where("user_id", "=", idVal).execute();
      }
    } catch (e) {
      captureException(e);
    }
    return { ok: true, addons: quantity };
  }

  const checkout_url = await createAddonCheckoutSession({
    stripe, customerId, siteRoot, scopeMetadata,
  });
  return { ok: false, checkout_url };
}
```

- [ ] **Step 4: Update the `/upgrade/addons/purchase` handler to pass `scope` + `currentAddons`**

In the handler (`upgrade.ts:1027`), select `premium_connection_addons` on the row query and pass the new params. The row select currently reads `["stripe_customer_id", "stripe_addon_subscription_id"]` — add `"premium_connection_addons"`. Then:

```ts
  const scope = isTeam ? { teamId: body.teamId! } : { userId: user.id };
  // ...inside the try, in the purchaseAddonCreditForScope(...) call, add:
        currentAddons: row.premium_connection_addons ?? 0,
        scope,
```

- [ ] **Step 5: Switch the enable-gate no-card branch to the coupon Checkout**

In `provisionAddonForConsentedEnable` (`upgrade.ts:954`), replace the final no-card branch so coupons work even when a client reaches the enable gate without pre-purchasing. Change:

```ts
  const checkout_url = await createAddonCardSetupSession({
    stripe, customerId, siteRoot, scopeMetadata,
  });
  return { ok: false, needsCard: true, checkout_url };
```

to:

```ts
  const checkout_url = await createAddonCheckoutSession({
    stripe, customerId, siteRoot, scopeMetadata,
  });
  return { ok: false, needsCard: true, checkout_url };
```

Remove the now-unused `createAddonCardSetupSession` import if no other caller remains (grep first: `grep -rn createAddonCardSetupSession workers/api/src`). If unreferenced, delete the function from `addons.ts` in this step.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd workers/api && npx vitest run src/app/upgrade.test.ts && npx tsc --noEmit -p .`
Expected: PASS; tsc clean. Fix any other `purchaseAddonCreditForScope` callers the compiler flags (add `scope`/`currentAddons`).

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/app/upgrade.ts workers/api/src/app/upgrade.test.ts workers/api/src/stripe/addons.ts
git commit -m "feat(api): idempotent add-on purchase + coupon Checkout on no-card path"
```

---

## Task 3: Client — confirm provisions the credit and advances (no more dead-end)

The web/team confirm point (`BuyAddonCommand._consent`) calls `UpgradeApi.purchaseAddon` at confirm. `ok` → return `CommandAddonConsented` (proceed to auth/enable, which finds the pre-bought credit). `checkoutUrl` → open the browser, toast, and return `CommandSkipped` (user pays, then reconnects). This makes both the pre-auth `_ConsentGate` path and the reactive `_offerAddonConsent` path do real provisioning instead of a silent refresh.

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart` — `BuyAddonCommand._consent` (211-231)
- Test: `cd apps/plot && flutter analyze` (no unit test harness for commands; behavior verified via analyze + manual run)

**Interfaces:**
- Consumes: `UpgradeApi.purchaseAddon({teamId})` → `AddonPurchase(ok, addons, checkoutUrl)` (`upgrade_api.dart:348`); `launchUrl` (already imported in `twist.dart`; add import to `upgrade.dart` if needed).
- Produces: `_consent` still returns `Future<CommandReturn>` — `CommandAddonConsented` on provisioned, `CommandSkipped` on checkout/abandon.

- [ ] **Step 1: Implement — call `purchaseAddon` at confirm**

Replace the body of `BuyAddonCommand._consent` (`upgrade.dart:211`) after the `ConfirmModal` confirmation:

```dart
  Future<CommandReturn> _consent(BuildContext context) async {
    final price =
        SubscriptionService.instance.usage?.connectionAddonPrice ?? 5;

    final confirmed = await ConfirmModal(
      title: 'Add a connection add-on',
      messageWidget: SubscriptionDisclosure(
        priceLine: 'Connection add-on — \$$price/month',
        note:
            "You'll be billed when the connection is added. Billed separately "
            "from your plan; it does not count toward your plan's connection "
            'limit.',
      ),
      confirmLabel: 'Add for \$$price/month',
      showCancel: false,
    ).run(context);
    if (!context.mounted || !confirmed) return const CommandSkipped();

    // Charge at confirm. The server is idempotent: an unused credit is reused
    // without a new charge. No card on file → a coupon-or-card Checkout URL.
    try {
      final result = await UpgradeApi.purchaseAddon(teamId: teamId);
      final url = result.checkoutUrl;
      if (!result.ok && url != null) {
        try {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        } catch (err, st) {
          log.warning('Failed to open add-on checkout', err, st);
        }
        if (context.mounted) {
          context.showToast(
            message:
                'Add a payment method or coupon in your browser, then connect '
                'again.',
          );
        }
        return const CommandSkipped();
      }
      // Provisioned (or already had an unused credit) — proceed to connect.
      return const CommandAddonConsented();
    } catch (e, st) {
      Tracker.captureException(e, st);
      if (context.mounted) {
        context.showToast(
          message: 'Could not add the connection add-on. Please try again.',
          isError: true,
        );
      }
      return const CommandSkipped();
    }
  }
```

Add any missing imports at the top of `upgrade.dart`: `import 'package:url_launcher/url_launcher.dart';` and the `Tracker` import (match the path used in `twist.dart`). Verify `log` is available in this file (it is used elsewhere in the command layer; add the logger import if absent).

- [ ] **Step 2: Verify the consent gate no longer dead-ends**

`_ConsentGate.run` (`command/twist.dart:1037`) already maps `CommandAddonConsented` → record consent + `CommandRefresh()`. With Task 3, that only happens AFTER the credit is provisioned, so the refreshed form's auth CTA leads to an enable that finds the credit. No code change needed there, but re-read it to confirm the mapping still holds. Same for `_offerAddonConsent` (`twist.dart:981`).

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter pub run build_runner build && flutter analyze lib/command/upgrade.dart lib/command/twist.dart`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart
git commit -m "feat(app): provision add-on credit at confirm; open coupon-or-card checkout when no card"
```

---

## Task 4: Period-reconcile cron — cancel unused credits at the billing boundary

**Files:**
- Create: `workers/api/src/stripe/addon-period-reconcile.ts`
- Modify: `workers/api/src/index.ts:286` (`scheduled()`)
- Test: `workers/api/src/stripe/addon-period-reconcile.test.ts`

**Interfaces:**
- Consumes: `reconcileScopeAddonBillingDown` (twist-integrations.ts:306); Stripe `subscriptions.retrieve`.
- Produces: `reconcileAddonsAtPeriodEnd({db, stripe, nowMs, windowMs})` — for every scope with a `stripe_addon_subscription_id` whose Stripe sub `current_period_end` is within `[nowMs, nowMs+windowMs]`, calls `reconcileScopeAddonBillingDown`. Returns `{ reconciled: number }`.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/stripe/addon-period-reconcile.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { reconcileAddonsAtPeriodEnd } from "./addon-period-reconcile";
import * as ti from "../app/twist-integrations";

function mockDb(userSubs: any[], teamSubs: any[]) {
  return {
    selectFrom: (t: string) => ({
      select: () => ({
        where: () => ({
          execute: async () => (t === "user_subscription" ? userSubs : teamSubs),
        }),
      }),
    }),
  } as any;
}

describe("reconcileAddonsAtPeriodEnd", () => {
  it("reconciles only subs whose period ends within the window", async () => {
    const now = 1_000_000_000_000;
    const spy = vi
      .spyOn(ti, "reconcileScopeAddonBillingDown")
      .mockResolvedValue(undefined);
    const db = mockDb(
      [
        { user_id: "u_soon", stripe_addon_subscription_id: "sub_soon" },
        { user_id: "u_later", stripe_addon_subscription_id: "sub_later" },
      ],
      []
    );
    const stripe = {
      subscriptions: {
        retrieve: vi.fn(async (id: string) => ({
          current_period_end:
            id === "sub_soon"
              ? Math.floor((now + 60 * 60 * 1000) / 1000) // +1h
              : Math.floor((now + 5 * 24 * 60 * 60 * 1000) / 1000), // +5d
        })),
      },
    } as any;

    const res = await reconcileAddonsAtPeriodEnd({
      db, stripe, nowMs: now, windowMs: 24 * 60 * 60 * 1000,
    });

    expect(res.reconciled).toBe(1);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({ scope: { userId: "u_soon" } })
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && npx vitest run src/stripe/addon-period-reconcile.test.ts`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement**

Create `workers/api/src/stripe/addon-period-reconcile.ts`:

```ts
import type Stripe from "stripe";
import type { Kysely } from "kysely";
import type { DB } from "@plotday/db";
import { reconcileScopeAddonBillingDown } from "../app/twist-integrations";

/**
 * Period-boundary reconcile: for every scope with an add-on subscription whose
 * Stripe billing period ends within [nowMs, nowMs+windowMs], set the add-on
 * quantity down to the scope's currently-active billable add-on connections
 * (canceling at zero). Down-only — never charges without consent. Keeps unused
 * credits reusable WITHIN a period; drops them at the boundary.
 */
export async function reconcileAddonsAtPeriodEnd(args: {
  db: Kysely<DB>;
  stripe: Stripe;
  nowMs: number;
  windowMs: number;
}): Promise<{ reconciled: number }> {
  const { db, stripe, nowMs, windowMs } = args;

  const userSubs = await db
    .selectFrom("user_subscription")
    .select(["user_id", "stripe_addon_subscription_id"])
    .where("stripe_addon_subscription_id", "is not", null)
    .execute();
  const teamSubs = await db
    .selectFrom("team_subscription")
    .select(["team_id", "stripe_addon_subscription_id"])
    .where("stripe_addon_subscription_id", "is not", null)
    .execute();

  const targets: { subId: string; scope: { userId: string } | { teamId: string } }[] = [
    ...userSubs.map((r) => ({ subId: r.stripe_addon_subscription_id as string, scope: { userId: r.user_id } })),
    ...teamSubs.map((r) => ({ subId: r.stripe_addon_subscription_id as string, scope: { teamId: r.team_id } })),
  ];

  let reconciled = 0;
  for (const t of targets) {
    const sub = await stripe.subscriptions.retrieve(t.subId);
    const periodEndMs = (sub.current_period_end ?? 0) * 1000;
    if (periodEndMs < nowMs || periodEndMs > nowMs + windowMs) continue;
    await reconcileScopeAddonBillingDown({ db, stripe, scope: t.scope });
    reconciled += 1;
  }
  return { reconciled };
}
```

- [ ] **Step 4: Wire into `scheduled()`**

In `workers/api/src/index.ts`, add a new `try` block inside `scheduled()` (after an existing one). The cron runs every 5 min; gate to run near the top of each hour so it isn't run 12×/hour, and use a 65-minute window so each period end is covered at least once:

```ts
  // Add-on period-boundary reconcile: drop unused connection add-on credits at
  // each billing period end (down-only). Runs hourly.
  try {
    if (event.cron && new Date(event.scheduledTime).getMinutes() < 5) {
      const { createStripeClient } = await import("./stripe/stripe");
      const { reconcileAddonsAtPeriodEnd } = await import(
        "./stripe/addon-period-reconcile"
      );
      const stripe = createStripeClient(env.STRIPE_SECRET_KEY);
      await withDb(env, async (db) => {
        const res = await reconcileAddonsAtPeriodEnd({
          db, stripe, nowMs: Date.now(), windowMs: 65 * 60 * 1000,
        });
        if (res.reconciled > 0) {
          logger.info("Add-on period reconcile", { count: res.reconciled });
        }
      });
    }
  } catch (error) {
    logger.error("Error in add-on period reconcile", error as Error);
  }
```

Confirm the exact `createStripeClient` import path against `upgrade.ts` (it imports from `./stripe/stripe` there via `../stripe/stripe`). Use a static top-of-file import instead of the dynamic `import()` shown if it does not create a cycle (preferred per repo rule); the dynamic import is only a fallback if a cycle appears.

- [ ] **Step 5: Run tests + tsc**

Run: `cd workers/api && npx vitest run src/stripe/addon-period-reconcile.test.ts && npx tsc --noEmit -p .`
Expected: PASS; tsc clean.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/stripe/addon-period-reconcile.ts workers/api/src/stripe/addon-period-reconcile.test.ts workers/api/src/index.ts
git commit -m "feat(api): period-boundary reconcile of unused connection add-on credits"
```

---

## Task 5: Remove the immediate disable-time reconciles

Freed credits must stay purchased until the period reconcile so they are reusable (archive-one-add-another). Remove the three immediate `reconcileScopeAddonBillingDown` calls.

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts` — remove the `waitUntil` reconcile blocks at `:1461` (disable), `:1678` (batch-disable), `:2072` (removeAuth).
- Test: `workers/api/src/app/twist-integrations.test.ts` (adjust any test asserting immediate reconcile-on-disable)

**Interfaces:**
- Consumes: nothing new.
- Produces: no reconcile on disable/removeAuth. `reconcileScopeAddonBillingDown` remains exported (used by Task 4).

- [ ] **Step 1: Find affected tests**

Run: `cd workers/api && grep -rn "reconcileScopeAddonBillingDown\|reconcileAddonQuantityDown\|premium_connection_addons" src/app/twist-integrations.test.ts src/app/*.test.ts`
Note any test asserting disable/removeAuth reduces quantity — those must flip to "does NOT reconcile immediately."

- [ ] **Step 2: Write/adjust the failing test**

In `twist-integrations.test.ts`, add (or convert an existing disable-reconcile test to) an assertion that disabling a premium connection does NOT call the down-reconcile. If the existing suite mocks `reconcileScopeAddonBillingDown`, assert `not.toHaveBeenCalled()` after a disable. Example shape:

```ts
it("does not reconcile add-on billing down immediately on disable (period reconcile owns down-moves)", async () => {
  const spy = vi.spyOn(reconcileModule, "reconcileScopeAddonBillingDown");
  await disablePremiumChannelViaHandler(/* existing test helper */);
  expect(spy).not.toHaveBeenCalled();
});
```

If there is no existing helper to drive the handler, instead delete the obsolete "reconciles down on disable" test and rely on the removal + tsc/build; note the removal in the commit message.

- [ ] **Step 3: Run to verify it fails (if a new assertion was added)**

Run: `cd workers/api && npx vitest run src/app/twist-integrations.test.ts -t "does not reconcile"`
Expected: FAIL — the handler still calls reconcile on disable.

- [ ] **Step 4: Remove the three reconcile blocks**

At each site (`twist-integrations.ts:1461`, `:1678`, `:2072`), delete the `c.executionCtx.waitUntil(...)` (or equivalent background) block that opens a fresh db/stripe and calls `reconcileScopeAddonBillingDown({ ... })`, including its surrounding try/catch and any now-unused `bgDb`/`bgStripe` locals created solely for it. Leave the enable/disable state changes and unrelated logic intact. After removal, run `grep -n reconcileScopeAddonBillingDown src/app/twist-integrations.ts` — only the export/definition (306) should remain.

- [ ] **Step 5: Run tests + tsc**

Run: `cd workers/api && npx vitest run src/app/twist-integrations.test.ts && npx tsc --noEmit -p .`
Expected: PASS; tsc clean (fix unused-import lint for anything the removal orphaned).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/app/twist-integrations.ts workers/api/src/app/twist-integrations.test.ts
git commit -m "refactor(api): drop immediate disable-time add-on reconcile (period reconcile owns down-moves)"
```

---

## Task 6: Docs — user-facing update + features

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)
- Modify: `docs/features.md` (if a connection-add-on section exists)

**Interfaces:** none.

- [ ] **Step 1: Generate the update fragment**

Run: `pnpm updates:new "Apply a coupon to a connection add-on; adding one with no card no longer dead-ends"`

- [ ] **Step 2: Write the bullet**

Edit the generated fragment; under `### Connections` (create it above `### Fixes` if absent):

```markdown
### Connections

- You can now apply a coupon when adding a connection add-on, and adding one
  with no card on file takes you straight to checkout instead of stalling.
```

- [ ] **Step 3: Commit**

```bash
git add docs/updates.d/ docs/features.md
git commit -m "docs: note coupon-capable connection add-on checkout"
```

---

## Final verification (run after all tasks)

- [ ] `cd workers/api && npx vitest run && npx tsc --noEmit -p .` — all green.
- [ ] `cd apps/plot && flutter pub run build_runner build && flutter analyze` — clean.
- [ ] Manual (macOS dev build, Team scope on a 100%-off coupon, no card): add a premium connector → confirm → browser opens a Checkout that accepts a coupon → apply 100%-off coupon → return → connection connects free. Retry after backing out mid-flow → no second charge. Archive one add-on connection, add another within the period → no new charge.
- [ ] Run `/finalize`.

## Self-review notes (author)

- **Spec coverage:** §1 idempotent purchase → Task 2; §2 client-confirm advance → Task 3; §3 coupon Checkout → Tasks 1–2; §4 period reconcile → Task 4; §5 remove disable reconcile → Task 5; §6 compat/errors/docs → Tasks 2/3 (keep `needs_card`+`checkout_url`; captureException) and Task 6. All covered.
- **Type consistency:** `getBillableConnectionAddonCount(db, scope)` and `scope: {userId}|{teamId}` used identically in Tasks 2, 4, 5; `AddonPurchase(ok, addons, checkoutUrl)` matches `upgrade_api.dart`; `reconcileScopeAddonBillingDown({db,stripe,scope})` matches the existing signature.
- **Compat:** enable-gate response stays `402 needs_card`+`checkout_url` (only the session type behind the URL changes), so old clients keep working.
