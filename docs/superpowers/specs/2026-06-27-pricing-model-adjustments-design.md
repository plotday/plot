# Pricing Model Adjustments — Design

Date: 2026-06-27
Status: Approved (brainstorming), pending written-spec review
Builds on: PR #487 (Free/Pro/Team, weighted twist capacity, connection + twist add-ons), now merged to `main`.

## Summary

Six adjustments to the just-shipped #487 pricing model:

1. **Twist add-ons are packs of 5** (were 20). Web price unchanged at **$10/pack**.
2. **Pro includes 3 twist automations** (was 10). Free stays **1**.
3. **Team gets one interchangeable pool of 50 slots per block** — usable for connections *and/or* twist automations — replacing today's two separate Team pools (50 connections + 10 twists per block).
4. **Connection add-ons and twist add-ons apply to individual accounts only** (Free/Pro personal scope), with **one deliberate exception**: the always-required premium connectors (LinkedIn / Instagram / WhatsApp) keep their $5/mo connection add-on on every plan, including Team.
5. **apps/site copy** updates, including a new upgrade-page heading/sub-heading, centring the (now two) plan cards, and adopting the term **"twist automations"** on the pricing and upgrade pages.
6. **Single source of truth** for all pricing numbers — extract the constants that are currently mirrored across `workers/api` and `apps/site` into one shared module both consume.

No database migration is required (greenfield: no live twist-add-on purchases to preserve; Team add-on columns become vestigial). No new Stripe products/prices (the $10 twist-add-on price is unchanged and product descriptions are pack-size-agnostic). The user owns App Store Connect changes.

## Background — current model (post-#487)

Verified from the code:

- `workers/api/src/utils/limits.ts`
  - `PLAN_LIMITS` (lines ~20–43): `free {connections:2, twistCapacity:1}`, `pro {connections:∞, twistCapacity:10}`, `team {connections:∞, twistCapacity:10}` (per block). `TEAM_CONNECTIONS_PER_GROUP = 50`.
  - `computeTwistBlocksNeeded()` (line ~297): `Math.ceil(Math.max(0, weightSum + pendingWeight - base) / 20)`.
  - Capacity calcs: personal `twistCapacity + 20 * addons` (~906); team `twistCapacity * blocks + 20 * addons` (~885); usage display `twistCapacity + 20 * twistAddonCount` (~1051).
  - `checkTwistCapacity(db, userId, teamId, candidateWeight)` (~863–923) — used + candidate ≤ capacity, else `reason: "twist_addon_required"` (echoes `candidateWeight`).
  - `checkChannelConnectionLimit()` (~622–825) and `getBillableConnectionAddonCount()` (~227–253) — pool counts exclude premium connectors; regular-beyond-pool and premium connectors are billed as $5 add-ons; team over-pool currently returns `reason: "addon_required"`.
- `workers/api/src/apple/iap.ts` — `IAP_TWIST_ADDON_PRODUCT_TO_COUNT` (~56–60): `twist_addon_1/2/3 → 1/2/3` blocks; capacity is `blocks × 20` in limits.ts.
- Schema: `user_subscription` + `team_subscription` carry `premium_connection_addons`, `twist_addon_count`, `stripe_addon_subscription_id`, `stripe_twist_addon_subscription_id` (Apple add-on columns on `user_subscription` only).
- `apps/site/app/lib/plans.ts` — independent numeric mirror: `PRICES`, `ADDON_PRICE = 5`, `TWIST_ADDON_PRICE = 10`, per-plan feature strings ("10 automations", "10 automations per 50 connections", "+20 twists").
- Stripe (account "Plot", `acct_1SF4jiPieS5YOSAm`): "Twist Add-on" product, generic description "Extra twists (automations) beyond those included with your plan", price `$10/mo`; "Connection Add-on" product, `$5/mo`.

## Detailed design

### Area 0 — Single source of truth (foundation)

