# Merge focus into another focus — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the **Archive** command on a focus (priority) with **"Merge into…"** when the focus has threads — opening a picker that moves all the focus's threads into a chosen target focus and then archives the source. Empty focuses keep one-click **Archive**; Inbox is unaffected. Also remove the leave-team coupling from archiving.

**Architecture:** Compute a per-focus `hasThreads` flag using the store's existing enrichment pattern (mirrors `active` / `unreadComputed`), so the synchronous menu builders can branch Merge-vs-Archive without going async. A new `MergeFocusInto` (`ShowCommands`) reuses the `MoveThreadToPriority` picker pattern; a new `MergeFocus` (`PriorityCommand`) re-files every thread and archives the source. Current-focus menus (header + command scope), which load the focus without enrichment, get the flag resolved at their build sites.

**Tech Stack:** Flutter, Drift (SQLite), flutter_bloc, rxdart, forui. Dart tests via `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-06-02-merge-focus-design.md`

---

## File Structure

- `apps/plot/lib/store/priority.dart` — add the transient `hasThreads` enrichment field + helpers + wire into `_enrichWithStatus` and `watch`. Add a public `Priority.hasThreadsFor(id)` and an instance `withHasThreads(bool)`.
- `apps/plot/lib/command/priority.dart` — add `MergeFocusInto` + `MergeFocus`; add the `archiveOrMergeCommand(priority)` slot helper + `enrichFocusFromList(...)` helper; branch `prioritySecondaryCommands`; strip the leave-team flow from `TogglePriorityArchived`.
- `apps/plot/lib/widget/unified_header.dart` — resolve `hasThreads` on the current focus in the two `commandsBuilder`s before calling `currentPriorityCommandGroups`.
- `apps/plot/lib/page/priority.dart` — enrich the current focus from `PrioritiesBloc` in the synchronous `_PriorityCommandScope`.
- `apps/plot/test/store/priority_has_threads_test.dart` — **new** unit tests for the `hasThreads` plumbing.
- `apps/plot/test/command/priority_archive_or_merge_test.dart` — **new** unit tests for the slot-selection logic.
- `docs/updates.md`, `docs/features.md` — user-facing note.

---

## Task 1: `hasThreads` enrichment on `Priority`

**Files:**
- Modify: `apps/plot/lib/store/priority.dart`
- Test: `apps/plot/test/store/priority_has_threads_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/store/priority_has_threads_test.dart`. This mirrors `priority_fromstore_icon_test.dart` — a pure unit test, no database. It guards against the `fromStore`-drops-fields gotcha (see `docs` memory: a field missing from `fromStore` silently resets on every `copyWith`).

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

PriorityRow _row({DateTime? archivedAt}) => PriorityRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      title: 'Test',
      path: Path('test'),
      order: const Order(0),
      root: false,
      unread: false,
      role: 'member',
      archivedAt: archivedAt,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
    );

void main() {
  test('defaults to false when not computed', () {
    final priority = Priority.fromStore(_row(), draft: true);
    expect(priority.hasThreads, isFalse);
  });

  test('fromStore carries the computed hasThreads flag', () {
    final priority = Priority.fromStore(_row(), draft: true, hasThreads: true);
    expect(priority.hasThreads, isTrue);
  });

  test('withHasThreads returns a copy with the flag set', () {
    final priority = Priority.fromStore(_row(), draft: true);
    expect(priority.withHasThreads(true).hasThreads, isTrue);
    expect(priority.withHasThreads(false).hasThreads, isFalse);
  });

  test('hasThreads survives the copyWith / fromStore round-trip', () {
    final priority =
        Priority.fromStore(_row(), draft: true, hasThreads: true);
    final updated = priority.copyWith(title: 'Renamed');
    expect(updated.hasThreads, isTrue,
        reason: 'copyWith must forward _hasThreadsComputed through fromStore');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/store/priority_has_threads_test.dart`
Expected: FAIL — `The method 'withHasThreads' isn't defined` / `No named parameter 'hasThreads'` / `hasThreads` getter undefined.

- [ ] **Step 3: Add the field, getter, and `fromStore` parameter**

In `apps/plot/lib/store/priority.dart`:

a) Add the `hasThreads` named parameter to the `Priority.fromStore` constructor (alongside `active` / `unreadComputed`, ~line 1049):

```dart
  Priority.fromStore(
    PriorityRow row, {
    this.parent,
    List<Priority>? children,
    PriorityAncestryData? ancestry,
    List<PriorityAncestor>? ancestors,
    Order? minAncestorTopOrder,
    this.draft = false,
    Path? originalPath,
    bool? active,
    bool? unreadComputed,
    bool? hasThreads,
    ThemeColor? displayColor,
  }) : children = children ?? [],
```

b) In that constructor's initializer list, next to `_unreadComputed = unreadComputed,` (~line 1080):

```dart
       _activeComputed = active,
       // ignore: prefer_initializing_formals
       _unreadComputed = unreadComputed,
       _hasThreadsComputed = hasThreads,
```

c) In the generative `Priority(...)` constructor (the new-priority one), next to `_unreadComputed = null,` (~line 1007):

