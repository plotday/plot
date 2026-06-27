# Pricing B2 — Twist add-on billing (Stripe usage-synced + Apple tiers) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make **twist add-ons** (+20 twists, $10/mo) a real, usage-synced billable add-on — exactly mirroring the existing connection-add-on mechanism but parametrized by add-on *kind*. On Stripe the standalone `twist_addon_monthly` subscription's quantity tracks the number of +20 blocks a scope needs; on Apple it's the tiered `twist_addon_1/2/3` products. B1 already added the `twist_addon_count` entitlement column and the `checkTwistCapacity` gate that returns `twist_addon_required`; this plan provisions the billing headroom behind it.

**Architecture:** Generalize `stripe/addons.ts` (currently hardcodes `addon_monthly` / `metadata.type:"addon"` / `+1`) into an **add-on-kind**–parametrized module with two kinds: `CONNECTION_ADDON` (unchanged behavior) and `TWIST_ADDON`. The connection up-path stays "+1 per connection"; the twist up-path is "set quantity to the number of +20 blocks needed" (`blocks = ceil(max(0, twistWeightSum − planTwistCapacity) / 20)`). Webhook (`stripe.ts`), Apple (`iap.ts`), the purchase endpoint (`app/upgrade.ts`), and the reconcile-down trigger all gain a twist path mirroring the connection one. Twist add-ons are **personal-only on Apple** (`team_subscription` has no Apple columns); team twist add-ons are Stripe-only and admin-gated.

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Vitest, Atlas. Stripe is mocked in tests (mirror the existing connection-add-on tests in `stripe/*.test.ts` / `app/upgrade.test.ts`).

## Global Constraints

- **Base:** branch `pricing-model-product-changes` (B1 done @ `56c8cd0e`). Continue on it.
- **Worktree DB on 54333** (ambient `$DATABASE_URL` stale 54322). Before any DB/migration/test: `export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54333/postgres"`. Schema changes regenerate **BOTH** `libs/db/src/types.ts` (`pnpm apply-migrations` → `pnpm types`) **and** `workers/api/src/db-types.ts` (`cd workers/api && pnpm db:types` against 54333). Commit both.
- **Naming (hard rule):** the paid add-on is a **"twist add-on"** everywhere — code identifiers `twist_addon` / `TWIST_ADDON`, user-facing "twist add-on" / "+20 twists". NEVER "automation slots/pack/capacity" (that word is marketing-page-only).
- **Stripe price** `twist_addon_monthly` ($10/mo) and **Apple** `twist_addon_1/2/3` are created by the user in the dashboards (see `docs/superpowers/specs/2026-06-26-pricing-billing-product-setup.md`); tests must not hit real Stripe/Apple — mock them.
- **Quantity = blocks**, where one block = +20 twists, $10. `blocks(scope) = ceil(max(0, activeTwistWeightSum − planTwistCapacityBase) / 20)`, with `planTwistCapacityBase = PLAN_LIMITS[plan].twistCapacity` (personal) or `PLAN_LIMITS.team.twistCapacity * connection_group_quantity` (team). When `blocks === 0` the twist sub is canceled.
- **Reconcile is down-only off-session** (mirror `reconcileAddonQuantityDown`); the up-charge goes only through the explicit purchase endpoint (Option A, matching the connection add-on). Never use fire-and-forget DB; `captureException` new catch blocks. Never use `c.var.db` in `waitUntil` (open a fresh `createDb`).
- Lint+test from `workers/api`: `pnpm lint` (= `tsc && eslint`) and `pnpm test`. Commit per task.

## File structure

