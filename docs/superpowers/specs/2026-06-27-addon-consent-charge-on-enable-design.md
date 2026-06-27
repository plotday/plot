# Usage-based add-on billing: consent before authorization, charge on enable

**Status:** Approved (design) — 2026-06-27
**Builds on:** the pricing model change (`2026-06-26-pricing-model-product-changes-design.md`, merged in #487). Connection/twist add-on columns, the usage-synced reconcile-down, `getBillableConnectionAddonCount`, and the StoreKit add-on tiers already exist.

## Problem

Two user-reported UX gaps and one underlying billing-timing flaw:

1. **Regular connection beyond pool → "upgrade only."** The *proactive* (pre-flight) at-limit prompt uses `_connectionAtLimitCommand()` → `ShowUpgradeOptions("Upgrade to add more connections")`, which offers **only** a plan upgrade — no add-on. Only the *reactive* path (after a server `addon_required` 403) uses `ConnectionCapacityOffer`, which correctly offers "$5/mo add-on **OR** Pro." A user who hits the proactive prompt has no way to choose the add-on.

2. **Premium connector (LinkedIn) → no consent before authorization.** Premium connectors authorize first (Unipile hosted auth, "Continue with LinkedIn"), then `activateDraft` runs, and only *then* does the server return `addon_required`. The add-on requirement and its cost are surfaced *after* the user has already granted LinkedIn access — the opposite of "consent first."

3. **The charge is decoupled from actual usage.** The add-on charge happens at the *purchase* step (`BuyAddonCommand` → `POST /upgrade/addons/purchase` bumps the Stripe subscription quantity and invoices immediately). Enabling a connection never charges — it only *gates*. So a user can be charged in the proactive purchase path and then abandon the OAuth/hosted-auth, paying for a connection that never exists. Billing is effectively prepaid, not usage-based.

## Goals

- **(a) Always prompt for explicit consent before authorization.** The user learns "this connection costs $X/mo" and agrees *before* handing over account access.
- **(b) Bill only for actual usage.** No charge unless the connection is actually authorized and enabled. Abandon at any step → no charge.

## Non-goals / constraints

- **App Store / StoreKit is constrained.** Apple charges at purchase via its own sheet; StoreKit cannot defer the charge to enable time. On App Store we therefore keep "purchase-then-connect," but we move the StoreKit sheet **before** authorization (the sheet *is* the explicit consent; abandoning it = no charge). Buy-then-abandon-auth leaves a cancelable Apple subscription — inherent to Apple's prepaid model, accepted and documented. (Premium add-ons on Apple are the tiered `addon_1/2/3`; regular-beyond-pool on Apple stays Pro-only — unchanged.)
- Twist add-ons are out of scope for this change (this is connection add-ons). The same principle could later apply to twist add-ons, but twist capacity is enforced at install and is not part of these two symptoms.
- No schema migration: all required columns already exist.

## Core principle

Make the add-on charge **a consequence of a connection enabling**, symmetric with the existing *reconcile-down* on disable:

- Today: disable a billable connection → `reconcileScope...Down` lowers the Stripe quantity → credit.
- New: enable a billable connection (after consent, with a card on file) → **reconcile-up** raises the Stripe quantity → charge.

The add-on quantity then always tracks actual billable usage. The only thing that ever raises the charge is enabling a billable connection *with consent*.

## Platform split

| Path | Consent | Charge timing |
| --- | --- | --- |
| Web / DMG / Android (Stripe) | In-app consent prompt before auth; $0 Stripe **setup** session captures a card if none on file (no charge) | **On enable** (reconcile-up), only when the connection actually enables |
| App Store (StoreKit) | StoreKit purchase sheet, shown **before** auth | At purchase (Apple constraint); abandoning the sheet = no charge |

## Component changes

### 1. One consent gate before authorization (client — `apps/plot/lib/command/twist.dart`, `upgrade.dart`)

Collapse the divergent proactive/reactive × premium/regular at-limit paths into a **single pre-auth capacity gate** that runs *before* the auth CTA whenever the connection being added will be billable:

- **Billability** is read from `usage`: a premium connector is always billable; a regular connector is billable when `personal.connections.count >= pool` (or the team equivalent). Trial/Pro/Team with an unlimited pool → not billable → no gate.
- **Prompt** (reuse/extend `ConnectionCapacityOffer` and `BuyAddonCommand`):
  - Web, premium connector: a single consent — "Connecting LinkedIn adds a $5/mo connection add-on, billed only once it's connected." (No "upgrade instead" — premium always needs the add-on, even on Pro.)
  - Web, regular beyond pool: the existing add-on **OR** upgrade-to-Pro choice.
  - App Store, premium: the StoreKit add-on tier sheet (before auth).
  - App Store, regular beyond pool: Pro-only (unchanged).
- **On consent (web):** ensure a card is on file; if not, open the $0 setup session, then return and continue. **Do not charge here.** Record the user's consent so the subsequent enable is authorized to reconcile-up.
- **Then** proceed to authorization (OAuth / "Continue with LinkedIn").
- Replace the proactive `_connectionAtLimitCommand()` calls for the *billable* case with this gate; gate the premium auth CTA behind it (fixes symptoms #1 and #2). Keep the reactive `addon_required` 403 → same gate as a **safety net** for stale-usage races.

### 2. Reconcile-up on enable, consent-gated (server — `workers/api/src/utils/limits.ts`, `stripe/addons.ts`, the enable handlers)

The enable path (`checkChannelConnectionLimit` and the `activateDraft` / channel-enable handlers) accepts a `consentAddon: true` signal from the client. When enabling a connection where `billable > purchased`:

- `consentAddon` **+ card on file** → reconcile the add-on quantity **up** to the new billable count (the charge), then enable. Reuse the existing quantity-set logic; this is the same Stripe call the purchase endpoint makes, now triggered by enable.
- `consentAddon` **+ no card** → return `needs_card` → client opens the $0 setup session, then retries the enable.
- **no** `consentAddon` → return `addon_required` (today's behavior) → client shows the consent gate. (Back-compat: older clients that never send the flag keep working through this path.)
- **Ordering / failure:** enable the connection (DB), then reconcile-up the billing. A transient Stripe failure self-heals on the next reconcile (consistent with the existing down-direction design); a hard card decline surfaces an error and falls to Stripe dunning rather than silently providing a free connection.

### 3. Card capture becomes a $0 setup session (server — `stripe/addons.ts` `createAddonCheckoutSession`)

Switch the add-on checkout to **setup mode** (save a card without charging). The subscription/charge is created off-session by the enable path's reconcile-up. Return URL: `/upgrade?addon=card_saved` with a "card saved — connect to finish" message (mirrors the existing "connect again to finish" pattern). The web `/upgrade` page handles the new `card_saved` return param.

### 4. Hardening: the generic reconcile is down-only

`reconcileScopeAddonBillingDown` (and the twist equivalent) must clamp to **never exceed** the currently purchased quantity (`min(current, billable)`), so background syncs and other non-consented paths can never silently raise a charge. Only the consented-enable path (component 2) raises the quantity. This makes "no consent → no new charge" an invariant, not an accident of which events happen to fire.

## Data flow (web, premium connector, no card on file)

1. User selects LinkedIn → client sees it's billable + no spare credit → **consent gate**: "Adds a $5/mo connection add-on, billed once connected."
2. User consents → no card → `createAddonCheckoutSession` (setup, $0) → Stripe → card saved → return to `/upgrade?addon=card_saved`.
3. User returns and authorizes LinkedIn ("Continue with LinkedIn").
4. `activateDraft` runs with `consentAddon: true` → server: `billable(1) > purchased(0)`, consent present, card on file → reconcile-up to quantity 1 (charge $5/mo prorated) → enable.
5. If the user abandons at step 3, nothing enables → **no charge** (saved card is harmless).

## Edge cases

- **Abandon auth after consent** → no enable, no charge.
- **Card declined on enable** → error surfaced; connection not silently free; Stripe dunning applies.
- **Stale usage** (client thought it wasn't billable) → server `addon_required` 403 → reactive consent gate.
- **Disable** → reconcile-down → credit (unchanged).
- **Team scope** → admin-gated, Stripe/web (unchanged); the consent gate routes team purchases to the admin/web flow.
- **Old clients** (no `consentAddon`) → `addon_required` → existing purchase path still works.

## Backwards compatibility

- `consentAddon` is a new optional request field; absent → server behaves exactly as today (`addon_required`), so old clients keep working.
- `POST /upgrade/addons/purchase` remains for the back-compat/reactive path; the new primary path is consent-gate → enable → reconcile-up. (The legacy absolute-quantity `POST /upgrade/addons` stays dormant/deprecated as before.)
- `createAddonCheckoutSession` changing from subscription-mode to setup-mode is the one behavior change to verify against any other caller; today its only callers are the add-on purchase paths.

## Testing

**Server (TDD, DB-backed — worktree DB):**
- enable + `consentAddon` + card on file → quantity reconciles up + connection enabled.
- enable + `consentAddon` + no card → `needs_card`, no charge, not enabled.
- enable without `consentAddon` (billable) → `addon_required`, no charge.
- abandon (no enable) → no quantity change.
- disable → reconcile-down.
- background reconcile path can never raise quantity above purchased (down-only invariant).
- card decline on enable → surfaced; not silently free.

**Flutter (`flutter analyze` whole project incl. `test/`):**
- consent gate precedes the auth CTA for premium + regular-beyond-pool on web.
- platform matrix: web (add-on or Pro; premium consent), App Store (Pro-only regular; StoreKit tier premium, sheet before auth).
- no charge path reachable before consent.

## Affected files (initial map)

- Client: `apps/plot/lib/command/twist.dart` (unify at-limit entry points, gate premium auth CTA, thread `consentAddon` into activate/enable), `apps/plot/lib/command/upgrade.dart` (`ConnectionCapacityOffer`, `BuyAddonCommand` → consent + setup-card capture, no upfront charge), `apps/plot/lib/api/upgrade_api.dart` / `iap_api.dart` (plumbing).
- Server: `workers/api/src/utils/limits.ts` (`checkChannelConnectionLimit` consent + reconcile-up; down-only clamp), `workers/api/src/stripe/addons.ts` (`createAddonCheckoutSession` → setup mode; reconcile-up helper), the `activateDraft` / channel-enable handlers (`workers/api/src/app/twists.ts` and/or `twist/tools/integrations.ts`), `workers/api/src/app/upgrade.ts` (return params).
- Site: `apps/site/app/routes/upgrade.tsx` (`?addon=card_saved` return handling).
