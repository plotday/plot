# Last Open Focus Launch Fallback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On launch, open the focus the user last deliberately picked instead of always Personal > Inbox — unless a scheduled event, focus block, or running session is active, which still win.

**Architecture:** Add one rung to the existing `NowLoaded.priority` precedence cascade (`context → event → focus block → session → **last open focus** → default Inbox`). A small persistence module records the device-local last-picked focus id when the user runs `ChangeCurrentPriority`, and the `NowBloc` reads it once at `start()` and exposes it on `NowLoaded`. The `priority` getter resolves the stored id against the live focus list, falling through to Inbox when it's absent or archived. The re-sign-in navigation is switched to the same cascade.

**Tech Stack:** Flutter, flutter_bloc, Drift (read-only here — **no schema change**), `shared_preferences` via the project's `ProfilePreferences` wrapper, `flutter_test`.

**Design spec:** `docs/superpowers/specs/2026-06-22-last-open-focus-launch-design.md`

## Global Constraints

- **No Drift/database schema change.** This is logic + a device-local pref only. Do not touch `lib/store/*` table classes, `Store.schemaVersion`, or migrations.
- **Device-local, not synced.** The last-open focus lives in `SharedPreferences` (per-profile), never in a synced table.
- **Scope is desktop / multi-panel launch + re-sign-in.** Do not change mobile single-panel behavior (it keeps landing on the focus list).
- **Recording trigger is deliberate picks only.** Persist exclusively from `ChangeCurrentPriority` (sidebar tree, header picker, agenda block tap, command palette). Never persist from automatic `setContext` callers (page-sync, deep-link load, event/block auto-select).
- **The synthetic "Everything" feed must not overwrite the stored focus** (its `priority` is null).
- **Imports:** app code uses only `flutter/widgets.dart` / `forui/forui.dart` (no `flutter/material.dart`). Not directly relevant here (no new UI), but keep it in mind.
- **`flutter analyze` must be clean** before any commit (`cd apps/plot && flutter analyze`).
- The shared SharedPreferences key string is **`last_open_focus`** and is defined once as `kLastOpenFocusKey`.

---

## Setup (run once before Task 1)

The worktree is already created on branch `last-open-focus-spec`. Resolve Flutter deps and generated code, then confirm a clean baseline:

- [ ] **S1: Resolve deps + codegen**

```bash
cd apps/plot
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

Expected: build_runner completes ("Succeeded after ..."). This generates the `*.g.dart` Drift code the tests compile against.

- [ ] **S2: Baseline analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: "No issues found!" (or only pre-existing issues unrelated to `lib/state/now*.dart`, `lib/command/priority.dart`, `lib/state/root_provider.dart`). If unrelated pre-existing issues appear, note them and proceed.

---

## Task 1: Last-open-focus persistence module

A single-responsibility module that owns the device-local pref: one writer, one reader, one key. Pure functions over `ProfilePreferences`, independently unit-testable with mocked prefs.

**Files:**
- Create: `apps/plot/lib/state/last_open_focus.dart`
- Test: `apps/plot/test/state/last_open_focus_test.dart` (record/load group only in this task; the cascade group is added in Task 2)

**Interfaces:**
- Produces:
  - `const String kLastOpenFocusKey` (= `'last_open_focus'`)
  - `Future<void> recordLastOpenFocus(Priority? picked)` — writes `picked.id.toString()`; no-op when `picked == null`.
  - `PriorityId? loadLastOpenFocusId()` — returns the parsed id, or `null` when unset, unparseable, or prefs are uninitialized.
- Consumes: `ProfilePreferences` (`apps/plot/lib/util/profile_preferences.dart`), `Priority`/`PriorityId`/`Uuid` (all exported by `apps/plot/lib/store/store.dart`).

- [ ] **Step 1: Write the failing tests**

Create `apps/plot/test/state/last_open_focus_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/last_open_focus.dart';
import 'package:plot/store/store.dart';

// Build a DB-free Priority. Copied verbatim from the helper in
// test/state/everything_entry_test.dart (lines 12-31). If that helper drifts,
// re-copy it.
Priority _focus(String title, {bool isInbox = false}) => Priority.fromStore(
      PriorityRow(
        id: Uuid.generate(),
        createdBy: Uuid.generate(),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        title: title,
        path: Path(title.toLowerCase()),
        order: const Order(0),
        unread: false,
        role: 'member',
        isInbox: isInbox,
        isFyi: false,
        attentionWindowSet: false,
        seeWithinSet: false,
        earlyNotificationsEnabledSet: false,
        notifyWindowSet: false,
      ),
      draft: true,
    );

