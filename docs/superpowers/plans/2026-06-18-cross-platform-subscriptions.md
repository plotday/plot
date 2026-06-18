# Cross-platform subscriptions (StoreKit IAP + Stripe) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make StoreKit IAP a first-class purchase path alongside Stripe — trial/free users can buy Core/Pro on iOS/Mac, entitlements are honored across platforms, and exactly one billing source is active at a time (no double-billing).

**Architecture:** `user_subscription` is the unified entitlement row, tracking both `origin`s (`stripe` | `app_store`). On IAP purchase the server cancels the user's Stripe sub (trial or `free_monthly` tracker) and flips the row to `app_store`; when the Apple sub lapses the server recreates the `free_monthly` Stripe sub. The Stripe `customer.subscription.deleted` handler defers to an active `app_store` row so the cancel can't clobber the new entitlement. The Flutter client gates the upgrade/manage/restore entries off `(effectivePlan, origin, status)`.

**Tech Stack:** TypeScript Cloudflare Workers (Hono, Kysely, Stripe SDK, Apple StoreKit 2 JWS), Vitest; Flutter/Dart (forui, bloc), `in_app_purchase`.

## Global Constraints

- **No schema migration needed** — `user_subscription` already has `plan`, `status`, `origin`, `billing_cycle_*`, `trial_ends_at`, `stripe_customer_id`, `stripe_subscription_id`, `apple_original_transaction_id`, `apple_product_id`.
- **StoreKit products stay immediate-charge** — `introductoryOffer: null` for both Core (`day.plot.app.core_monthly`, $14.99) and Pro (`day.plot.app.pro_monthly`, $24.99); one subscription group (`21300000`). No `Plot.storekit` / App Store Connect changes.
- **One active billing source per user** — Stripe XOR Apple, never both.
- **Paid Stripe users get no IAP on iOS** — they manage on the web. Only `free` and Stripe-`trialing` users are convertible to IAP.
- **Never `DELETE` synced rows; never fire-and-forget DB calls** (`await` + let errors propagate / `captureException`). `user_subscription` is **not** Flutter-synced (read via REST), so server-side updates are fine.
- **Report unexpected errors** — new TS catch blocks call `tracker.captureException` (or `postHog.captureException`); new Dart catch blocks call `Tracker.captureException`.
- **UI text is sentence case.** Manage label is exactly **"Manage your subscription"**.
- **Worktree DB**: use `$DATABASE_URL`; if running integration tests, `bash scripts/worktree-db` first and verify `psql "$DATABASE_URL" -tAc "show port;"` is the worktree port, not 54322.
- Run `pnpm --filter @plotday/api exec vitest run` for server tests; `cd apps/plot && flutter analyze` + `flutter test` for client.

## Reference: current code (verbatim anchors)

- `workers/api/src/apple/iap.ts:589` `applyAppleTransactionToUser(db, userId, txn)` — upserts row to `origin=app_store`; does **not** touch `stripe_subscription_id`; returns `{ plan, expiresAt }`.
- `workers/api/src/app/upgrade.ts:498` `POST /upgrade/iap/verify` — verifies JWS, calls `applyAppleTransactionToUser`, returns `{plan, expires_at, origin}`. No Stripe cancel, no paid-Stripe guard.
- `workers/api/src/stripe/stripe.ts:401` `handleSubscriptionDeleted(c, subscription)` — guard at `:416` only checks **Stripe** active subs; reverts row to free + recreates `free_monthly` via `createFreeSubscription` (`:516`).
- `workers/api/src/webhook.ts:946` `/hook/appstore` — verifies notification, calls `applyAppleTransactionToUser(db, userId, txn)` at `:1042`. No free recreation on lapse.
- `workers/api/src/stripe/utils.ts:129` `createFreeSubscription(stripe, {customerId, userId})`; `:170` `createInitialTrialSubscription(...)` (`trial_period_days: 30`).
- `apps/plot/lib/api/upgrade_api.dart:250` `SubscriptionInfo` — has `plan, effectivePlan, effectiveSource, origin`; **no `status`**.
- `apps/plot/lib/command/settings.dart:139` gating for `ShowUpgradeOptions`; `:123` for `ManageSubscriptionCommand`; `:145` `RestorePurchasesCommand`.
- `apps/plot/lib/command/upgrade.dart:159` `ShowUpgradeOptions` (hardcoded `['core','pro']`); `:232` `ManageSubscriptionCommand`; `:278` `RestorePurchasesCommand`.

---

## Task 1: Server — cancel Stripe sub on IAP convert + clear `stripe_subscription_id`

Make `applyAppleTransactionToUser` clear the stale `stripe_subscription_id` and report what it replaced, so the verify handler can cancel the Stripe sub.

**Files:**
- Modify: `workers/api/src/apple/iap.ts:589-643`
- Test: `workers/api/src/apple/iap.test.ts`

**Interfaces:**
- Produces: `applyAppleTransactionToUser(db, userId, txn)` now returns `{ plan: "free"|"core"|"pro"; expiresAt: Date | null; previous: { origin: string; status: string; plan: string; stripeSubscriptionId: string | null; stripeCustomerId: string | null } | null }`.

