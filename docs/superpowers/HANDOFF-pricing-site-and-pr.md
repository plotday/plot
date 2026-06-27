# Handoff prompt — finish the pricing model: site integration + PR

> Paste everything below the line into a fresh agent. It is self-contained.

---

You are taking over the **pricing-model product/billing change** for Plot. The server + Flutter implementation is DONE on a worktree branch; your job is to finish the **deferred polish**, do the **`apps/site` integration + upgrade-page rework**, and **open a PR** — leaving clearly-flagged user-owned items (manual product creation, live billing verification) for the human.

## Start here (orientation — read before touching anything)

- **Worktree (work here):** `/Users/kris.braun/code/plot/.claude/worktrees/pricing-model-product-changes`, branch `pricing-model-product-changes`, current HEAD `45414d8a3`. **Do not work in the main repo** except to read/commit the docs noted below.
- **This branch is based on an UNMERGED branch:** `independent-usage-based-addons` @ `7b7ea1845` (the "add-ons build", Plans 1–3 — standalone Stripe connection-add-on billing). The pricing work sits on top of it. So this branch's eventual PR **depends on** the add-ons branch merging first or together. `main` is ~17 commits ahead of that base.
- **Durable progress ledger (READ THIS FIRST):** `<worktree>/.superpowers/sdd/progress.md` — a complete task-by-task record of B1–B5 + B7 with every commit, every review finding, and every fix. It is the source of truth for what was done and why.
- **Memory:** the project memory `project_pricing_model_product_changes.md` (in `~/.claude/projects/.../memory/`) has the condensed state + all locked decisions.
- **Specs + plans (CURRENTLY UNTRACKED in the MAIN repo working tree — commit them):**
  - Specs: `docs/superpowers/specs/2026-06-26-pricing-model-product-changes-design.md` (Spec B — the product/billing design you're finishing), `2026-06-26-pricing-page-rewrite-design.md` (Spec A — marketing page), `2026-06-26-pricing-billing-product-setup.md` (the manual ops checklist), `2026-06-25-independent-usage-based-add-ons-design.md`.
  - Plans: `docs/superpowers/plans/2026-06-26-pricing-b{1,2,3,4,5,7}-*.md`.
  - These were authored during implementation but never committed. **First task: copy them into the worktree and commit them to the branch** so the PR carries its own design docs.

## What's already DONE (do not redo — it's reviewed and green)

All of Spec B's server + client, in 38 commits (`7b7ea1845..45414d8a3`), each built TDD + per-task-reviewed + **opus whole-branch-reviewed**, all findings fixed:

- **B1** weighted twist capacity: `twist.capacity_weight`, `PLAN_LIMITS.twistCapacity` (Free 1 · Pro 10 · Team 10/50-block; Pro/Team no longer "unlimited twists"), `checkTwistCapacity` at install (built-in assistant weight 0).
- **B2** twist-add-on billing: generalized `stripe/addons.ts` by add-on kind; `twist_addon_monthly` standalone Stripe sub (usage-synced) + Apple `twist_addon_1/2/3` tiers; `POST /upgrade/twist-addons/purchase` (`{teamId?, candidateWeight?}`); reconcile-down on twist removal. **`twist_addon_count` + `stripe_twist_addon_subscription_id` + `apple_twist_addon_*` columns.**
- **B3** connection capacity (web): a regular connection beyond the pool returns `addon_required` (not a hard block); `getBillableConnectionAddonCount = max(0, regular−pool) + addonRequired`; `selectConnectionsToTrim` flipped to **keep-oldest**; reconcile fires on any disable.
- **B4** AI cleanup: single uniform unpublished internal cap (`INTERNAL_AI_CAP`, no published limit), BYOK + choose-model + token billing removed, `ai_key` table dropped (contract migration), Flutter AI settings UI removed. Built-in assistant included everywhere.
- **B5** drop Core + connections-only trial: `core` removed from app `PlanKey`/`PLAN_LIMITS` (DB enum value left vestigial, `core→free` mapped at every read boundary), data migration `plan='core'→'free'`; new-user trial = Free + 30-day `trial_ends_at` **unlimited-connections-only** grant (twist capacity & history stay Free); `free_monthly` trial Stripe sub; welcome/expiry copy updated.
- **B7** Flutter purchase UX: `BuyTwistAddonCommand`, `twist_addon_required` 403 routing (echoes `candidateWeight`), connection-capacity offer (premium→add-on both platforms; regular-beyond-pool→ web "add-on OR Pro" / App Store Pro-only), twist-capacity offer, usage display (twist capacity + add-ons, "of unlimited" connections during trial/Pro), Core option + AI dead-code removed.

**Verification baseline:** server `npx tsc --noEmit` 0, `pnpm test` ~936 green; `flutter analyze lib` whole-app clean.

## Locked product decisions (do not relitigate — honor in the site work)

- **Naming:** the paid add-ons are **"connection add-on" ($5/mo)** and **"twist add-on" (+20 twists, $10/mo)**. **NEVER use "automation" in code or UI** — "automation" is reserved for the marketing pricing page (Spec A) only, used before a reader knows the word "twist".
- **Two billable add-ons, symmetric:** web/Stripe = usage-synced (confirm-charge on enable, auto-credit on drop); Apple = tiered (`addon_1/2/3`, `twist_addon_1/2/3`).
- **Connection capacity offer:** regular connection beyond the pool → **web/non-App-Store: "$5 connection add-on OR upgrade to Pro"**; **App Store: upgrade to Pro only** (Apple has no connection-capacity add-on; its `addon_1/2/3` tiers are reserved for the always-required premium connectors LinkedIn/IG/WhatsApp). Twist over-capacity → "twist add-on OR Pro" (Apple DOES have twist tiers).
- **Core:** dropped; no paying subscribers (Core was a Stripe reverse-trial). Replaced by the connections-only Free trial. The DB enum value `'core'` is intentionally kept vestigial.
- **Apple prices (US base, set in App Store Connect):** Pro `$24.99` (unchanged — annual is the real target, no Apple annual); `addon_1/2/3` `$5.99/$11.99/$17.99`; `twist_addon_1/2/3` `$11.99/$23.99/$35.99`. Basis: lowest `.99` ≥ web×1.15. **Stripe prices** (by lookup key): `addon_monthly` $5, `twist_addon_monthly` $10, plus existing `pro_*`/`team_*`/`free_monthly`.

## Your work

### Phase 0 — set up + commit the docs
1. Confirm you're in the worktree on `pricing-model-product-changes`. **DB is on port 54333** (ambient `$DATABASE_URL` is STALE = main's 54322 — always `export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54333/postgres"` before any DB/test command). The Flutter toolchain IS already set up (`flutter pub get` + `build_runner` were run) so `flutter analyze` is meaningful.
2. Copy the untracked specs + plans from the main repo working tree (`/Users/kris.braun/code/plot/docs/superpowers/{specs,plans}/2026-06-2{5,6}-pricing-*.md` and the add-ons design + `2026-06-26-addons-1-*.md`) into the worktree's `docs/superpowers/...` and commit them on the branch: `docs(pricing): spec + implementation plans for the pricing model change`. Also bring the ops checklist `2026-06-26-pricing-billing-product-setup.md`.