- `libs/db/schema/50-tables/20-user_subscription.sql` / `13-team_subscription.sql` — add `stripe_twist_addon_subscription_id`; user_subscription also gets `apple_twist_addon_original_transaction_id` + `apple_twist_addon_product_id`.
- `workers/api/src/stripe/addons.ts` — `AddonKind` abstraction; `CONNECTION_ADDON`/`TWIST_ADDON`; parametrized `addonPriceId`/`createAddonCheckoutSession`; new `setTwistAddonQuantity`; `reconcileAddonQuantityDown` kept kind-agnostic.
- `workers/api/src/stripe/stripe.ts` — webhook routes `metadata.type === "twist_addon"` → `twist_addon_count` + `stripe_twist_addon_subscription_id`.
- `workers/api/src/apple/iap.ts` — `IAP_TWIST_ADDON_PRODUCT_TO_COUNT`, `isTwistAddonProduct`, `applyAppleTwistAddonTransactionToUser`, `findUserByTwistAddonOriginalTransactionId`; ASN routing.
- `workers/api/src/app/upgrade.ts` — `twistAddonBlocksNeeded(...)`; `POST /upgrade/twist-addons/purchase`; reconcile helper for twists.
- `workers/api/src/app/twist-integrations.ts` OR `twist/management.ts` — reconcile-down trigger on twist removal (`deleteTwist`/`archiveAndDeleteTwist`/`deleteDraft`).
- `workers/api/src/utils/limits.ts` — export `twistAddonBlocksNeeded` helper (or place in upgrade.ts) reusing `getPersonalTwistWeightSum`/`getTeamTwistWeightSum` + `PLAN_LIMITS.twistCapacity`.
- Mirror test files: `stripe/addons.test.ts` (or wherever connection add-on unit tests live), `stripe/stripe.test.ts`, `apple/iap.test.ts`, `app/upgrade.test.ts`.

---

### Task 1: Schema — twist-add-on subscription + Apple columns

**Files:** `libs/db/schema/50-tables/20-user_subscription.sql`, `13-team_subscription.sql`; generated migration + both type files.

**Interfaces — Produces:**
- `user_subscription.stripe_twist_addon_subscription_id text UNIQUE` (nullable); `apple_twist_addon_original_transaction_id text` (nullable); `apple_twist_addon_product_id text` (nullable).
- `team_subscription.stripe_twist_addon_subscription_id text UNIQUE` (nullable). (No Apple columns on team — Apple is personal-only.)

- [ ] **Step 1:** In `20-user_subscription.sql`, after `stripe_addon_subscription_id`, add `"stripe_twist_addon_subscription_id" text UNIQUE,`; and near the `apple_addon_*` columns add `"apple_twist_addon_original_transaction_id" text,` and `"apple_twist_addon_product_id" text,`. Add a partial index on `stripe_twist_addon_subscription_id` mirroring the existing `idx_user_subscription_stripe_addon_subscription_id`. In `13-team_subscription.sql`, add only `"stripe_twist_addon_subscription_id" text UNIQUE,` + its partial index.
- [ ] **Step 2:** Generate + apply: `pnpm gen-migration -- add_twist_addon_subscription_columns` then `pnpm apply-migrations` (verify port 54333 first with `psql "$DATABASE_URL" -c "\conninfo"`).
- [ ] **Step 3:** Regenerate the kysely types too: `cd workers/api && pnpm db:types` (against 54333). Verify the new columns appear in both `libs/db/src/types.ts` and `workers/api/src/db-types.ts`.
- [ ] **Step 4:** `pnpm diff-schema-migrations` (no diff) + `pnpm --filter @plotday/db run lint`.
- [ ] **Step 5:** Commit (schema + migration + atlas.sum + both type files): `feat(db): add twist-add-on subscription + Apple columns`.

---

### Task 2: Generalize `stripe/addons.ts` by add-on kind + twist up-path

