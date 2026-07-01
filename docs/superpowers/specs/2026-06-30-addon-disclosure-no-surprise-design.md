# Connection add-on: no-surprise disclosure

Date: 2026-06-30
Status: Approved design (pending spec review)
Area: Flutter app — connection add flow (`apps/plot/lib/command/twist.dart`,
`apps/plot/lib/command/upgrade.dart`)

## Problem

A user can authenticate and set up a premium connection (LinkedIn / Instagram /
WhatsApp) and reach the "Add connection" button **before** ever seeing that the
connection requires a paid add-on ($5/month on web; StoreKit tiers on App
Store). The cost is a surprise late in the flow.

### Audit result (why this happens)

Money is already safe: the server (`chargeConsentedAddonOrError`,
`workers/api/src/app/twist-integrations.ts:516`) never charges without
`consentAddon === true`, and the client only sends that flag after showing a
disclosure. **No path charges before disclosing.** The defect is purely
*timing* — effort (OAuth + channel setup) is invested before the cost is shown.

Premium connectors are the focus because their add-on requirement is **certain
and knowable the instant the connector is picked**. Two root causes:

1. **The `teams.isEmpty ?` guard** (`twist.dart:2584` initial, `~2323`
   refresh). The pre-auth consent gate that replaces the auth button with a
   blocking upgrade modal is wired **only for personal-only users**. Any user
   who belongs to a team authenticates first and sees the $5/month cost only at
   the final "Add connection" step.
2. **The picker gives no cost signal early** — but per product decision the
   picker badge stays as "Add-on" (see Non-goals).

Regular (non-premium) connectors only need an add-on when *beyond the plan
pool*, which is not knowable until owner + connection count are resolved, so
they are out of scope for this change and keep today's reactive behavior.

## Approach

Replace the conditional blocking pre-auth gate with **passive, non-blocking
notices** shown at two points before commitment, and keep the actual
charge/consent at the single "Add connection" moment via the existing payment
modal.

Guiding principle: the user is *told* the cost twice before they commit, but is
never *blocked* or forced to tap anything extra to proceed. Money-safety is
unchanged — the server still enforces `consentAddon === true` at enable.

### Flow (all users, personal and team, unified)

1. **Pick premium connector** — picker unchanged ("Add-on" badge).
2. **Before auth** (AddSourceDetail modal): a passive notice renders next to
   "Continue with LinkedIn":
   > ⓘ LinkedIn requires a connection add-on — `<price>`, billed separately
   > from your plan when you add it.

   "Continue with LinkedIn" works exactly as today; the notice requires no tap.
3. **Authenticate** (Unipile hosted auth) — unchanged.
4. **After auth** (EditSource setup modal): the same passive notice renders
   directly **above the "Add connection" button**.
5. **Tap "Add connection"** — the existing payment modal fires:
   - **Web/DMG/Android:** `$5/mo` consent (`ConfirmModal` +
     `SubscriptionDisclosure`) → on confirm, `activateDraft(consentAddon: true)`
     → server charges on enable.
   - **App Store:** StoreKit purchase (`BuyAddonCommand._runIap`) at this
     moment, then enable.

   Single continuous flow: confirming the modal proceeds straight to adding the
   connection — **no forced second tap**. (Chosen over today's
   confirm→refresh→re-tap behavior; flag during spec review if the two-tap is
   preferred.)

### The two removals / additions

- **Remove** the blocking pre-auth premium gate: the
  `upgrade_premium_<provider>` `FormButton` that replaces the auth CTA
  (`twist.dart:2584-2599` and its refresh twin `~2323`). This deletes the
  `teams.isEmpty` conditionality entirely, so team users and personal users get
  the identical flow.
- **Add** the passive notice at the auth step (in place of the removed
  button-swap, alongside the always-present auth CTA) and above the "Add
  connection" Save button (the `StaticFormGroup` at `twist.dart:1540`).