void main() {
  group('recordLastOpenFocus / loadLastOpenFocusId', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
    });

    test('record then load round-trips the picked focus id', () async {
      final work = _focus('Work');
      await recordLastOpenFocus(work);
      expect(loadLastOpenFocusId(), work.id);
    });

    test('a deliberately chosen Inbox is recorded too', () async {
      final inbox = _focus('Inbox', isInbox: true);
      await recordLastOpenFocus(inbox);
      expect(loadLastOpenFocusId(), inbox.id);
    });

    test('recording the Everything feed (null) leaves the stored focus', () async {
      final work = _focus('Work');
      await recordLastOpenFocus(work);
      await recordLastOpenFocus(null);
      expect(loadLastOpenFocusId(), work.id);
    });

    test('load returns null when nothing has been recorded', () {
      expect(loadLastOpenFocusId(), isNull);
    });

    test('load returns null when the stored value is malformed', () async {
      await ProfilePreferences.instance
          .setString(kLastOpenFocusKey, 'not-a-uuid');
      expect(loadLastOpenFocusId(), isNull);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart
```

Expected: FAIL — compile error, `Target of URI doesn't exist: 'package:plot/state/last_open_focus.dart'` (and `recordLastOpenFocus` / `loadLastOpenFocusId` / `kLastOpenFocusKey` undefined).

- [ ] **Step 3: Implement the module**

Create `apps/plot/lib/state/last_open_focus.dart`:

```dart
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

/// Device-local SharedPreferences key for the user's most recently
/// *deliberately chosen* focus. Read once at launch by [NowBloc] to seed the
/// "last open focus" rung of `NowLoaded.priority`; written by
/// `ChangeCurrentPriority`. Not synced — each device remembers its own.
const String kLastOpenFocusKey = 'last_open_focus';

/// Persist [picked] as the device-local "last open focus".
///
/// No-op when [picked] is null: the only null caller is the synthetic
/// "Everything" feed (`ChangeCurrentPriority.everything`), which has no anchor
/// focus and must leave the previously stored real focus intact.
Future<void> recordLastOpenFocus(Priority? picked) async {
  if (picked == null) return;
  await ProfilePreferences.instance
      .setString(kLastOpenFocusKey, picked.id.toString());
}

/// Read the device-local "last open focus" id, or null when unset, the stored
/// value can't be parsed (corrupt pref), or prefs aren't initialized yet. The
/// caller resolves the id against the live focus list, so a since-deleted
/// focus naturally falls through to the default.
PriorityId? loadLastOpenFocusId() {
  final String? raw;
  try {
    raw = ProfilePreferences.instance.getString(kLastOpenFocusKey);
  } catch (_) {
    // ProfilePreferences not initialized (some non-production paths).
    return null;
  }
  if (raw == null) return null;
  try {
    return Uuid.fromString(raw);
  } catch (_) {
    return null;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart
```

Expected: PASS (5 tests). If `Path`, `Order`, `PriorityRow`, or `Priority.fromStore` don't resolve from `package:plot/store/store.dart`, confirm the `_focus` helper still matches `test/state/everything_entry_test.dart` and re-copy it.

- [ ] **Step 5: Analyze**

```bash
cd apps/plot && flutter analyze lib/state/last_open_focus.dart test/state/last_open_focus_test.dart
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/last_open_focus.dart apps/plot/test/state/last_open_focus_test.dart
git commit -m "feat(app): device-local last-open-focus persistence helper"
```

---

## Task 2: Add the "last open focus" rung to `NowLoaded.priority`

Carry a `lastOpenFocusId` on `NowLoaded` and resolve it in the `priority` getter, one rung above the Inbox fallback. The id is resolved against the live `priorities` list (mirrors `_activeFocusBlockPriority`), so an archived/deleted focus falls through.

**Files:**
- Modify: `apps/plot/lib/state/now_state.dart` (constructor ~52-68, field block ~70-74, props ~225-246, `priority` getter ~265-270, `_activeFocusBlockPriority` ~275-285, `copyWith` ~448-490)
- Test: `apps/plot/test/state/last_open_focus_test.dart` (add a second group)

**Interfaces:**
- Produces (on `NowLoaded`):
  - new field `final PriorityId? lastOpenFocusId;` (constructor param `this.lastOpenFocusId`, defaults null)
  - `copyWith({..., PriorityId? lastOpenFocusId})` preserving it
  - `priority` getter now consults `lastOpenFocusId` before `defaultPriority`
- Consumes: nothing new (`PriorityId` is already in scope in `now_state.dart` via the `priorityBlocksByPriority` map type).

- [ ] **Step 1: Write the failing tests**

Append a second group to `apps/plot/test/state/last_open_focus_test.dart`. Add these imports at the top of the file (alongside the existing ones):

```dart
import 'package:drift/native.dart';
import 'package:injector/injector.dart';
import 'package:plot/state/now.dart';
```

Add a `NowLoaded` builder helper below `_focus` (top level):

```dart
NowLoaded _seed({
  required Priority defaultPriority,
  List<Priority> priorities = const [],
  Priority? context,
  PriorityId? lastOpenFocusId,
  Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority = const {},
  Session? session,
}) =>
    NowLoaded(
      defaultPriority: defaultPriority,
      day: ScheduledDay.empty(),
      priorities: priorities,
      context: context,
      lastOpenFocusId: lastOpenFocusId,
      priorityBlocksByPriority: priorityBlocksByPriority,
      session: session,
    );
```

Add this group inside `main()` (after the existing `recordLastOpenFocus / loadLastOpenFocusId` group):

```dart
  group('NowLoaded.priority — last open focus rung', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    test('returns the last open focus when nothing above it applies', () {
      final inbox = _focus('Inbox', isInbox: true);
      final work = _focus('Work');
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox, work],
        lastOpenFocusId: work.id,
      );
      expect(state.priority.id, work.id);
    });

    test('falls back to the default when the last open focus is gone', () {
      final inbox = _focus('Inbox', isInbox: true);
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox], // the recorded focus was archived/deleted
        lastOpenFocusId: Uuid.generate(),
      );
      expect(state.priority.id, inbox.id);
    });

    test('falls back to the default when no last open focus is stored', () {
      final inbox = _focus('Inbox', isInbox: true);
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox],
        lastOpenFocusId: null,
      );
      expect(state.priority.id, inbox.id);
    });

    test('an explicit context outranks the last open focus', () {
      final inbox = _focus('Inbox', isInbox: true);
      final work = _focus('Work');
      final reading = _focus('Reading');
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox, work, reading],
        context: reading,
        lastOpenFocusId: work.id,
      );
      expect(state.priority.id, reading.id);
    });

    test('an active focus block outranks the last open focus', () {
      Time.setFrozenTime(DateTime(2026, 5, 1, 9, 30));
      addTearDown(Time.unfreeze);
      final inbox = _focus('Inbox', isInbox: true);
      final blocked = _focus('Blocked');
      final work = _focus('Work');
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox, blocked, work],
        lastOpenFocusId: work.id,
        priorityBlocksByPriority: {
          blocked.id: [
            PriorityBlockRow(
              id: Uuid.generate(),
              priorityId: blocked.id,
              createdBy: Uuid.generate(),
              orderValue: Order(0),
              effectiveAt: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1), // 9:00–10:00 covers 9:30
              archivedAt: null,
              createdAt: DateTime(2026, 5, 1, 9),
              updatedAt: DateTime(2026, 5, 1, 9),
            ),
          ],
        },
      );
      expect(state.priority.id, blocked.id);
    });

    group('session rung (needs a real Session)', () {
      late Store store;
      setUp(() {
        store = Store.forTesting(NativeDatabase.memory());
        Injector.appInstance
            .registerSingleton<Store>(() => store, override: true);
      });
      tearDown(() async {
        Injector.appInstance.removeByKey<Store>();
        await store.close();
      });

      test('a running session outranks the last open focus', () async {
        final inbox = _focus('Inbox', isInbox: true);
        final running = _focus('Running');
        final work = _focus('Work');
        final id = Uuid.generate();
        await store.into(store.sessions).insert(
              SessionsCompanion.insert(
                id: Value(id),
                start: DateTime(2026, 5, 1, 9),
                end: DateTime(2026, 5, 1, 9, 30),
                priorityId: Value(running.id),
              ),
            );
        final row = await (store.select(store.sessions)
              ..where((t) => t.id.equals(id.toBytes())))
            .getSingle();
        final session = Session.fromStore(row, priority: running);
        final state = _seed(
          defaultPriority: inbox,
          priorities: [inbox, running, work],
          lastOpenFocusId: work.id,
          session: session,
        );
        expect(state.priority.id, running.id);
      });
    });
  });
```

Coverage note: the **scheduled-event rung** can't be unit-seeded (`ScheduledDay` exposes only `empty()`), but it sits above the focus-block rung in the same untouched cascade prefix, so the focus-block test transitively demonstrates it outranks last-open. The event rung itself is exercised by existing agenda/now behavior and is not modified here.

- [ ] **Step 2: Run the new group to verify it fails**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart --plain-name 'last open focus rung'
```

Expected: FAIL to compile — `NowLoaded` has no named parameter `lastOpenFocusId`.

- [ ] **Step 3: Implement on `NowLoaded`**

In `apps/plot/lib/state/now_state.dart`:

**3a.** Add the constructor parameter. Change the constructor tail (the `everything = false,` line) to:

```dart
    this.everything = false,
    this.lastOpenFocusId,
  }) : now = Time.now(),
       // ignore: prefer_initializing_formals
       _day = day;
