# Reliable Onboarding Subscribe + Plan-Up Toast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make subscribing during onboarding reliable in all cases (web/Stripe or StoreKit, Pro connections and connection-limit), and show a plan-aware success toast when the app is refocused after a subscription is added.

**Architecture:** Introduce a `SubscriptionService` singleton that holds the latest subscription + usage + team snapshot in a `ValueNotifier`, refreshed on websocket broadcast, reconnect, and app refocus (`AppLifecycleState.resumed`). It coalesces concurrent fetches and replaces the single-slot `Store.onSubscriptionChanged` consumer. The onboarding gate awaits a fresh snapshot before evaluating, so stale "free/blocked" usage can no longer reappear the subscribe modal. A pure helper decides the toast; only the refocus path shows it, comparing the current effective-plan rank against an in-memory acknowledged baseline.

**Tech Stack:** Flutter / Dart, `equatable`, `ValueNotifier`/`WidgetsBindingObserver`, forui toasts, existing `UpgradeApi`.

---

## Background for the implementer (read first)

- **The bug:** `OnboardingTools` caches `UsageData` at load and the Pro-connector gate reads that cached snapshot. After a browser/Stripe upgrade, nothing re-fetches usage on refocus, so the cached "blocked" value re-shows the subscribe modal.
- **Why the normal flow is fine:** `twist.dart`'s `AddSourceDetail` re-fetches `getUsage()` on every run, so it self-heals. Onboarding's cached snapshot is the outlier.
- **Team:** `effectivePlan` can be `'free' | 'core' | 'pro' | 'team'`. We never *offer* Team (not a StoreKit product). We only *honor* it: once usage is fresh, `premiumOnboardingGate` defers a team member's tile tap to `AddSourceDetail`'s team-aware `weighted` path, which allows the Pro connection from the team pool. So the staleness fix is all that's needed for team — plus the toast recognizing team as an entitlement increase.
- **Plan rank:** `free=0 < core=1 < pro=2 = team=2`. Toast fires when the rank increases. The toast names core/pro; for team it uses neutral wording ("You can now add more connections") so Team is never surfaced as a buyable plan.
- **Toast surface:** `navigatorKey?.currentContext?.showToast(message: ...)` — the app's global navigator key (`lib/main.dart`), already used for context-free toasts in `settings.dart`.

### File structure

- **New** `apps/plot/lib/state/subscription_plan.dart` — pure helpers `planRank()` and `planUpToastMessage()`. No I/O, no context. Single responsibility: the rank/wording policy.
- **New** `apps/plot/lib/state/subscription_service.dart` — the singleton service + `SubscriptionSnapshot`. Holds state, coalesces fetches, owns the lifecycle/broadcast wiring.
- **New** `apps/plot/test/state/subscription_plan_test.dart` — unit tests for the pure helpers.
- **New** `apps/plot/test/state/subscription_service_test.dart` — unit tests for coalescing, baseline, resume-toast, reset (with injected fakes).
- **Modify** `apps/plot/lib/command/global.dart` — consume the service snapshot; `start()`/`reset()` on sign-in/out.
- **Modify** `apps/plot/lib/widget/onboarding/onboarding_tools.dart` — read usage from the service; `ensureFresh()` before gating.
- **Modify** `apps/plot/lib/command/upgrade.dart` — `refresh()` + `acknowledgeBaseline()` after a successful inline IAP purchase.

---

## Task 1: Pure plan-rank + toast-message helpers