- **Keep** the Save-button / reactive consent path (`twist.dart:1635`,
  `SaveSource._attempt` `~4659`) as the single place a charge/consent actually
  happens.

## Pricing rules (critical)

The notices **and** the payment modal must show the correct price per platform:

- **Web/DMG/Android:** use `SubscriptionService.instance.usage?.
  connectionAddonPrice ?? 5` → "$5/month".
- **App Store:** use the **live StoreKit price** for the next add-on tier
  (`IapService.instance.productFor(kIapAddonProductForCount[current + 1])?.
  price`) — never a hardcoded $5. Apple tiers ($5.99…) differ from Stripe, vary
  by storefront, and would go stale if hardcoded.
- **Fallback:** when the StoreKit price has not loaded yet, the notice omits the
  specific figure and reads "requires a connection add-on, billed separately
  from your plan" (matching the existing `_runIap` price-less fallback). The
  native purchase sheet still shows the exact amount.

The payment modal already resolves prices this way (`BuyAddonCommand`); the new
notices must reuse the same price source so notice and modal never disagree.

## Copy variants (spare-credit honesty)

The notice text adapts to whether a **new charge** will occur, decided by
`_evaluatePremium` (reused):

- **Charge applies** (`needsAddon` for the scope): "`<name>` requires a
  connection add-on — `<price>`, billed separately from your plan when you add
  it."
- **Spare credit exists** (already purchased an unused add-on): "`<name>` uses
  one of your connection add-ons — no additional charge." No payment modal
  fires at "Add connection" (enable consumes the existing credit).
- **No notice** when the connector is not premium, or (post-auth) the selected
  owner needs no add-on.

Pre-auth the owner is unknown, so the notice evaluates **personal** scope (the
common case). Post-auth the owner is selected, so the notice evaluates the
**selected owner** and is exact. Scope resolution at charge time is unchanged
(team add-ons remain admin/Stripe-managed).

## Components

- **`_AddonNotice`** — new stateless, passive inline banner widget: a muted
  info row (icon + text). Rendered in both modals. No interaction.
- **`_addonNoticeFor({usage, owner, isPremium, connectionName})`** — helper
  returning `Widget?` (null when no notice). Centralizes the premium +
  `needsAddon` decision (reusing `_evaluatePremium`) and the per-platform
  price/copy selection. Single source of truth for both notice sites.
- **Edits** in `twist.dart`:
  - Auth step (`~2578-2599` and refresh twin `~2323`): drop the
    `upgrade_premium_*` button-swap; always render the auth CTA plus the notice.
  - Save-button group (`~1540`): render the notice above the "Add connection"
    button when `isNewlyActivated && isPremium`.
  - "Add connection" action: ensure a single continuous flow (confirm → add) at
    the enable step.

No server changes. No changes to `chargeConsentedAddonOrError`,
`activateDraft`, `enableChannel`, or the Stripe/StoreKit charge logic.

## Non-goals / out of scope

- **Picker badge** stays "Add-on" (product decision — no price on the badge).
- **Regular connectors beyond the plan pool** keep today's behavior (the
  requirement isn't knowable up front; the add-on-or-Pro choice already appears
  before enable).
- **Enable an extra channel on an already-connected premium connection** — the
  connection already holds its add-on credit, so no notice/charge for extra
  channels. Unchanged.
- **Move-to-team** keeps today's pre-gate behavior.
- **Server billing mechanics** unchanged; this is Flutter-only.

## Verification

- `flutter analyze` clean (run `flutter pub run build_runner build` first in a
  worktree so Drift codegen doesn't produce false errors).
- Manual (run-app / TestFlight): premium connector as a **team member** shows
  the notice before "Continue with LinkedIn" and above "Add connection"; the
  payment modal appears only at "Add connection"; single-tap add.
- App Store: notice and modal show the **live StoreKit tier price**, not $5.
- Spare-credit account: notice reads "uses one of your connection add-ons"; no
  charge on add.
- No path charges before a notice + modal are shown (money-safety regression
  check).