```

**3b.** Add the field. Immediately after the `final Priority? context;` line (~74):

```dart
  /// Device-local "last open focus": the id of the focus the user most
  /// recently *picked* (sidebar/header/command/agenda tap), persisted across
  /// launches by `ChangeCurrentPriority` and read once at `NowBloc.start`.
  /// Resolved against [priorities] in [priority]; a since-archived/deleted
  /// focus falls through to [defaultPriority]. Null until the user has ever
  /// picked a focus on this device. See `lib/state/last_open_focus.dart`.
  final PriorityId? lastOpenFocusId;
```

**3c.** Insert the rung in the `priority` getter. Replace the getter body (~265-270) with:

```dart
  Priority get priority =>
      context ??
      scheduled.firstOrNull?.priority ??
      _activeFocusBlockPriority() ??
      session?.priority ??
      _lastOpenFocusPriority() ??
      defaultPriority;
```

Also update the getter's doc comment (~248-264): renumber the fallback as rung 6 and insert before it:
"5. [lastOpenFocusId] — the focus the user last deliberately opened on this device (see [_lastOpenFocusPriority]); the common cold-start landing." Bump "session" / "defaultPriority" numbering accordingly.

**3d.** Add the resolver method. Immediately after `_activeFocusBlockPriority()` (after its closing `}` ~285):

```dart
  /// The persisted [lastOpenFocusId] resolved to a [Priority] from
  /// [priorities]. Null when nothing is stored or the stored focus is no
  /// longer in the list (archived/deleted). Mirrors [_activeFocusBlockPriority].
  Priority? _lastOpenFocusPriority() {
    final id = lastOpenFocusId;
    if (id == null) return null;
    for (final p in priorities) {
      if (p.id == id) return p;
    }
    return null;
  }
