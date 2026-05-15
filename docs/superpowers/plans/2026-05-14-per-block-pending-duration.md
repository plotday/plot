# Per-Block Pending Duration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a priority's pending duration **per-block** rather than per-priority, so editing time on one day's agenda block stops affecting other days.

**Architecture:** Schema unchanged. Abandon `kCurrentEffectiveAt` (the epoch sentinel) for new writes. All writes go to `effective_at = block.start`. The watch query becomes a UNION of (rows whose `effective_at >= todayMidnight`) + (per-priority carry-forward anchor strictly before midnight). Duration resolution becomes a chronological walker assigning each in-window row to exactly one block; order resolution is unchanged but runs over the unified row set with the anchor as fallback. The single source of truth for behavior is `docs/superpowers/specs/2026-05-14-per-block-pending-duration-design.md`.

**Tech Stack:** Flutter, Drift (SQLite), flutter_bloc, forui. Lint: `cd apps/plot && flutter analyze`. Tests: `cd apps/plot && flutter test <path>`.

---

## File Structure

### Modify
- `apps/plot/lib/state/agenda_model.dart` — add `start`/`end` getters on `AgendaBlock` and stored fields on `PriorityBlock`.
- `apps/plot/lib/state/agenda_builder.dart` — compute block windows during build; replace `_cascadePendingDurations` with `_attachBlockDurations`.
- `apps/plot/lib/store/priority_block.dart` — remove `kCurrentEffectiveAt` and `setPendingDuration`; add `setBlockDuration`; add `resolveBlockDurations`; remove `effectivePriorityDurationAt`; change the watch query to the UNION form.
- `apps/plot/lib/state/now.dart` — replace `watchPendingDisplay` with `watchBlockDisplay`; replace `applyPendingBump` with `applyBlockBump`; make `startSession`'s pending fallback block-aware; add date-rollover watcher.
- `apps/plot/lib/state/now_state.dart` — remove `pendingFor` (caller moves to `pendingForBlock`).
- `apps/plot/lib/state/priority.dart` — remove `pendingDurationFor` (only caller is `agenda.dart`; that caller switches to a per-block lookup).
- `apps/plot/lib/page/agenda.dart` — `_ensurePendingForGapDrop` writes the default via `setBlockDuration` at the target period's anchor.
- `apps/plot/lib/widget/agenda.dart` — `_BlockHeader` subscribes to `watchBlockDisplay`; bump routes through `applyBlockBump`.
- `apps/plot/lib/command/timer.dart` — `RemoveTime.enabled` uses block-aware pending.
- `apps/plot/lib/widget_bridge/widget_bridge.dart` — `state.pendingFor(ctx)` callsite switches to block-aware lookup.
- `docs/agenda.md` — rewrite the "Pending Duration Cascade" section; adjust "Drop Behavior" and "Inline Duration Bump".
- `docs/updates.md` — one user-facing line.

### Create
- `apps/plot/test/store/resolve_block_durations_test.dart` — pure-function tests for the new walker.
- `apps/plot/test/state/agenda_builder_pending_test.dart` — tests for `_attachBlockDurations` and block-window computation.

### Delete or update
- `apps/plot/test/store/priority_block_test.dart` — existing tests for `effectivePriorityOrderAt` stay (the resolver is unchanged). Any tests that referenced `effectivePriorityDurationAt` or `setPendingDuration` are removed or rewritten in Task 11.

---

## Task 1: Block windows on the agenda model

**Files:**
- Modify: `apps/plot/lib/state/agenda_model.dart`
- Test: `apps/plot/test/state/agenda_builder_pending_test.dart` (create)

- [ ] **Step 1.1: Write failing test for the new fields**

Create `apps/plot/test/state/agenda_builder_pending_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_model.dart' as ui;
import 'package:plot/store/store.dart';

Priority _testPriority({String path = 'p1', double order = 0}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path(path),
    order: Order(order),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinRequestsSet: false,
    seeWithinUpdatesSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  group('AgendaBlock window getters', () {
    test('GapBlock.start/end come from range', () {
      final p = _testPriority();
      final start = DateTime(2026, 5, 14, 9);
      final end = DateTime(2026, 5, 14, 10);
      final block = ui.GapBlock(
        id: 'g',
        priority: p,
        range: DateTimeRange(start, end),
        threads: const [],
      );
      expect(block.start, start);
      expect(block.end, end);
    });

    test('PriorityBlock.start/end come from windowStart/windowEnd', () {
      final p = _testPriority();
      final start = DateTime(2026, 5, 14);
      final end = DateTime(2026, 5, 15);
      final block = ui.PriorityBlock(
        id: 'p',
        priority: p,
        threads: const [],
        windowStart: start,
        windowEnd: end,
      );
      expect(block.start, start);
      expect(block.end, end);
    });
  });
}
```

- [ ] **Step 1.2: Run the test and watch it fail**

Run: `cd apps/plot && flutter test test/state/agenda_builder_pending_test.dart -r expanded`
Expected: COMPILATION FAIL — `start`/`end`/`windowStart`/`windowEnd` not defined.

- [ ] **Step 1.3: Add `start`/`end` to the sealed `AgendaBlock` base class**

In `apps/plot/lib/state/agenda_model.dart` find:

```dart
sealed class AgendaBlock extends Equatable {
  const AgendaBlock();

  String get id;
  Priority get priority;
  List<Thread> get threads;
  bool get isOutside;
```

Add the two abstract getters right after `bool get isOutside;`:

```dart
  /// Inclusive start of this block's time window. Used as `effective_at`
  /// when the user edits the block's pending duration, and as the lower
  /// bound when checking session containment.
  DateTime get start;

  /// Exclusive end of this block's time window. Used as the upper bound
  /// when checking session containment. Standalone blocks at section
  /// end use the section's next-midnight as their end.
  DateTime get end;
```

- [ ] **Step 1.4: Implement `start`/`end` on `PriorityBlock`**

Find the `PriorityBlock` constructor (currently `const PriorityBlock({ ... })`) and:

1. Change the constructor signature to add two required parameters:

```dart
class PriorityBlock extends AgendaBlock {
  const PriorityBlock({
    required this.id,
    required this.priority,
    required this.threads,
    required this.windowStart,
    required this.windowEnd,
    this.isOutside = false,
    this.cascadeDuration,
  });
```

2. Add the fields below the existing fields:

```dart
  /// Inclusive start of this block's day-local window.
  final DateTime windowStart;

  /// Exclusive end of this block's day-local window.
  final DateTime windowEnd;

  @override
  DateTime get start => windowStart;

  @override
  DateTime get end => windowEnd;
```

3. Add `windowStart, windowEnd` to the `props` list:

```dart
  @override
  List<Object?> get props => [id, priority, threads, isOutside, cascadeDuration, windowStart, windowEnd];
```

- [ ] **Step 1.5: Implement `start`/`end` on `GapBlock`**

In `GapBlock`, add getters that read from `range`:

```dart
  @override
  DateTime get start =>
      range.start ?? (throw StateError('GapBlock without range.start'));

  @override
  DateTime get end =>
      range.end ?? (throw StateError('GapBlock without range.end'));
```

Place them next to the other field declarations.

- [ ] **Step 1.6: Implement `start`/`end` on `EventBlock`**

In `EventBlock`, add getters that read from the event's `at`:

```dart
  @override
  DateTime get start =>
      event.at?.start ??
      (throw StateError('EventBlock without event.at.start'));

  @override
  DateTime get end =>
      event.at?.end ??
      (throw StateError('EventBlock without event.at.end'));
```

- [ ] **Step 1.7: Update every existing `PriorityBlock(...)` call site to pass windows**

Existing constructors in `apps/plot/lib/state/agenda_builder.dart` (lines 143, 189, 426, 444, 642, 706, 892, 1012) and the test file `apps/plot/test/state/agenda_builder_test.dart` need `windowStart` and `windowEnd` parameters added. Search the repo:

```bash
grep -rn 'PriorityBlock(' apps/plot/lib apps/plot/test --include='*.dart'
```

For every UI `PriorityBlock` constructor call, add:

```dart
  windowStart: <pick a reasonable default>,
  windowEnd: <pick a reasonable default>,
```

Until Task 2 wires real values into the agenda builder, use placeholders that the test harness accepts. In `apps/plot/lib/state/agenda_builder.dart`, you can borrow the section's date midnight for `windowStart` and `windowStart.add(Duration(days: 1))` for `windowEnd`. The agenda builder rewrites all of these in Task 2; for now any deterministic non-null `DateTime` is fine.

In `apps/plot/test/state/agenda_builder_test.dart`, e.g. line 65, write:

```dart
final todayBlock = ui.PriorityBlock(
  id: 'p_today_${priority.path.value}_0',
  priority: priority,
  threads: [todayThreadA, todayThreadB],
  windowStart: DateTime(2026, 5, 2),
  windowEnd: DateTime(2026, 5, 3),
);
```

- [ ] **Step 1.8: Run the new test**

Run: `cd apps/plot && flutter test test/state/agenda_builder_pending_test.dart -r expanded`
Expected: PASS for both window-getter tests.

- [ ] **Step 1.9: Run the existing agenda builder tests**

Run: `cd apps/plot && flutter test test/state/agenda_builder_test.dart -r expanded`
Expected: PASS. If any fail because of missing `windowStart`/`windowEnd`, fix the construction site.

- [ ] **Step 1.10: Run `flutter analyze` on touched files**

Run: `cd apps/plot && flutter analyze lib/state/agenda_model.dart lib/state/agenda_builder.dart test/state/agenda_builder_pending_test.dart`
Expected: No errors.

- [ ] **Step 1.11: Commit**

```bash
git add apps/plot/lib/state/agenda_model.dart apps/plot/lib/state/agenda_builder.dart apps/plot/test/state/agenda_builder_pending_test.dart apps/plot/test/state/agenda_builder_test.dart
git commit -m "Add block window fields to AgendaBlock subtypes"
```

---

## Task 2: Compute block windows during agenda build

**Files:**
- Modify: `apps/plot/lib/state/agenda_builder.dart`
- Test: `apps/plot/test/state/agenda_builder_pending_test.dart`

The placeholders from Task 1.7 get replaced with real per-block windows derived from each section's contents.

- [ ] **Step 2.1: Write failing test for window computation**

Append to `apps/plot/test/state/agenda_builder_pending_test.dart`:

```dart
  group('AgendaBuilder block windows', () {
    setUp(() => Time.setFrozenTime(DateTime(2026, 5, 14, 14, 0)));
    tearDown(() => Time.unfreeze());

    test('standalone PriorityBlock with no time-anchored siblings uses '
        'section midnight to next midnight', () {
      final p = _testPriority();
      final today = Date(2026, 5, 14);
      final t = Thread(priority: p, title: 't', createdAt: today.toDateTime());
      final model = AgendaBuilder.build(
        threads: [t],
        context: p,
        horizonDays: 1,
      );
      final block = model.allBlocks.whereType<ui.PriorityBlock>().firstWhere(
        (b) => b.priority.id == p.id,
      );
      expect(block.start, DateTime(2026, 5, 14));
      expect(block.end, DateTime(2026, 5, 15));
    });
  });
```

Add the import `import 'package:plot/state/agenda_builder.dart';` if it's not already there.

- [ ] **Step 2.2: Run the test and watch it fail**

Run: `cd apps/plot && flutter test test/state/agenda_builder_pending_test.dart --name "standalone PriorityBlock" -r expanded`
Expected: FAIL — placeholder windows don't equal section midnight.

- [ ] **Step 2.3: Implement window computation**

In `apps/plot/lib/state/agenda_builder.dart`, add a new private helper right above `_atomsToModel`:

```dart
  /// Returns `(start, end)` for a standalone [PriorityBlock] at index
  /// [blockIndex] inside [sectionBlocks], which all belong to
  /// [sectionDate]. Walks back to find the closest preceding time-anchored
  /// block (gap or event) and forward to find the next. The standalone's
  /// window is `[prevEnd ?? sectionMidnight, nextStart ?? sectionMidnight + 1d)`.
  static ({DateTime start, DateTime end}) _standaloneWindow({
    required Date sectionDate,
    required List<AgendaBlock> sectionBlocks,
    required int blockIndex,
  }) {
    final midnight = DateTime(sectionDate.year, sectionDate.month, sectionDate.day);
    DateTime? prevEnd;
    for (var i = blockIndex - 1; i >= 0; i--) {
      final b = sectionBlocks[i];
      if (b is GapBlock) {
        prevEnd = b.range.end;
        if (prevEnd != null) break;
      } else if (b is EventBlock) {
        prevEnd = b.event.at?.end;
        if (prevEnd != null) break;
      }
    }
    DateTime? nextStart;
    for (var i = blockIndex + 1; i < sectionBlocks.length; i++) {
      final b = sectionBlocks[i];
      if (b is GapBlock) {
        nextStart = b.range.start;
        if (nextStart != null) break;
      } else if (b is EventBlock) {
        nextStart = b.event.at?.start;
        if (nextStart != null) break;
      }
    }
    return (
      start: prevEnd ?? midnight,
      end: nextStart ?? midnight.add(const Duration(days: 1)),
    );
  }
```

- [ ] **Step 2.4: Wire `_standaloneWindow` into all `PriorityBlock` constructions in the builder**

Currently every `PriorityBlock(...)` call in `agenda_builder.dart` builds blocks without windows (Task 1.7 used placeholders). Rewrite to populate windows from the surrounding section.

The cleanest place to apply windows is the **final** model construction. After `_cascadeAndSort` and before returning, add a window-resolution pass:

In `AgendaBuilder.build`, **after** the `_cascadePendingDurations` call (which will be replaced in Task 5 but still runs today) and **before** `return`, insert:

```dart
    final withWindows = _populateBlockWindows(withUnread);
```

…and then return `_cascadePendingDurations(withWindows, ...)`.

Add the helper:

```dart
  /// Rebuild every [PriorityBlock] in every [DateSection] with the
  /// `start`/`end` window derived from its position in the section.
  /// `GapBlock` and `EventBlock` already carry their own time anchors
  /// and are passed through unchanged.
  static AgendaModel _populateBlockWindows(AgendaModel model) {
    final newSections = <AgendaSection>[];
    for (final section in model.sections) {
      if (section is! DateSection) {
        newSections.add(section);
        continue;
      }
      final blocks = section.blocks;
      final rebuilt = <AgendaBlock>[];
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        if (b is PriorityBlock) {
          final w = _standaloneWindow(
            sectionDate: section.date,
            sectionBlocks: blocks,
            blockIndex: i,
          );
          rebuilt.add(PriorityBlock(
            id: b.id,
            priority: b.priority,
            threads: b.threads,
            isOutside: b.isOutside,
            cascadeDuration: b.cascadeDuration,
            windowStart: w.start,
            windowEnd: w.end,
          ));
        } else {
          rebuilt.add(b);
        }
      }
      newSections.add(DateSection(
        date: section.date,
        blocks: List.unmodifiable(rebuilt),
        isNow: section.isNow,
        scheduleAt: section.scheduleAt,
      ));
    }
    return AgendaModel(sections: List.unmodifiable(newSections));
  }
```

- [ ] **Step 2.5: Replace placeholder windows in builder construction sites**

At every `PriorityBlock(...)` call earlier in the file, the placeholders from Task 1.7 can be **kept** — they'll be overwritten by `_populateBlockWindows`. To make this explicit and avoid bogus values lingering if the pass is ever bypassed, change the placeholders to a clearly-temporary value:

```dart
windowStart: DateTime.fromMillisecondsSinceEpoch(0),
windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
```

