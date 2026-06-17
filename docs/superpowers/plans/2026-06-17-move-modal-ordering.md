# Smarter Move-modal Focus Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Order the "Move thread to focus" modal by recently-moved-into focuses first, then same-role focuses, then the existing base order — making batch triage faster.

**Architecture:** A tiny session-scoped in-memory MRU singleton (`MoveRecency`) records each move destination. A pure, stable tiered-sort function (`orderMoveTargets`) reorders the focus list into three tiers. Two touch-points in the move command record moves and apply the sort. No Drift schema, sync, or server change.

**Tech Stack:** Flutter / Dart, Drift (only as a test fixture to build real `Priority` objects), `flutter_test`.

## Global Constraints

- Flutter app code lives under `apps/plot/`; run all commands from there.
- UI/state files: `lib/state/` (state), `lib/command/` (user actions). Tests: `apps/plot/test/`.
- Only `flutter/widgets.dart` and `forui/forui.dart` for UI — N/A here (no widgets added).
- Lint gate: `cd apps/plot && flutter analyze` must pass with no new issues.
- Scope is the Move modal only. No change to compose / file-into-focus pickers, no server, no Drift schema, no sync change.
- `Priority.roleId` is typed `Uuid?` in the Dart model (the Drift column is nullable). The role invariant says it is effectively always set, but we do **not** retype the model (out of scope) — so `orderMoveTargets` accepts `Uuid? currentRoleId` and guards the same-role tier with an explicit non-null check.
- `Uuid` is an extension type over `package:uuid`'s `UuidValue` (value equality), so `List<Uuid>.indexOf` and `==` behave by value.

---

### Task 1: `MoveRecency` session-scoped MRU singleton

**Files:**
- Create: `apps/plot/lib/state/move_recency.dart`
- Test: `apps/plot/test/state/move_recency_test.dart`

**Interfaces:**
- Consumes: `Uuid` (from `package:plot/store/store.dart`, which re-exports it).
- Produces:
  - `class MoveRecency` with `static final MoveRecency instance`, `void record(Uuid focusId)`, `List<Uuid> get recent` (newest-first, deduped, unmodifiable), `void clear()`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/move_recency_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/state/move_recency.dart';
import 'package:plot/store/store.dart';

