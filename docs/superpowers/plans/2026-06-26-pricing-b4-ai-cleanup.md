# Pricing B4 — AI cleanup + internal soft cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Remove every **published** AI limit and the BYOK / choose-your-model / token-billing surfaces, make the built-in assistant included on every plan with no stated limit, and replace the per-feature Free AI caps with a single **unpublished internal soft cap** (abuse protection only, never surfaced). Old clients must not break (expand→contract for any client-facing field/column).

**Architecture:** Server-first in `workers/api`, then Flutter (`apps/plot`), then a CONTRACT migration. The per-plan/per-feature `FREE_AI_LIMITS` patchwork collapses to one internal ceiling applied uniformly; the `UserAiUsage` Durable Object metering is **kept** (it feeds the internal cap) but no longer surfaced. BYOK (`ai_key` table, `/ai-keys` endpoints, runtime provider loading) and model-choice (`ai_preference` key columns, model picker) are removed — all AI uses Plot's built-in provider. Schema columns/tables stay until reads are gone, then drop in a contract migration.

**Tech Stack:** TypeScript, Cloudflare Workers (Durable Objects), Kysely (Postgres), Vitest; Flutter/Dart; Atlas (expand + contract dirs).

## Global Constraints

- **Base:** branch `pricing-model-product-changes` (B3 done @ its head). Continue on it. Worktree DB on **54333** (ambient `$DATABASE_URL` stale 54322). Verify each commit with `npx tsc --noEmit` (covers tests; eslint excludes tests). DB-backed tests need `DATABASE_URL=…54333`.
- **Two generated type files** after any schema change: `libs/db/src/types.ts` (`pnpm apply-migrations`→`pnpm types`) AND `workers/api/src/db-types.ts` (`pnpm db:types` against 54333). Commit both.
- **Expand→contract:** keep client-facing API fields (`/usage` `ai`, `/ai-preference`, `/ai-keys`) responding with safe/empty defaults so older `apps/plot` clients don't break; the destructive schema drop is a **separate contract migration** (`pnpm gen-contract-migration`, lands in `migrations-contract/`) done LAST, after reads are removed.
- **Internal soft cap:** a single unpublished ceiling (constant in code, generous — abuse-only), applied uniformly regardless of plan, **never** included in `/usage`, never in any user copy. It is NOT a stated product limit.
- **Built-in assistant** (`BUILTIN_TWIST_PACKAGE_ID`): included on all plans, 0 capacity (B1), no published limit. Removing AI gating must not block it on Free.
- **Error capture:** new catch blocks → `captureException`. **PostHog/AI provider note:** when building AI features default to the latest Claude models — but B4 REMOVES choice, so all AI routes through the existing Plot built-in provider path; do not add new model config.
- **Naming:** never reintroduce "automation" for twist add-ons. Lint+test from `workers/api`; `flutter analyze` for `apps/plot`. Commit per task.

## File structure (inventory from exploration)

- Server limits/metering: `workers/api/src/utils/ai-limits.ts` (`FREE_AI_LIMITS`, `checkAiLimit`, `checkAiLimitForContacts`, `recordAiUsage`, `isUserAiUnlimited`, `isAiEnabled`), `workers/api/src/state/user-ai-usage.ts` (DO), `workers/api/src/utils/limits.ts` (`getUsage` `ai` payload).
- Call sites (~20, grep `checkAiLimit|checkAiLimitForContacts|recordAiUsage|isAiEnabled|isUserAiUnlimited`): `app/notification-summary.ts`, `app/notification-content.ts`, `app/summary.ts`, `app/sync/{threads,notes,priorities,priority-suggestions,capture}.ts`, `queue/{updates,note-analysis,backfill-embeddings}.ts`, `state/{classify-thread,channel-router}.ts`, `twist/tools/plot/{note,search,index,thread-helpers,auto-thread}.ts`.
- BYOK + model-choice: `workers/api/src/app/ai-keys.ts` (`/ai-keys`, `/ai-preference`, team variants), `workers/api/src/utils/ai-provider.ts` (`loadBuiltinProviderConfig`), `workers/api/src/twist/factory.ts` (twist AI key resolution), `workers/api/src/twist/tools/ai.ts` (`PROVIDER_MODEL_MAP`, `selectModel`, BYOK provider config), `libs/db/schema/50-tables/99-ai-key.sql`, `99-ai-preference.sql`. The free-plan "add an API key" install gate lives in `twist/management.ts` (3 sites: `add`, `activateDraft`, and one more — grep `Add an API key in settings`).
- Flutter: `apps/plot/lib/command/settings.dart` (ChangeAiPreference, OrgAiPreferences, _AddAiProvider, _ConfigureAiProvider, _SaveAiProvider, provider dropdown), `apps/plot/lib/api/upgrade_api.dart` (`PremiumUsage`/AI usage fields).