Add a `// overwritten by _populateBlockWindows` comment next to one occurrence so future readers don't get confused.

- [ ] **Step 2.6: Run the test**

Run: `cd apps/plot && flutter test test/state/agenda_builder_pending_test.dart -r expanded`
Expected: PASS.

- [ ] **Step 2.7: Lint and run the full agenda-builder test**

```bash
cd apps/plot && flutter analyze lib/state/agenda_builder.dart lib/state/agenda_model.dart
cd apps/plot && flutter test test/state/ -r expanded
```
Expected: No analyzer errors; all tests pass.

- [ ] **Step 2.8: Commit**

```bash
git add apps/plot/lib/state/agenda_builder.dart apps/plot/test/state/agenda_builder_pending_test.dart
git commit -m "Compute block windows during agenda build"
```

---

## Task 3: Implement `resolveBlockDurations` (pure)

**Files:**
- Modify: `apps/plot/lib/store/priority_block.dart` (add function; do not yet remove `effectivePriorityDurationAt`)
- Test: `apps/plot/test/store/resolve_block_durations_test.dart` (create)

- [ ] **Step 3.1: Write failing tests**

Create `apps/plot/test/store/resolve_block_durations_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

PriorityBlockRow _row({
  required DateTime effectiveAt,
  Duration? duration,
  double order = 0,
  DateTime? archivedAt,
}) {
  return PriorityBlockRow(
    id: Uuid.generate(),
    priorityId: Uuid.fromString('00000000-0000-0000-0000-000000000001'),
    createdBy: Uuid.fromString('00000000-0000-0000-0000-000000000002'),
    orderValue: Order(order),
    effectiveAt: effectiveAt,
    duration: duration,
    archivedAt: archivedAt,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  final todayMidnight = DateTime(2026, 5, 14);

  group('resolveBlockDurations', () {
    test('single row consumed by first chronological block', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
        (id: 'b', start: DateTime(2026, 5, 15, 9)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 14, 9), duration: const Duration(minutes: 30)),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], const Duration(minutes: 30));
      expect(result['b'], isNull);
    });

    test('multiple rows in different windows each attach to their own block', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
        (id: 'b', start: DateTime(2026, 5, 15, 9)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 14, 9), duration: const Duration(minutes: 30)),
        _row(effectiveAt: DateTime(2026, 5, 15, 9), duration: const Duration(minutes: 60)),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], const Duration(minutes: 30));
      expect(result['b'], const Duration(minutes: 60));
    });

    test('multiple rows in the same window — latest effective_at wins', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 10)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 14, 9), duration: const Duration(minutes: 30)),
        _row(effectiveAt: DateTime(2026, 5, 14, 10), duration: const Duration(minutes: 60)),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], const Duration(minutes: 60));
    });

    test('row with effective_at before todayMidnight is ignored', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 13, 9), duration: const Duration(minutes: 30)),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], isNull,
          reason: 'anchor rows do not contribute durations');
    });

    test('archived rows are ignored', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
      ];
      final rows = [
        _row(
          effectiveAt: DateTime(2026, 5, 14, 9),
          duration: const Duration(minutes: 30),
          archivedAt: DateTime(2026, 5, 14, 10),
        ),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], isNull);
    });

    test('rows with null duration are ignored', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 14, 9)),  // duration null
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], isNull);
    });

    test('future-dated row with no matching block is not consumed', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 15, 9), duration: const Duration(minutes: 30)),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], isNull);
    });
  });
}
```

- [ ] **Step 3.2: Run the test and watch it fail**

Run: `cd apps/plot && flutter test test/store/resolve_block_durations_test.dart -r expanded`
Expected: COMPILATION FAIL — `resolveBlockDurations` not defined.

- [ ] **Step 3.3: Implement `resolveBlockDurations` in `priority_block.dart`**

Add to `apps/plot/lib/store/priority_block.dart` right after `effectivePriorityDurationAt`:

```dart
/// Pure function. Returns a map from agenda block id to the duration
/// that block should display.
///
/// Walks the priority's blocks in chronological order; each block
/// consumes every unconsumed in-window row whose `effective_at <=
/// block.start`, and gets the latest such row's `duration`. Rows whose
/// `effective_at` is strictly before [todayMidnight] are ignored (they
/// serve only as the order resolver's anchor and never contribute a
/// duration). Archived rows and rows with null `duration` are skipped.
///
/// [blocks] must be sorted ascending by `start`.
Map<String, Duration?> resolveBlockDurations({
  required DateTime todayMidnight,
  required List<({String id, DateTime start})> blocks,
  required Iterable<PriorityBlockRow> blocksForPriority,
}) {
  final rows = blocksForPriority
      .where((r) => r.archivedAt == null)
      .where((r) => r.duration != null)
      .where((r) => !r.effectiveAt.isBefore(todayMidnight))
      .toList()
    ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));

  final out = <String, Duration?>{};
  var rowIdx = 0;
  for (final b in blocks) {
    Duration? best;
    while (rowIdx < rows.length &&
        !rows[rowIdx].effectiveAt.isAfter(b.start)) {
      best = rows[rowIdx].duration;
      rowIdx++;
    }
    out[b.id] = best;
  }
  return out;
}
```

- [ ] **Step 3.4: Re-run the test**

Run: `cd apps/plot && flutter test test/store/resolve_block_durations_test.dart -r expanded`
Expected: PASS — all seven tests green.

- [ ] **Step 3.5: Commit**

```bash
git add apps/plot/lib/store/priority_block.dart apps/plot/test/store/resolve_block_durations_test.dart
git commit -m "Add resolveBlockDurations walker"
```

---

## Task 4: Add `setBlockDuration` write path

**Files:**
- Modify: `apps/plot/lib/store/priority_block.dart`

The new write helper replaces `setPendingDuration`. It writes a row at `(priority_id, effective_at = blockStart)` rather than at the epoch sentinel.

- [ ] **Step 4.1: Add `setBlockDuration` to `PriorityBlock`**

In `apps/plot/lib/store/priority_block.dart`, just after the existing `setPendingDuration` static method, add:

```dart
  /// Upsert a `priority_block` row for [priorityId] at `effective_at =
  /// blockStart`, carrying [newDuration]. Carries the priority's
  /// effective order at [blockStart] into `order_value` so the row also
  /// participates in the order timeline (same convention reorders use).
  ///
  /// Semantics:
  ///   - normalize null/≤0 → null,
  ///   - if normalized equals the current row's duration, no-op,
  ///   - if normalized is null, soft-archive the row at this slot,
  ///   - otherwise upsert in place at `(priorityId, blockStart)`.
  static Future<void> setBlockDuration({
    required PriorityId priorityId,
    required DateTime blockStart,
    required Duration? newDuration,
  }) async {
    if (!Store.isAvailable) return;
    final normalized =
        (newDuration == null || newDuration <= Duration.zero) ? null : newDuration;

    final rows = await (Store.get.select(table)
          ..where((t) => t.priorityId.equals(priorityId.toBytes())))
        .get();

    final slotRow = rows.firstWhereOrNull(
      (r) => r.effectiveAt.isAtSameMomentAs(blockStart),
    );
    final currentDuration =
        slotRow?.archivedAt == null ? slotRow?.duration : null;
    if (normalized == currentDuration) return;

    final now = DateTime.now();

    if (normalized == null) {
      if (slotRow == null || slotRow.archivedAt != null) return;
      final archived = slotRow.copyWith(
        archivedAt: Value(now),
        updatedAt: now,
      );
      await Store.get.save(
        table,
        archived.toCompanion(false),
        PriorityBlocksBase(),
      );
      return;
    }

    final inheritedOrder = effectivePriorityOrderAt(
      moment: blockStart,
      blocksForPriority: rows,
      fallback: 0,
    );

    final row = slotRow != null
        ? slotRow.copyWith(
            orderValue: Order(inheritedOrder),
            duration: Value(normalized),
            archivedAt: const Value(null),
            updatedAt: now,
          )
        : PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: priorityId,
            createdBy: Base.userId,
            orderValue: Order(inheritedOrder),
            effectiveAt: blockStart,
            duration: normalized,
            archivedAt: null,
            createdAt: now,
            updatedAt: now,
          );
    await Store.get.save(
      table,
      row.toCompanion(false),
      PriorityBlocksBase(),
    );
  }
