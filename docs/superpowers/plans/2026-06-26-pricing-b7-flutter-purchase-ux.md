# Pricing B7 — Flutter purchase/upgrade UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extend the `apps/plot` purchase/upgrade UX to the new pricing model: a **twist-add-on** purchase flow (mirroring connection add-ons), the **connection-capacity** offer (regular connection beyond the pool → "$5 add-on or upgrade to Pro" on web, "Pro only" on App Store), twist-capacity in the usage display, and removal of the dropped **Core** plan + B4 AI dead code from the client.

**Architecture:** All in `apps/plot/lib`. The server (this branch) already returns `PlanLimitError` 403s with `reason ∈ {connection_limit, addon_required, twist_addon_required}` + JSON `{ reason, plan, current_count, limit, is_team, is_admin, team_id, candidate_weight? }`, and exposes `POST /upgrade/addons/purchase` (connection, +1) and `POST /upgrade/twist-addons/purchase` (`{ teamId?, candidateWeight? }`). The existing connection-add-on scaffold — `BuyAddonCommand` (`command/upgrade.dart:157`), `UpgradeApi.purchaseAddon` (`api/upgrade_api.dart:305`), `IapService.buyAddon` + `kIapAddonProductForCount` (`api/iap_api.dart:25,244`) — is the template; B7 adds the twist-add-on parallel and the new offer branching. App-Store-vs-web is `UpgradeUi.isAppStoreBuild` (`api/upgrade_api.dart:28`).

**Tech Stack:** Flutter/Dart, flutter_bloc, forui (no `material.dart`), `in_app_purchase` (StoreKit 2). Verify with `flutter analyze` (toolchain is set up in this worktree; changed files must be clean) and, for purchase-flow behavior, the `run-app` skill where warranted.

## Global Constraints

