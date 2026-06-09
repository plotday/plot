# Onboarding Pro Connection Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During app onboarding, show a "Pro" badge on Pro connector tiles and, when a tile is tapped by a user who can't add another Pro connection, open the existing upgrade picker instead of the connector setup flow.

**Architecture:** Reuse the existing premium gate (`_premiumGateCommand` / `_evaluatePremium`) in `lib/command/twist.dart` via a new pure public wrapper `premiumOnboardingGate`. Extract the existing private `_PremiumBadge` into a shared `ProBadge` widget. Wire both into `OnboardingTools`: fetch `UsageData` on load, render the badge on `twist.premium` tiles, and run the gate before opening setup.

**Tech Stack:** Flutter / Dart, forui widgets, `flutter_test`. No backend, schema, or API changes.

---

### Task 1: Public onboarding gate wrapper + unit tests

Adds the pure function the onboarding tap handler will call, and tests it. TDD: test first.

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` (add `premiumOnboardingGate` near the existing `_premiumGateCommand`, ~line 946)
- Test: `apps/plot/test/command/onboarding_premium_gate_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/onboarding_premium_gate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/twist.dart';

UsageData _usage({PremiumUsage? premium, List<TeamUsage> teams = const []}) {
  return UsageData(
    personal: PersonalUsage(
      connections: const ResourceUsage(count: 0, limit: 2),
      twists: const ResourceUsage(count: 0, limit: 2),
      premium: premium,
    ),
    teams: teams,
  );
}

TeamUsage _team() => const TeamUsage(
  id: 'team_1',
  name: 'Acme',
  connections: ResourceUsage(count: 0, limit: 50),
  premium: PremiumUsage(policy: PremiumPolicy.weighted, weight: 3),
  isAdmin: true,
);

void main() {
  group('premiumOnboardingGate', () {
    test('returns null for a non-premium connector', () {
      final gate = premiumOnboardingGate(
        usage: _usage(premium: const PremiumUsage(policy: PremiumPolicy.blocked)),
        isPremium: false,
      );
      expect(gate, isNull);
    });

    test('blocks Free/Core users with the upgrade-to-Pro command', () {
      final gate = premiumOnboardingGate(
        usage: _usage(premium: const PremiumUsage(policy: PremiumPolicy.blocked)),
        isPremium: true,
      );
      expect(gate, isNotNull);
      expect(gate!.title, 'Upgrade to Pro to add a Pro connection');
    });

    test('blocks when premium payload is missing (treated as blocked)', () {
      final gate = premiumOnboardingGate(usage: _usage(), isPremium: true);
      expect(gate, isNotNull);
      expect(gate!.title, 'Upgrade to Pro to add a Pro connection');
    });

    test('blocks a Pro user who already used their included Pro connection', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(
            policy: PremiumPolicy.credits,
            count: 1,
            limit: 1,
            included: 1,
          ),
        ),
        isPremium: true,
      );
      expect(gate, isNotNull);
      expect(gate!.title, "You've used your included Pro connection");
    });

    test('allows a Pro user with an unused included Pro connection', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(
            policy: PremiumPolicy.credits,
            count: 0,
            limit: 1,
            included: 1,
          ),
        ),
        isPremium: true,
      );
      expect(gate, isNull);
    });

    test('defers to the setup modal when the user has a team', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(policy: PremiumPolicy.blocked),
          teams: [_team()],
        ),
        isPremium: true,
      );
      expect(gate, isNull);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/command/onboarding_premium_gate_test.dart`
Expected: FAIL — `premiumOnboardingGate` is undefined (compile error / "isn't defined").

- [ ] **Step 3: Add the wrapper to `twist.dart`**

In `apps/plot/lib/command/twist.dart`, immediately after the `_premiumGateCommand` function (ends ~line 946, before `enum _PremiumGate`), add:

```dart
/// Onboarding-facing gate: the upgrade [Command] to run instead of opening
/// setup for a premium connector, or null to proceed. Mirrors the preemptive
/// gate [AddSourceDetail] applies — we only gate on the tile tap when the user
/// has no team to fall back to; team-aware gating happens inside the setup
/// modal. Pure (no context/IO) so it is unit-testable.
Command? premiumOnboardingGate({
  required UsageData usage,
  required bool isPremium,
}) {
  if (!isPremium || usage.teams.isNotEmpty) return null;
  return _premiumGateCommand(usage: usage, owner: 'personal', isPremium: true);
}
```

Verify `UsageData` is already imported in `twist.dart` (it is — `_premiumGateCommand` and `_evaluatePremium` already take it). No new import needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/command/onboarding_premium_gate_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/twist.dart apps/plot/test/command/onboarding_premium_gate_test.dart
git commit -m "feat: add premiumOnboardingGate wrapper for onboarding tiles

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Extract shared `ProBadge` widget

Lift the existing private `_PremiumBadge` out of `twist.dart` into a shared widget so both `ManageConnections` and onboarding can use it. Pure refactor — no behavior change.

**Files:**
- Create: `apps/plot/lib/widget/pro_badge.dart`
- Modify: `apps/plot/lib/command/twist.dart` (remove `_PremiumBadge` class ~lines 829-854; replace 2 usages at lines 526 and 602; add import)

- [ ] **Step 1: Create the shared widget**

Create `apps/plot/lib/widget/pro_badge.dart` (body copied verbatim from the current `_PremiumBadge`, including its doc comment). `context.theme` resolves to forui's `FThemeBuildContext.theme` extension, so the only imports needed are `flutter/widgets.dart` (for `StatelessWidget`/`Container`/`Text`/`EdgeInsets`/`BoxDecoration`/`BorderRadius`) and `forui/forui.dart` (for the `theme` extension + `FThemeData`):

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Badge identifying a connector as "Pro" (has a real per-connection cost —
/// currently Unipile-backed integrations like LinkedIn). Drives plan-specific
/// metering separately from the regular connection pool.
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Pro',
        style: TextStyle(
          fontSize: theme.typography.xs.fontSize,
          color: theme.colors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Replace usages and delete the private class in `twist.dart`**

In `apps/plot/lib/command/twist.dart`:

1. Add the import alongside the other `package:plot/widget/...` imports at the top:

```dart
import 'package:plot/widget/pro_badge.dart';
```

2. Replace both occurrences of `const _PremiumBadge(),` (lines 526 and 602) with:

```dart
const ProBadge(),
```

3. Delete the entire private `_PremiumBadge` class (the doc comment block + class, ~lines 829-854).

- [ ] **Step 3: Verify no other references remain**

Run: `cd apps/plot && grep -rn "_PremiumBadge" lib/`
Expected: no output (zero matches).

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/pro_badge.dart lib/command/twist.dart`
Expected: "No issues found!" (fix the `context.theme` import in `pro_badge.dart` if analyze flags it as undefined).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/pro_badge.dart apps/plot/lib/command/twist.dart
git commit -m "refactor: extract shared ProBadge widget from twist.dart

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire badge + gate into onboarding