**Files:**
- Create: `apps/plot/lib/state/subscription_plan.dart`
- Test: `apps/plot/test/state/subscription_plan_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/subscription_plan_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/subscription_plan.dart';

void main() {
  group('planRank', () {
    test('orders plans free < core < pro = team', () {
      expect(planRank('free'), 0);
      expect(planRank('core'), 1);
      expect(planRank('pro'), 2);
      expect(planRank('team'), 2);
    });

    test('treats unknown/empty as free', () {
      expect(planRank('weird'), 0);
      expect(planRank(''), 0);
    });
  });

  group('planUpToastMessage', () {
    test('names core and pro on an upgrade', () {
      expect(
        planUpToastMessage(prevRank: 0, newRank: 1, newEffectivePlan: 'core'),
        "You're now on Plot Core",
      );
      expect(
        planUpToastMessage(prevRank: 1, newRank: 2, newEffectivePlan: 'pro'),
        "You're now on Plot Pro",
      );
      expect(
        planUpToastMessage(prevRank: 0, newRank: 2, newEffectivePlan: 'pro'),
        "You're now on Plot Pro",
      );
    });

    test('uses neutral wording for team (never names Team)', () {
      final msg =
          planUpToastMessage(prevRank: 0, newRank: 2, newEffectivePlan: 'team');
      expect(msg, 'You can now add more connections');
      expect(msg, isNot(contains('Team')));
    });

    test('returns null when rank did not increase', () {
      // same rank (lateral pro <-> team)
      expect(
        planUpToastMessage(prevRank: 2, newRank: 2, newEffectivePlan: 'team'),
        isNull,
      );
      // no change
      expect(
        planUpToastMessage(prevRank: 1, newRank: 1, newEffectivePlan: 'core'),
        isNull,
      );
      // downgrade
      expect(
        planUpToastMessage(prevRank: 2, newRank: 0, newEffectivePlan: 'free'),
        isNull,
      );
    });

    test('returns null for an increase into free/unknown', () {
      expect(
        planUpToastMessage(prevRank: 0, newRank: 0, newEffectivePlan: 'free'),
        isNull,
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/subscription_plan_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'plot' ... subscription_plan.dart` / "planRank isn't defined".

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/state/subscription_plan.dart`:

```dart
/// Pure plan-tier policy used to decide whether a subscription change is an
/// upgrade worth a toast, and what to say. No I/O and no BuildContext so it is
/// trivially unit-testable.
///
/// `effectivePlan` values come from the server: 'free' | 'core' | 'pro' | 'team'.
/// `pro` and `team` are co-top: they grant equivalent capability (unlimited /
/// pooled connections incl. Pro connectors), so a lateral pro<->team move is
/// not an "upgrade".
library;

/// Rank of an effective plan. Higher = more entitlement.
/// free(0) < core(1) < pro(2) == team(2). Unknown/empty is treated as free.
int planRank(String plan) {
  switch (plan) {
    case 'core':
      return 1;
    case 'pro':
    case 'team':
      return 2;
    default:
      return 0;
  }
}