Today the numbers live in two hand-synced places: `workers/api/src/utils/limits.ts` (server) and `apps/site/app/lib/plans.ts` (site). This is the drift the user wants eliminated.

Create a small private workspace package `libs/pricing` (`@plotday/pricing`) exporting **pure constants only** (no logic, no DB, no runtime deps):

```ts
// @plotday/pricing
export const PLAN = {
  free: { connections: 2, twistCapacity: 1, syncHistoryDays: 7 },
  pro:  { connections: Infinity, twistCapacity: 3, syncHistoryDays: 365 },
  team: { syncHistoryDays: 365 }, // Team uses TEAM_SLOTS_PER_GROUP (interchangeable), not a fixed twistCapacity
} as const;

export const TEAM_SLOTS_PER_GROUP = 50;     // connections + twist weight share this, per block
export const TWIST_ADDON_BLOCK_SIZE = 5;    // twists granted per twist add-on pack
export const CONNECTION_ADDON_PRICE = 5;    // USD/mo, web
export const TWIST_ADDON_PRICE = 10;        // USD/mo, web
export const PLAN_PRICES = {
  pro:  { monthly: 25, annual: 20 },
  team: { monthly: 124, annual: 99 },
} as const;
```

Consumers:
- `workers/api/src/utils/limits.ts` imports `PLAN`, `TEAM_SLOTS_PER_GROUP`, `TWIST_ADDON_BLOCK_SIZE` and builds its `PLAN_LIMITS` / capacity math from them. Server-side logic, queries, and types stay in `limits.ts`; only the literals move.
- `apps/site/app/lib/plans.ts` imports the same constants for its numeric values and **derives** feature strings from them (e.g. `${PLAN.pro.twistCapacity} twist automations`) instead of hardcoding "10". Marketing copy/structure stays in `plans.ts`.

Wiring: add `libs/pricing` to `pnpm-workspace.yaml`; depend via `"@plotday/pricing": "workspace:*"` in `workers/api` and `apps/site`; build to ESM with the repo's shared `libs/tsconfig`. Mirror the existing `libs/*` package layout.

**Flutter (Dart) note.** Dart cannot import the TS source. The app already derives capacity/limit numbers from server responses (`/upgrade/usage` etc.) at runtime, and App Store confirms already use **live StoreKit prices** — so Flutter holds no authoritative capacity numbers. The only hardcoded pricing literals are the **web** add-on price fallbacks ("$5"/"$10") in confirm/summary copy. To keep these from drifting, the server's `/upgrade/usage` payload will include `connectionAddonPrice` and `twistAddonPrice` (sourced from `@plotday/pricing`), and Flutter reads those for its web confirm strings. This makes the TS package the single source for *every* number, including the ones Flutter shows. (Capacity numbers are already server-derived; no Flutter capacity constants exist to remove.)

### Area 1 — Twist add-on pack size 20 → 5

Replace the block-size magic number with `TWIST_ADDON_BLOCK_SIZE` (= 5) from `@plotday/pricing`, everywhere it appears:

- `computeTwistBlocksNeeded()` divisor `/ 20` → `/ TWIST_ADDON_BLOCK_SIZE` (limits.ts ~297).
- Personal capacity `+ 20 * addons` → `+ TWIST_ADDON_BLOCK_SIZE * addons` (~906).
- Usage display `+ 20 * twistAddonCount` → `+ TWIST_ADDON_BLOCK_SIZE * twistAddonCount` (~1051).
- (Team capacity calc is rewritten in Area 3, not here.)
- Apple: `IAP_TWIST_ADDON_PRODUCT_TO_COUNT` map stays `{1, 2, 3}` (number of packs per tier); each pack now grants 5, so the tiers grant +5/+10/+15. No map change; the ×block-size happens in the capacity calc which now reads 5.
- Comments/docstrings mentioning "+20" → "+5" (limits.ts header ~30–31; schema column comments in `libs/db/schema/50-tables/20-user_subscription.sql` ~50–51 and `13-team_subscription.sql`).