```

- [ ] **Step 4.2: Lint**

```bash
cd apps/plot && flutter analyze lib/store/priority_block.dart
```
Expected: No errors.

- [ ] **Step 4.3: Commit**

```bash
git add apps/plot/lib/store/priority_block.dart
git commit -m "Add setBlockDuration write path"
```

---

## Task 5: Replace `_cascadePendingDurations` with `_attachBlockDurations`

**Files:**
- Modify: `apps/plot/lib/state/agenda_builder.dart`
- Test: `apps/plot/test/state/agenda_builder_pending_test.dart`

The cascade pass currently folds the priority's global pending onto today's section. Replace it with a per-block fold driven by `resolveBlockDurations`.

- [ ] **Step 5.1: Write failing test**

Append to `apps/plot/test/state/agenda_builder_pending_test.dart`:

```dart
  group('AgendaBuilder per-block durations', () {
    setUp(() => Time.setFrozenTime(DateTime(2026, 5, 14, 14, 0)));
    tearDown(() => Time.unfreeze());

    test('only the first chronological block of a priority receives a '
        'duration row written at its window start', () {
      final p = _testPriority();
      final today = Date(2026, 5, 14);
      final tomorrow = today.addDays(1);
      final t1 = Thread(priority: p, title: 'today', createdAt: today.toDateTime());
      final t2 = Thread(priority: p, title: 'tomorrow', createdAt: tomorrow.toDateTime());
      final rows = {
        p.id: [
          PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: p.id,
            createdBy: Uuid.generate(),
            orderValue: Order(0),
            effectiveAt: DateTime(2026, 5, 14),  // today midnight
            duration: const Duration(minutes: 30),
            archivedAt: null,
            createdAt: DateTime(2026, 5, 14),
            updatedAt: DateTime(2026, 5, 14),
          ),
        ],
      };
      final model = AgendaBuilder.build(
        threads: [t1, t2],
        context: p,
        horizonDays: 2,
        priorityBlocksByPriority: rows,
      );
      final blocks = model.allBlocks.whereType<ui.PriorityBlock>().toList();
      expect(blocks.length, 2);
      expect(blocks[0].cascadeDuration, const Duration(minutes: 30),
          reason: 'today block consumes the row at its start');
      expect(blocks[1].cascadeDuration, isNull,
          reason: 'tomorrow block has no row in its window');
    });
  });
```

- [ ] **Step 5.2: Run the test and watch it fail**

Run: `cd apps/plot && flutter test test/state/agenda_builder_pending_test.dart --name "only the first chronological block" -r expanded`
Expected: FAIL — both blocks currently receive the priority's global pending via the old cascade.

- [ ] **Step 5.3: Implement `_attachBlockDurations`**

In `apps/plot/lib/state/agenda_builder.dart` add the new pass below `_populateBlockWindows`:

```dart
  /// For every priority, walk its agenda blocks in chronological order
  /// (across all sections) and attach the duration that `priority_block`
  /// rows resolve to for each block. Replaces the previous
  /// `_cascadePendingDurations` fold, which surfaced a per-priority
  /// total on today only.
  static AgendaModel _attachBlockDurations(
    AgendaModel model, {
    required DateTime todayMidnight,
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
  }) {
    if (priorityBlocksByPriority.isEmpty) return model;

    // 1. Build a chronological block list per priority.
    final blocksByPriority = <PriorityId, List<({String id, DateTime start})>>{};
    for (final section in model.sections) {
      for (final block in section.blocks) {
        // PriorityBlocks and priority-led GapBlocks are the only kinds
        // that carry a priority's pending; EventBlocks do not.
        if (block is PriorityBlock || block is GapBlock) {
          final list = blocksByPriority.putIfAbsent(
            block.priority.id,
            () => <({String id, DateTime start})>[],
          );
          list.add((id: block.id, start: block.start));
        }
      }
    }
    for (final list in blocksByPriority.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    // 2. Resolve durations per priority.
    final resolvedByBlockId = <String, Duration>{};
    for (final entry in blocksByPriority.entries) {
      final rows = priorityBlocksByPriority[entry.key] ?? const [];
      final perBlock = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: entry.value,
        blocksForPriority: rows,
      );
      for (final mapEntry in perBlock.entries) {
        final d = mapEntry.value;
        if (d != null && d > Duration.zero) {
          resolvedByBlockId[mapEntry.key] = d;
        }
      }
    }

    if (resolvedByBlockId.isEmpty) return model;

    // 3. Fold the resolved durations back onto each block.
    final newSections = <AgendaSection>[];
    for (final section in model.sections) {
      final newBlocks = <AgendaBlock>[];
      for (final block in section.blocks) {
        final dur = resolvedByBlockId[block.id];
        if (dur == null) {
          newBlocks.add(block);
          continue;
        }
        if (block is PriorityBlock) {
          newBlocks.add(PriorityBlock(
            id: block.id,
            priority: block.priority,
            threads: block.threads,
            isOutside: block.isOutside,
            cascadeDuration: dur,
            windowStart: block.windowStart,
            windowEnd: block.windowEnd,
          ));
        } else if (block is GapBlock) {
          newBlocks.add(GapBlock(
            id: block.id,
            priority: block.priority,
            range: block.range,
            threads: block.threads,
            isOutside: block.isOutside,
            periodAnchor: block.periodAnchor,
            cascadeDuration: dur,
          ));
        } else {
          newBlocks.add(block);
        }
      }
      switch (section) {
        case DateSection s:
          newSections.add(DateSection(
            date: s.date,
            blocks: List.unmodifiable(newBlocks),
            isNow: s.isNow,
            scheduleAt: s.scheduleAt,
          ));
        case TextSection s:
          newSections.add(TextSection(
            text: s.text,
            blocks: List.unmodifiable(newBlocks),
          ));
      }
    }
    return AgendaModel(sections: List.unmodifiable(newSections));
  }

  /// Compute today's local midnight from [now]. Pulled out so tests
  /// can pass a frozen `now`.
  static DateTime _todayMidnightFromNow(DateTime now) =>
      DateTime(now.year, now.month, now.day);
```

- [ ] **Step 5.4: Wire `_attachBlockDurations` into `AgendaBuilder.build`**

Replace the body of `AgendaBuilder.build` ending. Find the final `return _cascadePendingDurations(...)`. Change the function to call `_populateBlockWindows` first, then `_attachBlockDurations`:

```dart
    final withWindows = _populateBlockWindows(withUnread);
    return _attachBlockDurations(
      withWindows,
      todayMidnight: _todayMidnightFromNow(effectiveNow),
      priorityBlocksByPriority: priorityBlocksByPriority ?? const {},
    );
