# Cross-platform subscriptions: StoreKit (IAP) + Stripe — design

**Date:** 2026-06-18
**Status:** Approved design, pre-implementation
**Author:** Kris Braun (with Claude)

## Problem

New Plot users are automatically granted a **30-day free Core trial**, implemented
today as a **Stripe-native subscription** (`createInitialTrialSubscription`,
`workers/api/src/stripe/utils.ts`, `trial_period_days: 30`, no card collected).
Free users likewise carry a **`free_monthly` Stripe subscription**
(`createFreeSubscription`) purely to track monthly usage allocations.

On App Store builds the in-app upgrade entry (`ShowUpgradeOptions`) is gated on
`isFree || isAppStoreOrigin`. A trial user is `plan=core, status=trialing,
origin=stripe`, so the gate **hides all IAP options** — a trial user cannot
subscribe (Core or Pro) from iOS/Mac at all. When the trial ends they silently
drop to free with no in-app purchase path. This was discovered while validating
StoreKit: signed in as a trialing user, Settings showed only "Restore purchases".

We are introducing **StoreKit (IAP) as a real, first-class purchase path** that
coexists with Stripe, following Apple's best practices for cross-platform
subscriptions (a single unified entitlement, sold on whichever platform, honored
everywhere, never double-billed).

## Goals

- Trial and free users can purchase **Core** or **Pro** via IAP on iOS/Mac.
- IAP purchases charge **immediately** (no Apple introductory/free-trial offer).
- Entitlements created **outside** IAP (Stripe trial or paid) are fully honored
  in the Apple apps — users keep all benefits without being forced to re-buy.
- **Exactly one active billing source** per user at a time (Stripe *or* Apple);
  no double-billing.
- Users can **manage** an existing subscription: App-Store subs via Apple, paid
  Stripe subs via the web.

## Non-goals

- Matching Apple's free period to the *remaining* days of the Plot trial
  (Apple intro offers are fixed-duration; rejected as not worth the complexity).
- Mirroring StoreKit purchases into Stripe as the single source of truth
  (rejected — "phantom" non-charging Stripe subs are fragile). We track both
  origins in the unified table instead.
- Changing the existing trial-grant-on-signup behavior.

## Decisions (resolved during brainstorming)

1. **IAP charges immediately**, even with trial remaining — no Apple intro offer.
2. **External (Stripe) entitlements are honored** in the Apple apps.
3. **Paid Stripe** users: iOS can only **manage on the web** (no IAP).
4. **Stripe trial** users: iOS **can** upgrade via IAP, which **cancels** the
   Stripe trial.
5. **Source of truth:** unified `user_subscription` row, **tracking both
   origins**, invariant of at most one active source.
6. The **`free_monthly` Stripe tracker** is also canceled on IAP purchase, and
   **recreated** when the Apple sub cancels/lapses (to restore usage tracking).
7. Paid-Stripe management label: **"Manage your subscription"** (tappable → web).
8. App-Store **Core → Pro** upgrade is allowed from iOS.

---

## Section 1 — Entitlement model & invariant

`user_subscription` remains the single **unified entitlement row** per user. It
already carries `plan`, `status`, `origin`, `billing_cycle_start/end`,
`trial_ends_at`, `stripe_customer_id`, `stripe_subscription_id`,
`apple_original_transaction_id`, `apple_product_id`. The effective plan
(personal vs org/team) is computed by `getEffectivePlan`.

**Invariant: at most one active billing source per user at a time** — either a
Stripe subscription *or* an Apple (IAP) subscription, never both.

Representations:

| State | Row |
|---|---|
| Free tier | `free_monthly` **Stripe** sub → `plan=free, origin=stripe, status=active` |
| Stripe Core trial | `plan=core, status=trialing, origin=stripe` |
| Paid Stripe Core/Pro | `plan=core\|pro, status=active, origin=stripe` |
| Apple Core/Pro | `plan=core\|pro, status=active, origin=app_store`, `apple_*` set |

Usage allocations read from this row (`billing_cycle_*`, `plan`) **regardless of
origin**, so an Apple-subscribed user needs no Stripe sub. Switching billing
source cancels the other side (Section 3) so the row always reflects exactly one
live source.

## Section 2 — Client gating matrix (App Store builds)

Replaces the current `isFree || isAppStoreOrigin` gate in
`apps/plot/lib/command/settings.dart` (`settingsCommandsFromState`). Decision is
driven by `(effectivePlan, origin, status)`:

| Current state | Upgrade via IAP | Manage | Restore |
|---|---|---|---|
| `free` (free_monthly stripe) | **Core + Pro** | — | ✓ |
| `core` **trialing**, stripe | **Core + Pro** (converting cancels the Stripe trial) | — | ✓ |
| `core` **active**, stripe (paid web) | — | **"Manage your subscription"** → web | ✓ |
| `pro`/`team` active, stripe (paid web) | — | **"Manage your subscription"** → web | ✓ |
| `core` active, **app_store** | **Pro only** (Apple-managed upgrade) | "Manage your subscription" → Apple URL | ✓ |
| `pro` active, **app_store** | — | "Manage your subscription" → Apple URL | ✓ |
| `pro`/`team` via **org** (`effective_source = org`) | — (existing `!canBuildTwists` hide) | — | ✓ |

Behavioral notes:

- The **convertible** states are `free` and Stripe-`trialing` — this is the core
  fix that unblocks new users buying on iOS.
- **Paid Stripe → web-managed**, never offered IAP.
- `ShowUpgradeOptions` (`apps/plot/lib/command/upgrade.dart`) currently shows a
  fixed `['core', 'pro']` picker. It must be **filtered by current tier**:
  free/trialing → Core + Pro; app_store-core → Pro only.
- `RestorePurchases` stays unconditional on App Store builds.

**Required client model change:** `SubscriptionInfo` (`apps/plot/lib/api/upgrade_api.dart`)
must parse **`status`** from `/upgrade` (the server already returns it;
`fromJson` currently parses only `plan`, `effective_plan`, `effective_source`,
`origin`). Add `status` and a derived helper, e.g.:

```dart
bool get isStripeTrial => origin == 'stripe' && status == 'trialing';
bool get isPaidStripe  => origin == 'stripe' && status == 'active' && effectivePlan != 'free';
bool get isAppStore    => origin == 'app_store';
```

Note the server nulls `origin` for free plans
(`workers/api/src/app/upgrade.ts:56`), so `free` is uniformly `origin=null`.

## Section 3 — Purchase & reconciliation flows (server)

### A. Convert to Apple (free or `trialing` → IAP)

1. Client `BuyPlanCommand(plan)` (`apps/plot/lib/command/upgrade.dart`) →
   StoreKit purchase → POST `/upgrade/iap/verify` with the signed JWS.
2. Server `applyAppleTransactionToUser` (`workers/api/src/apple/iap.ts`):
   - Verify JWS (existing).
   - **Cancel the user's live Stripe sub** (`free_monthly` *or* the Core trial)
     via the Stripe API — immediately (no paid value lost).
   - Upsert the row → `origin=app_store`, `plan` from product, `status=active`,
     `apple_original_transaction_id`, billing cycle from the txn; clear
     `stripe_subscription_id` (keep `stripe_customer_id`).
3. **Race guard:** the `customer.subscription.deleted` webhook Stripe fires from
   that cancel must **not** recreate `free_monthly` — the Stripe webhook handler
   checks the row is now `origin=app_store` + active and no-ops.

### B. Apple sub ends → back to free

Triggers (ASSN V2 at `/hook/appstore`, `workers/api/src/webhook.ts`):
`EXPIRED`, final `DID_FAIL_TO_RENEW`, `REFUND`, `REVOKE`.

1. Deactivate the Apple entitlement on the row.
2. **Recreate the `free_monthly` Stripe sub** (`createFreeSubscription`) → row
   returns to `plan=free, origin=stripe, status=active`, restoring usage
   tracking.

### C. Invariant helper

A single "switch billing source" code path enforces *cancel-old-before-
activate-new*. All webhook handlers (Stripe and Apple) defer to the row's
current `origin` so late/out-of-order events cannot double-activate.

### D. Defense-in-depth

`/upgrade/iap/verify` (`workers/api/src/app/upgrade.ts`) rejects (no-op) if the
user already has an **active paid Stripe** sub, so a malformed/old client can
never trigger double-billing.

## Section 4 — Management UX & App Store 3.1.1

- **app_store sub** → "Manage your subscription" → `apps.apple.com/account/subscriptions`
  (existing `ManageSubscriptionCommand`).
- **paid Stripe sub** → "Manage your subscription" → opens web management in the
  external browser.
- **No new-purchase CTAs** anywhere on App Store builds — *new* purchases always
  go through IAP. The web link only **manages an existing** subscription (same
  risk-class as the existing `ManageTeams` web link; not a purchase CTA).
- **Residual review consideration:** the paid-Stripe "Manage your subscription"
  web link is the one outbound surface for a paying user. It is management, not
  purchase, and is the same posture as the existing team-management link, but it
  should be reviewed against current 3.1.1 posture before submission.
- The auto-renew + Terms/Privacy disclosure already on the IAP paywall stays.

## Section 5 — StoreKit product configuration

- Keep both products at **`introductoryOffer: null`** (immediate charge). Core
  `day.plot.app.core_monthly` $14.99/mo; Pro `day.plot.app.pro_monthly`
  $24.99/mo; period `P1M`.