/// Message to toast when the effective plan increases, or null for no toast.
///
/// Fires only when [newRank] > [prevRank]. Names the plan for the purchasable
/// tiers (core/pro). For `team` it uses neutral wording — we never surface
/// "Team" as a buyable plan anywhere in the app.
String? planUpToastMessage({
  required int prevRank,
  required int newRank,
  required String newEffectivePlan,
}) {
  if (newRank <= prevRank) return null;
  switch (newEffectivePlan) {
    case 'core':
      return "You're now on Plot Core";
    case 'pro':
      return "You're now on Plot Pro";
    case 'team':
      return 'You can now add more connections';
    default:
      return null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/subscription_plan_test.dart`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/subscription_plan.dart apps/plot/test/state/subscription_plan_test.dart
git commit -m "feat(subscribe): pure plan-rank + plan-up toast helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `SubscriptionService` + snapshot, with injected fakes for tests

**Files:**
- Create: `apps/plot/lib/state/subscription_service.dart`
- Test: `apps/plot/test/state/subscription_service_test.dart`

The service is constructed with injectable fetchers + a toast sink so the
refresh/baseline/resume logic is unit-testable without HTTP, `WidgetsBinding`,
or a real navigator. The production `instance` getter wires the real
`UpgradeApi` calls, the `/team` endpoint, and the global navigator toast.
`start()`/`reset()` (which touch `Store` and `WidgetsBinding`) are exercised
only by the running app — tests call `refresh()`, `handleAppResumed()`,
`acknowledgeBaseline()`, and `reset()` directly.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/subscription_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';

SubscriptionInfo _sub(String plan) => SubscriptionInfo(
      plan: plan,
      effectivePlan: plan,
      effectiveSource: 'personal',
    );

UsageData _usage({List<TeamUsage> teams = const []}) => UsageData(
      personal: const PersonalUsage(
        connections: ResourceUsage(count: 0, limit: 2),
        twists: ResourceUsage(count: 0, limit: 2),
      ),
      teams: teams,
    );

void main() {
  group('SubscriptionService', () {
    test('refresh fans the latest snapshot into the notifier', () async {
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: (_) {},
      );
      await svc.refresh();
      expect(svc.notifier.value.subscription?.effectivePlan, 'free');
      expect(svc.notifier.value.hasTeams, false);

      plan = 'pro';
      await svc.refresh();
      expect(svc.notifier.value.subscription?.effectivePlan, 'pro');
    });

    test('coalesces concurrent refreshes into one round-trip', () async {
      var calls = 0;
      final svc = SubscriptionService(
        fetchSubscription: () async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _sub('free');
        },
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: (_) {},
      );
      await Future.wait([svc.refresh(), svc.refresh(), svc.refresh()]);
      expect(calls, 1);
    });

    test('derives adminOrgs and hasTeams from the team payload', () async {
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub('free'),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => [
          {'id': 't1', 'role': 'admin'},
          {'id': 't2', 'role': 'member'},
        ],
        showToast: (_) {},
      );
      await svc.refresh();
      expect(svc.notifier.value.hasTeams, true);
      expect(svc.notifier.value.adminOrgs.length, 1);
      expect(svc.notifier.value.adminOrgs.single['id'], 't1');
    });

    test('first load sets the baseline so resume does not toast it', () async {
      final toasts = <String>[];
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub('pro'),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh(); // baseline := pro
      await svc.handleAppResumed(); // pro == pro, no toast
      expect(toasts, isEmpty);
    });

    test('resume toasts when the plan increased while backgrounded', () async {
      final toasts = <String>[];
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh(); // baseline := free
      plan = 'pro'; // upgraded in the browser
      await svc.handleAppResumed();
      expect(toasts, ["You're now on Plot Pro"]);
      // Acknowledged now — a second resume with no further change is silent.
      await svc.handleAppResumed();
      expect(toasts.length, 1);
    });

    test('team membership toasts with neutral wording', () async {
      final toasts = <String>[];
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh();
      plan = 'team';
      await svc.handleAppResumed();
      expect(toasts, ['You can now add more connections']);
    });

    test('acknowledgeBaseline suppresses a later resume toast (IAP path)',
        () async {
      final toasts = <String>[];
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh(); // baseline := free
      plan = 'pro';
      await svc.refresh(); // simulate IAP-driven refresh (no toast)
      svc.acknowledgeBaseline(); // IAP already showed its own toast
      await svc.handleAppResumed();
      expect(toasts, isEmpty);
    });

    test('reset clears the snapshot and baseline', () async {
      final toasts = <String>[];
      var plan = 'pro';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh();
      svc.reset();
      expect(svc.notifier.value.subscription, isNull);
      // After reset the next load re-baselines (no toast for the load itself).
      await svc.refresh();
      await svc.handleAppResumed();
      expect(toasts, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/subscription_service_test.dart`
Expected: FAIL — `subscription_service.dart` not found / `SubscriptionService` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/state/subscription_service.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/store/store.dart';
import 'package:plot/widget/toast.dart';
import 'subscription_plan.dart';

/// Immutable view of the current user's subscription/usage/team state.
class SubscriptionSnapshot extends Equatable {
  final SubscriptionInfo? subscription;
  final UsageData? usage;
  final List<Map<String, dynamic>> adminOrgs;
  final bool hasTeams;

  const SubscriptionSnapshot({
    this.subscription,
    this.usage,
    this.adminOrgs = const [],
    this.hasTeams = false,
  });

  @override
  List<Object?> get props => [subscription, usage, adminOrgs, hasTeams];
}

typedef SubscriptionFetcher = Future<SubscriptionInfo> Function();
typedef UsageFetcher = Future<UsageData> Function();
typedef TeamsFetcher = Future<List<Map<String, dynamic>>> Function();
typedef ToastSink = void Function(String message);

/// App-wide source of truth for subscription + usage state.
///
/// Refreshed on websocket broadcast, websocket reconnect, and app refocus.
/// Consumers listen to [notifier]; the onboarding gate awaits [ensureFresh]
/// before deciding whether to show the upgrade picker. A plan increase
/// detected on refocus surfaces a one-off success toast.
class SubscriptionService with WidgetsBindingObserver {
  SubscriptionService({
    required SubscriptionFetcher fetchSubscription,
    required UsageFetcher fetchUsage,
    required TeamsFetcher fetchTeams,
    required ToastSink showToast,
  })  : _fetchSubscription = fetchSubscription,
        _fetchUsage = fetchUsage,
        _fetchTeams = fetchTeams,
        _showToast = showToast;

  static SubscriptionService? _instance;
  static SubscriptionService get instance => _instance ??= SubscriptionService(
        fetchSubscription: UpgradeApi.getSubscription,
        fetchUsage: UpgradeApi.getUsage,
        fetchTeams: _defaultFetchTeams,
        showToast: _defaultShowToast,
      );

  final SubscriptionFetcher _fetchSubscription;
  final UsageFetcher _fetchUsage;
  final TeamsFetcher _fetchTeams;
  final ToastSink _showToast;

  final ValueNotifier<SubscriptionSnapshot> notifier =
      ValueNotifier<SubscriptionSnapshot>(const SubscriptionSnapshot());

  Future<void>? _inFlight;
  bool _baselineInitialized = false;
  int _acknowledgedRank = 0;
  bool _started = false;

  SubscriptionInfo? get subscription => notifier.value.subscription;
  UsageData? get usage => notifier.value.usage;

  /// Wire app-level triggers and load the initial snapshot. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    Store.get.onSubscriptionChanged = refresh;
    refresh();
  }

  /// Tear down on sign-out so a fresh sign-in re-baselines.
  void reset() {
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    Store.get.onSubscriptionChanged = null;
    notifier.value = const SubscriptionSnapshot();
    _baselineInitialized = false;
    _acknowledgedRank = 0;
    _inFlight = null;
  }

  /// Refetch subscription + usage + teams, coalescing concurrent callers.
  Future<void> refresh() {
    return _inFlight ??= _doRefresh().whenComplete(() => _inFlight = null);
  }

  /// Awaitable refresh used before gating decisions.
  Future<void> ensureFresh() => refresh();

  Future<void> _doRefresh() async {
    try {
      final results = await Future.wait([
        _fetchSubscription(),
        _fetchUsage(),
        _fetchTeams(),
      ]);
      final sub = results[0] as SubscriptionInfo;
      final usage = results[1] as UsageData;
      final orgs = results[2] as List<Map<String, dynamic>>;
      notifier.value = SubscriptionSnapshot(
        subscription: sub,
        usage: usage,
        adminOrgs: orgs.where((o) => o['role'] == 'admin').toList(),
        hasTeams: orgs.isNotEmpty,
      );
      if (!_baselineInitialized) {
        _acknowledgedRank = planRank(sub.effectivePlan);
        _baselineInitialized = true;
      }
    } catch (_) {
      // Non-critical — keep the last good snapshot. Consumers fall back to
      // their own backstops (AddSourceDetail re-fetches usage on run).
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      handleAppResumed();
    }
  }

  /// Refresh on refocus and toast if the plan went up since last acknowledged.
  Future<void> handleAppResumed() async {
    final wasInitialized = _baselineInitialized;
    await refresh();
    if (!wasInitialized) return; // first-ever successful load — no toast
    final plan = notifier.value.subscription?.effectivePlan;
    if (plan == null) return;
    final newRank = planRank(plan);
    final message = planUpToastMessage(
      prevRank: _acknowledgedRank,
      newRank: newRank,
      newEffectivePlan: plan,
    );
    _acknowledgedRank = newRank; // ack even on downgrade (silent)
    if (message != null) _showToast(message);
  }

  /// Mark the current plan as already acknowledged so the next refocus does
  /// not re-toast it. Called after an inline IAP purchase shows its own toast.
  void acknowledgeBaseline() {
    final plan = notifier.value.subscription?.effectivePlan;
    if (plan != null) {
      _acknowledgedRank = planRank(plan);
      _baselineInitialized = true;
    }
  }
}

Future<List<Map<String, dynamic>>> _defaultFetchTeams() async {
  final response = await api.get<List<dynamic>>('/team');
  return response.cast<Map<String, dynamic>>();
}

void _defaultShowToast(String message) {
  final context = navigatorKey?.currentContext;
  if (context == null) return;
  context.showToast(message: message);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/subscription_service_test.dart`
Expected: PASS (all tests green).

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/state/subscription_service.dart lib/state/subscription_plan.dart`
Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/subscription_service.dart apps/plot/test/state/subscription_service_test.dart
git commit -m "feat(subscribe): SubscriptionService snapshot with coalesced refresh + resume toast

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire `GlobalShortcuts` to the service (start/reset + consume snapshot)

`GlobalShortcuts` currently fetches subscription + `/team` itself and owns the
single `Store.onSubscriptionChanged` slot. Replace that with the service: it
`start()`s on sign-in, `reset()`s on sign-out, and rebuilds commands from the
service notifier. This removes the bottleneck so onboarding can also react.

**Files:**
- Modify: `apps/plot/lib/command/global.dart` (full rewrite of the `_GlobalShortcutsState` body)

- [ ] **Step 1: Replace the file contents**

Overwrite `apps/plot/lib/command/global.dart` with:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/state/user.dart';
import 'package:plot/util/developer_mode.dart';
import 'command.dart';

class GlobalShortcuts extends StatefulWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  State<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends State<GlobalShortcuts> {
  List<StaticCommandGroup> _getCommands({
    required bool signedIn,
    PrioritiesState? prioritiesState,
    bool showAllPriorities = false,
    String? email,
    SubscriptionInfo? subscription,
    List<Map<String, dynamic>> adminOrgs = const [],
    bool hasTeams = false,
  }) {
    // When signed out, only show settings commands (and debug commands in debug mode)
    if (!signedIn) {
      final commands = [...signedOutSettingsCommands];
      final debugCmds = buildDebugCommands();
      if (debugCmds != null) {
        commands.add(debugCmds);
      }
      return commands;
    }

    // When signed in, show all commands
    final commands = [
      StaticCommandGroup(
        title: 'Navigation',
        commands: [PageBackCommand()],
      ),
      StaticCommandGroup(
        title: 'Focuses',
        commands: [PickCurrentPriority(), AddFocus()],
      ),
      ...settingsCommandsFromState(
        prioritiesState,
        hasTeams: hasTeams,
        showAllPriorities: showAllPriorities,
        email: email,
        adminOrgs: adminOrgs,
        subscription: subscription,
      ),
    ];

    // Add debug commands in debug mode or developer mode
    final debugCmds = buildDebugCommands();
    if (debugCmds != null) {
      commands.add(debugCmds);
    }

    return commands;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserBloc, UserState>(
      builder: (context, userState) {
        final signedIn = userState is UserReady;

        if (!signedIn) {
          SubscriptionService.instance.reset();
          return CommandScope(
            commandsBuilder: () => _getCommands(signedIn: false),
            listenable: DeveloperMode.notifier,
            child: widget.child,
          );
        }

        // Loads the initial snapshot and wires broadcast/reconnect/refocus
        // refresh + the plan-up toast. Idempotent.
        SubscriptionService.instance.start();

        return BlocBuilder<PrioritiesBloc, PrioritiesState>(
          builder: (context, prioritiesState) {
            return BlocBuilder<LocalPreferencesBloc, LocalPreferencesState>(
              builder: (context, localPrefsState) {
                return ValueListenableBuilder<SubscriptionSnapshot>(
                  valueListenable: SubscriptionService.instance.notifier,
                  builder: (context, snapshot, _) {
                    return CommandScope(
                      commandsBuilder: () => _getCommands(
                        signedIn: true,
                        prioritiesState: prioritiesState,
                        showAllPriorities: localPrefsState.showAllPriorities,
                        email: userState.user.primaryEmail,
                        subscription: snapshot.subscription,
                        adminOrgs: snapshot.adminOrgs,
                        hasTeams: snapshot.hasTeams,
                      ),
                      listenable: DeveloperMode.notifier,
                      child: widget.child,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
```

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/global.dart`
Expected: "No issues found!" (in particular, no unused-import warnings — `api`, `store`, and the removed state fields are gone).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/global.dart
git commit -m "refactor(subscribe): GlobalShortcuts consumes SubscriptionService

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Onboarding gate reads the service and ensures fresh usage

Replace `OnboardingTools`' cached `_usage` with the service. The gate awaits
`ensureFresh()` so the first tap after returning from the browser sees the
post-upgrade usage; the misleading post-gate `_load()` (which re-cached stale
usage) is removed.

**Files:**
- Modify: `apps/plot/lib/widget/onboarding/onboarding_tools.dart`

- [ ] **Step 1: Update imports**

In `apps/plot/lib/widget/onboarding/onboarding_tools.dart`, add to the import
block (after the existing `package:plot/api/twist_api.dart` import):

```dart
import 'package:plot/state/subscription_service.dart';
```

- [ ] **Step 2: Drop the cached usage field and its load**

Replace the state fields (currently):

```dart
  List<Twist>? _twists;
  List<SourceSummary> _connected = const [];
  bool _loading = true;
  UsageData? _usage;
```

with:

```dart
  List<Twist>? _twists;
  List<SourceSummary> _connected = const [];
  bool _loading = true;
```

Then replace `_load()`'s body (currently fetching three things) with the
two-fetch version (no `getUsage()` here — the service owns usage):

```dart
  Future<void> _load() async {
    try {
      final results = await Future.wait([
        TwistApi.getAllTwists(),
        TwistApi.getSourcesSummary(),
      ]);
      if (!mounted) return;
      setState(() {
        _twists = results[0] as List<Twist>;
        _connected = results[1] as List<SourceSummary>;
        _loading = false;
      });
    } catch (e, t) {
      log.warning('Failed to load onboarding tools', e, t);
      if (mounted) setState(() => _loading = false);
    }
  }
```

- [ ] **Step 3: Gate on a fresh service snapshot**

Replace the top of `_openSetup` (the cached-usage gate block, currently):

```dart
    final usage = _usage;
    if (usage != null) {
      final gate = premiumOnboardingGate(usage: usage, isPremium: twist.premium);
      if (gate != null) {
        if (!mounted) return;
        await gate.run(context);
        if (mounted) await _load(); // refresh so an upgraded user can proceed
        return;
      }
    }
    await AddSourceDetail(twist, dismissable: true).run(context);
```

with:

```dart
    // Pull a fresh subscription/usage snapshot before gating. After a browser
    // (Stripe) upgrade, the cached value could otherwise still read "blocked"
    // and re-show the subscribe modal. The service coalesces this with any
    // refresh already kicked off by app refocus.
    if (twist.premium) {
      await SubscriptionService.instance.ensureFresh();
      if (!mounted) return;
      final usage = SubscriptionService.instance.usage;
      if (usage != null) {
        final gate =
            premiumOnboardingGate(usage: usage, isPremium: twist.premium);
        if (gate != null) {
          await gate.run(context);
          // The upgrade may complete out-of-band (browser). The service's
          // refocus/broadcast refresh updates usage; the user taps again to
          // proceed. No stale re-cache here.
          return;
        }
      }
    }
    await AddSourceDetail(twist, dismissable: true).run(context);
```

- [ ] **Step 4: Remove the now-unused `upgrade_api` import**

After Steps 2–3 this file no longer references `UpgradeApi` or `UsageData`
(`SourceSummary` comes from `twist_api.dart`, not `upgrade_api.dart`). Delete
this line from the import block:

```dart
import 'package:plot/api/upgrade_api.dart';
```

Verify nothing else needs it:

Run: `cd apps/plot && rg -n "UpgradeApi|UsageData" lib/widget/onboarding/onboarding_tools.dart`
Expected: no matches.

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/onboarding/onboarding_tools.dart`
Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/onboarding/onboarding_tools.dart
git commit -m "fix(onboarding): gate Pro connectors on a fresh subscription snapshot

Resolves the subscribe-modal-reappears bug after a browser/Stripe upgrade:
the onboarding gate now awaits SubscriptionService.ensureFresh() instead of a
snapshot cached at load time.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Acknowledge baseline after an inline IAP purchase

In-app StoreKit purchases happen in the foreground (no `resumed` event) and
already toast "Subscription active." Refresh the service and acknowledge the
new plan so a later unrelated refocus does not re-toast "You're now on Plot Pro".

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart`

- [ ] **Step 1: Add the import**

In `apps/plot/lib/command/upgrade.dart`, add to the import block (after
`package:plot/api/upgrade_api.dart`):

```dart
import 'package:plot/state/subscription_service.dart';
```

- [ ] **Step 2: Refresh + acknowledge in the purchased branch**

Replace the `purchased` case in `_runIap` (currently):

```dart
      case IapPurchaseStatus.purchased:
        context.showToast(message: 'Subscription active.');
        return const CommandDone();
```

with:

```dart
      case IapPurchaseStatus.purchased:
        // Pull the new entitlement and mark it acknowledged so the refocus
        // toast path does not double up on this inline confirmation.
        await SubscriptionService.instance.refresh();
        SubscriptionService.instance.acknowledgeBaseline();
        if (context.mounted) {
          context.showToast(message: 'Subscription active.');
        }
        return const CommandDone();
```

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/upgrade.dart`
Expected: "No issues found!"

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart
git commit -m "fix(subscribe): acknowledge plan after inline IAP to avoid double toast

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Repo-wide analyze, docs, and run-app verification

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Analyze every changed file together**

Run:
```bash
cd apps/plot && flutter analyze \
  lib/state/subscription_plan.dart \
  lib/state/subscription_service.dart \
  lib/command/global.dart \
  lib/command/upgrade.dart \
  lib/widget/onboarding/onboarding_tools.dart
```
Expected: "No issues found!"

- [ ] **Step 2: Run the state tests once more**

Run: `cd apps/plot && flutter test test/state/subscription_plan_test.dart test/state/subscription_service_test.dart`
Expected: PASS.

- [ ] **Step 3: Confirm the existing onboarding-gate tests still pass**

Run: `cd apps/plot && flutter test test/command/onboarding_premium_gate_test.dart`
Expected: PASS (we did not change `premiumOnboardingGate` / `_evaluatePremium`).

- [ ] **Step 4: Add a user-facing update note**

In `docs/updates.md`, under the `## Next release` heading, add to a `### Fixes`
section (create it at the end of the Next release block if absent):

```markdown
- Upgrading your plan now takes effect immediately when you return to the app — no more being asked to subscribe again right after you’ve paid. You’ll also see a quick confirmation when your new plan is active.
```

(If there is no `## Next release` heading because the last release was just
stamped, create a fresh `## Next release` section at the very top above the most
recent `## <version> — <date>` heading, then add the `### Fixes` bullet under it.)

- [ ] **Step 5: Commit the docs**

```bash
git add docs/updates.md
git commit -m "docs(updates): note immediate plan upgrade + confirmation toast

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Manual verification (run-app)**

Use the `run-app` skill. Because `OnboardingTools` is first-run only, the cleanest
checks are:

1. **Plan-up toast on refocus** — with the app signed in, simulate a plan
   increase server-side (or use a debug hook) and bring the window back to the
   foreground; confirm a single "You're now on Plot Pro" toast appears, and that
   re-focusing again does not repeat it.
2. **Onboarding gate** — if a fresh onboarding profile is available, tap a Pro
   connector while free (subscribe modal appears), complete the web upgrade,
   return to the app, tap the Pro connector again, and confirm it proceeds to
   `AddSourceDetail` instead of re-showing the subscribe modal.

Record the result. If `OnboardingTools` is not reachable in the agent profile
(already onboarded), note that the onboarding path was verified by code review +
unit tests and the toast path was verified live.

---

## Self-review notes (already reconciled)

- **Spec coverage:** SubscriptionService (§1) → Task 2; plan-up toast (§2) → Tasks 1 + 2; honor existing Team (§3) → Task 4 (`ensureFresh` defers team members to the team-aware path) + Task 1 rank includes team; wiring (§4) → Tasks 3 + 4; IAP double-toast guard (§5) → Task 5.
- **Naming consistency:** `planRank`, `planUpToastMessage`, `SubscriptionSnapshot`, `SubscriptionService.{instance,notifier,refresh,ensureFresh,handleAppResumed,acknowledgeBaseline,start,reset,subscription,usage}` are used identically across tasks.
- **Team wording:** neutral on all builds (`planUpToastMessage` never names Team); no `isAppStoreBuild` branch is needed, so the helper omits that parameter (a simplification over the spec, which is satisfied because team is neutral everywhere).
- **No offer of Team:** no task adds a Team CTA; `ShowUpgradeOptions` is untouched.
```