- [ ] **Step 1: Write the failing test** — append to `iap.test.ts`. Follow the existing file's DB harness (it already constructs a `Kysely<DB>` and inserts `user_subscription` rows; mirror that setup). Test that a prior `stripe` row is reported in `previous` and the row's `stripe_subscription_id` is cleared:

```ts
it("reports the prior Stripe row and clears stripe_subscription_id on convert", async () => {
  // Arrange: user with a Stripe Core trial row (mirror existing insert helper)
  await db.insertInto("user_subscription").values({
    user_id: userId, plan: "core", status: "trialing", origin: "stripe",
    stripe_customer_id: "cus_test", stripe_subscription_id: "sub_test",
    billing_cycle_start: new Date().toISOString(),
    billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
  }).execute();

  const txn = makeTxn({ productId: "day.plot.app.core_monthly" }); // existing test helper

  const result = await applyAppleTransactionToUser(db, userId, txn);

  expect(result.previous).toMatchObject({
    origin: "stripe", status: "trialing", plan: "core",
    stripeSubscriptionId: "sub_test", stripeCustomerId: "cus_test",
  });
  const row = await db.selectFrom("user_subscription").selectAll()
    .where("user_id", "=", userId).executeTakeFirstOrThrow();
  expect(row.origin).toBe("app_store");
  expect(row.stripe_subscription_id).toBeNull();
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/apple/iap.test.ts`
Expected: FAIL — `result.previous` is `undefined` and `stripe_subscription_id` still `"sub_test"`.

- [ ] **Step 3: Implement** — in `iap.ts`, read the prior row before the upsert and clear the Stripe sub id in both insert and update:

```ts
export async function applyAppleTransactionToUser(
  db: Kysely<DB>,
  userId: string,
  txn: JwsTransactionPayload
): Promise<{
  plan: "free" | "core" | "pro";
  expiresAt: Date | null;
  previous: {
    origin: string; status: string; plan: string;
    stripeSubscriptionId: string | null; stripeCustomerId: string | null;
  } | null;
}> {
  const plan = IAP_PRODUCT_TO_PLAN[txn.productId];
  if (!plan) throw new Error(`Unsupported productId: ${txn.productId}`);

  // Snapshot the prior row so the caller can reconcile (cancel) any Stripe sub.
  const prior = await db
    .selectFrom("user_subscription")
    .select(["origin", "status", "plan", "stripe_subscription_id", "stripe_customer_id"])
    .where("user_id", "=", userId)
    .executeTakeFirst();
  const previous = prior
    ? {
        origin: prior.origin, status: prior.status, plan: prior.plan,
        stripeSubscriptionId: prior.stripe_subscription_id,
        stripeCustomerId: prior.stripe_customer_id,
      }
    : null;

  const now = new Date();
  const expiresAt = txn.expiresDate ? new Date(txn.expiresDate) : null;
  const isExpired = expiresAt !== null && expiresAt.getTime() < now.getTime();
  const isRevoked = txn.revocationDate != null;
  const isEntitled = !isExpired && !isRevoked;

  const cycleStart = new Date(txn.purchaseDate);
  const cycleEnd = expiresAt ?? new Date(cycleStart.getTime() + 30 * 24 * 60 * 60 * 1000);
  const targetPlan: "free" | "core" | "pro" = isEntitled ? plan : "free";
  const status = isEntitled ? "active" : "canceled";

  await db
    .insertInto("user_subscription")
    .values({
      user_id: userId, plan: targetPlan, status, origin: "app_store",
      apple_original_transaction_id: txn.originalTransactionId,
      apple_product_id: txn.productId,
      stripe_subscription_id: null,
      billing_cycle_start: cycleStart.toISOString(),
      billing_cycle_end: cycleEnd.toISOString(),
    })
    .onConflict((oc) =>
      oc.column("user_id").doUpdateSet({
        plan: targetPlan, status, origin: "app_store",
        apple_original_transaction_id: txn.originalTransactionId,
        apple_product_id: txn.productId,
        stripe_subscription_id: null,
        billing_cycle_start: cycleStart.toISOString(),
        billing_cycle_end: cycleEnd.toISOString(),
        updated_at: sql`now()`,
      })
    )
    .execute();

  return { plan: targetPlan, expiresAt, previous };
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `pnpm --filter @plotday/api exec vitest run src/apple/iap.test.ts`
Expected: PASS (existing 10 + new test). Fix any existing test that destructured the old return shape (the added field is additive, so they should still pass).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/apple/iap.ts workers/api/src/apple/iap.test.ts
git commit -m "feat(iap): clear stale Stripe sub id and report prior row on Apple convert"
```

---

## Task 2: Server — `/upgrade/iap/verify` cancels the Stripe sub + rejects paid-Stripe