```

**3e.** Thread through `copyWith`. Add the parameter (after `bool? everything,` ~463):

```dart
    bool? everything,
    PriorityId? lastOpenFocusId,
  }) {
```

and the forwarding line (after `everything: everything ?? this.everything,` ~488):

```dart
      everything: everything ?? this.everything,
      lastOpenFocusId: lastOpenFocusId ?? this.lastOpenFocusId,
    );
```

**3f.** Add to `props`. Append `lastOpenFocusId,` to the `props` list (after `everything,` ~245). It is stable across the bloc's life, so it adds correctness without extra rebuilds.

- [ ] **Step 4: Run the full test file to verify it passes**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart
```

Expected: PASS (all groups — 11 tests).

- [ ] **Step 5: Analyze**

```bash
cd apps/plot && flutter analyze lib/state/now_state.dart lib/state/now.dart test/state/last_open_focus_test.dart
```

Expected: clean. (`now_state.dart` is `part of 'now.dart'`, so analyzing `now.dart` covers it too.)

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/now_state.dart apps/plot/test/state/last_open_focus_test.dart
git commit -m "feat(app): last-open-focus rung in NowLoaded.priority cascade"
```

---

## Task 3: Load the last-open focus in `NowBloc.start()`

Wire the tested reader into the bloc: read the id once at `start()` and feed it into every `NowLoaded` the watcher builds.

**Files:**
- Modify: `apps/plot/lib/state/now.dart` (imports; `NowBloc` field block; `start()` ~97; `NowLoaded(...)` build ~120-137)

**Interfaces:**
- Consumes: `loadLastOpenFocusId()` (Task 1), `NowLoaded.lastOpenFocusId` (Task 2).
- Produces: nothing new — connects the two.

No new unit test: this is integration wiring of units already covered by Task 1 (load) and Task 2 (getter). Verified by `flutter analyze` here and the end-to-end run in Task 6. (`loadLastOpenFocusId` is defensive against uninitialized prefs, so existing `NowBloc.start()` callers in tests are unaffected.)

- [ ] **Step 1: Add the import**

At the top of `apps/plot/lib/state/now.dart`, with the other `package:plot/state/...` imports:

```dart
import 'package:plot/state/last_open_focus.dart';
```

- [ ] **Step 2: Add the field**

In the `NowBloc` field declarations (near `_subscriptionLocalDate`), add:

```dart
  /// Loaded once at [start] from device-local prefs; seeds the "last open
  /// focus" rung of `NowLoaded.priority`. See [loadLastOpenFocusId].
  PriorityId? _lastOpenFocusId;
