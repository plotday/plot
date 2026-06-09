# Onboarding Pro connection gating — Design

**Date:** 2026-06-09
**Status:** Approved (brainstorm) — pending implementation plan

## Goal

Limit Pro connections during onboarding in the Flutter app. Add a "Pro" badge
to Pro connector tiles and, when a tile is tapped by a user who can't add
another Pro connection, show the existing upgrade selection modal instead of
opening the connector setup flow.

## Background (existing code)

- Onboarding "Connect your tools" tiles live in
  `apps/plot/lib/widget/onboarding/onboarding_tools.dart` (`_ToolTile`).
  Tapping a tile calls `_openSetup(twist)` → `AddSourceDetail(...).run(context)`.
- `Twist.premium` (`apps/plot/lib/api/twist_api.dart`) is already `true` for Pro
  connectors (e.g. LinkedIn, Unipile-backed).
- A "Pro" badge already exists as the private `_PremiumBadge` in
  `apps/plot/lib/command/twist.dart`, used in two places inside
  `ManageConnections` (active + available source rows).
- The upgrade picker already exists: `ShowUpgradeOptions({title, subtitle})` in
  `apps/plot/lib/command/upgrade.dart` (Core vs Pro `SelectModal`, routes to
  `BuyPlanCommand`).
- A full premium gate already exists in `twist.dart`:
  `_premiumGateCommand({usage, owner, isPremium})` → `_evaluatePremium(...)`,
  returning `_premiumBlockedCommand()` (Free/Core) or
  `_premiumAtLimitCommand(...)` (Pro who used their included Pro connection,
  or team pool exhausted), or `null` when allowed. `AddSourceDetail` already
  applies this gate **inside** the setup modal (swaps the auth button for an
  upgrade button), but only when the user has no team.
- Pro status / quotas come from `UpgradeApi.getUsage()` → `UsageData`
  (`apps/plot/lib/api/upgrade_api.dart`): `usage.personal.premium`
  (`PremiumPolicy.blocked|credits|weighted`, `isAtLimit`, `weight`),
  `usage.teams`.

What's missing: the **upfront** badge on onboarding tiles and intercepting the
tap **before** the setup modal opens.

## Decisions

1. **Badge visibility:** always show the "Pro" badge on `twist.premium`
   connectors, regardless of the user's plan (consistent with
   `ManageConnections`). The badge is informational ("this is a Pro feature").
2. **Gating rule:** full usage-based gate (reuse `_premiumGateCommand` /
   `_evaluatePremium`). This also blocks a Pro user who has already used their
   one included Pro connection — not just Free/Core users.
3. **Team fallback:** mirror `AddSourceDetail` — only gate preemptively on the
   tile tap when the user has **no team** (`usage.teams.isEmpty`). If they have
   a team, proceed into `AddSourceDetail` where the team-aware gate runs.
   (Onboarding users are almost always team-less; this is correctness
   insurance.)

## Code changes

### `apps/plot/lib/command/twist.dart`

Add a thin public wrapper around the existing private gate:

```dart
/// Onboarding-facing gate: the upgrade command to run instead of opening
/// setup for a premium connector, or null to proceed. Mirrors the preemptive
/// gate AddSourceDetail applies (only when the user has no team to fall back
/// to — team-aware gating happens inside the setup modal).
Command? premiumOnboardingGate({
  required UsageData usage,
  required bool isPremium,
}) {
  if (!isPremium || usage.teams.isNotEmpty) return null;
  return _premiumGateCommand(usage: usage, owner: 'personal', isPremium: true);
}
```

Replace the two `_PremiumBadge()` usages with the shared `ProBadge` (below) and
remove the private `_PremiumBadge` class.

### `apps/plot/lib/widget/pro_badge.dart` (new)

Extract the existing `_PremiumBadge` body verbatim into a public `ProBadge`
widget (theme `primary` color at 12% alpha, rounded pill, "Pro" text). Used by
both `twist.dart` and onboarding.

### `apps/plot/lib/widget/onboarding/onboarding_tools.dart`

- `_load()`: add `UpgradeApi.getUsage()` to the existing `Future.wait`; store
  `UsageData? _usage` in state. (Existing `catch` already logs + clears the
  spinner.)
- `_ToolTile`: when `twist.premium`, render `ProBadge` trailing the name (after
  the `Flexible` name, with small leading spacing).
- `_openSetup(twist)`: at the top, if `_usage != null`, compute
  `premiumOnboardingGate(usage: _usage!, isPremium: twist.premium)`. If
  non-null: `await gate.run(context)`, then `if (mounted) await _load();`
  (refresh usage so an upgraded user can immediately tap through), and return.
  Otherwise fall through to today's `AddSourceDetail` flow.
- Import `package:plot/api/upgrade_api.dart` for `UsageData` / `UpgradeApi` and
  `package:plot/widget/pro_badge.dart`.

## Failure / edge handling

- Usage fetch failure → `_usage == null` → badge still shows (driven by
  `twist.premium`); tap falls through to `AddSourceDetail`, whose own gate is
  the backstop. No new error path.
- No DB / schema / API changes. No `FONT_CACHE_VERSION` bump (no new icons).

## Testing

`premiumOnboardingGate` is a pure function — unit test it:

- not premium → `null`
- premium + Free/Core (`PremiumPolicy.blocked`) → blocked upgrade command
- premium + Pro at limit (`credits`, `isAtLimit == true`) → at-limit command
- premium + Pro allowed (`credits`, not at limit) → `null`
- premium + user has a team → `null` (defer to setup modal)

(Assert on the returned command's identity/title rather than running it.)

## Out of scope

- No change to `AddSourceDetail`'s internal gate (still the backstop / team
  path).
- No change to the upgrade modal copy or `BuyPlanCommand`.
- No change to `_UpgradeCopy` footer text.