---

### Task 1: Internal soft cap — collapse `FREE_AI_LIMITS`, drop the `/usage` AI payload

**Files:** `workers/api/src/utils/ai-limits.ts`, `workers/api/src/utils/limits.ts` (`getUsage`); tests `ai-limits.test.ts`, `limits.test.ts`.

**Interfaces — Produces:**
- `INTERNAL_AI_DAILY_CAP` (or monthly) constant — single generous unpublished ceiling.
- `checkAiLimit(...)` now enforces the internal cap **uniformly** (plan-independent); `isUserAiUnlimited` removed (or always-false internal-only). `recordAiUsage` + the `UserAiUsage` DO unchanged (still meter).
- `getUsage().personal` no longer includes `ai` (or includes it only as a back-compat stub with no limit). `PlanLimits` AI-limit fields, if any, removed.

- [ ] **Step 1:** Replace `FREE_AI_LIMITS` (per-feature/per-plan map) with one `INTERNAL_AI_DAILY_CAP` constant (pick a generous number, e.g. high four-figures/day — comment it as abuse-only, unpublished). Rewrite `checkAiLimit`/`checkAiLimitForContacts` to enforce that single cap regardless of plan (no `isUserAiUnlimited` plan bypass). Keep `recordAiUsage` + the DO. Update `ai-limits.test.ts` to assert the new uniform-cap behavior (no plan dependence; the cap is high; over-cap returns not-allowed). TDD where practical.
- [ ] **Step 2:** In `getUsage` (`limits.ts`), remove the `personal.ai` block (or return a back-compat stub with `limit: null`/unlimited). Update `limits.test.ts` and any `/usage` shape test. Keep the rest of the payload identical (connections/twists/premium).
- [ ] **Step 3:** `npx tsc --noEmit` 0; `DATABASE_URL=…54333 pnpm test ai-limits limits` green; `pnpm lint` 0. Commit: `feat(ai): single internal soft cap replaces published Free AI limits; drop /usage AI payload`.

---

### Task 2: Remove the free-plan "add an API key" AI gate at twist install

**Files:** `workers/api/src/twist/management.ts` (3 `if (effective.plan === "free") { …aiKeyCount… "Add an API key in settings…" }` blocks — grep `Add an API key in settings`); test.

- [ ] **Step 1:** Delete the three free-plan AI-key gate blocks so installing/activating an AI-using twist no longer requires a BYOK key on Free (built-in AI is included now). Leave the surrounding capacity checks (`checkTwistCapacity`) intact.
- [ ] **Step 2:** If a test asserts the gate, update/remove it; add/adjust a test that a Free user can install an AI twist without a key. `npx tsc --noEmit` 0; `DATABASE_URL=…54333 pnpm test management` green; lint 0. Commit: `feat(ai): drop the Free-plan API-key requirement for AI twists`.

---

### Task 3: Remove BYOK runtime + `/ai-keys` endpoints (all AI uses the built-in provider)

**Files:** `workers/api/src/app/ai-keys.ts`, `workers/api/src/utils/ai-provider.ts`, `workers/api/src/twist/factory.ts`, `workers/api/src/twist/tools/ai.ts`; their tests; route registration.

**HIGH-RISK — the twist runtime AI path.** The goal: every AI call (built-in features + twists) routes through Plot's built-in provider; no user-supplied keys, no per-user provider config.

- [ ] **Step 1:** In `tools/ai.ts`, remove the BYOK provider-config branch and `PROVIDER_MODEL_MAP`/`selectModel`'s BYOK paths so it always uses the Plot built-in provider (the existing default/`AIDisabledStub`-free path). Keep the model-tier selection that the built-in provider already uses. Verify the twist AI tool still constructs + runs against the built-in provider.
- [ ] **Step 2:** In `factory.ts` + `ai-provider.ts`, remove `loadBuiltinProviderConfig`/twist-AI-key resolution; the runtime always passes the built-in provider config. Remove `twist_ai_disabled`/BYOK effective-plan logic.
- [ ] **Step 3:** `/ai-keys` + team `/ai-keys` endpoints (`ai-keys.ts`): keep the **GET** routes returning an **empty list** (expand→contract: older Flutter calls them on settings open) and make POST/DELETE no-ops or 410; OR if no client calls survive after Task 4's Flutter removal, remove them — but since older clients exist, prefer returning empty/neutral responses this task and delete the file in the contract step (Task 6). The `AI_KEY_ENCRYPTION_KEY` env becomes unused (note it; don't rotate here).
- [ ] **Step 4:** Tests: twist AI runs via built-in provider with no key; `/ai-keys` GET returns empty; no path reads `ai_key`. `npx tsc --noEmit` 0; `DATABASE_URL=…54333 pnpm test ai factory tools` (+ the twist runtime tests) green; lint 0. Commit: `feat(ai): remove BYOK runtime; all AI uses the built-in provider; /ai-keys returns empty`.