Use Task 1's `previous` to cancel the user's Stripe subscription after the entitlement flips to Apple, and reject IAP for an active **paid** Stripe plan (defense-in-depth; the client won't offer it).

**Files:**
- Modify: `workers/api/src/app/upgrade.ts:498-555`
- Test: `workers/api/src/app/upgrade.test.ts` (create if absent; otherwise add to the existing upgrade test file)

**Interfaces:**
- Consumes: `applyAppleTransactionToUser(...).previous` (Task 1); `createStripeClient(c.env.STRIPE_SECRET_KEY)` from `../stripe/utils`.
- Produces: `/upgrade/iap/verify` returns `409 {error:"manage_on_web"}` when a paid Stripe sub is active; otherwise unchanged response plus a best-effort Stripe cancel.

- [ ] **Step 1: Write the failing test** — a paid Stripe user is rejected; a trial user's Stripe sub gets canceled. Mock the Stripe client's `subscriptions.cancel`. Follow the existing handler-test pattern in `workers/api/src/app/*.test.ts` (Hono test client + seeded `c.var.db`); if none exists, drive `upgrade.request("/upgrade/iap/verify", {...})` with a stubbed `verifyTransaction`.

```ts
it("rejects IAP when the user has an active paid Stripe plan", async () => {
  await seedSubscription({ userId, plan: "core", status: "active", origin: "stripe" });
  const res = await postIapVerify({ product_id: "day.plot.app.pro_monthly" });
  expect(res.status).toBe(409);
  expect(await res.json()).toMatchObject({ error: "manage_on_web" });
});

it("cancels the Stripe trial sub after a successful convert", async () => {
  await seedSubscription({
    userId, plan: "core", status: "trialing", origin: "stripe",
    stripe_customer_id: "cus_x", stripe_subscription_id: "sub_x",
  });
  const cancel = vi.spyOn(stripeMock.subscriptions, "cancel").mockResolvedValue({} as any);
  const res = await postIapVerify({ product_id: "day.plot.app.core_monthly" });
  expect(res.status).toBe(200);
  expect(cancel).toHaveBeenCalledWith("sub_x");
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/app/upgrade.test.ts`
Expected: FAIL — verify returns 200 for the paid case and never calls `subscriptions.cancel`.

- [ ] **Step 3: Implement** — insert the guard before `applyAppleTransactionToUser`, and the cancel after. Replace `iap.ts:542` region of the handler:

```ts
  // Defense-in-depth: a genuinely paid Stripe subscriber must manage/upgrade
  // on the web (the client already hides IAP for them). A trial or free
  // (free_monthly) Stripe row is convertible.
  const existing = await c.var.db
    .selectFrom("user_subscription")
    .select(["origin", "status", "plan"])
    .where("user_id", "=", user.id)
    .executeTakeFirst();
  if (
    existing && existing.origin === "stripe" &&
    existing.status === "active" && existing.plan !== "free"
  ) {
    logger.warn("IAP: blocked — active paid Stripe plan, manage on web", {
      user_id: user.id, plan: existing.plan,
    });
    return c.json({ error: "manage_on_web" }, 409);
  }

  const result = await applyAppleTransactionToUser(c.var.db, user.id, txn);

  // Reconcile: cancel the now-superseded Stripe subscription (the Core trial
  // or the free_monthly tracker). The row is already origin=app_store, so the
  // customer.subscription.deleted webhook will defer to it (Task 3).
  const prevSubId = result.previous?.stripeSubscriptionId ?? null;
  if (prevSubId) {
    try {
      const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
      await stripe.subscriptions.cancel(prevSubId);
    } catch (e) {
      // Non-fatal: the entitlement already flipped to Apple. Log so a leaked
      // Stripe sub can be reconciled; the deletion webhook guard also covers us.
      c.var.tracker.captureException(e as Error);
      logger.warn("IAP: failed to cancel superseded Stripe subscription", {
        user_id: user.id, stripe_subscription_id: prevSubId,
        error: (e as Error).message,
      });
    }
  }

  c.var.tracker.capture("[User] Subscription Created", {
    plan: result.plan, origin: "app_store", apple_product_id: txn.productId,
  });
```

Add `createStripeClient` to the imports from `../stripe/utils`.

- [ ] **Step 4: Run tests, verify pass**

Run: `pnpm --filter @plotday/api exec vitest run src/app/upgrade.test.ts src/apple/iap.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/upgrade.ts workers/api/src/app/upgrade.test.ts
git commit -m "feat(iap): cancel superseded Stripe sub on convert; reject IAP for paid Stripe"
```

---

## Task 3: Server — Stripe deletion guard defers to active `app_store` entitlement

Stop `handleSubscriptionDeleted` from reverting a user to free when their row is already an active `app_store` entitlement (the convert path cancels their Stripe sub, which fires this webhook).

**Files:**
- Modify: `workers/api/src/stripe/stripe.ts:401-431` (extend the existing guard)
- Test: `workers/api/src/stripe/stripe.test.ts` (add; mirror existing stripe handler tests)

**Interfaces:**
- Consumes: the row written by `applyAppleTransactionToUser` (`origin=app_store`).

- [ ] **Step 1: Write the failing test**

```ts
it("skips free-revert when the user already has an active app_store entitlement", async () => {
  await seedSubscription({
    userId, plan: "pro", status: "active", origin: "app_store",
    stripe_customer_id: "cus_x",
    billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
  });
  await handleSubscriptionDeletedTest({ customer: "cus_x", id: "sub_old" });
  const row = await getSub(userId);
  expect(row.origin).toBe("app_store");
  expect(row.plan).toBe("pro");           // untouched
  expect(createFreeSubscription).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/stripe/stripe.test.ts`
Expected: FAIL — the handler reverts the row to free and calls `createFreeSubscription`.

- [ ] **Step 3: Implement** — after the existing Stripe-active guard (`stripe.ts:431`), add an app_store-entitlement guard:

```ts
  // Cross-platform guard: if this user has flipped to an active App Store
  // entitlement (e.g. the IAP convert path just cancelled their Stripe trial /
  // free_monthly sub), do NOT revert to free or recreate a free Stripe sub.
  // The Apple subscription is the source of truth now.
  const appStoreRow = await c.var.db
    .selectFrom("user_subscription")
    .select(["origin", "status", "billing_cycle_end"])
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();
  if (
    appStoreRow &&
    appStoreRow.origin === "app_store" &&
    (appStoreRow.status === "active" ||
      (appStoreRow.billing_cycle_end != null &&
        new Date(appStoreRow.billing_cycle_end).getTime() > Date.now()))
  ) {
    logger.info("Skipping free-revert — user has an active App Store entitlement", {
      customer_id: customerId, deleted_subscription_id: subscription.id,
    });
    return;
  }
```

- [ ] **Step 4: Run tests, verify pass**

Run: `pnpm --filter @plotday/api exec vitest run src/stripe/stripe.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/stripe/stripe.ts workers/api/src/stripe/stripe.test.ts
git commit -m "feat(billing): Stripe deletion handler defers to active app_store entitlement"
```

---

## Task 4: Server — recreate `free_monthly` when the Apple sub lapses

When an App Store Server Notification reports a non-entitled state (expire / refund / revoke), reinstate the `free_monthly` Stripe sub so free-tier usage tracking resumes. Honor the billing-retry grace period (don't downgrade during `GRACE_PERIOD`).

**Files:**
- Modify: `workers/api/src/webhook.ts:1042` (after `applyAppleTransactionToUser`)
- Create: `workers/api/src/stripe/reinstate-free.ts` — `reinstateFreeSubscription(db, env, userId)` extracted from the `stripe.ts:507-528` recreation logic (reuse `createFreeSubscription` + `getBillingCycleDates`)
- Test: `workers/api/src/webhook.test.ts` (add appstore-lapse case) + `workers/api/src/stripe/reinstate-free.test.ts`

**Interfaces:**
- Produces: `reinstateFreeSubscription(db: Kysely<DB>, env: Env, userId: string): Promise<void>` — creates a `free_monthly` Stripe sub for the user's `stripe_customer_id`, sets the row to `plan=free, status=active, origin=stripe, stripe_subscription_id=<new>`, billing cycle from the new sub.

- [ ] **Step 1: Write the failing test** (helper):

```ts
it("recreates free_monthly and flips the row back to stripe/free", async () => {
  await seedSubscription({
    userId, plan: "pro", status: "active", origin: "app_store",
    stripe_customer_id: "cus_x",
  });
  vi.spyOn(stripeMock.subscriptions, "create").mockResolvedValue(
    { id: "sub_free", items: { data: [{ current_period_start: 1, current_period_end: 2 }] } } as any
  );
  await reinstateFreeSubscription(db, env, userId);
  const row = await getSub(userId);
  expect(row).toMatchObject({ plan: "free", status: "active", origin: "stripe", stripe_subscription_id: "sub_free" });
});
```

And the webhook lapse case:

```ts
it("reinstates free on EXPIRED, keeps entitlement on GRACE_PERIOD", async () => {
  await seedSubscription({ userId, plan: "core", status: "active", origin: "app_store",
    apple_original_transaction_id: "otx", stripe_customer_id: "cus_x" });

  await postAppStoreNotification({ notificationType: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD",
    txn: makeTxn({ originalTransactionId: "otx", expiresDate: Date.now() - 1000 }) });
  expect((await getSub(userId)).origin).toBe("app_store");   // unchanged during grace

  await postAppStoreNotification({ notificationType: "EXPIRED",
    txn: makeTxn({ originalTransactionId: "otx", expiresDate: Date.now() - 1000 }) });
  expect((await getSub(userId)).origin).toBe("stripe");      // reinstated
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/stripe/reinstate-free.test.ts src/webhook.test.ts`
Expected: FAIL — `reinstateFreeSubscription` not defined; webhook doesn't reinstate.

- [ ] **Step 3a: Implement `reinstate-free.ts`** — factor the recreation logic out of `stripe.ts:507-528`:

```ts
import type { Kysely } from "kysely";
import type { DB } from "../db-types";
import type { Env } from "../types";
import { createStripeClient, createFreeSubscription, getBillingCycleDates } from "./utils";

/** Reinstate a free_monthly Stripe subscription for usage tracking and flip the
 *  user's row back to stripe/free. Used when an App Store entitlement lapses. */
export async function reinstateFreeSubscription(
  db: Kysely<DB>, env: Env, userId: string
): Promise<void> {
  const row = await db.selectFrom("user_subscription")
    .select(["stripe_customer_id"]).where("user_id", "=", userId).executeTakeFirst();
  if (!row?.stripe_customer_id) return; // no Stripe customer to attach tracking to

  const stripe = createStripeClient(env.STRIPE_SECRET_KEY);
  const freeSub = await createFreeSubscription(stripe, {
    customerId: row.stripe_customer_id, userId,
  });
  const { start, end } = getBillingCycleDates(freeSub);

  await db.updateTable("user_subscription").set({
    plan: "free", status: "active", origin: "stripe",
    stripe_subscription_id: freeSub.id,
    billing_cycle_start: start.toISOString(), billing_cycle_end: end.toISOString(),
    updated_at: sql`now()`,
  }).where("user_id", "=", userId).execute();
}
```

(Import `sql` from `kysely`. Then refactor `stripe.ts:507-528` to call `reinstateFreeSubscription` to avoid duplication — keep behavior identical.)

- [ ] **Step 3b: Wire the webhook** — in `webhook.ts`, replace the `:1042` apply with grace-aware reinstatement:

```ts
      // Grace period (billing retry): Apple still entitles the user even though
      // expiresDate has passed. Skip the downgrade entirely.
      const inGracePeriod =
        notif.notificationType === "DID_FAIL_TO_RENEW" &&
        notif.subtype === "GRACE_PERIOD";
      if (inGracePeriod) {
        return c.json({ ok: true, grace: true });
      }

      const applied = await applyAppleTransactionToUser(db, userId, txn);

      // Entitlement lapsed (expire / refund / revoke) — restore free-tier
      // usage tracking via a fresh free_monthly Stripe sub.
      if (applied.plan === "free") {
        try {
          await reinstateFreeSubscription(db, c.env, userId);
        } catch (e) {
          c.var.tracker.captureException(e as Error);
          logger.warn("AppStore webhook: failed to reinstate free subscription", {
            user_id: userId, error: (e as Error).message,
          });
        }
      }
```

Add the import: `import { reinstateFreeSubscription } from "../stripe/reinstate-free";`

- [ ] **Step 4: Run tests, verify pass**

Run: `pnpm --filter @plotday/api exec vitest run src/stripe/reinstate-free.test.ts src/webhook.test.ts src/stripe/stripe.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/stripe/reinstate-free.ts workers/api/src/stripe/reinstate-free.test.ts \
        workers/api/src/webhook.ts workers/api/src/webhook.test.ts workers/api/src/stripe/stripe.ts
git commit -m "feat(iap): reinstate free_monthly Stripe sub when Apple entitlement lapses (grace-aware)"
```

---

## Task 5: Client — `SubscriptionInfo` parses `status` + cross-platform helpers

**Files:**
- Modify: `apps/plot/lib/api/upgrade_api.dart:250-287`
- Test: `apps/plot/test/api/subscription_info_test.dart` (create)

**Interfaces:**
- Produces: `SubscriptionInfo.status` (String, default `'active'`); helpers `isStripeTrial`, `isPaidStripe`, `isAppStore`.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';

void main() {
  SubscriptionInfo of(Map<String, dynamic> j) => SubscriptionInfo.fromJson(j);

  test('stripe trial is convertible, not paid', () {
    final s = of({'plan': 'core', 'effective_plan': 'core', 'origin': 'stripe', 'status': 'trialing'});
    expect(s.isStripeTrial, isTrue);
    expect(s.isPaidStripe, isFalse);
    expect(s.isAppStore, isFalse);
  });

  test('active stripe core is paid', () {
    final s = of({'plan': 'core', 'effective_plan': 'core', 'origin': 'stripe', 'status': 'active'});
    expect(s.isPaidStripe, isTrue);
    expect(s.isStripeTrial, isFalse);
  });

  test('free defaults (origin null) are not paid/trial/appstore', () {
    final s = of({'plan': 'free', 'effective_plan': 'free', 'status': 'active'});
    expect(s.isPaidStripe, isFalse);
    expect(s.isStripeTrial, isFalse);
    expect(s.isAppStore, isFalse);
    expect(s.isFree, isTrue);
  });

  test('app_store origin', () {
    final s = of({'plan': 'pro', 'effective_plan': 'pro', 'origin': 'app_store', 'status': 'active'});
    expect(s.isAppStore, isTrue);
  });
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd apps/plot && flutter test test/api/subscription_info_test.dart`
Expected: FAIL — `isStripeTrial`/`isPaidStripe`/`isAppStore`/`status` undefined.

- [ ] **Step 3: Implement** — add `status` and helpers to `SubscriptionInfo`:

```dart
class SubscriptionInfo extends Equatable {
  final String plan;
  final String effectivePlan;
  final String effectiveSource;
  final String? origin;

  /// Personal subscription status: 'active' | 'trialing' | 'canceled' | …
  /// Distinguishes a Stripe free trial (convertible to IAP) from an actively
  /// paid Stripe plan (web-managed).
  final String status;

  const SubscriptionInfo({
    required this.plan,
    required this.effectivePlan,
    required this.effectiveSource,
    this.origin,
    this.status = 'active',
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    return SubscriptionInfo(
      plan: json['plan'] as String? ?? 'free',
      effectivePlan: json['effective_plan'] as String? ?? 'free',
      effectiveSource: json['effective_source'] as String? ?? 'personal',
      origin: json['origin'] as String?,
      status: json['status'] as String? ?? 'active',
    );
  }

  bool get isFree => effectivePlan == 'free';
  bool get isCore => effectivePlan == 'core';
  bool get canBuildTwists => effectivePlan == 'pro' || effectivePlan == 'team';
  bool get hasPaidPlan => effectivePlan != 'free';
  bool get isAppStoreOrigin => origin == 'app_store';

  /// On the 30-day Stripe Core trial — convertible to IAP on App Store builds.
  bool get isStripeTrial => origin == 'stripe' && status == 'trialing';

  /// Actively paying via Stripe (web) — managed on the web, never offered IAP.
  bool get isPaidStripe =>
      origin == 'stripe' && status == 'active' && effectivePlan != 'free';

  /// Active subscription purchased via App Store IAP.
  bool get isAppStore => origin == 'app_store';

  @override
  List<Object?> get props => [plan, effectivePlan, effectiveSource, origin, status];
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd apps/plot && flutter test test/api/subscription_info_test.dart && flutter analyze lib/api/upgrade_api.dart`
Expected: PASS, no analyzer issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/api/upgrade_api.dart apps/plot/test/api/subscription_info_test.dart
git commit -m "feat(app): SubscriptionInfo parses status + cross-platform helpers"
```

---

## Task 6: Client — `ShowUpgradeOptions` tier filter, `ManageSubscriptionCommand` web routing + label

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart:159-273`
- Test: `apps/plot/test/command/upgrade_command_test.dart` (create)

**Interfaces:**
- Consumes: `SubscriptionInfo` helpers (Task 5).
- Produces: `ShowUpgradeOptions({List<String> availablePlans = const ['core','pro'], ...})` — picker only offers `availablePlans`; if exactly one, skips the picker and buys it directly. `ManageSubscriptionCommand({bool appStoreOrigin})` opens the **web** management for Stripe-origin subs even on App Store builds; title is "Manage your subscription".

- [ ] **Step 1: Write the failing test** — assert tier filtering chooses the right `BuyPlanCommand` and that a single available plan skips the modal. (Use a thin seam: extract the plan list resolution into a testable static, e.g. `ShowUpgradeOptions.plansFor(SubscriptionInfo)`.)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/upgrade.dart';

void main() {
  SubscriptionInfo sub({String plan = 'free', String? origin, String status = 'active'}) =>
      SubscriptionInfo(plan: plan, effectivePlan: plan, effectiveSource: 'personal', origin: origin, status: status);

  test('free → core + pro', () {
    expect(ShowUpgradeOptions.plansFor(sub()), ['core', 'pro']);
  });
  test('stripe trial core → core + pro', () {
    expect(ShowUpgradeOptions.plansFor(sub(plan: 'core', origin: 'stripe', status: 'trialing')), ['core', 'pro']);
  });
  test('app_store core → pro only', () {
    expect(ShowUpgradeOptions.plansFor(sub(plan: 'core', origin: 'app_store')), ['pro']);
  });
  test('paid stripe / pro → none', () {
    expect(ShowUpgradeOptions.plansFor(sub(plan: 'pro', origin: 'app_store')), isEmpty);
    expect(ShowUpgradeOptions.plansFor(sub(plan: 'core', origin: 'stripe', status: 'active')), isEmpty);
  });
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd apps/plot && flutter test test/command/upgrade_command_test.dart`
Expected: FAIL — `plansFor` / `availablePlans` undefined.

- [ ] **Step 3: Implement**

In `ShowUpgradeOptions`, add the field + resolver + single-plan shortcut:

```dart
class ShowUpgradeOptions extends Command {
  ShowUpgradeOptions({String? title, String? subtitle, List<String>? availablePlans})
    : _title = title ?? 'Upgrade your plan',
      _subtitle = subtitle,
      _availablePlans = availablePlans ?? const ['core', 'pro'],
      super(
        title: title ?? 'Upgrade your plan',
        icon: PlotIcon.sparkles,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  final String _title;
  final String? _subtitle;
  final List<String> _availablePlans;

  /// Which tiers to offer for [sub]'s current state on App Store builds.
  /// Mirrors the gating matrix: free/trial → both; app_store-core → pro only;
  /// paid Stripe / pro / team → none.
  static List<String> plansFor(SubscriptionInfo sub) {
    if (sub.isPaidStripe || sub.canBuildTwists) return const [];
    if (sub.isAppStore && sub.isCore) return const ['pro'];
    return const ['core', 'pro'];
  }
```

In `run`, after the non-App-Store early return, handle 0/1/2 available plans:

```dart
    if (_availablePlans.isEmpty) return const CommandSkipped();
    if (_availablePlans.length == 1) {
      return BuyPlanCommand(plan: _availablePlans.first).run(context);
    }

    final result = await SelectModal.open<String>(
      context,
      showFilter: false,
      title: _title,
      subtitle: _modalSubtitle(),
      items: (_) async => [SelectGroup<String>(items: _availablePlans)],
      itemBuilder: (plan, _) => Builder(/* unchanged */),
    );
```

In `ManageSubscriptionCommand`, change title and route Stripe-origin to web even on App Store builds:

```dart
class ManageSubscriptionCommand extends Command {
  ManageSubscriptionCommand({this.appStoreOrigin = false})
    : super(
        title: 'Manage your subscription',
        icon: PlotIcon.settings,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  /// True when the active subscription was purchased via StoreKit IAP. When
  /// false on an App Store build, the active sub is Stripe-origin, so we route
  /// to web management (3.1.1-safe: managing an existing sub, not a new purchase).
  final bool appStoreOrigin;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (appStoreOrigin) {
      final uri = Uri.parse(_appStoreManageSubscriptionsUrl);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e, st) {
        log.warning('Failed to open App Store subscriptions URL', e, st);
      }
      return const CommandDone();
    }
    // Stripe-origin (incl. on App Store builds): manage on the web.
    try {
      final url = await UpgradeApi.getPortalUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return const CommandDone();
    } catch (e, st) {
      log.warning('Failed to open billing management', e, st);
      if (context.mounted) {
        context.showToast(message: 'Could not open subscription management.', isError: true);
      }
      return const CommandSkipped();
    }
  }
}
```

Note: callers now pass `appStoreOrigin: subscription.isAppStore` (Task 7 wires this).

- [ ] **Step 4: Run tests, verify pass**

Run: `cd apps/plot && flutter test test/command/upgrade_command_test.dart && flutter analyze lib/command/upgrade.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart apps/plot/test/command/upgrade_command_test.dart
git commit -m "feat(app): filter upgrade tiers by plan; route Stripe manage to web"
```

---

## Task 7: Client — Settings gating matrix

Rewrite the App-group gating so the entries follow the Section-2 matrix. Extract the decision into a pure, testable function.

**Files:**
- Modify: `apps/plot/lib/command/settings.dart:118-153`
- Test: `apps/plot/test/command/settings_subscription_gating_test.dart` (create)

**Interfaces:**
- Consumes: `SubscriptionInfo` (Tasks 5), `ShowUpgradeOptions.plansFor` (Task 6), `UpgradeUi.isAppStoreBuild`.
- Produces: `subscriptionCommandsFor({required SubscriptionInfo? subscription, required bool isAppStoreBuild})` → ordered `List<Command>` of the manage/upgrade/restore entries.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/settings.dart';
import 'package:plot/command/upgrade.dart';

void main() {
  SubscriptionInfo sub({String plan = 'free', String? origin, String status = 'active'}) =>
      SubscriptionInfo(plan: plan, effectivePlan: plan, effectiveSource: 'personal', origin: origin, status: status);

  List<Type> types(List cmds) => cmds.map((c) => c.runtimeType).toList();

  test('stripe trial (App Store) → upgrade + restore, no manage', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'core', origin: 'stripe', status: 'trialing'), isAppStoreBuild: true);
    expect(types(cmds), [ShowUpgradeOptions, RestorePurchasesCommand]);
  });

  test('paid stripe (App Store) → manage + restore, no upgrade', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'core', origin: 'stripe', status: 'active'), isAppStoreBuild: true);
    expect(types(cmds), [ManageSubscriptionCommand, RestorePurchasesCommand]);
  });

  test('app_store core → upgrade(pro) + manage + restore', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'core', origin: 'app_store'), isAppStoreBuild: true);
    expect(types(cmds), [ShowUpgradeOptions, ManageSubscriptionCommand, RestorePurchasesCommand]);
  });

  test('app_store pro → manage + restore', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'pro', origin: 'app_store'), isAppStoreBuild: true);
    expect(types(cmds), [ManageSubscriptionCommand, RestorePurchasesCommand]);
  });

  test('free (App Store) → upgrade + restore', () {
    final cmds = subscriptionCommandsFor(subscription: sub(), isAppStoreBuild: true);
    expect(types(cmds), [ShowUpgradeOptions, RestorePurchasesCommand]);
  });

  test('non-App-Store free → upgrade only (no restore)', () {
    final cmds = subscriptionCommandsFor(subscription: sub(), isAppStoreBuild: false);
    expect(types(cmds), [ShowUpgradeOptions]);
  });
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd apps/plot && flutter test test/command/settings_subscription_gating_test.dart`
Expected: FAIL — `subscriptionCommandsFor` undefined.

- [ ] **Step 3: Implement** — add the pure function in `settings.dart` and call it from `settingsCommandsFromState`'s App group, replacing the inline `if` blocks at `:123` and `:139`/`:145`:

```dart
/// The subscription-related Settings entries (manage / upgrade / restore),
/// in display order, per the cross-platform gating matrix. Pure for testing.
List<Command> subscriptionCommandsFor({
  required SubscriptionInfo? subscription,
  required bool isAppStoreBuild,
}) {
  final cmds = <Command>[];
  final s = subscription;

  // Upgrade: only when there are tiers to offer for this state.
  if (s != null) {
    if (isAppStoreBuild) {
      if (ShowUpgradeOptions.plansFor(s).isNotEmpty) {
        cmds.add(ShowUpgradeOptions(availablePlans: ShowUpgradeOptions.plansFor(s)));
      }
    } else if (!s.canBuildTwists) {
      // Web/DMG: existing behavior — offer upgrade unless already top-tier.
      cmds.add(ShowUpgradeOptions());
    }
  }

  // Manage: app_store paid → Apple; stripe paid → web. Not for trial/free.
  if (s != null && s.hasPaidPlan && (s.isAppStore || s.isPaidStripe)) {
    cmds.add(ManageSubscriptionCommand(appStoreOrigin: s.isAppStore));
  }

  // Restore: always available on App Store builds.
  if (isAppStoreBuild) cmds.add(RestorePurchasesCommand());

  return cmds;
}
```

Then in `settingsCommandsFromState`, replace the three inline entries (`ManageSubscriptionCommand` block at `:123`, `ShowUpgradeOptions` block at `:139`, `RestorePurchasesCommand` at `:145`) with a spread, placing them where `ShowUpgradeOptions`/restore currently sit in the `App` group:

```dart
      ...subscriptionCommandsFor(
        subscription: subscription,
        isAppStoreBuild: UpgradeUi.isAppStoreBuild,
      ),