```dart
       _activeComputed = null,
       _unreadComputed = null,
       _hasThreadsComputed = null,
```

d) Add the field declaration next to `_unreadComputed` (~line 1219):

```dart
  /// Computed unread status from query (considers local overrides).
  /// Falls back to row's unread value if not computed.
  final bool? _unreadComputed;

  /// Computed "has threads" status from query: true when the focus has at
  /// least one non-archived, non-draft thread filed directly under it. Falls
  /// back to false when not computed (e.g. loaded without `_enrichWithStatus`).
  final bool? _hasThreadsComputed;
```

e) Add the getter next to `active` (~line 1326):

```dart
  /// Returns true if this priority has active threads.
  bool get active => _activeComputed ?? false;

  /// Returns true when this focus has at least one non-archived, non-draft
  /// thread filed directly under it. Drives the Archive-vs-"Merge into…"
  /// choice on the focus menu. Defaults to false when not computed.
  bool get hasThreads => _hasThreadsComputed ?? false;
```

f) Add to `==` and `hashCode` (~lines 1338, 1345):

```dart
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Priority &&
          super == other &&
          _activeComputed == other._activeComputed &&
          _unreadComputed == other._unreadComputed &&
          _hasThreadsComputed == other._hasThreadsComputed &&
          displayColor == other.displayColor);

  @override
  int get hashCode => Object.hash(
    super.hashCode,
    _activeComputed,
    _unreadComputed,
    _hasThreadsComputed,
    displayColor,
  );
```

- [ ] **Step 4: Forward `hasThreads` through `copyWith` and add `withHasThreads`**

In `copyWith`'s trailing `Priority.fromStore(...)` call, next to `active:` / `unreadComputed:` (~line 1456):

```dart
      active: _activeComputed,
      unreadComputed: _unreadComputed,
      hasThreads: _hasThreadsComputed,
    );
```

Add the `withHasThreads` helper (place it right after the `copyWith` method, before `_removeFromParent`):

```dart
  /// Returns a copy of this priority with the computed [hasThreads] flag set,
  /// preserving every other computed-enrichment field. Used to enrich the
  /// current focus where the owning bloc loads it without `_enrichWithStatus`
  /// (header and command-scope menus).
  Priority withHasThreads(bool value) => Priority.fromStore(
        this,
        parent: parent,
        children: children,
        draft: draft,
        ancestors: _ancestors,
        minAncestorTopOrder: minAncestorTopOrder,
        originalPath: _originalPath,
        active: _activeComputed,
        unreadComputed: _unreadComputed,
        hasThreads: value,
      );
```

- [ ] **Step 5: Run the unit test to verify it passes**

Run: `cd apps/plot && flutter test test/store/priority_has_threads_test.dart`
Expected: PASS (all 4 tests).

- [ ] **Step 6: Add the query helpers and wire enrichment**

Add the non-empty-focus query helpers next to `_getUnreadPriorityIds` / `_watchUnreadPriorityIds` (~line 681 / 704):