void main() {
  group('MoveRecency', () {
    setUp(() => MoveRecency.instance.clear());
    tearDown(() => MoveRecency.instance.clear());

    test('record prepends newest-first and dedupes', () {
      final r = MoveRecency.instance;
      final a = Uuid.generate();
      final b = Uuid.generate();

      r.record(a);
      r.record(b);
      expect(r.recent, [b, a], reason: 'newest move comes first');

      r.record(a); // move into `a` again
      expect(r.recent, [a, b], reason: 'a returns to front, no duplicate');
    });

    test('recent is unmodifiable', () {
      final r = MoveRecency.instance;
      r.record(Uuid.generate());
      expect(() => r.recent.add(Uuid.generate()), throwsUnsupportedError);
    });

    test('clear empties the list', () {
      final r = MoveRecency.instance;
      r.record(Uuid.generate());
      r.clear();
      expect(r.recent, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/move_recency_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'plot' ... move_recency.dart` / `MoveRecency` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/state/move_recency.dart`:

```dart
import 'package:plot/store/store.dart';

/// Session-scoped, in-memory record of the focuses a thread was most recently
/// moved into, newest first. Used by the Move modal to float just-used move
/// destinations to the top during a triage burst.
///
/// Intentionally not persisted and not a Bloc: it is a lightweight cross-cutting
/// cache shared between the move command (which records) and the Move modal
/// (which reads). A fresh app run starts empty, so between sessions role
/// affinity leads.
class MoveRecency {
  MoveRecency._();

  /// The app-wide instance.
  static final MoveRecency instance = MoveRecency._();

  final List<Uuid> _recent = []; // newest first, deduped

  /// Most-recently moved-into focus ids, newest first.
  List<Uuid> get recent => List.unmodifiable(_recent);

  /// Record a move destination: move it to the front, deduped.
  void record(Uuid focusId) {
    _recent
      ..remove(focusId)
      ..insert(0, focusId);
  }

  /// Clears the recency list (sign-out / store reset / test isolation).
  void clear() => _recent.clear();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/move_recency_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/move_recency.dart apps/plot/test/state/move_recency_test.dart
git commit -m "feat(move): add session-scoped MoveRecency MRU singleton"
```

---

### Task 2: `orderMoveTargets` pure tiered sort

**Files:**
- Modify: `apps/plot/lib/state/move_recency.dart` (add a top-level function)
- Test: `apps/plot/test/state/order_move_targets_test.dart`

**Interfaces:**
- Consumes: `Priority` and `Uuid` (from `package:plot/store/store.dart`); `MoveRecency` is not used by the function itself.
- Produces:
  - `List<Priority> orderMoveTargets({required List<Priority> focuses, required List<Uuid> recentMoves, required Uuid? currentRoleId})` — a **stable** tiered reorder:
    - Tier 0 (top): `focuses` whose `id` is in `recentMoves`, ordered by MRU position (index in `recentMoves`, smallest = newest = first).
    - Tier 1: `currentRoleId != null && focus.roleId == currentRoleId`, excluding Tier 0.
    - Tier 2: the rest, in incoming order.
    - Within Tier 1 and Tier 2, the incoming order of `focuses` is preserved.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/order_move_targets_test.dart`. The helpers mirror `apps/plot/test/state/compose_focus_role_search_test.dart`; we build real `Priority` objects via an in-memory Store and read them back with `Priority.getRaw`, which (with no sessions) yields a deterministic base order of ascending `path`.

```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/move_recency.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

Future<void> _insertActor(Store store, Uuid id,
    {required String name, bool self = false}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(ActorId(id)),
          type: const Value(ActorType.contact),
          name: Value(name),
          email: Value('${name.replaceAll(' ', '.').toLowerCase()}@x.test'),
          self: Value(self),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

Future<void> _insertRole(Store store, Uuid id,
    {required Uuid createdBy, required String name}) async {
  await store.into(store.roles).insert(
        RolesCompanion(
          id: Value(id),
          createdBy: Value(createdBy),
          name: Value(name),
        ),
      );
}

Future<void> _insertPriority(Store store, Uuid id,
    {required Uuid createdBy,
    required String title,
    required String path,
    bool isInbox = false,
    Uuid? roleId}) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: Value(title),
          createdBy: Value(createdBy),
          path: Value(Path(path)),
          isInbox: Value(isInbox),
          roleId: roleId == null ? const Value.absent() : Value(roleId),
        ),
      );
}

List<String> _titles(List<Priority> ps) => ps.map((p) => p.title).toList();

void main() {
  group('orderMoveTargets', () {
    late Store store;
    late Uuid self;
    late Uuid roleA;
    late Uuid roleB;
    late Map<String, Priority> byTitle;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
      store = Store.forTesting(NativeDatabase.memory());
      Injector.appInstance.registerSingleton<Store>(() => store, override: true);
      Actor.clearCache();
      Role.clearCache();
      Priority.clearCache();

      self = Uuid.generate();
      roleA = Uuid.generate();
      roleB = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertRole(store, roleA, createdBy: self, name: 'Role A');
      await _insertRole(store, roleB, createdBy: self, name: 'Role B');

      // Base order = ascending path (no sessions => recent-order ties break on path).
      await _insertPriority(store, Uuid.generate(),
          createdBy: self,
          title: 'Everything',
          path: 'a',
          isInbox: true,
          roleId: roleA);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Alpha', path: 'a.b', roleId: roleA);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Beta', path: 'a.c', roleId: roleA);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Gamma', path: 'a.d', roleId: roleB);
      await _insertPriority(store, Uuid.generate(),
          createdBy: self, title: 'Delta', path: 'a.e', roleId: roleB);

      final all = await Priority.getRaw(order: PriorityOrder.recent);
      byTitle = {for (final p in all) p.title: p};
    });

    tearDown(() async {
      Actor.clearCache();
      Role.clearCache();
      Priority.clearCache();
      Injector.appInstance.removeByKey<Store>();
      await store.close();
    });

    test('base order is ascending path (sanity)', () {
      expect(_titles(byTitle.values.toList()..sort((a, b) =>
          (a.path?.toString() ?? '').compareTo(b.path?.toString() ?? ''))),
          ['Everything', 'Alpha', 'Beta', 'Gamma', 'Delta']);
    });

    test('empty recency: same-role focuses lead, then base order', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: const [],
        currentRoleId: roleA,
      );
      // Tier 1 (roleA, base order): Everything, Alpha, Beta.
      // Tier 2 (roleB, base order): Gamma, Delta. Inbox is NOT pinned.
      expect(_titles(ordered), ['Everything', 'Alpha', 'Beta', 'Gamma', 'Delta']);
    });

    test('recent moves float above same-role, in MRU order', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: [byTitle['Delta']!.id, byTitle['Gamma']!.id], // Delta newest
        currentRoleId: roleA,
      );
      // Tier 0 (MRU): Delta, Gamma. Then Tier 1 roleA: Everything, Alpha, Beta.
      expect(_titles(ordered), ['Delta', 'Gamma', 'Everything', 'Alpha', 'Beta']);
    });

    test('a recent + same-role focus appears once, in Tier 0', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: [byTitle['Beta']!.id], // Beta is roleA AND recent
        currentRoleId: roleA,
      );
      // Tier 0: Beta. Tier 1 roleA: Everything, Alpha. Tier 2 roleB: Gamma, Delta.
      expect(_titles(ordered), ['Beta', 'Everything', 'Alpha', 'Gamma', 'Delta']);
    });

    test('null currentRoleId: no same-role tier, base order after recents', () {
      final ordered = orderMoveTargets(
        focuses: byTitle.values.toList()
          ..sort((a, b) => (a.path?.toString() ?? '')
              .compareTo(b.path?.toString() ?? '')),
        recentMoves: [byTitle['Gamma']!.id],
        currentRoleId: null,
      );
      // Tier 0: Gamma. Tier 2 (everyone else, base order): Everything, Alpha, Beta, Delta.
      expect(_titles(ordered), ['Gamma', 'Everything', 'Alpha', 'Beta', 'Delta']);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/order_move_targets_test.dart`
Expected: FAIL — `orderMoveTargets` is undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `apps/plot/lib/state/move_recency.dart` (below the `MoveRecency` class):

```dart
/// Reorders [focuses] for the Move modal into three stable tiers:
///
/// 1. focuses recently moved-into this session ([recentMoves]), newest first;
/// 2. focuses sharing [currentRoleId] (the moved thread's current role), in
///    incoming order;
/// 3. everything else, in incoming order.
///
/// [focuses] arrives in the desired Tier-3 base order (visit-recency, then
/// alphabetical). The sort is stable: ties fall back to the incoming index, so
/// the base order survives within tiers 2 and 3, while tier 1 is driven by MRU
/// position. [currentRoleId] may be null (the model types `roleId` nullable);
/// when null, the same-role tier is empty.
List<Priority> orderMoveTargets({
  required List<Priority> focuses,
  required List<Uuid> recentMoves,
  required Uuid? currentRoleId,
}) {
  int tierOf(Priority p) {
    if (recentMoves.contains(p.id)) return 0;
    if (currentRoleId != null && p.roleId == currentRoleId) return 1;
    return 2;
  }

  final indexed = <(int, Priority)>[
    for (var i = 0; i < focuses.length; i++) (i, focuses[i]),
  ];
  indexed.sort((a, b) {
    final ta = tierOf(a.$2);
    final tb = tierOf(b.$2);
    if (ta != tb) return ta.compareTo(tb);
    if (ta == 0) {
      // Both recent: smaller MRU index = more recent = earlier.
      return recentMoves.indexOf(a.$2.id).compareTo(recentMoves.indexOf(b.$2.id));
    }
    return a.$1.compareTo(b.$1); // preserve incoming order
  });
  return [for (final e in indexed) e.$2];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/order_move_targets_test.dart`
Expected: PASS (5 tests). If the "base order" sanity test reveals `getRaw` returns a different order, adjust the expected lists to the observed base order — the tier assertions remain valid relative to it.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/move_recency.dart apps/plot/test/state/order_move_targets_test.dart
git commit -m "feat(move): add orderMoveTargets tiered sort (recency > role > base)"
```

---

### Task 3: Wire recording + ordering into the Move command

**Files:**
- Modify: `apps/plot/lib/command/thread.dart` (import; `_applyPriorityMove` record; `_getMoveCommands` read + delete Inbox pin block)

**Interfaces:**
- Consumes: `MoveRecency.instance.record` / `.recent` and `orderMoveTargets(...)` from Task 1/2; `thread.priority.roleId` (`Uuid?`).
- Produces: no new public surface — behavior change only.

- [ ] **Step 1: Add the import**

In `apps/plot/lib/command/thread.dart`, add to the `package:plot/state/...` import group (near line 20):

```dart
import 'package:plot/state/move_recency.dart';
```

- [ ] **Step 2: Record the move destination**

In `_applyPriorityMove` (the shared path both `MoveToPriority` and `_CreateAndMoveToNewPriority` funnel through), find:

```dart
  final updated = thread.copyWith(priority: priority);
  priorityBloc?.markFeedMove(thread.id);
```

Insert the record call between them:

```dart
  final updated = thread.copyWith(priority: priority);
  // Remember this destination so the next Move opens with it on top (Tier 1).
  MoveRecency.instance.record(priority.id);
  priorityBloc?.markFeedMove(thread.id);
```

- [ ] **Step 3: Replace the Inbox-pin block with the tiered sort**

In `MoveThreadToPriority._getMoveCommands`, find this block (it begins with the `// Partition out the root (Inbox)` comment and ends with the `commands` list literal):

```dart
    final priorities = await Priority.getRaw(order: PriorityOrder.recent);
    // Partition out the root (Inbox), which `getRaw` returns alongside the
    // focuses, so it can be pinned to the bottom of the list. It renders as
    // the ordinary role focus it is (FocusLabel brands it via `isInbox`).
    final inboxId = Priority.defaultInbox(priorities)?.id;
    Priority? root;
    final focuses = <Priority>[];
    for (final p in priorities) {
      if (p.id == inboxId) {
        root = p;
      } else if (p.id != thread.priority.id) {
        focuses.add(p);
      }
    }
    final commands = <Command>[
      ...focuses.map(
        (priority) => MoveToPriority(thread, priority, bloc: bloc),
      ),
      if (root != null && thread.priority.id != root.id)
        MoveToPriority(thread, root, bloc: bloc),
    ];
```

Replace it with (keeping the `final priorities = ...` line):

```dart
    final priorities = await Priority.getRaw(order: PriorityOrder.recent);
    // Every non-current focus participates in the tiered ordering — Inbox and
    // FYI focuses included (no longer pinned). Tier 1: focuses moved-into this
    // session (MRU); Tier 2: focuses in the moved thread's current role; Tier 3:
    // the getRaw base order (visit-recency, then alphabetical). FocusLabel still
    // brands the Inbox via `isInbox`.
    final focuses =
        priorities.where((p) => p.id != thread.priority.id).toList();
    final ordered = orderMoveTargets(
      focuses: focuses,
      recentMoves: MoveRecency.instance.recent,
      currentRoleId: thread.priority.roleId,
    );
    final commands = <Command>[
      for (final priority in ordered)
        MoveToPriority(thread, priority, bloc: bloc),
    ];
```

Leave the trailing `return Commands(prompt: 'Move thread to focus', groups: [...], secondaryCommand: ...)` unchanged.

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No new issues (no unused `Priority.defaultInbox` import problem — `Priority` is still used; `defaultInbox` is a static method that simply stops being called here).

- [ ] **Step 5: Run the existing + new tests**

Run: `cd apps/plot && flutter test test/state/move_recency_test.dart test/state/order_move_targets_test.dart`
Expected: PASS (8 tests total).

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/thread.dart
git commit -m "feat(move): order Move modal by move-recency then role affinity"
```

---

### Task 4: Manual verification in the running app

**Files:** none (verification only).

- [ ] **Step 1: Launch the app**

Use the `run-app` skill to launch Plot.app and connect dart-mcp.

- [ ] **Step 2: Verify the behavior**

1. Open a thread and Move it (`.` shortcut or the Move command) into focus **X** in a role different from the thread's current role.
2. Open a *second* thread and invoke Move. **Expected:** focus **X** is at the **top** of the list (Tier 1), above the second thread's same-role focuses.
3. Confirm the **Inbox is no longer forced to the bottom** — it sits wherever the tiers place it (e.g. top of Tier 2 if it shares the thread's role, or in Tier 1 if you just moved a thread into it).
4. Quit and relaunch the app, then open Move on a thread before moving anything. **Expected:** Tier 1 is empty, so same-role focuses lead (session-only recency reset).

- [ ] **Step 3: Note the result**

Record what was observed (pass/fail per check) in the final summary. No commit.

---

## Self-Review

**1. Spec coverage:**
- Flat ranked list (tiered sort) → `orderMoveTargets` (Task 2), wired in Task 3. ✓
- Session-only in-memory MRU → `MoveRecency` (Task 1). ✓
- Tier rules (recency > role > base) → `orderMoveTargets` + tests. ✓
- Record in `_applyPriorityMove` → Task 3 Step 2. ✓
- Inbox un-pinned, participates in tiers → Task 3 Step 3 (block deleted); asserted in Task 2 "empty recency" + Task 4 check 3. ✓
- `roleId` non-null invariant → handled as `Uuid?` + guard (Global Constraints + Task 2), reconciled honestly since the model stays nullable. ✓
- Move-modal-only scope; no schema/sync/server change → only `move_recency.dart` + `thread.dart` touched. ✓
- TDD on the pure functions → Tasks 1–2. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓ (Task 2 Step 4 notes a contingency to align expected lists with the observed base order — this is a verification instruction, not a placeholder, and the tier assertions hold regardless.)

**3. Type consistency:** `MoveRecency.instance` / `record(Uuid)` / `recent` (List<Uuid>) / `clear()` and `orderMoveTargets({focuses, recentMoves, currentRoleId: Uuid?})` are referenced identically across Tasks 1–3. `thread.priority.roleId` is `Uuid?`, matching the `Uuid? currentRoleId` parameter. ✓
