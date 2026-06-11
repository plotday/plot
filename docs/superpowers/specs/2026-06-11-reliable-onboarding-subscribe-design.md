# Reliable onboarding subscribe + plan-up toast

**Date:** 2026-06-11
**Status:** Design — approved for planning

## Problem

A user upgraded to Pro during onboarding. Because they were on macOS, checkout
happened in an external browser (Stripe). When they returned to the app and
tapped a Pro connector, they were shown the subscribe modal **again** even
though the subscription had already synced (the websocket reconnected and a
`subscription` change broadcast was received).

### Root cause

`OnboardingTools` (`apps/plot/lib/widget/onboarding/onboarding_tools.dart`)
caches `UsageData` in `_usage` at load time (`_load()`, line ~57) and the
Pro-connector gate reads that cached snapshot (`_openSetup`, line ~77):

```dart
final usage = _usage;                       // cached at _load()
if (usage != null) {
  final gate = premiumOnboardingGate(usage: usage, isPremium: twist.premium);
  ...
}
```

The web upgrade path just launches the browser and returns immediately
(`upgrade.dart` `_runWeb` → `CommandSkipped`). The `_load()` refresh that runs
right after the gate fires **before** Stripe checkout completes, so it re-caches
the still-free usage. When the user returns to the app, **nothing re-fetches
usage on refocus**, so the cached "free / blocked" snapshot still gates them and
the subscribe modal reappears.

Two structural facts make this worse:

- The normal setup flow in `twist.dart` re-fetches `getUsage()` fresh on every
  command run (lines ~1223, ~1774, ~2593…), so it is largely self-healing — the
  cached onboarding snapshot is the outlier.
- `Store.onSubscriptionChanged` is a **single callback slot**, currently claimed
  by `GlobalShortcuts`. Nothing else can react to subscription changes, so there
  is no clean way for onboarding (or anything else) to refresh on a sub change.

## Goals

1. Subscribing during onboarding is reliable in **all** cases — Pro connections
   and going beyond the connection limit — regardless of whether the purchase
   completed via StoreKit (in-app) or the web/Stripe flow (external browser).
2. Show a success toast when the app is **refocused** and a subscription has been
   added. This applies app-wide, not just in onboarding.
3. Honor the **Team plan** when a user is already on it: an existing team member
   can add Pro connections. (We never *offer* Team — it is not a StoreKit
   product — we only honor it when present.)

## Non-goals

- No "upgrade to Team" CTA anywhere. The upgrade picker (`ShowUpgradeOptions`)
  stays core/pro only.
- No persistence of the toast baseline across app restarts (in-memory only).
- No change to the server-side subscription/usage/`/team` endpoints.

## Design

### 1. `SubscriptionService` singleton (new)

`apps/plot/lib/state/subscription_service.dart` — mirrors the existing
`BroadcastClient.connectionState` `ValueNotifier` idiom.

Holds the latest **`SubscriptionSnapshot`** (Equatable):

```dart
class SubscriptionSnapshot {
  final SubscriptionInfo? subscription;
  final UsageData? usage;
  final List<Map<String, dynamic>> adminOrgs;
  final bool hasTeams;
}
```

Exposed as a `ValueListenable<SubscriptionSnapshot>` so many widgets can react
(replacing the single-callback bottleneck).

Methods / behavior:

- `refresh()` — fetches `getSubscription()` + `getUsage()` + `/team`
  concurrently and updates the notifier. **Coalesces** concurrent calls: a
  single in-flight future is reused so a burst of triggers (reconnect +
  broadcast + resume) results in one round-trip.
- `ensureFresh()` — awaitable; triggers/awaits a refresh. Used by the onboarding
  gate before it evaluates so the first tap after returning from the browser
  sees post-upgrade usage.
- Is a `WidgetsBindingObserver`: on `AppLifecycleState.resumed` → `refresh()`,
  then run the plan-up check (§2).
- Becomes the single consumer of `Store.onSubscriptionChanged` (both the
  websocket-reconnect path and the `subscription` broadcast call it) → `refresh()`.
  The store keeps its one callback slot; the service fans out via its notifier.
- `start()` on sign-in (initial load + baseline init). `reset()` on sign-out
  (clears snapshot + baseline so a fresh sign-in re-baselines). These are driven
  from the same place `GlobalShortcuts` currently fetches subscription / clears
  on sign-out.

### 2. Plan-up detection + toast

Effective-plan rank, read from `subscription.effectivePlan`:

| plan | rank |
|------|------|
| free | 0 |
| core | 1 |
| pro  | 2 |
| team | 2 |

(`pro` and `team` are co-top: a lateral pro↔team transition produces no toast,
since capability is equivalent.)

The service keeps an in-memory **acknowledged rank** baseline, set on the first
successful load (so cold start never toasts).

The plan-up check runs **only** on the `resumed`-triggered refresh:

- If `currentRank > acknowledgedRank` → show a plan-aware toast via
  `navigatorKey?.currentContext?.showToast(...)`.
- Then set `acknowledgedRank = currentRank`. Downgrades also update the baseline
  (silently, no toast) so a later re-upgrade toasts again.

Broadcast/reconnect refreshes update the snapshot **but do not touch the
baseline**. So if the upgrade broadcast lands while the app is backgrounded, the
toast still fires on the next refocus. And because `resumed` *also* calls
`refresh()` itself, the toast + unblock happen even if no broadcast ever arrived
— this is the reliability guarantee.

The decision is a **pure function**, unit-testable:

```dart
/// Returns the toast message for a plan increase, or null for no toast.
String? planUpToastMessage({
  required int prevRank,
  required int newRank,
  required String newEffectivePlan, // 'core' | 'pro' | 'team' | 'free'
  required bool isAppStoreBuild,
});
```

Wording:

- `core` / `pro` (purchasable on all builds): **"You're now on Plot Core" /
  "You're now on Plot Pro"** — named on all builds.
- `team`: **neutral wording on all builds** — "You can now add more
  connections". Never names "Plot Team" (we do not surface Team as a buyable
  plan anywhere). This still confirms the new capability so the user understands
  why the Pro connector now works.

### 3. Honoring an existing Team membership

No new gating logic is required. Once `ensureFresh()` makes `usage.teams`
current:

- `premiumOnboardingGate` (`twist.dart` ~line 930) returns `null` whenever
  `usage.teams.isNotEmpty`, deferring to `AddSourceDetail`.
- `AddSourceDetail` runs team-aware gating: a team member's Pro connection uses
  the `weighted` policy (`_evaluatePremium`, lines ~965–974) — premium counts as
  3 from the team pool — instead of the personal premium credit.

The only reason this fails today is staleness (`usage.teams` showing `[]` before
membership syncs), which the refresh-on-refocus / `ensureFresh()` fix resolves.

### 4. Wiring changes

- **`OnboardingTools`**: drop the local `getUsage()` in `_load()`; read `usage`
  from the service and listen to its notifier so the UI updates if the snapshot
  changes while open. In `_openSetup`, `await SubscriptionService.instance
  .ensureFresh()` before calling `premiumOnboardingGate`. Remove the now-
  misleading immediate `_load()` after the gate (it re-cached stale usage).
- **`GlobalShortcuts`**: becomes a pure consumer of the service snapshot
  (`subscription`, `adminOrgs`, `hasTeams`) instead of fetching them itself and
  owning `onSubscriptionChanged`. Sign-in triggers `service.start()`; sign-out
  triggers `service.reset()`.

### 5. Avoiding a double-toast on in-app (StoreKit) purchase

In-app StoreKit purchases happen in the foreground (no `resumed` event) and
already show "Subscription active." inline (`upgrade.dart` `_runIap`,
`IapPurchaseStatus.purchased`). After a successful inline IAP purchase, call
`service.refresh()` then `service.acknowledgeBaseline()` so a later unrelated
refocus does not re-toast "You're now on Plot Pro".

## Edge cases

- **Toast context null early**: guard `navigatorKey?.currentContext` before
  showing the toast; skip if null.
- **Tap before resume-refetch lands**: `_openSetup` awaits `ensureFresh()`, so
  the gate always evaluates fresh usage even on an immediate tap.
- **Downgrade / removed from team**: no toast; baseline follows the lower rank.
- **Older server without `premium` payload**: unchanged — `_evaluatePremium`
  treats a missing payload as blocked (existing behavior).
- **App Store + Team**: handled by §2 wording (neutral, never names Team),
  consistent with `upgrade_api.dart`'s rule that Team must not be referenced on
  App Store builds.

## Testing

- Pure unit tests for `planUpToastMessage`: free→core, free→pro, free→team,
  core→pro, core→team, pro↔team (no toast), same rank (no toast), downgrade (no
  toast), and App Store vs non-App-Store wording for `team`.
- Unit test the service's refresh coalescing with a fake `UpgradeApi` (one
  round-trip for a burst of triggers; snapshot updates; baseline init on first
  load; baseline reset on `reset()`).
- Existing `premiumOnboardingGate` / `_evaluatePremium` tests stay green.
- Lifecycle wiring kept thin; the logic lives in the tested pure pieces.

## Files touched

- **New**: `apps/plot/lib/state/subscription_service.dart`
- **New**: `apps/plot/test/state/subscription_service_test.dart`
- `apps/plot/lib/widget/onboarding/onboarding_tools.dart` — consume service;
  `ensureFresh()` before gating.
- `apps/plot/lib/command/global.dart` — consume service; start/reset on
  sign-in/out.
- `apps/plot/lib/command/upgrade.dart` — `refresh()` + `acknowledgeBaseline()`
  after successful inline IAP.
- `apps/plot/lib/store/store.dart` — point `onSubscriptionChanged` at the
  service (or have the service register itself).