**Files:** `workers/api/src/stripe/addons.ts`; unit test alongside it.

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `export type AddonKind = { lookupKey: string; metadataType: string; priceMissingError: string }`.
  - `export const CONNECTION_ADDON: AddonKind` (`addon_monthly` / `"addon"`) and `export const TWIST_ADDON: AddonKind` (`twist_addon_monthly` / `"twist_addon"`).
  - `addonPriceId(stripe, kind)` (was hardcoded) — back-compat: keep existing `provisionAddonCredit`/`createAddonCheckoutSession` working for connections.
  - `createAddonCheckoutSession({ kind, stripe, customerId, siteRoot, scopeMetadata })` — `kind` defaults to `CONNECTION_ADDON` so existing callers are unchanged; uses `kind.lookupKey` + `metadata.type = kind.metadataType`; success/cancel urls carry `?addon=` for connection, `?twist_addon=` for twist (param derived from `kind.metadataType`).
  - `setTwistAddonQuantity({ stripe, customerId, twistAddonSubscriptionId, scopeMetadata, quantity })` → creates the standalone `twist_addon_monthly` sub at `quantity` (metadata `{ type: "twist_addon", ...scope }`) if none, else updates it to the absolute `quantity` (proration `always_invoice`); returns `{ subscriptionId, quantity }`. (Unlike connections' `+1`, twists set an absolute block count.)
  - `reconcileAddonQuantityDown` stays as-is (operates on a sub id + target `activeCount`; reused for twists with `activeCount = blocks`).

- [ ] **Step 1:** Write failing unit tests (mock `Stripe` like the existing connection add-on unit tests): `setTwistAddonQuantity` creates a sub at quantity N with `metadata.type="twist_addon"` and price looked up by `twist_addon_monthly` when no sub exists; updates to absolute N when one exists; `createAddonCheckoutSession({kind: TWIST_ADDON})` uses the twist lookup key + metadata. Run; expect FAIL (symbols undefined).
- [ ] **Step 2:** Refactor: extract `AddonKind`, the two consts, `addonPriceId(stripe, kind)`; thread `kind` (defaulting to `CONNECTION_ADDON`) through `createAddonCheckoutSession`; add `setTwistAddonQuantity`. Keep `provisionAddonCredit` (connection +1) and `customerHasPaymentMethod` unchanged. Run tests; expect PASS. Also run the existing connection add-on tests to confirm no regression.
- [ ] **Step 3:** `pnpm lint` clean. Commit: `refactor(stripe): parametrize add-ons by kind; add twist-add-on quantity provisioning`.

---

### Task 3: Stripe webhook routes the twist-add-on subscription

**Files:** `workers/api/src/stripe/stripe.ts`; `stripe/stripe.test.ts`.

**Interfaces:**
- Consumes: `metadata.type` on the subscription.
- Produces: `isTwistAddonSubscription(sub)` (`metadata.type === "twist_addon"`); `handleSubscriptionUpdate` writes a twist-add-on sub's quantity → `twist_addon_count` + `stripe_twist_addon_subscription_id` + status, and **never** touches plan or connection-add-on fields; `handleSubscriptionDeleted` zeroes `twist_addon_count` + clears `stripe_twist_addon_subscription_id`. Cross-origin guard: never overwrite an Apple-driven twist entitlement (`apple_twist_addon_original_transaction_id is null`), mirroring the connection guard.

- [ ] **Step 1:** Failing tests mirroring the connection-add-on webhook tests: a `metadata.type:"twist_addon"` `customer.subscription.updated` sets `twist_addon_count` to the item quantity + records `stripe_twist_addon_subscription_id`, leaving `plan`/`premium_connection_addons` untouched; `deleted` zeroes it; a plan or connection-add-on event never clobbers `twist_addon_count`. Run; expect FAIL.
- [ ] **Step 2:** Add `isTwistAddonSubscription` and the twist branch in `handleSubscriptionUpdate`/`handleSubscriptionDeleted`, mirroring the connection-add-on branch but on the twist columns + the Apple-twist guard. Run; expect PASS.
- [ ] **Step 3:** `pnpm lint`. Commit: `feat(stripe): route twist-add-on subscription webhook to twist_addon_count`.

---

### Task 4: Apple twist-add-on tiers

**Files:** `workers/api/src/apple/iap.ts`; `apple/iap.test.ts`; the App Store Server Notification handler (`apple/handle-appstore.ts` or wherever `applyAppleAddonTransactionToUser` is dispatched).

**Interfaces:**
- Produces: `IAP_TWIST_ADDON_PRODUCT_TO_COUNT = { "day.plot.app.twist_addon_1":1, "_2":2, "_3":3 }` (N = number of +20 blocks); `isTwistAddonProduct(productId)`; `applyAppleTwistAddonTransactionToUser(db, userId, txn)` → writes `twist_addon_count` + `apple_twist_addon_original_transaction_id` + `apple_twist_addon_product_id`, never touching plan/connection fields (mirror `applyAppleAddonTransactionToUser`); `findUserByTwistAddonOriginalTransactionId`. The ASN handler routes a twist-add-on product to the twist apply fn.

- [ ] **Step 1:** Failing tests mirroring the Apple connection add-on tests: applying `day.plot.app.twist_addon_2` to a (Free) user sets `twist_addon_count = 2` + the Apple twist columns; expiry/revocation resets to 0; a connection-add-on apply does not touch `twist_addon_count` and vice-versa. Run; expect FAIL.
- [ ] **Step 2:** Add the map, guards, `applyAppleTwistAddonTransactionToUser`, `findUserByTwistAddonOriginalTransactionId`, and the ASN routing (extend the product→handler dispatch to recognize twist-add-on products). Run; expect PASS.
- [ ] **Step 3:** `pnpm lint`. Commit: `feat(apple): twist-add-on tiers drive twist_addon_count (personal)`.

---

### Task 5: Purchase endpoint + reconcile-down on twist removal

**Files:** `workers/api/src/app/upgrade.ts`; `workers/api/src/utils/limits.ts` (export `twistAddonBlocksNeeded`); reconcile trigger in `twist/management.ts` (`deleteTwist` :702, `archiveAndDeleteTwist` :1354, `deleteDraft` :1249); `app/upgrade.test.ts`.

**Interfaces:**
- Produces:
  - `twistAddonBlocksNeeded(db, scope)`: `ceil(max(0, weightSum − base)/20)`, `base = PLAN_LIMITS[plan].twistCapacity` (personal) or `PLAN_LIMITS.team.twistCapacity * connection_group_quantity` (team); `weightSum` from `getPersonalTwistWeightSum`/`getTeamTwistWeightSum`. Status-gate the plan like `checkTwistCapacity` (lapsed → free → base = 1/0).
  - `POST /upgrade/twist-addons/purchase` (body `{ teamId? }`): computes target blocks for the scope, then — card on file → `setTwistAddonQuantity` (off-session) + write `twist_addon_count`/`stripe_twist_addon_subscription_id`; no card → `createAddonCheckoutSession({kind: TWIST_ADDON})` returns `{ checkout_url }`. Team path admin-gated (reject non-admins) and team-scoped. Mirror `purchaseAddonCreditForScope`'s atomicity + `captureException`.
  - A twist reconcile-down helper (mirror `reconcileScopeAddonBillingDown` but using `stripe_twist_addon_subscription_id` + `twistAddonBlocksNeeded` as the target) invoked from the twist-removal paths via `waitUntil` with a fresh `createDb` (no `c.var.db` in `waitUntil`).

- [ ] **Step 1:** Failing tests: `twistAddonBlocksNeeded` math (e.g. Free base 1, weightSum 1 → 0 blocks; weightSum 21 → 1 block; weightSum 41 → 2; team base `10*blocks`); the purchase endpoint with a mocked card-on-file customer sets the twist sub quantity to the target and writes `twist_addon_count`; card-less returns a `checkout_url`; a non-admin team member is rejected. Run; expect FAIL.
- [ ] **Step 2:** Implement `twistAddonBlocksNeeded`, the endpoint, and the reconcile helper; wire the reconcile into `deleteTwist`/`archiveAndDeleteTwist`/`deleteDraft` (down-only, `waitUntil`+fresh db, `captureException`). Run; expect PASS.
- [ ] **Step 3:** `pnpm lint` + full `workers/api` `pnpm test` (the new + all existing). Commit: `feat(upgrade): twist-add-on purchase endpoint + reconcile-down on twist removal`.

---

## Self-Review

**Spec coverage (Spec B "Area 2 — Billing"):** twist add-on Stripe usage-synced sub (Tasks 2,3,5) ✅; Apple tiers (Task 4) ✅; quantity = blocks needed, cancel-at-zero (Tasks 2,5) ✅; webhook routing by metadata, no cross-clobber, Apple guard (Task 3) ✅; schema `stripe_twist_addon_subscription_id` + Apple cols (Task 1) ✅; reconcile-down on twist removal (Task 5) ✅; team admin-gated, Apple personal-only (Tasks 1,5) ✅. The enable-time gate (`checkTwistCapacity` → `twist_addon_required`) already exists from B1; this plan fulfils it.

**Deferred to later plans:** the Flutter purchase UX that calls `POST /upgrade/twist-addons/purchase` (B7); connection capacity-add-on generalization (B3).

**Placeholder note:** mechanical webhook/Apple/endpoint bodies say "mirror the connection-add-on branch" rather than transcribing — the connection implementations are the in-repo template and the test specs pin the exact behavior. Implementers must read the connection counterpart in the same file before writing the twist branch.