```dart
  /// Efficiently gets which of the given priority IDs have at least one
  /// non-archived, non-draft thread filed directly under them.
  static Future<Set<PriorityId>> _getNonEmptyPriorityIds(
    List<PriorityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.priorityId.isIn(idBytes) &
          a.archivedAt.isNull() &
          a.draft.equals(false),
    );

    final results = await query.get();
    return results
        .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
        .toSet();
  }

  /// Watches which priorities have at least one non-archived, non-draft thread.
  static Stream<Set<PriorityId>> _watchNonEmptyPriorityIds() {
    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    query.where(a.archivedAt.isNull() & a.draft.equals(false));

    return query
        .watch()
        .map(
          (results) => results
              .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
              .toSet(),
        )
        .distinct();
  }

  /// Whether the focus identified by [id] currently has at least one
  /// non-archived, non-draft thread filed directly under it. Used to resolve
  /// the Archive-vs-"Merge into…" label for focuses loaded without
  /// `_enrichWithStatus`.
  static Future<bool> hasThreadsFor(PriorityId id) async {
    final ids = await _getNonEmptyPriorityIds([id]);
    return ids.contains(id);
  }
```

Wire it into `_enrichWithStatus` (~line 585). Add the query and pass the flag:

```dart
    // Compute which priorities have active/unread status
    final activeIds = await _getActivePriorityIds(priorityIds);
    final unreadIds = await _getUnreadPriorityIds(priorityIds);
    final nonEmptyIds = await _getNonEmptyPriorityIds(priorityIds);

    // Create new Priority objects with computed status
    return priorities.map((p) {
      return Priority.fromStore(
        p,
        parent: p.parent,
        children: p.children,
        draft: p.draft,
        ancestors: p._ancestors,
        minAncestorTopOrder: p.minAncestorTopOrder,
        active: activeIds.contains(p.id),
        unreadComputed: unreadIds.contains(p.id),
        hasThreads: nonEmptyIds.contains(p.id),
        displayColor: p.displayColor,
      );
    }).toList();
```

Wire it into `watch` (~lines 415-444). Add the fourth stream, switch `combineLatest3` → `combineLatest4`, and pass the flag:

```dart
    // Watch active, unread, and non-empty priority IDs
    final activePriorityIdsStream = _watchActivePriorityIds();
    final unreadPriorityIdsStream = _watchUnreadPriorityIds();
    final nonEmptyPriorityIdsStream = _watchNonEmptyPriorityIds();

    // Combine all four streams
    return Rx.combineLatest4(
          prioritiesStream,
          activePriorityIdsStream,
          unreadPriorityIdsStream,
          nonEmptyPriorityIdsStream,
          (priorities, activeIds, unreadIds, nonEmptyIds) =>
              (priorities, activeIds, unreadIds, nonEmptyIds),
        )
        .map((tuple) {
          final priorities = tuple.$1;
          final activeIds = tuple.$2;
          final unreadIds = tuple.$3;
          final nonEmptyIds = tuple.$4;

          return priorities.map((p) {
            return Priority.fromStore(
              p,
              parent: p.parent,
              children: p.children,
              draft: p.draft,
              ancestors: p._ancestors,
              minAncestorTopOrder: p.minAncestorTopOrder,
              active: activeIds.contains(p.id),
              unreadComputed: unreadIds.contains(p.id),
              hasThreads: nonEmptyIds.contains(p.id),
              displayColor: p.displayColor,
            );
          }).toList();
        })
        .debounceTime(const Duration(milliseconds: 100))
        .distinct()
        .transform(
          ExpiringStreamTransformer((priorities) {
```

(Leave the `.debounceTime/.distinct/.transform` tail exactly as-is.)

- [ ] **Step 7: Verify analyze + tests pass**

Run: `cd apps/plot && flutter analyze lib/store/priority.dart test/store/priority_has_threads_test.dart && flutter test test/store/priority_has_threads_test.dart`
Expected: No analyzer issues; tests PASS.

> If analyze reports `Rx.combineLatest4` undefined, confirm the rxdart import is present (the file already uses `Rx.combineLatest3`, so it should be).

