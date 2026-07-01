# Connection add-ons: coupon-or-card checkout + period-reconciled credits

**Date:** 2026-06-30
**Status:** Approved design (pre-implementation)
**Author:** Kris Braun (with Claude)

## Problem

A user on a Team plan with a 100%-off coupon (so **no payment card on file**) tried to
add a premium connection add-on (LinkedIn / Instagram / WhatsApp). The UI spun and
popped a modal "as if it were charging," showed no error, and did **not** add the
connection. They were never given a chance to add payment — in their case, another
coupon code.

### Root cause (current code, post-PR #489)

Two distinct defects, both reproduced against the current tree:

1. **Consent-before-auth dead-end.** Connecting a premium connector triggers
   `_premiumGateCommand` → `_ConsentGate` *before* auth
   (`apps/plot/lib/command/twist.dart:1037`). The gate shows the "Add for $5/month"
   `ConfirmModal`; on confirm it records a *local* consent flag and returns
   `CommandRefresh()` (`twist.dart:1069`). Nothing is charged and no connection is
   added — the modal simply refreshes. The charge / `needs_card` step only fires
   later, after the user re-triggers connect and completes OAuth. A user who reads the
   refresh as "it charged" stops there. This is exactly the reported symptom.

2. **No coupon path, ever.** Even if the user pushes through to the enable step, the
   server's no-card branch returns a `402 needs_card` pointing at a Stripe **setup**
   session (`createAddonCardSetupSession`, `workers/api/src/stripe/addons.ts:107`),
   which captures a **card only**. Neither the setup session nor
   `createAddonCheckoutSession` sets `allow_promotion_codes`, so there is no way to
   enter a coupon anywhere in the flow.

### Relevant current code

- Gate: `chargeConsentedAddonOrError` (`workers/api/src/app/twist-integrations.ts:504`).
- No-card helper: `provisionAddonForConsentedEnable` (`workers/api/src/app/upgrade.ts:954`).
- No-card detection: `customerHasPaymentMethod` (`workers/api/src/stripe/addons.ts:23`) —
  correctly returns `false` for a 100%-off-coupon customer with no card.
- Stripe helpers: `provisionAddonCredit`, `createAddonCardSetupSession`,
  `createAddonCheckoutSession`, `reconcileAddonQuantityDown` (`workers/api/src/stripe/addons.ts`).
- Counting: `getPersonalPremiumConnectionCount` / `getTeamPremiumConnectionCount`
  (active premium connections) and `getPersonalPremiumAddons` /
  `getTeamPremiumAddons` (purchased credits = `premium_connection_addons`) in
  `workers/api/src/utils/limits.ts`.
- Immediate disable-time reconcile: `reconcileScopeAddonBillingDown`, called from
  three `waitUntil` sites (`twist-integrations.ts:1461`, `:1678`, `:2072`).
- Client no-card handler: `_handleNeedsCard` (`twist.dart:956`);
  `ApiException.needsCard` (`apps/plot/lib/api/api_exception.dart:71`).
- Cron infra: `workers/api/src/index.ts:286` (`scheduled()`), `wrangler.jsonc` crons
  (`*/5 * * * *`).

## Goals

- A user with **no card** who adds a premium add-on gets a Checkout that accepts a
  **coupon OR a card** in one screen; a 100%-off coupon makes the add-on free.
- Confirming actually **provisions and advances** — no silent refresh dead-end.
- **Charge once per credit, at confirm.** Never double-charge on
  confirm→back-out→retry. Allow archive-one-add-another with no new charge.
- Unused credits (never completed, or archived connection) are **canceled at the
  period boundary**, not stranded forever and not refunded mid-period.

## Non-goals

- App Store / StoreKit add-on flow is unchanged (Apple prepaid; charge at purchase).
- Twist add-ons (`twist_addon_*`) are out of scope; this covers connection add-ons only.
- No mid-period "cancel add-on now for a prorated refund" affordance (period reconcile
  is the model; can be added later).