```

- [ ] **Step 5.5: Delete `_cascadePendingDurations` and `_foldCascadeIntoTodaySection`**

Both helpers (currently `apps/plot/lib/state/agenda_builder.dart` lines roughly 67–241) are replaced by `_attachBlockDurations`. Delete them entirely along with the `_emitResidualGaps` helper if it is no longer referenced elsewhere. Verify by grepping:

```bash
grep -n '_cascadePendingDurations\|_foldCascadeIntoTodaySection\|_emitResidualGaps' apps/plot/lib
```

If `_emitResidualGaps` is still called from `_consolidateAndSort` or similar, leave it. The cascade-residual logic was about overflow that no longer exists; if no caller remains, delete it.

- [ ] **Step 5.6: Re-run the test**

Run: `cd apps/plot && flutter test test/state/agenda_builder_pending_test.dart -r expanded`
Expected: PASS.

- [ ] **Step 5.7: Run all agenda builder tests**

Run: `cd apps/plot && flutter test test/state/agenda_builder_test.dart -r expanded`
Expected: PASS. Some existing tests may have implicitly relied on `cascadeDuration` showing on today-only; if any fail, the fix is to update the test's expectations to the new per-block semantics (each block independently shows its row's duration).

- [ ] **Step 5.8: Lint**

```bash
cd apps/plot && flutter analyze lib/state/agenda_builder.dart
```
Expected: No errors.

- [ ] **Step 5.9: Commit**

```bash
git add apps/plot/lib/state/agenda_builder.dart apps/plot/test/state/agenda_builder_pending_test.dart
git commit -m "Replace cascade fold with per-block duration walker"
```

---

## Task 6: UNION fetch query with per-priority carry-forward anchor

**Files:**
- Modify: `apps/plot/lib/store/priority_block.dart`

The watch query is replaced with a UNION: forward-window rows + one carry-forward anchor per priority strictly before today's midnight.

- [ ] **Step 6.1: Rewrite `streamPriorityBlocksGroupedByPriority`**

Replace the function body in `apps/plot/lib/store/priority_block.dart`:

```dart
/// Stream every `priority_block` row that the agenda might care about,
/// grouped by priority id. Returns a UNION of:
///   1. All non-archived rows with `effective_at >= todayMidnight`
///      (the forward window — today, future, and pre-planned changes).
///   2. The per-priority carry-forward anchor: the most-recent
///      non-archived row strictly before `todayMidnight`, so the
///      cumulative order resolver still has a baseline once historical
///      rows fall out of the forward window.
///
/// Anchor rows participate in [effectivePriorityOrderAt] only;
/// [resolveBlockDurations] filters them out and ignores their
/// `duration` values.
Stream<Map<PriorityId, List<PriorityBlockRow>>>
    streamPriorityBlocksGroupedByPriority() {
  final db = Store.get;
  final todayMidnight = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );

  final query = db.customSelect(
    '''
SELECT * FROM priority_blocks
WHERE archived_at IS NULL AND effective_at >= ?1

UNION ALL

SELECT pb.* FROM priority_blocks pb
WHERE pb.archived_at IS NULL
  AND pb.effective_at < ?1
  AND pb.effective_at = (
    SELECT MAX(effective_at) FROM priority_blocks
    WHERE priority_id = pb.priority_id
      AND archived_at IS NULL
      AND effective_at < ?1
  )
''',
    variables: [Variable.withDateTime(todayMidnight)],
    readsFrom: {db.priorityBlocks},
  );

  return query.watch().map((rows) {
    final out = <PriorityId, List<PriorityBlockRow>>{};
    for (final r in rows) {
      final row = db.priorityBlocks.map(r.data);
      out.putIfAbsent(row.priorityId, () => <PriorityBlockRow>[]).add(row);
    }
    return out;
  });
}
```

Add the imports at the top of the file if missing:

```dart
import 'package:drift/drift.dart' show Variable;
```

Drift's `customSelect` and `map(r.data)` are documented in `package:drift`; the table accessor `db.priorityBlocks` is generated by the existing Drift codegen.

- [ ] **Step 6.2: Smoke-test the query compiles**

Run: `cd apps/plot && flutter analyze lib/store/priority_block.dart`
Expected: No errors. (The query itself is integration-tested implicitly by the next tasks; the test infrastructure for the local Drift store typically uses `flutter test` with an in-memory database, which is heavy infra — out of scope here.)

- [ ] **Step 6.3: Commit**

```bash
git add apps/plot/lib/store/priority_block.dart
git commit -m "Bound priority_block fetch to today's window + per-priority anchor"
```

---

## Task 7: `watchBlockDisplay` live overlay

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

Replace `NowBloc.watchPendingDisplay(priorityId)` with `watchBlockDisplay({priorityId, blockStart, blockEnd})`. Existing callers are switched in Task 9; for now both exist.

- [ ] **Step 7.1: Add `watchBlockDisplay`**

In `apps/plot/lib/state/now.dart`, after `watchPendingDisplay`, add:

```dart
  /// Live remaining-duration stream for a specific agenda block.
  /// Resolution order:
  ///   1. Active session for this priority whose `pomodoroAt` falls in
  ///      `[blockStart, blockEnd)` AND `at.isNow()` →
  ///      `pomodoroAt + pomodoro - now`.
  ///   2. Paused-explicit session for this priority whose `pomodoroAt`
  ///      falls in `[blockStart, blockEnd)` →
  ///      `pomodoroAt + pomodoro - end` (frozen remaining at pause).
  ///   3. The block's resolved row duration via the per-priority block
  ///      walker against `priority_block` rows.
  static Stream<PriorityPendingDisplay> watchBlockDisplay({
    required PriorityId priorityId,
    required DateTime blockStart,
    required DateTime blockEnd,
  }) {
    bool inWindow(DateTime t) =>
        !t.isBefore(blockStart) && t.isBefore(blockEnd);

    return Rx.combineLatest4(
      streamPriorityBlocksGroupedByPriority(),
      Session.watchCurrent(),
      Session.watchLatestPausedFor(priorityId),
      Stream<void>.periodic(const Duration(minutes: 1), (_) {}).startWith(null),
      (blocksByPriority, currentSession, pausedExplicit, _) {
        final now = Time.now();
        final activeInBlock =
            currentSession != null &&
            currentSession.priority?.id == priorityId &&
            currentSession.at.isNow() &&
            currentSession.pomodoroAt != null &&
            currentSession.pomodoro != null &&
            inWindow(currentSession.pomodoroAt!);
        if (activeInBlock) {
          final end =
              currentSession.pomodoroAt!.add(currentSession.pomodoro!);
          final remaining = end.difference(now);
          return PriorityPendingDisplay(
            duration: remaining > Duration.zero ? remaining : null,
          );
        }
        if (pausedExplicit != null &&
            pausedExplicit.pomodoroAt != null &&
            inWindow(pausedExplicit.pomodoroAt!)) {
          final originalEnd =
              pausedExplicit.pomodoroAt!.add(pausedExplicit.pomodoro!);
          final remaining = originalEnd.difference(pausedExplicit.end);
          return PriorityPendingDisplay(
            duration: remaining > Duration.zero ? remaining : null,
          );
        }
        final rows = blocksByPriority[priorityId] ?? const [];
        final todayMidnight = DateTime(now.year, now.month, now.day);
        // Single-block walker — the block itself is the only entry.
        final out = resolveBlockDurations(
          todayMidnight: todayMidnight,
          blocks: [(id: 'b', start: blockStart)],
          blocksForPriority: rows,
        );
        return PriorityPendingDisplay(duration: out['b']);
      },
    );
  }
```

- [ ] **Step 7.2: Lint**

```bash
cd apps/plot && flutter analyze lib/state/now.dart
```
Expected: No errors.

- [ ] **Step 7.3: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "Add watchBlockDisplay block-aware live overlay"
```

---

## Task 8: `applyBlockBump` write router

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

Replace `applyPendingBump` with a block-aware router.

- [ ] **Step 8.1: Add `applyBlockBump`**

In `apps/plot/lib/state/now.dart`, immediately below `applyPendingBump`, add:

```dart
  /// Block-aware version of [applyPendingBump]. Same routing logic
  /// (session row when one is in play, otherwise `priority_block`) but
  /// the priority_block write lands at `effective_at = blockStart`
  /// rather than the epoch sentinel, and "is a session in play" means
  /// "is a session for this priority pomodoroAt-anchored inside this
  /// block's [blockStart, blockEnd) window".
  static Future<void> applyBlockBump({
    required PriorityId priorityId,
    required DateTime blockStart,
    required DateTime blockEnd,
    required Duration? currentDisplayed,
    required Duration? newDisplayed,
  }) async {
    final delta =
        (newDisplayed ?? Duration.zero) - (currentDisplayed ?? Duration.zero);
    if (delta == Duration.zero) return;

    bool inWindow(DateTime t) =>
        !t.isBefore(blockStart) && t.isBefore(blockEnd);

    final liveActive = await Session.activeFor(priorityId);
    final liveInBlock = liveActive != null &&
        liveActive.pomodoroAt != null &&
        inWindow(liveActive.pomodoroAt!);
    Session? livePaused;
    bool pausedInBlock = false;
    if (!liveInBlock) {
      livePaused = await Session.latestPausedFor(priorityId);
      pausedInBlock = livePaused != null &&
          livePaused.pomodoroAt != null &&
          inWindow(livePaused.pomodoroAt!);
    }
    final liveSource = liveInBlock
        ? liveActive
        : pausedInBlock
            ? livePaused
            : null;

    final clearing = newDisplayed == null;
    if (clearing) {
      if (liveSource != null && liveSource.pomodoroAt != null) {
        final anchorOffset = liveSource.at.isNow()
            ? Time.now().difference(liveSource.pomodoroAt!)
            : liveSource.end.difference(liveSource.pomodoroAt!);
        final collapsed = liveSource.at.isNow()
            ? liveSource.copyWith(
                end: Time.now(), pomodoro: Value(anchorOffset))
            : liveSource.copyWith(pomodoro: Value(anchorOffset));
        await Session.fromStore(collapsed).save();
      }
      await PriorityBlock.setBlockDuration(
        priorityId: priorityId,
        blockStart: blockStart,
        newDuration: null,
      );
      return;
    }

    if (liveSource != null &&
        liveSource.pomodoro != null &&
        liveSource.pomodoroAt != null) {
      final newPomodoro = liveSource.pomodoro! + delta;
      await Session.fromStore(
        liveSource.copyWith(pomodoro: Value(newPomodoro)),
      ).save();
      return;
    }

    await PriorityBlock.setBlockDuration(
      priorityId: priorityId,
      blockStart: blockStart,
      newDuration: newDisplayed,
    );
  }
```

- [ ] **Step 8.2: Lint**

```bash
cd apps/plot && flutter analyze lib/state/now.dart
```
Expected: No errors.

- [ ] **Step 8.3: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "Add applyBlockBump block-aware write router"
```

---

## Task 9: Wire `_BlockHeader` to the block-aware APIs

**Files:**
- Modify: `apps/plot/lib/widget/agenda.dart`

`_BlockHeader` currently subscribes to per-priority `watchPendingDisplay` and routes bumps through `applyPendingBump`. Switch to the block-aware versions.

- [ ] **Step 9.1: Add helpers to read `(start, end)` from a header's block**

In `apps/plot/lib/widget/agenda.dart`, inside `_BlockHeaderState`, add:

```dart
  /// `(start, end)` for the block this header introduces. Reads the
  /// uniform `start`/`end` getters added on `AgendaBlock`.
  ({DateTime start, DateTime end}) get _blockWindow {
    final b = widget.block;
    return (start: b.start, end: b.end);
  }
```

- [ ] **Step 9.2: Switch the subscription**

Find `_subscribePending` (around `apps/plot/lib/widget/agenda.dart:607`) and replace:

```dart
  void _subscribePending() {
    if (!_blockHasEditablePending(widget.block)) return;
    _pendingSub = NowBloc.watchPendingDisplay(widget.priority.id).listen((d) {
      if (!mounted) return;
      setState(() => _pendingDisplay = d);
    });
  }
```

…with:

```dart
  void _subscribePending() {
    if (!_blockHasEditablePending(widget.block)) return;
    final w = _blockWindow;
    _pendingSub = NowBloc.watchBlockDisplay(
      priorityId: widget.priority.id,
      blockStart: w.start,
      blockEnd: w.end,
    ).listen((d) {
      if (!mounted) return;
      setState(() => _pendingDisplay = d);
    });
  }
```

- [ ] **Step 9.3: Switch the bump callback**

Find `_applyPriorityBump` (around line 1071) and replace:

```dart
  void _applyPriorityBump({
    required Priority priority,
    required Duration? newDisplayed,
    required Duration? currentDisplayed,
  }) {
    NowBloc.applyPendingBump(
      priorityId: priority.id,
      currentDisplayed: currentDisplayed,
      newDisplayed: newDisplayed,
    );
  }
```

…with:

```dart
  void _applyPriorityBump({
    required Priority priority,
    required Duration? newDisplayed,
    required Duration? currentDisplayed,
  }) {
    final w = _blockWindow;
    NowBloc.applyBlockBump(
      priorityId: priority.id,
      blockStart: w.start,
      blockEnd: w.end,
      currentDisplayed: currentDisplayed,
      newDisplayed: newDisplayed,
    );
  }
```

- [ ] **Step 9.4: Re-subscribe on block-window change**

Update `didUpdateWidget` so the subscription is rebuilt when the block's window changes (e.g. a section rebuild moves a standalone's anchor). Find the existing block:

```dart
    if (oldWidget.priority.id != widget.priority.id ||
        _blockHasEditablePending(oldWidget.block) !=
            _blockHasEditablePending(widget.block)) {
      _pendingSub?.cancel();
      _pendingDisplay = null;
      _subscribePending();
    }
```

…and broaden the condition:

```dart
    final windowChanged = oldWidget.block.start != widget.block.start ||
        oldWidget.block.end != widget.block.end;
    if (oldWidget.priority.id != widget.priority.id ||
        _blockHasEditablePending(oldWidget.block) !=
            _blockHasEditablePending(widget.block) ||
        windowChanged) {
      _pendingSub?.cancel();
      _pendingDisplay = null;
      _subscribePending();
    }
```

- [ ] **Step 9.5: Lint**

```bash
cd apps/plot && flutter analyze lib/widget/agenda.dart
```
Expected: No errors.

- [ ] **Step 9.6: Commit**

```bash
git add apps/plot/lib/widget/agenda.dart
git commit -m "Wire _BlockHeader to per-block pending APIs"
```

---

## Task 10: Update the remaining callers

Several other places call the old APIs. Switch each.

**Files:**
- Modify: `apps/plot/lib/state/now.dart` (startSession's pending fallback)
- Modify: `apps/plot/lib/state/now_state.dart` (remove `pendingFor`)
- Modify: `apps/plot/lib/state/priority.dart` (remove `pendingDurationFor`)
- Modify: `apps/plot/lib/page/agenda.dart` (`_ensurePendingForGapDrop`)
- Modify: `apps/plot/lib/command/timer.dart` (`RemoveTime.enabled`)
- Modify: `apps/plot/lib/widget_bridge/widget_bridge.dart`

- [ ] **Step 10.1: `_ensurePendingForGapDrop` writes via `setBlockDuration`**

In `apps/plot/lib/page/agenda.dart`, replace the body of `_ensurePendingForGapDrop`:

```dart
  void _ensurePendingForGapDrop(
    PriorityBloc bloc,
    PriorityId priorityId,
    DateTime targetPeriodStart,
    Date? targetDate,
  ) {
    // Look up whether a row already exists for this priority at the
    // target period's anchor. The agenda model already attached the
    // resolved duration; read it off the matching block.
    final agenda = bloc.state.agenda;
    Duration? current;
    for (final section in agenda.sections) {
      if (targetDate != null &&
          section is DateSection &&
          section.date != targetDate) {
        continue;
      }
      for (final block in section.blocks) {
        if (block.priority.id != priorityId) continue;
        if (block.start != targetPeriodStart) continue;
        if (block is PriorityBlock) current = block.cascadeDuration;
        if (block is GapBlock) current = block.cascadeDuration;
      }
    }
    if (current != null && current > Duration.zero) return;

    final available = _availableInGap(agenda, targetPeriodStart, targetDate);
    if (available == null || available <= Duration.zero) {
      _log.info(
        '[agenda block-drop] skip pending default: no gap room at '
        'periodStart=$targetPeriodStart date=$targetDate',
      );
      return;
    }
    const defaultBlock = Duration(minutes: 30);
    final newPending = available < defaultBlock ? available : defaultBlock;
    _log.info(
      '[agenda block-drop] defaulting pending duration: priority=$priorityId '
      'period=$targetPeriodStart available=$available -> $newPending',
    );
    unawaited(
      store.PriorityBlock.setBlockDuration(
        priorityId: priorityId,
        blockStart: targetPeriodStart,
        newDuration: newPending,
      ),
    );
  }