- [ ] **Step 8: Commit**

```bash
git commit -- apps/plot/lib/store/priority.dart apps/plot/test/store/priority_has_threads_test.dart \
  -m "feat(priority): compute hasThreads enrichment flag"
```

---

## Task 2: `MergeFocusInto` + `MergeFocus` commands

**Files:**
- Modify: `apps/plot/lib/command/priority.dart`

No standalone test here — construction is covered by Task 3's selection test, and the runtime behavior is verified manually in Task 6 (it needs a Store + BuildContext, matching the codebase's "pure logic unit-tested, integration verified via run-app" convention).

- [ ] **Step 1: Add the two command classes**

Add to `apps/plot/lib/command/priority.dart` (place them just above `class ShowPriorityCommands` near line 1242). All needed symbols are already imported by this file: `Thread`, `Priority`, `Value`, `Uuid` (via `store/store.dart`), `NowBloc`/`NowLoaded` (via `state/now.dart`), `PriorityRoute` (via `router.dart`), `Tracker` (via `analytics/tracker.dart`), `PlotIcon`, `provider`, command base types (via `command.dart`).

```dart
/// Opens a focus picker to merge [source]'s threads into another focus.
/// Selecting a target moves every thread filed under [source] into it and
/// then archives [source]. Shown on a focus only when it has threads (an
/// empty focus keeps the plain Archive command).
class MergeFocusInto extends ShowCommands {
  MergeFocusInto(this.source)
    : super(
        title: 'Merge into…',
        icon: PlotIcon.move,
        eventObject: EventObject.priority,
        eventAction: EventAction.archived,
        commandsBuilder: (context) => _buildTargets(source),
      );

  final Priority source;

  static Future<Commands> _buildTargets(Priority source) async {
    // `getRaw` skips the unread/active enrichment the picker doesn't display,
    // so the modal opens immediately (same reasoning as MoveThreadToPriority).
    final priorities = await Priority.getRaw(order: PriorityOrder.recent);
    Priority? root;
    final focuses = <Priority>[];
    for (final p in priorities) {
      if (p.root) {
        root = p;
      } else if (p.id != source.id) {
        focuses.add(p);
      }
    }
    final commands = <Command>[
      ...focuses.map((target) => MergeFocus(source, target)),
      if (root != null && source.id != root.id)
        MergeFocus(source, root, label: 'Inbox', glyph: PlotIcon.inbox),
    ];
    return Commands(
      prompt: 'Merge "${source.displayTitle}" into…',
      groups: [StaticCommandGroup(title: 'Focuses', commands: commands)],
    );
  }
}

/// Moves every thread filed under [_source] into the target focus, then
/// archives [_source]. Filing is per-user, so this only re-files the current
/// user's view and archives their copy of the source focus — teammates are
/// unaffected.
class MergeFocus extends PriorityCommand {
  MergeFocus(Priority source, Priority target, {super.label, super.glyph})
    : _source = source,
      super(
        target,
        eventObject: EventObject.priority,
        eventAction: EventAction.archived,
      );

  final Priority _source;
  Priority get _target => priority!;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Capture whether we're viewing the source focus before any await, so we
    // can follow the threads to the target after archiving the source.
    final nowBloc = context.read<NowBloc?>();
    final viewingSource = nowBloc?.state is NowLoaded &&
        (nowBloc!.state as NowLoaded).priority.id == _source.id;

    try {
      // Re-file every thread filed under the source — including archived
      // threads and drafts — so nothing is stranded under the archived
      // source. The thread save() is what syncs the re-filing (the mechanism
      // MoveToPriority relies on). We intentionally skip the per-thread
      // /sync/priority-moves learning signal: a bulk merge is a deliberate
      // re-file, not N classifier-training events.
      final threads = await Thread.get(
        priorityId: _source.id,
        archived: null,
        draft: null,
      );
      for (final thread in threads) {
        await thread.copyWith(priority: _target).save();
      }
      // Archive the source focus.
      await _source.copyWith(archivedAt: Value(DateTime.now())).save();
    } catch (e, stackTrace) {
      Tracker.captureException(e, stackTrace);
      return const CommandMessage(
        'Could not merge focus. Please try again.',
        isError: true,
      );
    }

    if (viewingSource) {
      return CommandRoute(
        PriorityRoute(priorityIdString: _target.id.toShortString()),
      );
    }
    return const CommandDone();
  }
}
```