---

### Task 4: Remove model-choice + `ai_preference` key reads

**Files:** `workers/api/src/app/ai-keys.ts` (`/ai-preference`), anything reading `ai_preference.builtin_ai_key_id`/`twist_ai_key_id`; test.

- [ ] **Step 1:** Remove model-/provider-selection reads of `ai_preference` (builtin_ai_key_id, twist_ai_key_id). Keep `/ai-preference` GET responding (back-compat) with the key fields as `null` and any remaining real prefs (e.g. an on/off toggle if kept) intact; POST stops accepting key selection. Don't drop the columns yet (Task 6).
- [ ] **Step 2:** Tests + `npx tsc --noEmit` 0; `DATABASE_URL=…54333 pnpm test` green; lint 0. Commit: `feat(ai): remove choose-your-model; ai_preference key fields no longer read`.

---

### Task 5: Flutter — remove BYOK/model settings UI + AI usage display

**Files:** `apps/plot/lib/command/settings.dart`, `apps/plot/lib/api/upgrade_api.dart`.

- [ ] **Step 1:** Remove `ChangeAiPreference`, `OrgAiPreferences`, `_AddAiProvider`, `_ConfigureAiProvider`, `_SaveAiProvider`, and the provider/model dropdowns from settings. Remove the AI-usage meter display (the `/usage` `ai` consumer) and the BYOK/model fields from `upgrade_api.dart` (parse defensively — tolerate the server still sending stub fields). Keep settings otherwise intact.
- [ ] **Step 2:** `cd apps/plot && flutter analyze` clean; adjust/remove affected widget tests. Commit: `feat(ai): remove BYOK + model-choice settings UI and AI usage meter (apps/plot)`.

---

### Task 6: Contract migration — drop `ai_key` + `ai_preference` key columns

**Files:** `libs/db/schema/50-tables/99-ai-key.sql` (delete), `99-ai-preference.sql` (drop key columns); contract migration; both type files.

- [ ] **Step 1:** Remove the `ai_key` table schema file and the `builtin_ai_key_id`/`twist_ai_key_id` (+ any BYOK-only) columns from `99-ai-preference.sql`. **First** add a data step nulling `ai_preference` FK references if needed.
- [ ] **Step 2:** `pnpm gen-contract-migration -- drop_ai_key_byok` (destructive DDL → `migrations-contract/`). `pnpm apply-migrations`. Regenerate BOTH type files (`pnpm types` + `cd workers/api && pnpm db:types`). `pnpm diff-schema-migrations` clean; `pnpm --filter @plotday/db run lint`.
- [ ] **Step 3:** `npx tsc --noEmit` 0 (no code references the dropped columns); full `DATABASE_URL=…54333 pnpm test` green. Commit (schema + contract migration + atlas.sum + both type files): `feat(db): contract — drop ai_key table and BYOK ai_preference columns`.

---

## Self-Review

**Spec coverage (Areas 3 + 4):**
- Per-feature Free AI limits removed; built-in assistant no published limit → Task 1. ✅
- Internal unpublished soft cap (metering kept, not surfaced) → Task 1. ✅
- Free-plan API-key gate for AI twists removed → Task 2. ✅
- BYOK storage + settings UI + runtime path removed → Tasks 3, 5, 6. ✅
- Choose-your-model removed → Tasks 4, 5, 6. ✅
- Token/usage billing & budgets surfaces removed (the `/usage` AI meter + Flutter display) → Tasks 1, 5. ✅
- Expand→contract for client-facing fields (`/usage` ai, `/ai-preference`, `/ai-keys` kept responding; columns dropped last) → Tasks 1, 3, 4, 6. ✅
- Built-in assistant included everywhere, 0 capacity (B1) → enforced by removing gates (Task 2) + uniform cap (Task 1). ✅

**Risk callouts:** Task 3 is the highest-risk (live twist-AI runtime) — verify the built-in provider path end-to-end (a twist that calls AI still works with no key). Task 6 is destructive — runs only after all reads are gone (Tasks 3–4) and behind the contract-migration soak per `libs/db/AGENTS.md`.

**Open nuance (flag, not blocking):** the exact internal soft-cap number is a product call — pick a generous default and note it for the user to tune; it is never surfaced so changing it later is safe.