```

- [ ] **Step 10.2: Make `NowLoaded.pendingFor` block-aware**

`NowLoaded.pendingFor(p)` is called by `startSession` (and by `widget_bridge.dart` and `command/timer.dart`) to ask "what's the planned duration for priority `p` right now?" Replace it with a block-aware lookup that finds the block currently containing `now` for `p`.

In `apps/plot/lib/state/now_state.dart`, replace:

```dart
  Duration? pendingFor(Priority p) {
    final rows = priorityBlocksByPriority[p.id] ?? const [];
    return effectivePriorityDurationAt(
      moment: now,
      blocksForPriority: rows,
    );
  }
```

…with:

```dart
  /// Pending duration for priority [p] resolved at "the block containing
  /// `now`": the latest in-window `priority_block` row whose
  /// `effective_at <= now`, treating the timeline as if `now` were a
  /// single block at `[now, now]`. Returns null when no in-window row
  /// applies. Rows with `effective_at < today's midnight` (the order
  /// anchors) are ignored.
  Duration? pendingFor(Priority p) {
    final rows = priorityBlocksByPriority[p.id] ?? const [];
    final todayMidnight = DateTime(now.year, now.month, now.day);
    final out = resolveBlockDurations(
      todayMidnight: todayMidnight,
      blocks: [(id: 'now', start: now)],
      blocksForPriority: rows,
    );
    return out['now'];
  }
```

This shifts the semantics: the value is now "what's the duration of the user's *current* block right now" rather than "what's the priority's global pending." For the timer's purposes the two collapse — the user pressing Start on a priority means starting *this* block's work.

- [ ] **Step 10.3: Remove `Priority.pendingDurationFor` and its caller**

The agenda page's `_ensurePendingForGapDrop` was the only caller, and Task 10.1 already replaced it with a per-block lookup. Delete the function in `apps/plot/lib/state/priority.dart` (around line 1206–1217):

```dart
  // delete the whole pendingDurationFor method body
```

- [ ] **Step 10.4: `widget_bridge.dart` keeps using `pendingFor`**

In `apps/plot/lib/widget_bridge/widget_bridge.dart:193`:

```dart
state.previewPomodoro ?? state.pendingFor(ctx) ?? kDefaultPomodoro;
```

Leave this line as-is — `pendingFor` is now block-aware (Task 10.2) and the existing call still type-checks.

- [ ] **Step 10.5: `command/timer.dart` keeps using `pendingFor`**

Same situation as 10.4. In `apps/plot/lib/command/timer.dart:200`:

```dart
final base =
    state.previewPomodoro ?? state.pendingFor(ctx) ?? kDefaultPomodoro;
```

Leave the line; behavior shifts under the hood to block-aware.

- [ ] **Step 10.6: Run analyzer across all changed files**

```bash
cd apps/plot && flutter analyze
```
Expected: No errors. If `effectivePriorityDurationAt` is still referenced anywhere, those references are dead code (Task 11 removes the definition).

- [ ] **Step 10.7: Commit**

```bash
git add apps/plot/lib/state/now_state.dart apps/plot/lib/state/priority.dart apps/plot/lib/page/agenda.dart
git commit -m "Switch remaining callers to block-aware pending lookups"
```

---

## Task 11: Remove dead code and the epoch sentinel

**Files:**
- Modify: `apps/plot/lib/store/priority_block.dart`
- Modify: `apps/plot/lib/state/now.dart`
- Modify: `apps/plot/test/store/priority_block_test.dart` (only if any test references removed symbols)

- [ ] **Step 11.1: Delete `effectivePriorityDurationAt` and `kCurrentEffectiveAt`**

In `apps/plot/lib/store/priority_block.dart`, delete:

- The `effectivePriorityDurationAt` function (around lines 108–124).
- The `kCurrentEffectiveAt` constant (around line 98).
- The `setPendingDuration` static method (around lines 190–281).
- The doc comment on `duration` that references `effectivePriorityDurationAt` — update it to say "Resolved via `resolveBlockDurations`."

Search for stragglers:

```bash
grep -rn 'effectivePriorityDurationAt\|kCurrentEffectiveAt\|setPendingDuration\b' apps/plot --include='*.dart'
```

Each remaining reference must be deleted or rewritten. The generated `store.g.dart` may still mention `effectivePriorityDurationAt` in a comment; if so, update the source comment in `priority_block.dart` and regenerate (Task 14).

- [ ] **Step 11.2: Delete `watchPendingDisplay` and `applyPendingBump`**

In `apps/plot/lib/state/now.dart`, delete the old methods. Search:

```bash
grep -rn 'watchPendingDisplay\|applyPendingBump' apps/plot --include='*.dart'
```

Expected: zero matches after the deletion (Tasks 7, 8, 9 already added replacements; Task 10 wires all callers).

- [ ] **Step 11.3: Re-run analyzer**

```bash
cd apps/plot && flutter analyze
```
Expected: No errors.

- [ ] **Step 11.4: Run the full test suite**

```bash
cd apps/plot && flutter test -r expanded
```

Expected: PASS. Existing tests in `test/store/priority_block_test.dart` for `effectivePriorityOrderAt` still pass (that resolver is unchanged). Any test that calls `setPendingDuration` or `effectivePriorityDurationAt` needs to be deleted; rewrite as `resolveBlockDurations` if the behavior was important.

- [ ] **Step 11.5: Commit**

```bash
git add apps/plot/lib/store/priority_block.dart apps/plot/lib/state/now.dart apps/plot/test/store/priority_block_test.dart
git commit -m "Remove epoch sentinel and per-priority pending APIs"
```

---

## Task 12: Date-rollover watcher in NowBloc

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

The watch query's `:today_midnight` is bound at construction. After local-midnight passes, the window doesn't re-narrow. Add a watcher that re-issues the `priority_block` subscription when the local date changes.

- [ ] **Step 12.1: Add a stored last-seen local-date field on `NowBloc`**

In `apps/plot/lib/state/now.dart`, in the `NowBloc` class fields:

```dart
  /// Local date at which the current `_subscription` was started. When
  /// the local date changes (across midnight) the priority_block watch
  /// is re-issued so its bounded UNION query re-narrows.
  DateTime? _subscriptionLocalDate;
```

- [ ] **Step 12.2: Set `_subscriptionLocalDate` when starting**

In `NowBloc.start`, right after `_subscription = Rx.combineLatest6(`, before the assignment, capture the local date:

```dart
    final now = Time.now();
    _subscriptionLocalDate = DateTime(now.year, now.month, now.day);
```

- [ ] **Step 12.3: Check for date rollover in `_onTrackTick`**

`_onTrackTick` already fires every minute. Add a date check at the top:

```dart
  Future<void> _onTrackTick() async {
    final now = Time.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_subscriptionLocalDate != null &&
        today != _subscriptionLocalDate) {
      // Local date rolled over — re-subscribe so the priority_block
      // query re-binds today_midnight to the new day.
      _resubscribePriorityBlocks();
    }

    if (state is! NowLoaded) return;
    // ...existing body...
  }