- [ ] **Step 2: Verify analyze**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: No analyzer issues.

> If `EventAction.archived` / `EventObject.priority` aren't valid enum members, match what `TogglePriorityArchived` uses (it passes `EventObject.priority` + `EventAction.archived`, so they are valid). If `context.read<NowBloc?>()` errors, mirror `_buildNewPriorityForm`'s `context.read<NowBloc>()` and guard with `nowBloc.state is NowLoaded`.

- [ ] **Step 3: Commit**

```bash
git commit -- apps/plot/lib/command/priority.dart \
  -m "feat(priority): add MergeFocusInto + MergeFocus commands"
```

---

## Task 3: Slot selection + strip leave-team flow

**Files:**
- Modify: `apps/plot/lib/command/priority.dart`
- Test: `apps/plot/test/command/priority_archive_or_merge_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/priority_archive_or_merge_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/priority.dart';
import 'package:plot/store/store.dart';

PriorityRow _row({DateTime? archivedAt}) => PriorityRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      title: 'Test',
      path: Path('test'),
      order: const Order(0),
      root: false,
      unread: false,
      role: 'member',
      archivedAt: archivedAt,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
    );

void main() {
  test('active focus with threads → Merge into…', () {
    final p = Priority.fromStore(_row(), draft: true, hasThreads: true);
    final cmd = archiveOrMergeCommand(p);
    expect(cmd, isA<MergeFocusInto>());
    expect(cmd.title, 'Merge into…');
  });

  test('active focus without threads → Archive', () {
    final p = Priority.fromStore(_row(), draft: true, hasThreads: false);
    final cmd = archiveOrMergeCommand(p);
    expect(cmd, isA<TogglePriorityArchived>());
    expect(cmd.title, 'Archive');
  });

  test('archived focus → Un-archive (never Merge)', () {
    final p = Priority.fromStore(
      _row(archivedAt: DateTime(2026, 1, 2)),
      draft: true,
      hasThreads: true,
    );
    final cmd = archiveOrMergeCommand(p);
    expect(cmd, isA<TogglePriorityArchived>());
    expect(cmd.title, 'Un-archive');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/command/priority_archive_or_merge_test.dart`
Expected: FAIL — `The function 'archiveOrMergeCommand' isn't defined`.

- [ ] **Step 3: Add `archiveOrMergeCommand` and branch `prioritySecondaryCommands`**

In `apps/plot/lib/command/priority.dart`, replace the `TogglePriorityArchived(priority)` entry in `prioritySecondaryCommands` (~line 1260) and add the helper:

```dart
List<Command> prioritySecondaryCommands(Priority priority) => [
  // The Inbox (root) is a fixed tile — no name/icon/colour to edit.
  if (!priority.isViewer && !priority.root) EditPriorityCommand(priority),
  if (!priority.isViewer) ShowEarlyNotificationsSettings(priority),
  ShowTimeLog(priority),
  if (!priority.root && !priority.isViewer && !priority.isPlot)
    archiveOrMergeCommand(priority),
];

/// The destructive slot on a focus menu. An archived focus offers Un-archive;
/// an active focus with threads offers "Merge into…" (move its threads
/// elsewhere, then archive); an active empty focus offers a one-click Archive.
/// Inbox / viewer / Plot focuses never reach here (gated by the caller).
Command archiveOrMergeCommand(Priority priority) {
  if (priority.archivedAt != null) return TogglePriorityArchived(priority);
  if (priority.hasThreads) return MergeFocusInto(priority);
  return TogglePriorityArchived(priority);
}
```

- [ ] **Step 4: Strip the leave-team flow from `TogglePriorityArchived`**