Web price stays $10/pack. Apple tier prices unchanged in code (set in ASC by the user).

### Area 2 — Pro included twists 10 → 3

`PLAN.pro.twistCapacity = 3` in `@plotday/pricing` (flows to `limits.ts` `PLAN_LIMITS` and `plans.ts`). Free stays 1. No other logic change — `checkTwistCapacity` already reads the per-plan capacity.

### Area 3 — Team interchangeable 50-slot pool

Replace Team's two separate pools with one shared pool per block.

- **Pool** = `TEAM_SLOTS_PER_GROUP * connection_group_quantity` (= 50 × blocks).
- **Used slots** = regular (non-premium) connection count + twist weight sum. Premium connectors are billed as add-ons (Area 4) and do **not** consume a slot. Built-in assistant weight 0 (unchanged).
- New shared helper `getTeamUsedSlots(db, teamId): Promise<number>` = `getTeamConnectionCount` (regular only) + `getTeamTwistWeightSum`. Both capacity checks consult it:
  - `checkChannelConnectionLimit()` Team-regular branch: allow if `usedSlots + 1 ≤ pool`, else over-capacity.
  - `checkTwistCapacity()` Team branch: allow if `usedSlots + candidateWeight ≤ pool`, else over-capacity. Drop the `twistCapacity * blocks + 20 * addons` formula and the team `twist_addon_count` read.
- **Over capacity → add a 50-block.** Replace the Team `addon_required` / `twist_addon_required` outcomes with a new outcome reason `team_block_required` (carrying current `usedSlots`, `pool`, `blocks`). Admins are directed to increase `connection_group_quantity` (buy another 50-block, the existing Team-plan quantity mechanism); non-admin members are told to ask an admin. **Open implementation detail (resolve in plan):** confirm whether raising `connection_group_quantity` is an in-app endpoint or a Stripe billing-portal action today, and wire the client offer to whichever exists (the marketing FAQ already promises "add another block of 50 anytime").
- `PLAN_LIMITS.team.twistCapacity` (the `10`) is removed in favor of the shared pool. `team_subscription.twist_addon_count` is no longer read or written for capacity (column kept vestigial; no migration).

Free teams (plan `free` or non-active subscription) keep 0 capacity (unchanged).

### Area 4 — Add-ons individual-only (premium-connector exception)

- **Twist add-ons:** purchase + capacity only for personal scope (Free/Pro). Remove the Team twist-add-on paths: the admin-gated team twist-add-on purchase branch (`app/upgrade.ts` ~1035–1047 team branch), team reconcile-down for twist add-ons, and any webhook routing that writes `team_subscription.twist_addon_count`. Team capacity comes solely from blocks (Area 3).
- **Connection add-ons:**
  - *Regular connection beyond pool* → add-on on **individual only**. On Team, regular-beyond-pool resolves to `team_block_required` (Area 3), not an add-on. Revert the #487 "regular-beyond-pool → add-on" generalization for **team scope** only; keep it for personal scope.
  - *Always-required premium connectors* (LinkedIn / Instagram / WhatsApp) → still a $5/mo connection add-on on **every** plan including Team (admin-gated on Team), billed separately, not counted in the pool. This is unchanged from today; `team_subscription.premium_connection_addons` and the premium add-on purchase/charge/reconcile paths remain for this case.

Net: on Team, the only surviving add-on is the premium-connector connection add-on. `team_subscription.twist_addon_count` becomes vestigial; `premium_connection_addons` stays in use (premium connectors only).

### Area 5 — apps/site copy

`apps/site/app/lib/plans.ts`:
- Numbers sourced from `@plotday/pricing` (Area 0).
- Pro feature: "3 twist automations" (derived). Free: "1 twist automation".
- Team: reframe the two separate lines into the interchangeable pool, e.g. "50 connections or twist automations, shared across your team (add 50 more anytime)". Drop "10 automations per 50 connections".
- Add-on availability note: connection/twist add-ons apply to individual accounts; note the premium-connector exception applies on every plan.
- "No-code automation builder" line unchanged (user-confirmed).