## Billing model (the core shift)

Drop "charge strictly on enable." Adopt a **credit** model with period-boundary
reconciliation.

- A **credit** is one paid slot in the scope's add-on subscription;
  `premium_connection_addons` == the Stripe add-on subscription `quantity`.
- **Active add-ons** = enabled, non-archived premium connections in the scope
  (`getPersonalPremiumConnectionCount` / `getTeamPremiumConnectionCount`).
- **Invariant:** within a billing period, `purchased ≥ active`, and credits are
  **sticky and reusable**. At each period boundary, `purchased` reconciles **down** to
  `active`.

Consequences: you charge once per credit at confirm; you never double-charge; freed
credits are reusable for the rest of the period; and you stop paying for unused credits
at the next renewal.

## Design

### 1. Purchase-at-confirm, idempotent (server)

New helper (replaces `provisionAddonForConsentedEnable`), invoked when the user
confirms the $5/mo disclosure. Given the resolved scope
(`resolveAddonScope`, `twist-integrations.ts:439`):

1. Read `purchased` (`get{Personal,Team}PremiumAddons`) and count `active`
   (`get{Personal,Team}PremiumConnectionCount`).
2. **`purchased > active` → an unused credit already exists → consume it, no charge,
   return `{ ok: true }`.** This makes confirm→back-out→retry and
   archive-one-add-another free.
3. Else a new credit is needed:
   - **Card on file** (`customerHasPaymentMethod` true) → `provisionAddonCredit`
     (off-session bump quantity +1, charge now) → `{ ok: true }`.
   - **No card** → `{ ok: false, needs_checkout: true, checkout_url }` from a
     `mode: subscription` Checkout with **`allow_promotion_codes: true`** (see §3).

The HTTP gate (`chargeConsentedAddonOrError`) maps `needs_checkout` to a `402` with a
stable reason (keep `reason: "needs_card"` for client compatibility, or introduce
`needs_checkout`; see §6 Compatibility). Charge-first ordering is retained: provision
before the caller enables the connection.

### 2. Client: confirm provisions and advances

- The consent path calls the provision endpoint **at confirm** (in the
  `ConfirmModal`-accepting branch), instead of only recording a local flag and
  returning `CommandRefresh()`.
  - `{ ok: true }` → proceed to auth/enable (carry `consentAddon: true` as today so the
    enable is idempotent and re-consumes the just-provisioned credit).
  - `{ needs_checkout }` → open the Checkout URL in the browser (reuse
    `_handleNeedsCard` / `launchUrl`); on return, re-run provision → step 2 finds the
    fresh credit → `{ ok: true }` → enable.
- This removes the `CommandRefresh()` dead-end (`twist.dart:1069`) as the terminal
  state of a consent. The reactive `addon_required` path
  (`_offerAddonConsent`, `twist.dart:981`) collapses into the same provision call.

### 3. Coupon-or-card Checkout (Stripe)

Use a `mode: subscription` Checkout session that both **creates/bumps the add-on
subscription** and **allows a promotion code**:

- Add `allow_promotion_codes: true` to `createAddonCheckoutSession`
  (`addons.ts:122`).
- Route the no-card branch to this subscription Checkout instead of the card-only
  setup session. On completion: coupon → $0 sub; card → charged; the existing
  subscription webhook records the credit (`premium_connection_addons` +
  `stripe_addon_subscription_id`).
- Retire `createAddonCardSetupSession` from this path (may be deleted if no other
  caller remains).

### 4. Period reconcile (scheduled) — cancels unused credits

A new scheduled reconcile, added to `scheduled()` (`index.ts:286`) as its own
`try`/`withDb` block (reusing the existing `*/5 * * * *` cron):

- For each active add-on subscription whose `current_period_end` falls within the next
  cron window, set Stripe `quantity = active` **down-only**; cancel the subscription
  when `active == 0`. Reuse `reconcileAddonQuantityDown` (`addons.ts:61`), which is
  already down-only and cancels at zero.