Replace the entire `run` method body of `TogglePriorityArchived` (~lines 380-466) with the plain toggle (archiving never affects team membership):

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    if (priority.root) {
      return CommandMessage(
        "The default focus can't be archived",
        isError: true,
      );
    }
    final isArchived = priority.archivedAt != null;
    await priority
        .copyWith(archivedAt: Value(isArchived ? null : DateTime.now()))
        .save();
    return const CommandDone();
  }
```

- [ ] **Step 5: Run the selection test to verify it passes**

Run: `cd apps/plot && flutter test test/command/priority_archive_or_merge_test.dart`
Expected: PASS (all 3 tests).

- [ ] **Step 6: Remove now-unused imports and verify analyze**

The removed branch was the only user of `ApiException` and `NetworkException`. Remove these two import lines from the top of `apps/plot/lib/command/priority.dart`:

```dart
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
```

Keep `import 'package:plot/api/api.dart' as api;` (still used at other call sites) and `UpgradeApi` (still used by the edit form). `ConfirmModal` comes from a still-used barrel import, so leave that import alone. `Priority.countOtherTopLevelTeamPriorities` is now unused but is a public static (no analyzer error) — leave it; removing it is optional cleanup out of scope here.

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: No analyzer issues. (If analyze flags any other now-unused import from the removed branch, remove exactly what it names.)

- [ ] **Step 7: Commit**

```bash
git commit -- apps/plot/lib/command/priority.dart apps/plot/test/command/priority_archive_or_merge_test.dart \
  -m "feat(priority): show Merge-into on non-empty focuses; drop leave-team archive flow"
```

---

## Task 4: Resolve `hasThreads` for current-focus menus

The header and command-scope menus load the current focus via `PriorityBloc` (which deliberately skips `_enrichWithStatus`, see `state/priority.dart:2586-2592`), so `hasThreads` is unset there. Resolve it at the build sites.

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` (add `enrichFocusFromList` helper)
- Modify: `apps/plot/lib/widget/unified_header.dart`
- Modify: `apps/plot/lib/page/priority.dart`

- [ ] **Step 1: Add the list-lookup helper**

In `apps/plot/lib/command/priority.dart`, add near `currentPriorityCommands` (~line 1268):

```dart
/// Returns [focus] enriched with `hasThreads` taken from the sidebar's
/// already-computed [loaded] priority list, so current-focus menus show the
/// right Archive/"Merge into…" label without re-querying. Falls back to
/// [focus] unchanged (hasThreads = false) when it isn't in the list (e.g. the
/// sidebar is search-filtered).
Priority enrichFocusFromList(Priority focus, List<Priority> loaded) {
  for (final p in loaded) {
    if (p.id == focus.id) return focus.withHasThreads(p.hasThreads);
  }
  return focus;
}
```

- [ ] **Step 2: Enrich in the header menus (async builders)**

In `apps/plot/lib/widget/unified_header.dart`, in `_buildPriorityAndThreadMenuCommand` (~line 954):

```dart
        final thread = state.thread;
        final priorityBloc = context.read<PriorityBloc?>();
        final focus = state.thread?.priority ?? state.context;
        final enrichedFocus =
            focus.withHasThreads(await Priority.hasThreadsFor(focus.id));
        final priorityGroups = currentPriorityCommandGroups(
          enrichedFocus,
          context: context,
          nowState: context.read<NowBloc?>()?.state,
        );
```

And in `_buildPriorityMenuCommand` (~line 974):

```dart
        final focus = state.context;
        final enrichedFocus =
            focus.withHasThreads(await Priority.hasThreadsFor(focus.id));
        final priorityGroups = currentPriorityCommandGroups(
          enrichedFocus,
          context: context,
          nowState: context.read<NowBloc?>()?.state,
        );
```

> `Priority` is already in scope in this file (it uses `state.context` typed as `Priority`). If `Priority` isn't imported directly, add `import 'package:plot/store/store.dart';` (most widget files already have it).

- [ ] **Step 3: Enrich in the synchronous command scope**

In `apps/plot/lib/page/priority.dart`, `_PriorityCommandScope.build` (~line 259):