```

(Keep `ManageTeams` and the rest of the group unchanged. Verify the import of `ManageSubscriptionCommand, RestorePurchasesCommand, ShowUpgradeOptions` at `:49` stays.)

- [ ] **Step 4: Run tests, verify pass**

Run: `cd apps/plot && flutter test test/command/settings_subscription_gating_test.dart && flutter analyze lib/command/settings.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/settings.dart apps/plot/test/command/settings_subscription_gating_test.dart
git commit -m "feat(app): cross-platform subscription gating matrix in Settings"
```

---

## Task 8: Dev seed — add a free and a trialing user

So the IAP paywall is reachable in local dev without DB surgery (the gap found during investigation: every seeded user was on a paid Stripe plan).

**Files:**
- Modify: the seed generator (locate with `grep -rl "createInitialTrialSubscription\|free_monthly\|user_subscription" workers scripts --include=*.ts` — likely `workers/api/scripts/generate-seed.ts` or `scripts/`). Add two users: one with **no** `user_subscription` row (or `plan=free` via `free_monthly`) and one **`core/trialing/stripe`**.
- Test: manual seed apply + verify.

- [ ] **Step 1: Locate the generator and the existing user-seed block**

Run: `grep -rn "user_subscription\|createInitialTrialSubscription\|plan: *'core'\|seed" workers/api/scripts scripts 2>/dev/null | head`

- [ ] **Step 2: Add the two users** following the file's existing pattern — a `free@plot.day` (free) and `trial@plot.day` (`plan: 'core', status: 'trialing', origin: 'stripe', trial_ends_at: +30d`). Mirror the exact insert/builder shape used for existing seeded subscriptions.

- [ ] **Step 3: Apply and verify**

Run (worktree DB — set it up first if `.worktree-db` is absent):
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/cross-platform-subs
bash scripts/worktree-db   # if .worktree-db absent
psql "$DATABASE_URL" -tAc "show port;"   # must be the worktree port, not 54322
# run the project's seed command (e.g. pnpm --filter @plotday/db seed or the generator), then:
psql "$DATABASE_URL" -c "SELECT u.email, s.plan, s.status, s.origin FROM \"user\" u LEFT JOIN user_subscription s ON s.user_id=u.id WHERE u.email IN ('free@plot.day','trial@plot.day');"
```
Expected: `free@plot.day` → free (or no row), `trial@plot.day` → `core/trialing/stripe`.