- Both remain in **one subscription group** (`21300000`) so Apple natively
  handles Core↔Pro upgrade/downgrade and proration.
- No App Store Connect intro-offer work needed. The local `apps/plot/ios/Plot.storekit`
  already matches.

## Section 6 — Edge cases

- **Grace period:** `DID_FAIL_TO_RENEW` + subtype `GRACE_PERIOD` → keep
  entitlement active; deactivate (and recreate `free_monthly`) only on final
  `EXPIRED`. Do not drop to free during grace.
- **Refund / revoke:** `REFUND` / `REVOKE` → revoke entitlement immediately →
  recreate `free_monthly`.
- **Apple Core↔Pro change:** `DID_CHANGE_RENEWAL_PREF` (downgrade defers to
  period end) / immediate upgrade → update `plan` from renewal info; stays
  `origin=app_store`.
- **Web mirror of the invariant:** if a user has an **active app_store** sub and
  attempts to subscribe on the **web**, the web flow routes them to "manage on
  Apple" instead of creating a Stripe sub.
- **Team/org-covered users:** when `effective_plan` is `pro`/`team` via an org,
  the existing `!canBuildTwists` gate hides IAP — no personal purchase offered.
- **Trial expiry without conversion:** unchanged — Stripe cancels at trial end
  (`missing_payment_method: cancel`) → existing downgrade-to-free path.
- **Restore on a new device:** Restore purchases re-verifies the Apple
  `original_transaction_id` and re-links the entitlement (existing).
- **Sandbox / App Review:** the server accepts Sandbox JWS (existing). A
  fresh reviewer account gets a Stripe Core trial → on iOS sees Core + Pro IAP
  (trialing is convertible) → can complete a Sandbox purchase. This keeps IAP
  reachable for review.

## Section 7 — Testing

- **Server units** (extend `workers/api/src/apple/iap.test.ts`):
  - Convert cancels the live Stripe sub and flips the row to `app_store`.
  - Apple-end (`EXPIRED`/`REFUND`/`REVOKE`) recreates `free_monthly`.
  - Race guard: a stale `customer.subscription.deleted` after Apple is active is
    ignored (no free recreation).
  - `/upgrade/iap/verify` rejects when an active paid Stripe sub exists.
  - Grace period keeps entitlement; final expiry drops to free.
- **Gating unit test:** the Section-2 matrix → exact commands shown for each
  `(plan, origin, status)` combination.
- **Manual:**
  - **Level A** (StoreKit local, Xcode) — purchase sheet + convertible-state
    visibility (trial/free shows Core + Pro).
  - **Level B** (Sandbox / TestFlight) — full round-trip: trial → IAP → Stripe
    canceled → Apple active → cancel → `free_monthly` recreated, DB-verified.
- **Dev-seed fix:** add a genuinely **free** user and a **trialing** user to the
  seed (`generate-seed.ts`) so the paywall is reachable without DB surgery —
  fixes the gap found during this investigation (all dev users were on paid
  Stripe plans).

## Affected code (for planning)

**Client (`apps/plot/`):**
- `lib/api/upgrade_api.dart` — `SubscriptionInfo`: parse `status`; add helpers.
- `lib/command/settings.dart` — `settingsCommandsFromState`: new gating matrix
  for `ShowUpgradeOptions` / `ManageSubscriptionCommand` / `RestorePurchasesCommand`.
- `lib/command/upgrade.dart` — `ShowUpgradeOptions`: filter tiers by current
  plan; `ManageSubscriptionCommand`: route paid-Stripe → web.

**Server (`workers/api/`):**
- `src/apple/iap.ts` — `applyAppleTransactionToUser`: cancel Stripe sub on
  convert; clear `stripe_subscription_id`.
- `src/app/upgrade.ts` — `/upgrade/iap/verify`: paid-Stripe rejection guard.
- `src/webhook.ts` — `/hook/appstore`: on Apple-end events, recreate
  `free_monthly`; honor grace period.
- `src/stripe/*` — Stripe webhook (`customer.subscription.deleted`): race guard
  deferring to current `origin`; web subscribe path: app_store-active mirror.
- `src/stripe/utils.ts` — reuse `createFreeSubscription`; add a cancel helper if
  one doesn't exist.
- A shared "switch billing source" helper enforcing the one-active invariant.

**Data/seed:**
- `generate-seed.ts` — add free + trialing demo users.

## Open questions / residual risks

- **3.1.1 posture** of the paid-Stripe "Manage your subscription" web link
  (Section 4) — confirm before submission.
- **Stripe cancel semantics** for a genuinely *paid* Stripe sub that somehow
  reaches IAP (shouldn't, given gating + guard): immediate vs period-end. Trial
  and free cancel immediately (no value lost); the guard should prevent the paid
  case entirely.