### Phase 1 — deferred B7 polish (small, optional-but-nice; all recorded in the ledger)
Apply these in `apps/plot/lib/command/upgrade.dart` (mirror the existing patterns; `flutter analyze` the changed files clean; one commit):
- **Live App Store prices in the add-on confirm modals.** Both `BuyAddonCommand` (connection) and `BuyTwistAddonCommand` (twist) hardcode the WEB price in the confirm modal ("$5/month", "$10/month") even on App Store, where Apple charges the tier price ($6.99…/$12.99…). Use the live StoreKit price for the App-Store confirm: `IapService.instance.productFor(kIap{Addon,TwistAddon}ProductForCount[current+1])?.price` (the plan-upgrade path already does this via `_livePlanPrice`). Keep the web/Stripe confirm showing the $5/$10 web price.
- **(Minor) `BuyPlanCommand`** still accepts `plan: 'core'` (dead, maps to Pro) — tighten the type/assert so a stray `'core'` can't mispurchase.
- **(Minor)** the twist usage suffix has a dead "of unlimited" branch (`twists.limit` is never null) — drop it or confirm intent.

### Phase 2 — site integration (the main job)
The marketing **pricing page** (Spec A) is already done on branch **`feature/new-pricing`** (it changed `apps/site/app/lib/plans.ts`, `routes/pricing.tsx`, `pricing.module.css`, `routes/twists.tsx`; merge-base with main `9ef1f5f68`). The **`apps/site/app/routes/upgrade.tsx`** checkout/account page is still the OLD version on this branch and needs reworking.

1. **Integrate the branches.** Bring `feature/new-pricing` and the latest `main` into `pricing-model-product-changes` (merge or rebase — your call; merge is safer given the shared base). Expect a **`plans.ts` conflict**: `feature/new-pricing` rewrote it for the new page (Free/Pro/Team, à-la-carte note, `ADDON_PRICE`), while Spec B says the `PLAN_LIMITS`-mirror in `plans.ts` is updated in this PR. Reconcile: keep the page rewrite, drop `core`, and sync the numeric mirror to the server's `PLAN_LIMITS` (Free 2 conn / 1 twist, Pro ∞ / 10, Team 50-block / 10-per-block) and add the **twist add-on** ($10/mo) alongside the connection add-on ($5/mo). Per `plans.ts`'s own header note, the API mirror is updated here.
   - ⚠️ Spec A's Free card line "Up to 2 connections ($5/mo each beyond)" is correct for **web** (add-on OR Pro), per the rev-2 decision. Make sure the page reflects "$5/mo connection add-on **or** upgrade to Pro" framing, and add a line about **twist add-ons** ($10/mo for +20) matching the new capacity model. (Confirm final wording with the human if unsure — the page is marketing-sensitive.)
