# App Store add-on modal copy: clear upgrade framing

**Date:** 2026-06-27
**Status:** Approved (design)
**Branch:** `addon-modal-copy` (off `origin/main` @ 52158260d, includes #498)

## Problem

On the App Store, the connection and twist add-ons are **tiered, mutually-exclusive,
total-priced** auto-renewable subscriptions:

- Twist: `twist_addon_1/2/3` → 5 / 10 / 15 twist automations @ $11.99 / $23.99 / $35.99
- Connection: `addon_1/2/3` → 1 / 2 / 3 connections @ $5.99 / $11.99 / $17.99

When a user already holds tier 1 and buys tier 2, Apple replaces the tier-1
subscription and charges the **new total** ($23.99 / $11.99). But the live confirm
modals (`BuyTwistAddonCommand._runIap`, `BuyAddonCommand._runIap` in
`apps/plot/lib/command/upgrade.dart`, post-#498) present it like an increment at the
total price:

- Twist modal hardcodes `"Adds +5 twist automations"` for **every** tier, so tier 2
  reads "Adds +5 … $23.99/month" — looks like $23.99 buys 5 twists.
- Connection modal states no quantity at all, so tier 2 reads "$11.99/month" for what
  the user experiences as adding one connection.

The marginal-price framing can't be used cleanly (tier deltas are $12.00 / $6.00 vs the
nominal $11.99 / $5.99 per-unit price — a one-cent mismatch), so the fix anchors on the
**total**, which always equals the displayed (live) price exactly.

The **web/Stripe paths are genuinely incremental** (twist $10/+5 unbounded; connection
$5/+1 usage-synced) and are correct as-is — they are **out of scope**.

## Decision

Adopt **increment + total** framing on the App Store confirm modals only. State what's
changing (the increment) and anchor the total price with the new total capacity. Use an
"Upgrade to …" button verb on tiers 2/3 so the step-up (and Apple's proration/replacement
shown in the native sheet) reads correctly. All prices come from **live StoreKit**
(`IapService.productFor(...).price`); the price-less fallback keeps #498's behaviour.

The twist block size (5) becomes a single source of truth: surface
**`twistAddonBlockSize`** from `@plotday/pricing` (`TWIST_ADDON_BLOCK_SIZE`) in the
`/upgrade/usage` `pricing` object and read it in Flutter instead of hardcoding `5`.

## Exact copy

### Twist add-on — `BuyTwistAddonCommand._runIap` (App Store)
`blocks = twistAddonCount + 1` · `total = blocks × twistAddonBlockSize` · `price` = live
StoreKit price for `twist_addon_{blocks}`.

| State | priceLine | note | confirmLabel |
|---|---|---|---|
| First (count 0) | `Twist add-on — $<price>/month` | `Adds 5 twist automations. Billed separately from your plan.` | `Add for $<price>/month` |
| Upgrade (count ≥ 1) | `Twist add-on — $<price>/month` | `Adds 5 more twist automations (<total> total). Billed separately from your plan.` | `Upgrade to $<price>/month` |

(The `5` increment is `twistAddonBlockSize`. Price-less fallback: confirmLabel
`Add a twist add-on`, no priceLine — unchanged from #498.)

### Connection add-on — `BuyAddonCommand._runIap` (App Store)
`total = (premium.purchased) + 1` · `price` = live StoreKit price for `addon_{total}`.
`connectionName` is set when a premium connector (LinkedIn/Instagram/WhatsApp) triggered
the add-on; null on the proactive/generic path. Disclosure tail is #498's:
`Billed separately from your plan; it doesn't count toward your plan's connection limit.`

| State | priceLine | note | confirmLabel |
|---|---|---|---|
| First, generic | `Connection add-on — $<price>/month` | `Adds 1 connection. <tail>` | `Add for $<price>/month` |
| First, named | `Connection add-on — $<price>/month` | `<name> requires a connection add-on. <tail>` | `Purchase a connection add-on` |
| Upgrade, generic | `Connection add-on — $<price>/month` | `Adds 1 more connection (<total> total). <tail>` | `Upgrade to $<price>/month` |
| Upgrade, named | `Connection add-on — $<price>/month` | `<name> requires a connection add-on. Adds 1 more (<total> total). <tail>` | `Purchase a connection add-on` |

## Components & changes

1. **`@plotday/pricing`** — already exports `TWIST_ADDON_BLOCK_SIZE = 5`. No change.
2. **Server `/upgrade/usage`** (`workers/api/src/app/upgrade.ts` `getUsage`) — add
   `twistAddonBlockSize: TWIST_ADDON_BLOCK_SIZE` to the existing `pricing` object
   (alongside `connectionAddonPrice` / `twistAddonPrice`). Additive, backwards-compatible.
3. **Flutter usage model** (`apps/plot/lib/api/upgrade_api.dart`) — parse
   `pricing.twistAddonBlockSize` (nullable; default to `5` if absent so old servers/clients
   still work).
4. **Flutter `BuyTwistAddonCommand._runIap`** — branch first vs upgrade copy; compute
   `total = (current+1) × blockSize`; "Upgrade to" verb on upgrades.
5. **Flutter `BuyAddonCommand._runIap`** — branch first vs upgrade × named vs generic;
   compute `total = current+1`; "Upgrade to" verb on generic upgrades (named keeps
   "Purchase a connection add-on").
6. **Flutter `TwistCapacityOffer`** (entry chooser) — its add-on tile currently shows the
   **web** price (`$10`) and always "Add 5" on App Store. Fix the App Store path: ensure
   `IapService` is initialised, then show the live StoreKit price for the next tier
   (`twist_addon_{current+1}`) and mirror the confirm-modal framing:
   - first (count 0): title `Add 5 twist automations — $11.99/month`, details `Billed separately from your plan`
   - upgrade (count ≥1): title `Add 5 more twist automations — $23.99/month`, details `10 total · billed separately from your plan`
   - StoreKit price unavailable: omit the price (never show the web price on App Store).
   The web path is unchanged (`Add 5 twist automations — $10/month`). `5` increment and
   `total` use `twistAddonBlockSize`.
7. **`ConnectionCapacityOffer`** — **no change.** On App Store its add-on tile never renders
   (premium → straight to `BuyAddonCommand`; non-premium → Pro-only); the `$5` tile is
   web-only and correct.

## Out of scope

- Web/Stripe consent paths (`_purchaseViaEndpoint`, `_consent`) — correct as incremental.
- `ConnectionCapacityOffer` add-on tile — web-only; never renders on App Store (see item 7).
- The Pro upgrade modal (`ProUpgradeDetails`) and StoreKit loading bridge — unchanged from #498.
- Going "fully on-demand" (dropping the twist chooser) — explicitly rejected; the
  add-on-vs-Pro chooser stays to keep the Pro upsell at the limit.

## App Store review readiness

Goal: after this PR the App Store (iOS + Mac App Store) builds present every IAP purchase
surface with accurate, live, consistent pricing and Apple-compliant disclosure, and the
review screenshots match the app.

In scope (this PR):
- Twist + connection add-on confirm modals: correct increment+total copy, live prices.
- Twist capacity chooser: live App Store next-tier price (no web-price leak).
- Auto-renew + Terms/Privacy disclosure on every IAP-triggering screen (already present via
  `SubscriptionDisclosure`; verify nothing regressed).
- Accurate 2880×1800 review screenshots for all six add-on tiers.

Outside this PR's control (code cannot fix — flagged to user):
- **Paid Apps Agreement must be active with a bank account attached.** Per the prior 2.1(b)
  rejections, StoreKit returns the products as `notFoundIDs` (buy buttons look broken)
  while the Agreement is "Pending User Info". Account-level; must be resolved in App Store
  Connect before resubmission.
- The IAP products (`twist_addon_1/2/3`, `addon_1/2/3`, `pro_monthly`) must be configured,
  priced, and attached to the submitted version with their own review screenshots.
- Final on-device behaviour can only be verified in TestFlight (StoreKit does not load in
  local debug builds), so the local check is `flutter analyze` + the rendered review
  screenshots.

## Verification

- `flutter analyze` clean.
- IAP `_runIap` paths only render on App Store builds (StoreKit), so they can't be driven
  end-to-end locally — final on-device verification is TestFlight. Local verification:
  the **App Store review screenshots** (below) render the exact `ConfirmModal` +
  `SubscriptionDisclosure` widgets with the new copy.
- Backwards-compat: `/usage` field is additive; Flutter defaults blockSize to 5 if absent.

## Deliverable: regenerated App Store review screenshots

Regenerate **6** review screenshots (2880×1800, sRGB, Mac 16:10 spec) on this post-#498
branch (no Cancel row), via the temporary `reassemble()` capture hack
([[project_appstore_iap_modal_screenshot_capture]]):

- Twist tiers 1/2/3: $11.99 "Adds 5 twist automations"; $23.99 "Adds 5 more twist automations (10 total)"; $35.99 "Adds 5 more twist automations (15 total)".
- Connection tiers 1/2/3 (generic): $5.99 "Adds 1 connection"; $11.99 "Adds 1 more connection (2 total)"; $17.99 "Adds 1 more connection (3 total)".

Existing twist screenshots on the Desktop are superseded (they show the dropped Cancel
row and the old per-product totals).