```

- [ ] **Step 3: Load it at the top of `start()`**

Make `start()` begin with the load (before `final nowSubscriptionStart = Time.now();`, ~98):

```dart
  Future<void> start() {
    _lastOpenFocusId = loadLastOpenFocusId();
    final nowSubscriptionStart = Time.now();
```

- [ ] **Step 4: Pass it into the `NowLoaded` build**

In the `combineLatest6` mapper's `return NowLoaded(...)` (~120-137), add the field after `everything: prior?.everything ?? false,`:

```dart
              everything: prior?.everything ?? false,
              lastOpenFocusId: _lastOpenFocusId,
            );
```

- [ ] **Step 5: Analyze**

```bash
cd apps/plot && flutter analyze lib/state/now.dart
```

Expected: clean.

- [ ] **Step 6: Run the now/last-open tests to confirm no regression**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart test/state/everything_entry_test.dart
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "feat(app): load last-open focus at NowBloc.start"
```

---

## Task 4: Record the focus on a deliberate pick

Persist the chosen focus from `ChangeCurrentPriority` — the one command every deliberate focus pick flows through.

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` (import; `ChangeCurrentPriority.run()` ~147-162)

**Interfaces:**
- Consumes: `recordLastOpenFocus(Priority?)` (Task 1). The command's `priority` field is `Priority?` — non-null for an ordinary pick, null for `ChangeCurrentPriority.everything()`. The helper no-ops on null.

No new unit test: `recordLastOpenFocus` is unit-tested in Task 1; this step only calls it at the right spot (testing the command itself needs a full widget/router context). Verified by `flutter analyze` and the Task 6 run.

- [ ] **Step 1: Add the import**

In `apps/plot/lib/command/priority.dart`, with the other `package:plot/state/...` imports (near `import 'package:plot/state/now.dart';`):

```dart
import 'package:plot/state/last_open_focus.dart';
```

- [ ] **Step 2: Add the record call**

In `ChangeCurrentPriority.run()`, immediately after the `if (nowBloc.state is NowLoaded) { ... }` block closes (after line ~162, before `final tabsRouter = _tabsRouterOrNull(context);`):

```dart
    // Remember this deliberate pick as the device-local "last open focus" so
    // the next cold start reopens here instead of the Inbox. Null for the
    // synthetic "Everything" feed (the helper no-ops). Fire-and-forget — a
    // missed pref write is harmless and must not delay navigation.
    unawaited(recordLastOpenFocus(priority));