```

- [ ] **Step 12.4: Implement `_resubscribePriorityBlocks`**

```dart
  /// Tear down and rebuild the combined subscription so the
  /// `streamPriorityBlocksGroupedByPriority` query re-binds its
  /// `today_midnight` parameter. Called on local-date rollover.
  void _resubscribePriorityBlocks() {
    _subscription?.cancel();
    _subscription = null;
    start();
  }
```

`start()` already sets `_subscriptionLocalDate` per Step 12.2, so the next rollover will fire correctly.

- [ ] **Step 12.5: Lint**

```bash
cd apps/plot && flutter analyze lib/state/now.dart
```
Expected: No errors.

- [ ] **Step 12.6: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "Re-issue priority_block watch on local-date rollover"
```

---

## Task 13: Documentation updates

**Files:**
- Modify: `docs/agenda.md`
- Modify: `docs/updates.md`

- [ ] **Step 13.1: Rewrite the "Pending Duration Cascade" section in `docs/agenda.md`**

In `docs/agenda.md`, find the section heading `## Pending Duration Cascade` and the four paragraphs that follow it. Replace the entire section with:

```markdown
## Pending Duration Per Block

Each agenda block can have its own **pending duration** — planned time the
user wants to commit to that block. Pending duration is per-block, not
per-priority: editing time on one day's block affects only that block.

- The +/− gutter on a priority block (or a priority-led gap block) writes
  a `priority_block` row at `effective_at = block.start` with the new
  duration. The next agenda rebuild reads it back and attaches it to the
  block via `cascadeDuration`.
- Blocks without a row in their window display no pending. Nothing
  cascades into a block from earlier days or earlier blocks; nothing
  carries over to later blocks.
- When the user runs the timer, the block containing `now` shows
  remaining time live; the static row duration is the source once the
  session ends.

The render is a pure post-process — the agenda builder folds each row's
duration onto the matching block via the per-block resolver and never
writes back. Priorities with no row in their window are unaffected by
the fold and continue to appear only where they have threads.
```

- [ ] **Step 13.2: Update "Drop Behavior" in `docs/agenda.md`**

Find the bullet starting "Cross-period drop into a gap with no pending duration set" and replace it with:

```markdown
- **Cross-period drop into a gap with no pending duration set** — when
  the target gap has no `priority_block` row at its anchor for the
  source priority, the drop also writes a default
  `priority_block` row at the gap's anchor with `duration =
  min(30m, available-gap-room)`. This applies regardless of whether the
  dragged block has threads; the next agenda rebuild reads the row and
  attaches it as the destination block's pending duration.
```

- [ ] **Step 13.3: Update "Inline Duration Bump" in `docs/agenda.md`**

Find the three bullets under "Inline Duration Bump" describing event blocks, priority blocks (cascade slice), and priority blocks (no slice). Replace the three with two:

```markdown
- **Event blocks** — the event thread's duration (via `SetThreadDuration`).
- **Priority and priority-led gap blocks** — the block's own pending
  duration. There is no priority-wide total to re-anchor; each block
  stands alone.
- **Empty gap blocks** — no editable duration; the bump UI is suppressed.
```

- [ ] **Step 13.4: Add a one-line user-facing note to `docs/updates.md`**

Open `docs/updates.md`. In the top (most recent) section, add a new bullet:

```markdown
- Time you add to a block in the agenda now applies only to that block instead of every day.
```

Keep the existing top section header intact; insert the bullet at the top of that section's list.

- [ ] **Step 13.5: Commit**

```bash
git add docs/agenda.md docs/updates.md
git commit -m "Document per-block pending duration"
```

---

## Task 14: Regenerate Drift codegen and run finalize checks

**Files:**
- Modify: `apps/plot/lib/store/store.g.dart` (regenerated)

If any doc comment on `priority_block` columns referenced removed symbols (e.g. `effectivePriorityDurationAt`), the generated `store.g.dart` needs to refresh.

- [ ] **Step 14.1: Regenerate the Drift code**

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

Expected: build_runner runs to completion; `store.g.dart` may be modified.

- [ ] **Step 14.2: Re-run the full suite**

```bash
cd apps/plot && flutter analyze
cd apps/plot && flutter test -r expanded
```

Expected: No analyzer errors. All tests pass.

- [ ] **Step 14.3: Commit (only if files changed)**

```bash
git status --short apps/plot/lib/store/store.g.dart
# If the file shows as modified:
git add apps/plot/lib/store/store.g.dart
git commit -m "Regenerate Drift codegen after priority_block doc updates"
```

---

## Task 15: Manual smoke test

Hot-reload the running Flutter app and verify the end-to-end behaviour.

- [ ] **Step 15.1: Hot-reload**

The Flutter app is already running with hot reload (per `apps/plot/AGENTS.md`). Save any file or hit `r` in the Flutter run console.

- [ ] **Step 15.2: Verify the bug is gone**

1. Open the agenda.
2. Pick a priority with threads scheduled on at least three different days (today + two future days).
3. Click `+15m` on today's block. Verify only today's gutter shows `15m`. The future-day blocks should remain empty.
4. Click `+30m` on tomorrow's block. Verify only tomorrow's gutter changes (today stays at `15m`, the day after stays empty).
5. Click `−` enough times on tomorrow's block to clear it. Verify only tomorrow's gutter resets.

- [ ] **Step 15.3: Verify the timer routes correctly**

1. On a priority's block today, click `+30m` so the block shows 30m.
2. Start the timer (`StartTimer`). Verify the block's gutter switches to a countdown and the value matches the row's 30m.
3. Pause / resume / stop. Verify the static value reasserts after the session ends.

- [ ] **Step 15.4: Verify reordering still affects subsequent days**

1. On Monday's view, drag-reorder a priority above another priority for Tuesday's gap.
2. Verify Tuesday's block ordering reflects the new sort, and Monday's does not.
3. Scroll forward; Wednesday/Thursday should also use the new ordering (carry-forward via the anchor).

- [ ] **Step 15.5: If anything is wrong, debug; do not commit broken state**

---

## Self-Review

Spec coverage check (sections vs. tasks):

- **Goal / Today's bug** — Task 5 fixes the cascade; Task 11 deletes the per-priority APIs. ✓
- **What changes (user-visible)** — Task 15.2 verifies each bullet. ✓
- **Data model & block windows** — Task 1 adds the fields; Task 2 computes them. ✓
- **Query: bounded window with per-priority anchor** — Task 6. ✓
- **Window freshness at date rollover** — Task 12. ✓
- **Resolver changes** — Task 3 (`resolveBlockDurations`); `effectivePriorityOrderAt` unchanged (no task). ✓
- **Agenda integration** — Task 5. ✓
- **Sessions and the live overlay** — Task 7. ✓
- **Writes** — Tasks 4, 8, 10. ✓
- **What this does not change** — covered implicitly; no task needed. ✓
- **Testing** — pure-function tests in Tasks 3, 5; smoke in 15. ✓
- **Documentation updates** — Task 13. ✓
- **Rollout** — Tasks 11, 14. ✓

Placeholder scan: no "TBD", "TODO", "implement later", "add appropriate validation". Every code block is concrete.

Type/name consistency check:

- `setBlockDuration({priorityId, blockStart, newDuration})` — Tasks 4, 8, 10 use this exact signature. ✓
- `resolveBlockDurations({todayMidnight, blocks, blocksForPriority})` — Tasks 3, 5, 7, 10 use this exact signature. ✓
- `watchBlockDisplay({priorityId, blockStart, blockEnd})` — Tasks 7, 9 use this exact signature. ✓
- `applyBlockBump({priorityId, blockStart, blockEnd, currentDisplayed, newDisplayed})` — Tasks 8, 9 use this exact signature. ✓
- `PriorityBlock(windowStart, windowEnd, ...)` — Tasks 1, 5 use these field names. ✓
- `AgendaBlock.start` / `AgendaBlock.end` — Tasks 1, 9, 5, 10 use these getters. ✓
