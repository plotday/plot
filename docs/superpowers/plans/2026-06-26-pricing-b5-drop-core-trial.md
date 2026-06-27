# Pricing B5 — Drop Core + connections-only trial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Drop the **Core** plan from the product, and replace the old "30-day Core trial" for new users with **30 days of unlimited connections on Free** (a `trial_ends_at`-gated, connections-only grant — twist capacity and import history stay Free). No Core subscribers to migrate (none paying); any `plan='core'` row (all trials) is data-migrated to `'free'` keeping its `trial_ends_at`.

**Architecture:** Server-only (`workers/api`) + one welcome-thread copy migration + a data migration. We **stop using `'core'` in application code** (remove it from `PlanKey`/`PLAN_LIMITS` and every `"free"|"core"|"pro"|"team"` annotation) and **map any legacy `'core'` to `'free'` at the read boundary** (`getPersonalPlan`/`getEffectivePlan`). We **leave the `'core'` value in the DB `subscription_plan` enum** (vestigial — Postgres enum-value removal requires recreating the type; not worth it for a dead value). The new-user trial is a **Free** subscription (`free_monthly`) with `trial_ends_at` set; during the window the **connection pool is unlimited** (only connections — twistCapacity stays 1, syncHistory 7). At expiry, connections beyond the Free pool of 2 are trimmed (keep-oldest, B3's trimmer).

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely, Vitest, Atlas (a data migration in `migrations/`).

## Global Constraints

- **Base:** branch `pricing-model-product-changes` (B4 done @ its head). Continue on it. Worktree DB **54333** (ambient `$DATABASE_URL` stale 54322). Verify each commit with `npx tsc --noEmit` (covers tests). Schema/data migration → regenerate BOTH `libs/db/src/types.ts` and `workers/api/src/db-types.ts`; commit both.
- **Trial grant (verbatim, user decision):** **unlimited connections ONLY** for 30 days on Free. NOT full Pro: `twistCapacity` stays 1, `syncHistoryDays` stays 7. Implemented via `trial_ends_at` on a Free subscription (no new plan enum value).
- **Core handling (verbatim):** no paying Core users; data-migrate `plan='core'` → `'free'` (keep `trial_ends_at`). Leave `'core'` in the DB enum (vestigial). Retire `core_monthly` Stripe/Apple products is MANUAL (already in the ops checklist `2026-06-26-pricing-billing-product-setup.md`) — NOT this plan.
- **Read-boundary mapping:** `getPersonalPlan`/`getEffectivePlan`/team-plan reads must coerce a stray `'core'` to `'free'` so `PLAN_LIMITS[plan]` never indexes a missing key.
- **Trim on expiry:** use `selectConnectionsToTrim` (B3, keep-oldest) with the Free connection budget. Reuse the existing trial-expiry path in `utils/trial.ts`.
- Naming/error rules unchanged. Lint+test from `workers/api`. Commit per task.

## File structure

- `workers/api/src/utils/limits.ts` — `PlanKey` (drop `core`), `PLAN_LIMITS` (drop `core` row), `getPersonalPlan`/team reads (map `core`→`free`), the connection-pool reads (trial-aware), `getBillableConnectionAddonCount`, `getUsage`.
- `workers/api/src/utils/plan.ts` — `getEffectivePlan` (`"free"|"core"|"pro"|"team"` → drop core / map).
- `workers/api/src/apple/iap.ts` — `IAP_PRODUCT_TO_PLAN` (drop `core_monthly`), the `"free"|"core"|"pro"` annotations.
- `workers/api/src/app/upgrade.ts` — `planFromLookupKey` (drop `core`).
- `workers/api/src/stripe/stripe.ts` — `validPlans` (drop `core`), trial detection (`:656-657`).
- `workers/api/src/stripe/utils.ts` — `createInitialTrialSubscription` (Free trial, not core).
- `workers/api/src/app/account.ts` — activation (`plan: "free"` + `trial_ends_at`).
- `workers/api/src/utils/trial.ts` — `expireTrial` (guard on `trial_ends_at` not `plan==='core'`; trim connections).
- `libs/db/migrations/` — a data migration `UPDATE user_subscription SET plan='free' WHERE plan='core'`.
- `libs/db/schema/.../welcome` or a new migration — welcome-thread copy.
- Tests across the above.

---

### Task 1: Trial-aware connection pool (Free + active trial → unlimited connections only)

**Files:** `workers/api/src/utils/limits.ts`; test.

**Interfaces — Produces:**
- A helper `personalConnectionPool(db, userId): Promise<number>` (or fold into existing reads) = `Infinity` when the user's `user_subscription.trial_ends_at > now()` (regardless of plan, but plan is Free during trial), else `PLAN_LIMITS[plan].connections`. Twist capacity + sync history are NOT affected by the trial.
- `checkChannelConnectionLimit` (personal regular branch), `getBillableConnectionAddonCount` (personal), and `getUsage` (personal connections limit) use this trial-aware pool.

- [ ] **Step 1:** Write failing DB-backed tests: a Free user with `trial_ends_at` in the future can enable a 3rd+ regular connection (pool effectively ∞ → `allowed:true`, no `addon_required`); the SAME user with `trial_ends_at` in the past (or null) hits the Free pool of 2 (`addon_required` on the 3rd). `getBillableConnectionAddonCount` returns 0 over-pool term during an active trial. `getUsage` reports the connection limit as unlimited (`null`) during trial.
- [ ] **Step 2:** Implement the trial-aware pool. Fetch `trial_ends_at` alongside `plan` where the pool is read (avoid an extra round-trip — extend the existing `getPersonalPlan` query or add a small `getPersonalConnectionContext` returning `{ plan, trialActive }`). `pool = trialActive ? Infinity : PLAN_LIMITS[plan].connections`. Thread it through `checkChannelConnectionLimit`, `getBillableConnectionAddonCount`, `getUsage`. Do NOT touch twistCapacity/syncHistory.
- [ ] **Step 3:** `npx tsc --noEmit` 0; `DATABASE_URL=…54333 pnpm test limits` green; lint 0. Commit: `feat(limits): 30-day trial grants unlimited connections on Free (connections only)`.

---

### Task 2: New-user trial rework (Free trial, not Core; expiry trims connections)

**Files:** `workers/api/src/stripe/utils.ts` (`createInitialTrialSubscription`), `workers/api/src/app/account.ts` (activation), `workers/api/src/utils/trial.ts` (`expireTrial`/reminder), `workers/api/src/stripe/stripe.ts` (trial detection `:656-657`); tests.

**Interfaces:**
- `createInitialTrialSubscription` creates a **Free** trial: price `free_monthly` (the usage tracker), `trial_period_days: 30`, metadata `{ plan: "free" }`, same `trial_settings`/`payment_settings` shape. (Or keep a paid-on-convert flow if desired — but the trial grants only connections, so a Free tracker sub + `trial_ends_at` is the model.)
- `account.ts` activation inserts `user_subscription` with `plan: "free"` + `trial_ends_at = now()+30d`.
- `trial.ts` `expireTrial` guards on **`trial_ends_at` present and elapsed** (NOT `plan === 'core'`); on expiry it trims connections beyond the Free pool (2) via `selectConnectionsToTrim` (keep-oldest), clears the trial grant (leave `trial_ends_at` as a past marker or null it), and does NOT change plan (already `'free'`). The "trial ending" reminder copy is updated to the connections framing.
- `stripe.ts` trial detection (`:656-657`, currently `metadata.plan === 'core' || subscription.trial_end`) → key off `subscription.trial_end`/`trial_ends_at` only.

- [ ] **Step 1:** Failing tests: a newly-activated user has `plan='free'` + `trial_ends_at` ~30d out (not `'core'`); `expireTrial` on a Free user whose `trial_ends_at` elapsed trims connections beyond 2 (keep oldest) and leaves `plan='free'`; the trial detection no longer depends on `'core'`.
- [ ] **Step 2:** Implement. Reuse `selectConnectionsToTrim` from `limits.ts`. Keep `captureException` on unexpected errors.
- [ ] **Step 3:** `npx tsc --noEmit` 0; `DATABASE_URL=…54333 pnpm test trial account stripe` green; lint 0. Commit: `feat(trial): new users get a 30-day connections trial on Free (replaces Core trial)`.

---

### Task 3: Drop `core` from application code + data-migrate existing rows

**Files:** `workers/api/src/utils/limits.ts` (`PlanKey`, `PLAN_LIMITS`, reads), `utils/plan.ts`, `apple/iap.ts`, `app/upgrade.ts`, `stripe/stripe.ts`, plus any test seeds using `'core'`; a data migration.

**Interfaces:**
- `PlanKey = "free" | "pro" | "team"` (no `core`); `PLAN_LIMITS` has no `core` row. Every `"free"|"core"|"pro"|"team"` annotation drops `core`. `getPersonalPlan`/`getEffectivePlan`/team-plan reads **map a stray `'core'` → `'free'`** (defensive: `(sub.plan === 'core' ? 'free' : sub.plan)`), so a legacy DB value never indexes a missing `PLAN_LIMITS` key. `IAP_PRODUCT_TO_PLAN` drops the `core_monthly` entry; `planFromLookupKey` drops the `core` branch; `stripe.ts` `validPlans` drops `core`.

- [ ] **Step 1:** Remove `core` from `PlanKey` + `PLAN_LIMITS`. `npx tsc --noEmit` will now flag EVERY remaining `core` reference — walk them: drop `core` from each union annotation; in plan-READ sites (`getPersonalPlan`, `getEffectivePlan`, team reads, `stripe.ts` plan parse) coerce `'core'`→`'free'` so the cast stays valid and legacy rows are safe. Remove the `core_monthly` IAP map entry + `planFromLookupKey` core branch + `validPlans` core. Update any test that seeds `plan:'core'` (change to `'free'`/`'pro'` as appropriate, or — for trial tests — `'free'` + `trial_ends_at`).
- [ ] **Step 2:** Data migration: `pnpm gen-migration -- migrate_core_subscriptions_to_free` then add (or let Atlas no-op the schema and hand-add the data step) `UPDATE user_subscription SET plan='free' WHERE plan='core'; UPDATE team_subscription SET plan='free' WHERE plan='core';` in the generated migration. (No schema DDL — the enum value stays.) `pnpm apply-migrations`; regenerate both type files. Note: `db-types.ts` `SubscriptionPlan` will STILL list `'core'` (enum unchanged) — that's expected and harmless; the app-level `PlanKey` is the one without it.
- [ ] **Step 3:** `pnpm diff-schema-migrations` clean; `pnpm --filter @plotday/db run lint`; `npx tsc --noEmit` 0 (no remaining `core` in app types); `DATABASE_URL=…54333 pnpm test` green; lint 0. Commit (code + data migration + both type files): `feat(plans): drop Core from application code; migrate core rows to free`.

---

### Task 4: Welcome-thread copy → connections trial

**Files:** a new migration updating the welcome-thread note copy (the latest is `libs/db/migrations/20260501014946_update_welcome_thread_copy.sql`; mirror its UPDATE pattern); optionally a `docs/updates.d/` fragment.

- [ ] **Step 1:** Add a migration that updates the welcome-thread note copy from the old "Core plan free for 30 days … up to 5 connections and 2 twists … archived" framing to the new: *30 days of unlimited connections on Free; after 30 days you continue on Free with up to 2 connections (extras stay if you add a $5/mo connection add-on, or upgrade to Pro).* Keep it plain-language, sentence case. Find the note by its stable key/`source` (the prior migrations UPDATE by a key — reuse it).
- [ ] **Step 2:** `pnpm apply-migrations`; regen types if the migration is data-only it still runs. `pnpm diff-schema-migrations` clean. Add a `docs/updates.d/` fragment ("New: start with 30 days of unlimited connections"). Commit: `feat(onboarding): welcome-thread copy for the connections trial`.

---

## Self-Review

**Spec coverage (Area 5 + the trial decision):**
- Drop Core: `PlanKey`/`PLAN_LIMITS`/annotations/IAP/lookup/stripe → Task 3; data-migrate rows → Task 3 Step 2; enum value left vestigial (documented). ✅
- New-user trial = Free + 30-day unlimited connections only → Tasks 1, 2. ✅
- Trial expiry trims connections (keep-oldest) → Task 2. ✅
- Welcome thread updated → Task 4. ✅
- `core_monthly` product retirement is manual (ops checklist), not code. ✅ (noted)

**Deferred / out of scope:** dropping the `'core'` enum value from the DB (vestigial, kept); `apps/site`'s `plans.ts` Core entry (the site is integrated + handled in the site step, after B7); the `core_monthly` Stripe/Apple product retirement (manual).

**Risk:** Task 3 is broad (tsc-driven sweep across ~7 files). The read-boundary `core→free` coercion is the safety net for any legacy/vestigial `'core'` value. Task 1's trial-aware pool must NOT leak into twistCapacity/syncHistory (connections only).