```dart
  @override
  Widget build(BuildContext context) {
    final bloc = context.watch<PriorityBloc>();
    final nowState = context.watch<NowBloc>().state;
    // The sidebar's PrioritiesBloc list is enriched with hasThreads; reuse it
    // so the command-palette focus menu shows the right Archive/Merge label.
    final loaded = context.watch<PrioritiesBloc>().state.priorities;
    final focus = bloc.state.thread?.priority ?? bloc.state.context;
    return CommandScope(
      commands: currentPriorityCommandGroups(
        enrichFocusFromList(focus, loaded),
        nowState: nowState,
      ),
      child: child,
    );
  }
```

> Ensure `PrioritiesBloc` is imported in `page/priority.dart` (`import 'package:plot/state/priorities.dart';`) — add it if missing. `PrioritiesBloc` is provided by the priorities shell above this page, so `context.watch<PrioritiesBloc>()` resolves.

- [ ] **Step 4: Verify analyze**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart lib/widget/unified_header.dart lib/page/priority.dart`
Expected: No analyzer issues.

- [ ] **Step 5: Commit**

```bash
git commit -- apps/plot/lib/command/priority.dart apps/plot/lib/widget/unified_header.dart apps/plot/lib/page/priority.dart \
  -m "feat(priority): resolve hasThreads for current-focus menus"
```

---

## Task 5: Docs

**Files:**
- Modify: `docs/updates.md`
- Modify: `docs/features.md`

- [ ] **Step 1: Add a user-facing update note**

Add a bullet to the top (current) section of `docs/updates.md`, in plain language:

```markdown
- Merge a focus into another one: the focus menu now offers "Merge into…" — pick a destination and all its threads move there, then the focus is archived. Empty focuses still archive in one tap.
```

- [ ] **Step 2: Reflect the capability in features**

Add a short line under the focus/priority management area of `docs/features.md` describing that focuses can be merged into another focus (moving their threads and archiving the source).

- [ ] **Step 3: Commit**

```bash
git commit -- docs/updates.md docs/features.md \
  -m "docs: note Merge-into-focus capability"
```

---

## Task 6: Finalize + manual verification

**Files:** none (verification + checklist)

- [ ] **Step 1: Full analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No new issues introduced by this branch.

- [ ] **Step 2: Run the unit tests**

Run: `cd apps/plot && flutter test test/store/priority_has_threads_test.dart test/command/priority_archive_or_merge_test.dart`
Expected: PASS.

- [ ] **Step 3: Manual verification via the `run-app` skill**

Launch the app (run-app skill) and confirm:
- A focus **with** threads shows **"Merge into…"** in its sidebar kebab menu, right-click menu, and header "More" menu. Selecting a target moves all the focus's threads there and archives the source. The picker excludes the source focus and lists **Inbox** at the bottom.
- If the merge was initiated while viewing the source focus, the view follows to the target focus; threads appear there.
- A focus **with no** threads shows **"Archive"** (one tap, no picker).
- **Inbox** shows neither Merge nor Archive.
- Archiving a focus that used to be the "last team focus" no longer prompts to leave a team.

- [ ] **Step 4: Run the project finalize checklist**

Invoke the `finalize` skill (lint, backwards-compat, error capture, docs). Address anything it surfaces.

---

## Self-Review notes (addressed)

- **Spec coverage:** Detection via enrichment flag (Task 1) → spec §1/Option 2.A; slot branch + labels (Task 3) → spec §2; picker (Task 2) → spec §3; merge action incl. move-all + skip learning signal + route-follow + per-user semantics (Task 2) → spec §4; leave-team removal (Task 3) → spec §5; current-focus enrichment (Task 4) covers the spec's flagged risk; docs (Task 5) → spec §"Out of scope/Docs".
- **No confirmation dialog / no create-new-focus in picker / no descendant handling** — matches approved judgment calls (flat focuses).
- **Type consistency:** `hasThreads` (getter), `_hasThreadsComputed` (field), `withHasThreads` / `hasThreadsFor` / `archiveOrMergeCommand` / `enrichFocusFromList` used consistently across tasks; `MergeFocusInto` / `MergeFocus` names stable.