```

(`unawaited` is already available via `import 'dart:async';` at the top of the file.)

- [ ] **Step 3: Analyze**

```bash
cd apps/plot && flutter analyze lib/command/priority.dart
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/priority.dart
git commit -m "feat(app): record last-open focus on deliberate focus pick"
```

---

## Task 5: Re-sign-in navigation honors the cascade

After a genuine re-sign-in, navigate to the current-priority cascade (which now includes an active event/block and the last-open focus) instead of hardcoding the Inbox.

**Files:**
- Modify: `apps/plot/lib/state/root_provider.dart` (~214-227)

**Interfaces:**
- Consumes: `NowLoaded.priority` (the cascade; unchanged signature).

No new unit test: this is a one-line target change inside the `UserReady` handler, which isn't unit-testable in isolation. The cascade value it now uses is fully covered by Task 2's getter tests. Verified by `flutter analyze` and Task 6.

- [ ] **Step 1: Change the navigation target**

In `apps/plot/lib/state/root_provider.dart`, in the `if (navigateToDefault && context.mounted)` block (~220-227), change:

```dart
                  final priorityId = nowBloc.loadedState.defaultPriority.id;
```

to:

```dart
                  // Use the current-priority cascade (active event/block,
                  // running session, or last-open focus, else Inbox) so a
                  // re-sign-in lands where a cold start would. Cold start /
                  // deep-link refresh is still gated out by
                  // PostAuthNavigationGate above.
                  final priorityId = nowBloc.loadedState.priority.id;
```

Also tighten the comment just above (~214-219) so it no longer says "jump to the default priority" — say "jump to the current-priority cascade".

- [ ] **Step 2: Analyze**

```bash
cd apps/plot && flutter analyze lib/state/root_provider.dart
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/state/root_provider.dart
git commit -m "feat(app): re-sign-in navigates the current-priority cascade"
```

---

## Task 6: Docs, full analyze, and end-to-end verification

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing update note**

In `docs/updates.md`, under the top `## Next release` heading, add a bullet to the `### Fixes` section (create `## Next release` and `### Fixes` if the most recent heading is already a stamped version, per the repo convention — newest at the very top):

```markdown
- The app now reopens the focus you last had open, instead of always starting on your Personal inbox. A scheduled event or focus block happening right now still takes you straight there.
```

- [ ] **Step 2: Full analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: "No issues found!" (or only the pre-existing unrelated issues noted in Setup S2).

- [ ] **Step 3: Full test run for touched areas**

```bash
cd apps/plot && flutter test test/state/
```

Expected: PASS (no regressions in the `state` test suite).

- [ ] **Step 4: Manual end-to-end verification (desktop / multi-panel)**

Use the `run-app` skill to launch the macOS app, then verify each case (the app must be in a desktop/multi-panel window):

1. **Last-open reopen:** Pick a non-Inbox focus (e.g. "Work") from the sidebar. Fully quit and relaunch. → App opens into **Work**, not Personal > Inbox.
2. **No-pick default:** With a fresh profile (or after clearing the `last_open_focus` pref), launch. → App opens into **Personal > Inbox** (unchanged today's behavior).
3. **Archived fallback:** Pick a focus, archive it, relaunch. → App opens into **Personal > Inbox** (graceful fallback).
4. **Event/focus-block precedence (if feasible):** With a focus block scheduled covering "now" on a different focus, relaunch. → App opens into the **focus-block's focus**, overriding last-open.
5. **Everything feed:** Open the "Everything" feed, then pick a real focus "Work", then open "Everything" again, then relaunch. → App opens into **Work** (Everything didn't overwrite the memory).

Record the observed result for each (the project's verification standard requires evidence, not assertion). If any case fails, stop and debug before proceeding.

- [ ] **Step 5: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs: note last-open-focus launch behavior in updates"
```

---

## Self-Review (completed during plan authoring)

- **Spec coverage:** new rung (Task 2), record-only-on-deliberate-pick (Task 4), `ProfilePreferences` device-local storage (Task 1), resolve-with-fallback (Task 2), re-sign-in consistency (Task 5), desktop-only scope (no mobile change; verified Task 6), tests for resolve/missing/null/focus-block/session/context + record round-trip/Everything-noop/Inbox/malformed (Tasks 1-2). Event-rung unit-seeding gap is documented (Task 2 coverage note) with rationale. No-schema, not-synced constraints stated.
- **Placeholder scan:** none — every code/test step shows complete code.
- **Type consistency:** `kLastOpenFocusKey` (String), `recordLastOpenFocus(Priority?)`, `loadLastOpenFocusId() → PriorityId?`, `NowLoaded.lastOpenFocusId` (`PriorityId?`), `_lastOpenFocusPriority() → Priority?` — names and types match across Tasks 1-5.