`apps/site/app/routes/pricing.tsx`:
- FAQ "1 on Free, 10 on Pro" → "1 on Free, 3 on Pro".
- "add 20 slots for $10/month" / "add 20 more for $10/mo" → "add 5 ... for $10" (two spots, ~line 58 and ~344), worded as "twist automations".
- Team interchangeable framing in the FAQ; the "What happens at the limit" answer already says Team adds a 50-block — keep.
- "automations" → "twist automations" on the included-capacity and add-on lines.

`apps/site/app/routes/upgrade.tsx`:
- **Heading** → "Do more with Plot"; **sub-heading** → "Add connections and twist automations to bring all your work together." (replaces the Pro-only "Upgrade for unlimited connections.").
- **Centre the plan cards.** With Core dropped only Pro + Team render; centre the grid so 2 cards are balanced (and still correct for 1 or 3 cards). Adjust the grid/justify in the relevant `.module.css` or layout container rather than hardcoding two columns.
- Add-on summary copy: "+20 twists each" → "+5 twist automations each" (two spots, ~447 and ~659–660). Prices stay sourced from `plans.ts` (`ADDON_PRICE`/`TWIST_ADDON_PRICE`, which now come from `@plotday/pricing`) — the site is TS and reads the shared constants directly, not `/usage`. (Only Flutter, which can't import the TS package, reads the prices from `/usage` — see Area 0.)

### Area 6 — Stripe (verify, likely no change)

The $10 twist-add-on price and $5 connection-add-on price are unchanged, and the product descriptions are pack-size-agnostic ("Extra twists (automations) beyond those included with your plan"). Expected: **no Stripe object changes**. As a verification step, confirm in **both** Sandbox and Production that: the twist-add-on price is $10/mo with a stable `lookup_key`, the connection-add-on price is $5/mo, and no description references a pack size. Update only if a description is found to name "20". (The connected MCP account exposes one mode at a time; verify each mode.)

## Out of scope / user-owned

- **App Store Connect**: re-pricing or relabeling the `twist_addon_1/2/3` tiers for packs of 5, and any IAP product copy — the user owns these.
- **Creating Stripe products/prices**: none needed (Area 6).
- **Data migration**: none (greenfield twist add-ons; Team add-on columns vestigial).
- **Subscriber migration**: none.

## Testing

- `workers/api` vitest (DB-backed; isolated worktree DB): update/extend tests for `computeTwistBlocksNeeded` (÷5), Pro capacity = 3, twist add-on pack = 5, the new Team interchangeable pool (connection+twist share 50×blocks; over → `team_block_required`), twist add-ons rejected for team scope, premium connector add-on still charged on Team.
- `@plotday/pricing` consumed by both `workers/api` and `apps/site` — `tsc` in each confirms the shared import resolves.
- `apps/site` tsc + eslint clean; verify derived feature strings render expected numbers.
- Flutter `flutter analyze lib` clean; verify `/usage`-driven capacity display and web add-on price strings.
- `pnpm lint` in changed packages; `diff-schema-migrations` clean (no schema change); both generated type files unchanged.

## Risks / notes

- The Team capacity check now joins connections + twists; ensure both `checkChannelConnectionLimit` and `checkTwistCapacity` use the identical `getTeamUsedSlots` to avoid divergence (the bug class #487's whole-branch reviews kept catching).
- `team_block_required` is a new client contract — Flutter must handle it (admin → increase blocks; member → ask admin). This replaces `addon_required`/`twist_addon_required` on Team only; personal scope keeps the existing reasons.
- Dropping Pro 10→3 silently reduces capacity for any current Pro user with 4–10 active twists; since #487 is freshly shipped this is expected to be negligible, but the over-capacity path (offer +5 pack) handles it gracefully.