- [ ] **Step 4: Commit**

```bash
git add <seed generator file>
git commit -m "chore(seed): add free and trialing dev users for IAP testing"
```

---

## Task 9: Finalize

- [ ] **Step 1: Lint + typecheck both sides**

Run:
```bash
pnpm --filter @plotday/api exec vitest run        # full api suite green
pnpm --filter @plotday/api run lint                # or repo lint for changed pkgs
cd apps/plot && flutter analyze && flutter test
```
Expected: all green (note any pre-existing main failures separately).

- [ ] **Step 2: `docs/updates.md`** — add under `## Next release`, a `### Subscriptions` section: a plain-language bullet, e.g. "You can now subscribe to Core or Pro directly on iPhone, iPad, and Mac, and your plan stays in sync however you signed up."

- [ ] **Step 3: `docs/features.md`** — note cross-platform (App Store + web) subscription purchasing if a subscriptions section exists.

- [ ] **Step 4: Backwards-compat check** — `/upgrade` response is unchanged (additive client parse of `status`); old clients ignore it. `/upgrade/iap/verify` adds a 409 path only for paid-Stripe (old clients never hit it because they didn't offer IAP to those users). Note in the commit.

- [ ] **Step 5: Commit docs**

```bash
git add docs/updates.md docs/features.md
git commit -m "docs: cross-platform subscriptions release note"
```

---

## Self-review notes (author)

- **Spec coverage:** Section 1 invariant → Tasks 1–4; Section 2 matrix → Tasks 5–7; Section 3 flows → Tasks 1–4; Section 4 manage/3.1.1 → Task 6; Section 5 StoreKit (no-op) → Global Constraints; Section 6 edge cases (grace/refund/web-mirror) → Task 4 (grace), Tasks 1–3 (refund→reinstate), **web-mirror of the invariant is NOT yet covered** — see Deferred; Section 7 testing → per-task tests + Task 9; seed fix → Task 8.
- **Deferred (flag to user):** the **web → "manage on Apple" mirror** when an `app_store` sub is active (Section 6) lives in the web subscribe flow (`apps/site` / Stripe checkout entry), not the app. Recommend a follow-up task once the app-side lands, since it's a separate surface and lower-risk (a web user re-subscribing is rare). 
- **Type consistency:** `previous.stripeSubscriptionId` (Task 1) consumed in Task 2; `reinstateFreeSubscription` (Task 4) signature matches its call; `ShowUpgradeOptions.plansFor` (Task 6) consumed in Task 7; `SubscriptionInfo.status/isStripeTrial/isPaidStripe/isAppStore` (Task 5) consumed in Tasks 6–7.
- **Test harness caveat:** server test scaffolding (DB seeding, Stripe mock, Hono request helpers) must follow the existing patterns in `iap.test.ts` and the stripe/webhook test files; the test snippets above show intent + assertions — wire them to the real harness during execution.