- Never increases quantity → never charges without consent.
- Catches "confirmed but never completed" (abandoned OAuth after a paid credit) and
  "archived the connection." Because it fires only at the period boundary, within-period
  reuse (§1.2) still holds.
- Scope discovery: iterate `user_subscription` / `team_subscription` rows with a
  non-null `stripe_addon_subscription_id`; recompute `active` per scope. (Implementation
  detail for the plan: batch and bound per-run work like sibling cron sweeps.)

### 5. Disable / archive behavior change

**Remove the immediate `reconcileScopeAddonBillingDown` at the three disable sites**
(`twist-integrations.ts:1461`, `:1678`, `:2072`). Freed credits stay purchased until
the period reconcile — which is what enables archive-one-add-another without a
re-charge. Down-moves now happen in exactly one place (the period reconcile) instead of
scattered across disable / batch-disable / removeAuth.

Confirmed decisions:
- A user who disables their only add-on **keeps the reusable credit until renewal**
  (no mid-period prorated refund). This is the intended consequence of "reusable within
  a period."
- Period-reconcile trigger is the **cron window on `current_period_end`** (not the
  `invoice.upcoming` webhook).

### 6. Money-safety, errors, compatibility

- **Money-safety:** idempotent provision (step 1.2) prevents double-charge; period
  reconcile is strictly down-only; abandoned checkout → unused credit → reused on retry
  or dropped at renewal. The only accepted cost is paying out the current period for a
  credit you stopped using mid-period (standard subscription proration; the credit
  remains reusable).
- **Errors:** every new catch block calls `captureException` (PostHog) per AGENTS.md.
  Post-charge DB writes remain best-effort (wrapped, `captureException` only) since the
  Stripe webhook re-syncs the authoritative quantity.
- **Compatibility:** older Flutter clients only understand `402 reason: "needs_card"`
  with `checkout_url`, and `_handleNeedsCard` opens that URL. Since the no-card branch
  still returns `402` + `checkout_url`, keeping `reason: "needs_card"` keeps old clients
  working (they just open a coupon-capable Checkout instead of a setup session). New
  clients may additionally recognize `needs_checkout`. Do **not** remove or rename the
  `checkout_url` field.

## Testing

- **Unit (server):**
  - Idempotent reuse: `purchased > active` returns `ok` with **no** Stripe call.
  - Card on file: off-session `provisionAddonCredit` bump, returns `ok`.
  - No card: returns `needs_checkout` + `checkout_url`; the Checkout session carries
    `allow_promotion_codes: true` and `mode: "subscription"`.
  - Period reconcile: down-only to `active`; cancels at `active == 0`; never increases.
- **Integration (real DB, serial):**
  - confirm → back-out → retry = exactly one credit / one charge.
  - archive one connection → add another within the period = no new charge.
  - abandoned enable after a paid credit → credit reused mid-period; dropped by the
    period reconcile at renewal.
- **Client:** `flutter analyze` clean (run `build_runner` first in a worktree);
  consent confirm advances to auth/enable or opens Checkout; no terminal
  `CommandRefresh()` dead-end.

## Rollout / ops

- Stripe: confirm the `addon_monthly` price exists and that promotion codes are
  configured for the coupons that should apply to add-ons.
- The period-reconcile cron is additive and idempotent; safe to ship before/after the
  client change. Ship server first (backward compatible via `needs_card`), client
  second.
- Update `docs/updates.d/` with a user-facing note (coupon can now be applied to
  connection add-ons; adding an add-on with no card no longer dead-ends).

## Open items for the plan (not blocking)

- Exact SQL/iteration strategy and per-run bound for the reconcile cron.
- Whether `createAddonCardSetupSession` has any remaining caller after the switch (delete
  if not).
- Whether to introduce the `needs_checkout` reason for new clients or keep `needs_card`
  only (leaning: keep `needs_card` to minimize surface; revisit if UX copy needs to
  differ between "add a card" and "add a coupon or card").