- **Base:** branch `pricing-model-product-changes` (B5 done @ `2475cbc8e`). The Flutter toolchain IS set up (`flutter pub get` + `build_runner build` already run); `flutter analyze <file>` is meaningful. Re-run `build_runner` only if you change a `@JsonSerializable`/drift/route-annotated class.
- **Decision (locked):** connection capacity offer — **web/non-App-Store:** regular-beyond-pool → "$5/mo connection add-on OR upgrade to Pro" (both); **App Store:** regular-beyond-pool → **upgrade to Pro only** (Apple has no connection-capacity add-on; the `addon_1/2/3` Apple tiers are reserved for the always-required premium connectors). Premium connectors (LinkedIn/IG/WhatsApp) → connection add-on on both platforms (Apple uses `addon_1/2/3`).
- **Twist add-on:** +20 twists, $10/mo (web usage-synced) / Apple tiers `twist_addon_1/2/3`. On a `twist_addon_required` 403, the client echoes the error's `candidate_weight` to `POST /upgrade/twist-addons/purchase`. User-facing wording: **"twist add-on" / "+20 twists"** — NEVER "automation". App Store: auto-present the next `twist_addon_{active+1}` tier (mirror connection add-on tier logic), cap 3.
- **Core is gone:** remove `kIapProductCoreMonthly` usage, the `'core'` branch in `BuyPlanCommand`/`plansFor()`, and any core plan card — only `free`/`pro`/`team` remain (defensive parse of a legacy `'core'` from older servers → treat as `free`/`pro` per existing code, but don't OFFER core).
- **No AI meter** (B4 removed it server-side) — remove the dead `hasAiKeys` (`widget/twist_details.dart`) and `adminOrgs` (`state/subscription_service.dart`) while here.
- forui only; sentence case; use the project `Modal`/`ConfirmModal`/`CommandModal` framework; desktop cursor (no web pointer on tap targets). Guard concurrent purchases (mirror `_addonPurchaseInFlight`). Commit per task.

## File structure

- `apps/plot/lib/api/iap_api.dart` — twist-add-on product IDs + `buyTwistAddon`; drop core product usage.
- `apps/plot/lib/api/upgrade_api.dart` — `ApiException.candidateWeight` + `twist_addon_required`; `purchaseTwistAddon`; usage models (twist capacity).
- `apps/plot/lib/command/upgrade.dart` — `BuyTwistAddonCommand`; the connection-capacity "add-on or Pro" branching; remove `'core'`.
- `apps/plot/lib/command/twist.dart` — route `twist_addon_required` (twist install) + regular-beyond-pool `addon_required` to the right command; `_usageSuffix` twist capacity + add-ons.
- `apps/plot/lib/widget/twist_details.dart`, `apps/plot/lib/state/subscription_service.dart` — dead-code removal.

---

### Task 1: API/IAP plumbing — twist-add-on endpoint, product IDs, `candidateWeight`

**Files:** `api/upgrade_api.dart`, `api/iap_api.dart`; their tests if present.

**Interfaces — Produces:**
- `ApiException.candidateWeight: int?` parsed from the 403 body `candidate_weight`; `ApiException.isTwistAddonRequired => reason == 'twist_addon_required'`.
- `UpgradeApi.purchaseTwistAddon({ String? teamId, int? candidateWeight }): Future<AddonPurchase>` → `POST /upgrade/twist-addons/purchase` body `{ teamId?, candidateWeight? }`, parses `{ ok, twist_addons?, checkout_url? }` (reuse/extend `AddonPurchase`; map `twist_addons`→`addons`).
- `kIapTwistAddonProductForCount = {1:'day.plot.app.twist_addon_1', 2:'day.plot.app.twist_addon_2', 3:'day.plot.app.twist_addon_3'}`; `kIapMaxTwistAddons = 3`; `IapService.buyTwistAddon(int count)` (mirror `buyAddon`); add the 3 IDs to `_kAllProductIds` so StoreKit loads them.

- [ ] **Step 1:** In `api/upgrade_api.dart`, add `candidateWeight` (parse `json['candidate_weight'] as int?`) + `isTwistAddonRequired` to `ApiException`. Add `purchaseTwistAddon(...)` mirroring `purchaseAddon` (`:305`), POSTing to `/upgrade/twist-addons/purchase` with `candidateWeight` in the body when non-null.
- [ ] **Step 2:** In `api/iap_api.dart`, add `kIapTwistAddonProductForCount` + `kIapMaxTwistAddons` (mirror `:25-32`), add the 3 IDs to `_kAllProductIds` (`:161`), and `buyTwistAddon(count)` mirroring `buyAddon` (`:244`).
- [ ] **Step 3:** `cd apps/plot && flutter analyze lib/api/upgrade_api.dart lib/api/iap_api.dart` → clean (no NEW issues). If `AddonPurchase` is `@JsonSerializable`, re-run build_runner. Add/adjust any model unit test. Commit: `feat(iap): twist-add-on purchase API + StoreKit product IDs + candidateWeight parsing`.

---

### Task 2: `BuyTwistAddonCommand` + route the `twist_addon_required` 403

**Files:** `command/upgrade.dart` (new command), `command/twist.dart` (the twist-install 403 handler ~:3518).

**Interfaces:**
- Consumes: `purchaseTwistAddon`, `buyTwistAddon`, `ApiException.candidateWeight`.
- Produces: `BuyTwistAddonCommand({ int? candidateWeight, String? teamId })` mirroring `BuyAddonCommand` (`:157`):
  - **App Store + personal:** auto-present `twist_addon_{active+1}` via `IapService.buyTwistAddon(active+1)`, cap `kIapMaxTwistAddons`; confirm modal with `SubscriptionDisclosure`; over-cap → toast.
  - **Non-App-Store / team:** confirm modal ("+20 twists — $10/mo, billed to your card on file, prorated"), then `UpgradeApi.purchaseTwistAddon(teamId: teamId, candidateWeight: candidateWeight)`; `ok` → refresh usage + toast; `checkoutUrl` → open browser + toast. Team is admin-gated (server enforces; surface the 403 message if non-admin).
  - Concurrency guard (static in-flight bool, mirror `_addonPurchaseInFlight`).

- [ ] **Step 1:** Add `BuyTwistAddonCommand` to `command/upgrade.dart` mirroring `BuyAddonCommand`'s structure (confirm → IAP-tier or endpoint → refresh → toast), using the twist endpoint/products + `candidateWeight`.
- [ ] **Step 2:** In `command/twist.dart`, the twist-INSTALL 403 path (`ActivateDraftCommand`/the install flow around `:3518`, currently only handles `isPlanLimitExceeded`): add `if (e.isTwistAddonRequired)` → `BuyTwistAddonCommand(candidateWeight: e.candidateWeight, teamId: e.teamId)`. Keep the existing generic plan-limit message as the fallback. Also surface the over-capacity case at the twist at-limit command (`_twistAtLimitCommand` :950) so the user can buy a twist add-on OR upgrade.
- [ ] **Step 3:** `flutter analyze lib/command/upgrade.dart lib/command/twist.dart` clean. Commit: `feat(upgrade): BuyTwistAddonCommand; route twist_addon_required to twist add-on purchase`.

---

### Task 3: Connection-capacity offer — regular-beyond-pool "add-on or Pro" (web) / Pro-only (App Store)

**Files:** `command/twist.dart` (the connection 403 handlers at `:3812`, `:4284`), `command/upgrade.dart`.

**Interfaces:**
- Today `addon_required` always routes straight to `BuyAddonCommand` (buys a connection add-on). New behavior must distinguish:
  - **Premium connector** (`twist.premium`/`isPremium` — LinkedIn/IG/WhatsApp): `addon_required` → connection add-on (existing `BuyAddonCommand`), both platforms (Apple `addon_1/2/3`).
  - **Regular connector beyond pool** (`addon_required`, NOT premium): **non-App-Store** → present a CHOICE: "$5/mo connection add-on" (→ `BuyAddonCommand`) OR "Upgrade to Pro" (→ `ShowUpgradeOptions`/`BuyPlanCommand` pro). **App Store** → "Upgrade to Pro" only (no connection-capacity add-on on Apple).
  - The client knows `isPremium` for the connector it's enabling (it's in scope at the enable site). Use it to branch.