Fetch usage on load, show the badge on Pro tiles, and gate the tap.

**Files:**
- Modify: `apps/plot/lib/widget/onboarding/onboarding_tools.dart`

- [ ] **Step 1: Add imports**

`onboarding_tools.dart` already imports `package:plot/command/twist.dart` unrestricted (for `AddSourceDetail`, `SourceSummary`, `EditSource`), so `premiumOnboardingGate` is already in scope once Task 1 lands — do **not** add a second `twist.dart` import. Add only these two, grouped with the other `package:plot/...` imports:

```dart
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/widget/pro_badge.dart';
```

- [ ] **Step 2: Store usage in state and fetch it in `_load`**

In `_OnboardingToolsState` (after `bool _loading = true;`, ~line 41) add:

```dart
  UsageData? _usage;
```

In `_load()`, extend the `Future.wait` to also fetch usage and store the result. Replace the existing `Future.wait` block (lines 51-60) with:

```dart
      final results = await Future.wait([
        TwistApi.getAllTwists(),
        TwistApi.getSourcesSummary(),
        UpgradeApi.getUsage(),
      ]);
      if (!mounted) return;
      setState(() {
        _twists = results[0] as List<Twist>;
        _connected = results[1] as List<SourceSummary>;
        _usage = results[2] as UsageData;
        _loading = false;
      });
```

(The existing `catch` block that logs and clears `_loading` is unchanged — on failure `_usage` stays null, which the gate treats as fall-through.)

- [ ] **Step 3: Gate the tap in `_openSetup`**

At the very top of `_openSetup(Twist twist)` (before the existing `await AddSourceDetail(...)` on line 68), add:

```dart
    // Pro connectors: gate before opening setup. If the user can't add another
    // Pro connection (Free/Core, or a Pro user who used their included one),
    // show the upgrade picker instead. Usage may be null if it failed to load —
    // fall through to AddSourceDetail, whose own gate is the backstop.
    final usage = _usage;
    if (usage != null) {
      final gate = premiumOnboardingGate(usage: usage, isPremium: twist.premium);
      if (gate != null) {
        await gate.run(context);
        if (mounted) await _load(); // refresh so an upgraded user can proceed
        return;
      }
    }
```

- [ ] **Step 4: Render the badge in `_ToolTile`**

In `_ToolTile.build`, the `Row` currently ends with the `Flexible` name (lines 271-283). Add a trailing badge after the `Flexible(...)` child, inside the `Row`'s `children`:

```dart
            if (twist.premium) ...[
              const SizedBox(width: 8),
              const ProBadge(),
            ],
```

Place this immediately after the closing `),` of the `Flexible(` widget and before the `Row`'s `children: [` closing `]`. The `Row` already has `mainAxisSize: MainAxisSize.min`; the `Flexible` name ellipsizes so the badge stays visible.

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/onboarding/onboarding_tools.dart`
Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/onboarding/onboarding_tools.dart
git commit -m "feat: gate Pro connectors and show Pro badge in onboarding

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full analyze + targeted test run

Catch any cross-file fallout and confirm the suite is green.

**Files:** none (verification only)

- [ ] **Step 1: Analyze the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: "No issues found!" — if any pre-existing issues appear that are unrelated to these files, note them but do not fix unrelated code.

- [ ] **Step 2: Run the new + nearby tests**

Run: `cd apps/plot && flutter test test/command/`
Expected: all PASS (includes the new `onboarding_premium_gate_test.dart`).

- [ ] **Step 3: Verify (run-app)**

Use the `run-app` skill to launch Plot.app, reach the onboarding "Connect your tools" step, and confirm:
- LinkedIn (and any other Pro connector) shows a "Pro" badge.
- Tapping a Pro connector as a Free user opens the Core/Pro upgrade picker (not the connector setup modal).
- Tapping a non-Pro connector (e.g. Gmail) opens the normal setup flow unchanged.

(If the agent profile can't easily reach onboarding or drive a real subscription state, document what was and wasn't verified.)

---

## Notes for the implementer

- No `FONT_CACHE_VERSION` bump — no Font Awesome icons added/removed.
- No DB / Drift schema change, no API/worker change, no `public/` submodule change.
- `/finalize` afterward: lint is covered by Task 4 Step 1; `captureException` — no new catch blocks (the existing `_load` catch is unchanged); docs — this is a small UX gating change; add a one-line bullet to the top of `docs/updates.md` (e.g. "Pro connectors now show a Pro badge during setup, with a quick path to upgrade.").