2. **Rework `apps/site/app/routes/upgrade.tsx`** per Spec B Area 6 + the add-ons design's "Site changes → upgrade.tsx" section. Current state to fix: it has a 0–N **add-on quantity stepper** posting to the OLD `POST /upgrade/addons` endpoint, a `'core'` plan in `handleCheckout`/`planParam`, and no twist-add-on surface. Target:
   - **Remove the add-on quantity stepper.** Add-ons are usage-synced now — show an **informational summary** (active connection add-ons + monthly cost, active twist add-ons + cost) and **card management**; the first add-on is created via the Checkout-session card capture (the add-ons build added `createAddonCheckoutSession` server-side). Do not POST a manual quantity.
   - **Remove `core`** from the plan options/params (keep Free/Pro/Team).
   - **Add the twist-add-on surface** (informational + the `?twist_addon=` return handling, parallel to `?addon=`).
   - Use the new server endpoints/return params; do not call the retired `POST /upgrade/addons` quantity endpoint. (Check whether the add-ons build already removed it server-side; if not, that retirement may belong here.)
   - Verify: `cd apps/site && pnpm lint` (or the site's typecheck/build) clean.
3. **Sweep `apps/site` for stale `core`** references and the old add-on/AI framing; fix any.

### Phase 3 — finalize + PR
1. Run `/finalize` (the project finalization skill): `pnpm lint` in changed packages (`workers/api`, `apps/site`), `flutter analyze` for `apps/plot`, backwards-compat check, `captureException` on new catch blocks, `docs/updates.d/` fragments for user-facing changes (several were added during implementation — verify), and the public-submodule note (no `public/` changes were needed here; B6 SDK `capacity_weight` was deferred — the column exists server-side, builder-declaration via the SDK is a separate future PR).
2. Run the full server suite (`cd workers/api && DATABASE_URL=…54333 pnpm test`) and confirm green (one or two pre-existing parallel-DB-isolation flakes exist — `note-link`/`mute`/`save-contact-group`/`link*`; they pass in isolation; don't chase them).
3. **Open the PR** with `gh`. The PR body MUST:
   - Summarize the model (Free/Pro/Team, connection + twist add-ons, weighted twist capacity, AI cleanup, Core dropped + connections trial).
   - **Flag the dependency:** this branch is based on the unmerged `independent-usage-based-addons` branch — it must merge first or together (note its PR/branch).
   - **Flag the USER-OWNED prerequisites that block real billing** (these cannot be done by an agent — they're manual dashboard work, per `docs/superpowers/specs/2026-06-26-pricing-billing-product-setup.md`):
     - Create Stripe `twist_addon_monthly` ($10) + verify `addon_monthly` ($5); create Apple `twist_addon_1/2/3` and verify `addon_1/2/3`; retire `core_monthly` after the trial rework ships.
     - **Live verification** still needed: a Stripe **test-clock** run confirming the $0 `free_monthly` 30-day trial fires `customer.subscription.deleted` → `expireTrial` (NON-blocking — entitlement reverts via the live `trial_ends_at` check regardless; only the proactive trim + expiry note depend on it). StoreKit **sandbox** for the new Apple tiers.
   - End with the standard Claude Code attribution.

## Process + harness gotchas (learned the hard way this session)

- **Use subagent-driven-development** for the multi-step phases (fresh implementer per task, per-task review, then an **opus whole-branch review** before the PR — the whole-branch reviews caught a real, per-task-invisible bug in B2, B3, AND B5; do not skip the final opus review).
- **The harness emits STALE `<system-reminder>` diagnostics** mid-edit (TDD red-phase snapshots, and recurring false `stripe_twist_addon_subscription_id`/`as PlanKey` "errors"). **Never trust them — always verify the committed HEAD yourself** with `npx tsc --noEmit` (server; it typechecks tests too, unlike `pnpm lint` which is `tsc && eslint` but eslint excludes tests) and `flutter analyze` (Flutter). I was misled repeatedly until I started verifying every HEAD directly.
- **Two generated DB type files** after any schema change: `libs/db/src/types.ts` (`pnpm apply-migrations`→`pnpm types`) AND `workers/api/src/db-types.ts` (`pnpm db:types` against 54333). Commit both. Contract (destructive) migrations go in `migrations-contract/` via `pnpm gen-contract-migration`.
- **`as PlanKey` on a DB plan value is unsound** (the DB type still includes `'core'`) — that's how two crash sites slipped past tsc in B5. Any new DB→PlanKey read must map `'core'→'free'`.
- Commit per task; keep `<worktree>/.superpowers/sdd/progress.md` updated as a recovery ledger (survives context compaction).

When done, report: the integration commits, the upgrade.tsx rework, the deferred-polish commit, the PR URL, and a crisp list of the user-owned items still blocking go-live.