- [ ] **Step 1:** Add a helper command/flow (e.g. `ConnectionCapacityOffer({String? teamId, required bool isPremium})`): premium → `BuyAddonCommand`; regular + non-App-Store → a `SelectModal`/`CommandModal` choice (add-on vs Pro); regular + App Store → Pro upgrade directly. Mirror `ShowUpgradeOptions` for the Pro path.
- [ ] **Step 2:** At the connection 403 sites (`twist.dart:3812` `_ActivateNoProviderSource`, `:4284` `SaveSource`), replace the direct `BuyAddonCommand(teamId: e.teamId)` on `e.isAddonRequired` with the new offer flow, passing the connector's `isPremium`. (For premium connectors behavior is unchanged.)
- [ ] **Step 3:** `flutter analyze` the changed files clean. Commit: `feat(upgrade): regular-connection-beyond-pool offers add-on or Pro (web) / Pro only (App Store)`.

---

### Task 4: Usage display — twist capacity + twist add-ons; trial-unlimited connections

**Files:** `command/twist.dart` (`_usageSuffix` :979-1014, the ManageTwists header :2791), `api/upgrade_api.dart` (usage models if a field is missing).

**Interfaces:**
- `_usageSuffix` for twists shows capacity used/available (the server `twists` `{count,limit}` — `count` is the weighted sum, `limit` the capacity) + twist add-on count if any (parallel to the connection "Add-ons: X of Y"). For connections, when `limit == null` (Pro or active trial → unlimited) render "unlimited" instead of "X of N".

- [ ] **Step 1:** Update `_usageSuffix` (and any twist usage header) to render: connections "X of N" or "unlimited" when `limit == null`; twists "X of N" capacity (+ "Twist add-ons: …" when present). No AI meter (already gone). If the usage model lacks a twist-add-on count field, either derive it or add it (the server `premium` block covers connection add-ons; twist add-ons may need a small `/usage` extension OR display purchased twist packs from a separate read — if not available, show capacity only and note it).
- [ ] **Step 2:** `flutter analyze` clean. Optionally drive via `run-app` to eyeball the Manage Connections / Manage Twists headers. Commit: `feat(usage): show twist capacity + twist add-ons; unlimited connections during trial/Pro`.

---

### Task 5: Remove Core + B4 AI dead code from the client

**Files:** `command/upgrade.dart` (`BuyPlanCommand` `:32-129`, `plansFor()` `:470`), `api/iap_api.dart` (`kIapProductCoreMonthly`), `widget/twist_details.dart` (`hasAiKeys`), `state/subscription_service.dart` (`adminOrgs`).

- [ ] **Step 1:** Remove the `'core'` plan option from `BuyPlanCommand`'s product map + `plansFor()` (so the upgrade picker never offers Core); keep defensive parse of a legacy `'core'` plan value from `/usage` (treat as a paid plan / map to pro) but don't OFFER it. Remove `kIapProductCoreMonthly` if now unused (or leave the const unused-but-harmless if other code references it — grep). 
- [ ] **Step 2:** Remove the dead `hasAiKeys` param + its message block from `widget/twist_details.dart` and the `adminOrgs` field from `state/subscription_service.dart` (B4 follow-up; confirm no readers via grep).
- [ ] **Step 3:** `flutter analyze lib/command/upgrade.dart lib/api/iap_api.dart lib/widget/twist_details.dart lib/state/subscription_service.dart` clean. Commit: `chore(upgrade): drop Core plan option + B4 AI dead code (hasAiKeys, adminOrgs)`.

---

## Self-Review

**Spec coverage (Area 6 / the add-ons Plan-4 client work + B7 generalizations):**
- Twist add-on purchase (web usage-synced via endpoint + candidateWeight; Apple tiers) → Tasks 1–2. ✅
- `twist_addon_required` 403 routed → Task 2. ✅
- Connection capacity: regular-beyond-pool → add-on or Pro (web) / Pro only (App Store); premium unchanged → Task 3. ✅
- Usage display: twist capacity + add-ons, trial/Pro unlimited connections, no AI meter → Task 4. ✅
- Drop Core option + B4 dead code → Task 5. ✅

**Verification ceiling (flag):** `flutter analyze` proves compile/lint correctness; the actual StoreKit purchase sheets + the live `/upgrade/*/purchase` round-trips can only be fully verified with the `run-app` skill (and real billing needs the Apple/Stripe products from the ops checklist `2026-06-26-pricing-billing-product-setup.md`, which is manual/user-owned). The plan delivers analyze-clean code; behavioral purchase verification is a run-app / device pass.

**Deferred to integration:** the `apps/site` `upgrade.tsx`/`plans.ts` web checkout/account changes are a SEPARATE step after integrating `feature/new-pricing` (the marketing page) — not in B7.
