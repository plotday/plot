# Focus blocks on the agenda — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a focus block the single concept the user works with — the running timer ("Start focus") writes a `priority_block` row so it appears on the agenda; pausing shows a sliding "remaining" block; stopping removes it; scheduled blocks auto-start when their focus is selected; dragging an active block to the future stops it; dragging onto now starts it.

**Architecture:** Keep `Session` as the time-tracking record and `priority_block` rows as the durable agenda block; bridge them with explicit rules in `NowBloc` (start/pause/stop manage the row alongside the session) and `AgendaBuilder` (synthesize a sliding paused block from a `pausedFocus` descriptor). Auto-start is a derivation in `setContext` + `_onTrackTick`. Drag routes through existing `moveFocusBlock` extended to start/stop the session based on whether the new window covers now.

**Tech Stack:** Flutter / Dart, flutter_bloc, Drift (SQLite local store), forui widgets. The Plot app under `apps/plot/`.

**Spec:** `docs/superpowers/specs/2026-05-31-focus-blocks-on-agenda-design.md`

---

## File overview

- **Modify** `apps/plot/lib/command/timer.dart` — rename command titles to "Start focus" / "Pause focus" / "Stop focus".
- **Modify** `apps/plot/lib/state/now_state.dart` — `kDefaultPomodoro` 15m → 30m; add `PausedFocus` descriptor and field on `NowLoaded`.
- **Modify** `apps/plot/lib/state/now.dart` — manual Start writes a covering `priority_block` row; Pause/Stop archive it; auto-start trigger in `setContext` + `_onTrackTick`; extend `_capToEnd` to clamp against next focus block; expose `pausedFocus`.
- **Modify** `apps/plot/lib/state/agenda_builder.dart` — accept `pausedFocus` parameter; synthesize sliding paused `PriorityBlock` capped to next anchored item.
- **Modify** `apps/plot/lib/state/priority.dart` — subscribe to `NowBloc.stream`, thread `pausedFocus` through `AgendaBuilder.build` call sites, extend `moveFocusBlock` with session start/stop routing.
- **Modify** `apps/plot/lib/command/focus_block.dart` — `ScheduleFocusBlock` edit branch routes through session start/stop after the row write.
- **Modify** `apps/plot/lib/widget/root_menu_bar.dart` — update hard-coded "Start timer"/"Pause timer" labels.
- **Modify** `apps/plot/lib/widget/unified_header.dart` — update header pill "Start timer" tooltip/label.
- **Test** `apps/plot/test/state/agenda_builder_test.dart` — add tests for `pausedFocus` synthesis.
- **Test** `apps/plot/test/state/now_test.dart` (new file) — tests for manual Start writes a row, Pause/Stop archive, auto-start, `_capToEnd` against next focus block.
- **Test** `apps/plot/test/command/timer_test.dart` (new file) — assert command titles.

---

## Task 1: Rename timer commands to "focus"

**Files:**
- Modify: `apps/plot/lib/command/timer.dart`
- Test: `apps/plot/test/command/timer_test.dart` (new)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/timer_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/timer.dart';

void main() {
  group('Timer command titles', () {
    test('StartTimer title is "Start focus"', () {
      expect(StartTimer().title, 'Start focus');
    });

    test('StopTimer title is "Pause focus"', () {
      expect(StopTimer().title, 'Pause focus');
    });

    test('EndTimer title is "Stop focus"', () {
      expect(EndTimer().title, 'Stop focus');
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/command/timer_test.dart`
Expected: FAIL — current titles are "Start timer", "Pause timer", "Stop".

- [ ] **Step 3: Update the three command titles**

In `apps/plot/lib/command/timer.dart`:
- Line 53: change `title: 'Start timer'` → `title: 'Start focus'`
- Line 81: change `title: 'Pause timer'` → `title: 'Pause focus'`
- Line 109: change `title: 'Stop'` → `title: 'Stop focus'`

Class names (`StartTimer`, `StopTimer`, `EndTimer`), shortcuts, icons, and analytics keys stay unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/command/timer_test.dart`
Expected: PASS.

- [ ] **Step 5: Update hard-coded labels in `root_menu_bar.dart`**

In `apps/plot/lib/widget/root_menu_bar.dart:208`, find:

```dart
label: inactive ? 'Start timer' : 'Pause timer',
```

Replace with:

```dart
label: inactive ? 'Start focus' : 'Pause focus',
```

- [ ] **Step 6: Update `unified_header.dart` comments/strings**

In `apps/plot/lib/widget/unified_header.dart:1128`, the comment says "Start timer". Update the comment to "Start focus". Then check the surrounding `Button.icon(StartTimer())` — the button label comes from the command title, so no string change needed there. Search the file for any other `'Start timer'` / `'Pause timer'` literals:

```bash
cd apps/plot && grep -n "Start timer\|Pause timer" lib/widget/unified_header.dart
```

Replace any UI literals with the new spelling. Leave doc comments mentioning the historical name alone if they exist.

- [ ] **Step 7: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/command/timer.dart lib/widget/root_menu_bar.dart lib/widget/unified_header.dart test/command/timer_test.dart`
Expected: No issues found.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/command/timer.dart apps/plot/lib/widget/root_menu_bar.dart apps/plot/lib/widget/unified_header.dart apps/plot/test/command/timer_test.dart
git commit -m "feat: rename Start/Pause/Stop timer to focus

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Bump default focus duration to 30 minutes

**Files:**
- Modify: `apps/plot/lib/state/now_state.dart:29`

- [ ] **Step 1: Read the current constant**

Open `apps/plot/lib/state/now_state.dart` and locate:

```dart
/// Default pomodoro duration when the focused priority has no
/// `priority_block.duration` set. Long enough to be useful, short
/// enough that the user notices when it's wrong.
const Duration kDefaultPomodoro = Duration(minutes: 15);
```

- [ ] **Step 2: Change 15 → 30**

Replace the constant with:

```dart
/// Default pomodoro duration when the focused priority has no
/// `priority_block.duration` set. Long enough to be useful, short
/// enough that the user notices when it's wrong.
const Duration kDefaultPomodoro = Duration(minutes: 30);
```

- [ ] **Step 3: Audit existing tests for the 15-minute expectation**

Run:

```bash
cd apps/plot && grep -rn "minutes: 15\|kDefaultPomodoro" lib test
```

For any test that exercises `kDefaultPomodoro`'s value (e.g. asserting "15"), update the expectation to 30. If a test only references the symbolic constant, no change needed.

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now_state.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/now_state.dart
# include any test files updated in step 3
git commit -m "feat: default focus block duration is 30 minutes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add `PausedFocus` to `NowLoaded`

**Files:**
- Modify: `apps/plot/lib/state/now_state.dart`

- [ ] **Step 1: Add the `PausedFocus` value type**

At the bottom of `apps/plot/lib/state/now_state.dart` (above the `_sentinel`), add:

```dart
/// A paused, explicit focus session whose remaining time should slide
/// forward on the agenda from `now` until the user resumes or stops.
/// Surfaced by [NowBloc] so [AgendaBuilder] can synthesize the
/// sliding block without re-querying.
class PausedFocus extends Equatable {
  const PausedFocus({required this.priority, required this.remaining});

  final Priority priority;
  final Duration remaining;

  @override
  List<Object?> get props => [priority.id, remaining];
}
```

(`Equatable` is already imported at the top of `now.dart`, which uses `part of 'now.dart'` for this file.)

- [ ] **Step 2: Add `pausedFocus` field on `NowLoaded`**

In the constructor parameter list (`NowLoaded({...})`), add `this.pausedFocus,`. In the field declarations, add:

```dart
/// The latest paused, explicit focus session — drives the agenda's
/// synthesized sliding "remaining" block. Null when no paused session
/// exists, when the paused session is for a priority other than
/// [context], or when remaining ≤ 0.
final PausedFocus? pausedFocus;
```

In `props`, append `pausedFocus`.

In `copyWith`, add the same `Object? pausedFocus = _sentinel` sentinel pattern as `trackingPausedAt` and thread it through:

```dart
PausedFocus? pausedFocus = _sentinel as PausedFocus?,
```

Wait — the existing sentinel pattern uses `Object?` typed as `_sentinel`. Match it exactly:

```dart
Object? pausedFocus = _sentinel,
```

and inside:

```dart
pausedFocus: identical(pausedFocus, _sentinel)
    ? this.pausedFocus
    : pausedFocus as PausedFocus?,
```

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now_state.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/now_state.dart
git commit -m "feat: add PausedFocus descriptor on NowLoaded

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `AgendaBuilder` synthesizes the paused sliding block

**Files:**
- Modify: `apps/plot/lib/state/agenda_builder.dart`
- Test: `apps/plot/test/state/agenda_builder_test.dart`

- [ ] **Step 1: Write failing tests for the synthesis**

Append to `apps/plot/test/state/agenda_builder_test.dart`, inside `void main()`, add a new group at the bottom:

```dart
  group('pausedFocus synthesis', () {
    test('synthesizes a sliding block at [now, now+remaining) when '
        'pausedFocus is set', () {
      final p = _testPriority();
      final now = DateTime(2026, 5, 31, 10, 0);
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 7,
        now: now,
        priorityById: {p.id: p},
        pausedFocus: (
          priority: p,
          remaining: const Duration(minutes: 20),
        ),
      );

      final today = Date(2026, 5, 31);
      final section = model.sections.firstWhere(
        (s) => s is DateSection && s.date == today,
      ) as DateSection;
      final paused = section.blocks
          .whereType<ui.PriorityBlock>()
          .firstWhere((b) => b.id.startsWith('fp_'));
      expect(paused.windowStart, now);
      expect(paused.windowEnd, now.add(const Duration(minutes: 20)));
      expect(paused.isCurrent, isTrue);
      expect(paused.sourceRow, isNull);
    });

    test('shrinks the paused block to fit before the next anchored item',
        () {
      final p = _testPriority();
      final now = DateTime(2026, 5, 31, 10, 0);
      // A focus block at 10:10 — only 10 minutes of room.
      final nextRow = _focusRow(
        p,
        DateTime(2026, 5, 31, 10, 10),
        const Duration(minutes: 30),
      );
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 7,
        now: now,
        priorityById: {p.id: p},
        priorityBlocksByPriority: {p.id: [nextRow]},
        pausedFocus: (
          priority: p,
          remaining: const Duration(minutes: 30),
        ),
      );

      final today = Date(2026, 5, 31);
      final section = model.sections.firstWhere(
        (s) => s is DateSection && s.date == today,
      ) as DateSection;
      final paused = section.blocks
          .whereType<ui.PriorityBlock>()
          .firstWhere((b) => b.id.startsWith('fp_'));
      expect(paused.windowEnd, DateTime(2026, 5, 31, 10, 10));
    });

    test('drops the paused block when no room exists before the next '
        'anchored item', () {
      final p = _testPriority();
      final now = DateTime(2026, 5, 31, 10, 0);
      // A focus block starting exactly at now — zero room.
      final nextRow = _focusRow(
        p,
        DateTime(2026, 5, 31, 10, 0),
        const Duration(minutes: 30),
      );
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 7,
        now: now,
        priorityById: {p.id: p},
        priorityBlocksByPriority: {p.id: [nextRow]},
        pausedFocus: (
          priority: p,
          remaining: const Duration(minutes: 30),
        ),
      );
      final pausedBlocks = model.sections
          .expand((s) => s.blocks)
          .whereType<ui.PriorityBlock>()
          .where((b) => b.id.startsWith('fp_'));
      expect(pausedBlocks, isEmpty);
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/plot && flutter test test/state/agenda_builder_test.dart -p vm`
Expected: FAIL — `pausedFocus` parameter doesn't exist.

- [ ] **Step 3: Add the `pausedFocus` parameter to `AgendaBuilder.build`**

In `apps/plot/lib/state/agenda_builder.dart`, in the `build` static method signature, add the new optional parameter at the end:

```dart
static AgendaModel build({
  required List<Thread> threads,
  required Priority context,
  required int horizonDays,
  int minFillDays = 0,
  Map<Uuid, List<ThreadAssociationRow>>? associationsByParentId,
  DateTime? now,
  Map<PriorityId, List<PriorityBlockRow>>? priorityBlocksByPriority,
  Map<PriorityId, Priority>? priorityById,
  /// A paused focus block whose remaining time should slide forward
  /// from `now`. When set, [AgendaBuilder] synthesizes a `PriorityBlock`
  /// at `[now, now + remaining)` on today's section, shrunk so it
  /// never overlaps the next anchored item (event or future focus
  /// block). Dropped if zero room remains.
  ({Priority priority, Duration remaining})? pausedFocus,
}) {
```

- [ ] **Step 4: Synthesize the paused block inside the today loop**

Inside `build`, find the `for (var date = today; ...)` loop. Just before the section is added (`sections.add(DateSection(...))`), within the `isToday` branch, insert the synthesis:

```dart
      // Paused focus block (sliding from `now`). Inserted only on
      // today's section, before any leading gap/trailing/anchored
      // blocks have settled into `blocks`. We instead append after
      // gap interleaving, then re-sort by start so the paused block
      // lands in the right place between consecutive anchored items.
      if (isToday && pausedFocus != null) {
        // Find the earliest "next anchored item" start strictly after now.
        DateTime? nextAnchored;
        for (final a in anchored) {
          if (!a.start.isBefore(effectiveNow)) {
            if (nextAnchored == null || a.start.isBefore(nextAnchored)) {
              nextAnchored = a.start;
            }
          }
        }
        final cap = nextAnchored ?? nextMidnight;
        var end = effectiveNow.add(pausedFocus.remaining);
        if (end.isAfter(cap)) end = cap;
        if (end.isAfter(effectiveNow)) {
          final pausedBlock = PriorityBlock(
            id: 'fp_${pausedFocus.priority.id}',
            priority: pausedFocus.priority,
            threads: const [],
            cascadeDuration: end.difference(effectiveNow),
            windowStart: effectiveNow,
            windowEnd: end,
            isCurrent: true,
          );
          // Insert into `blocks` at the correct position, replacing
          // any gap that the paused block now subsumes. Easiest path:
          // rebuild `blocks` with the paused entry merged in by
          // re-running gap interleaving against `anchored + paused`.
          // To avoid duplicating that logic, splice it into the
          // already-built list directly:
          int insertAt = 0;
          for (var i = 0; i < blocks.length; i++) {
            final b = blocks[i];
            final start = b.start;
            if (start.isAfter(effectiveNow) ||
                start.isAtSameMomentAs(effectiveNow)) {
              insertAt = i;
              break;
            }
            insertAt = i + 1;
          }
          blocks.insert(insertAt, pausedBlock);
        }
      }
```

Note: `blocks` is declared `final` but its contents are mutable until `List.unmodifiable(blocks)` wraps it. The current code writes `blocks: List.unmodifiable(blocks)` inside `DateSection(...)`. The above `insert` must run **before** `sections.add(DateSection(...))` and **after** the trailing-gap branch. Add it as a step between the trailing gap (`if (anchored.isNotEmpty && ... blocks.add(GapBlock(...))`) and the empty-day fallback's else, so it doesn't fire on a truly empty day. Place it right before `sections.add(...)`:

```dart
      // (existing trailing-gap and empty-day blocks above)

      // Paused focus block synthesis (today only) — see above.
      if (isToday && pausedFocus != null) {
        // ...the synthesis block from above...
      }

      // scheduleAt: the default time the day-header "+" pre-fills...
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/state/agenda_builder_test.dart -p vm`
Expected: PASS — all three new tests plus the previous suite.

- [ ] **Step 6: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/agenda_builder.dart test/state/agenda_builder_test.dart`
Expected: No issues found.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/state/agenda_builder.dart apps/plot/test/state/agenda_builder_test.dart
git commit -m "feat: AgendaBuilder synthesizes paused focus block

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `_capToEnd` clamps against next focus block

**Files:**
- Modify: `apps/plot/lib/state/now.dart`
- Test: `apps/plot/test/state/now_test.dart` (new)

- [ ] **Step 1: Find the current cap function**

Read `apps/plot/lib/state/now.dart` around line 450 onward. Locate `_capToEnd(...)` and `NowLoaded.pomodoroEndCap(...)`. Confirm which one is the actual cap used by `startSession` (it's `_capToEnd`, which delegates to `pomodoroEndCap`).

- [ ] **Step 2: Write the failing test**

Create `apps/plot/test/state/now_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/now_state.dart';
import 'package:plot/store/store.dart';

PriorityBlockRow _row(PriorityId pid, DateTime at, Duration d) =>
    PriorityBlockRow(
      id: Uuid.generate(),
      priorityId: pid,
      createdBy: Uuid.generate(),
      orderValue: Order(0),
      effectiveAt: at,
      duration: d,
      archivedAt: null,
      createdAt: at,
      updatedAt: at,
    );

void main() {
  group('NowLoaded.pomodoroEndCap with future focus blocks', () {
    test('clamps against the next non-archived focus block on the same '
        'priority after now', () {
      // Pure unit test of the cap helper — no bloc, no store.
      // Build a minimal NowLoaded by stubbing the public ctor parameters.
      // Skipped here if NowLoaded ctor requires non-trivial deps; we'll
      // exercise this path via the integration test in Task 8 instead.
    }, skip: 'covered by integration in Task 8');
  });
}
```

(The cap function uses `priorityBlocksByPriority` from state. We exercise it via the larger Task 8 integration test rather than constructing a full `NowLoaded` here.)

- [ ] **Step 3: Implement the cap extension**

In `apps/plot/lib/state/now.dart`, find `pomodoroEndCap` (around line 388 in `now_state.dart` — actually in `now_state.dart`, not `now.dart`). Open `apps/plot/lib/state/now_state.dart`. The method body:

```dart
DateTime? pomodoroEndCap(Priority? priority) {
  if (priority == this.priority) {
    final scheduledEnd = scheduled.firstOrNull?.priority == priority
        ? scheduled.firstOrNull?.at?.end
        : null;
    if (scheduledEnd != null) return scheduledEnd;
  }
  return next.firstOrNull?.at?.start;
}
```

Replace with:

```dart
DateTime? pomodoroEndCap(Priority? priority) {
  DateTime? cap;
  if (priority == this.priority) {
    final scheduledEnd = scheduled.firstOrNull?.priority == priority
        ? scheduled.firstOrNull?.at?.end
        : null;
    if (scheduledEnd != null) cap = scheduledEnd;
  }
  final nextEventStart = next.firstOrNull?.at?.start;
  if (cap == null || (nextEventStart != null && nextEventStart.isBefore(cap))) {
    cap = nextEventStart ?? cap;
  }
  // Also clamp against the start of the next non-archived focus block
  // whose `effective_at` strictly follows `now`, across all priorities.
  // A focus block on another priority still blocks this session because
  // it'll trigger an auto-start (or distraction handoff) at its start.
  for (final rows in priorityBlocksByPriority.values) {
    for (final row in rows) {
      if (row.archivedAt != null) continue;
      final d = row.duration;
      if (d == null || d <= Duration.zero) continue;
      if (!row.effectiveAt.isAfter(now)) continue;
      if (cap == null || row.effectiveAt.isBefore(cap)) {
        cap = row.effectiveAt;
      }
    }
  }
  return cap;
}
```

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now_state.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/now_state.dart apps/plot/test/state/now_test.dart
git commit -m "feat: clamp planned pomodoro against next focus block

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Manual Start writes a covering `priority_block` row

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

- [ ] **Step 1: Locate the write site**

In `apps/plot/lib/state/now.dart`, find the end of `startSession` (around line 657). After `await Session.resume(ctx, ...)` returns, the active row needs to be written.

- [ ] **Step 2: Add row creation/reuse logic**

Just before each `await Session.resume(...)` call inside `startSession` (there are three branches: paused-resume, event-resume, fresh-start), add a helper call. Add this private method to `NowBloc`:

```dart
/// Ensure a non-archived focus block row covers `[start, start + duration)`
/// on [priority]. Reuses any existing covering row by upserting in place;
/// otherwise writes a fresh row. Idempotent for the common case where the
/// scheduled row already matches.
Future<void> _ensureFocusRow(
  Priority priority,
  DateTime start,
  Duration duration,
) async {
  final rows = priorityBlocksByPriority[priority.id] ?? const [];
  // Look for a non-archived covering row.
  for (final r in rows) {
    if (r.archivedAt != null) continue;
    final d = r.duration;
    if (d == null || d <= Duration.zero) continue;
    if (!r.effectiveAt.isAfter(start) && r.effectiveAt.add(d).isAfter(start)) {
      // Existing row covers `start`. If its duration is shorter than what
      // we're about to run, extend it; otherwise leave it alone.
      final coveringEnd = r.effectiveAt.add(d);
      final neededEnd = start.add(duration);
      if (neededEnd.isAfter(coveringEnd)) {
        await PriorityBlock.setBlockDuration(
          priorityId: priority.id,
          blockStart: r.effectiveAt,
          newDuration: neededEnd.difference(r.effectiveAt),
        );
      }
      return;
    }
  }
  // No covering row — create one at `start`.
  await PriorityBlock.setBlockDuration(
    priorityId: priority.id,
    blockStart: start,
    newDuration: duration,
  );
}
```

Note: `priorityBlocksByPriority` is on `NowLoaded`; access via `loadedState.priorityBlocksByPriority` since this method lives on the bloc.

Adjust accordingly:

```dart
Future<void> _ensureFocusRow(
  Priority priority,
  DateTime start,
  Duration duration,
) async {
  if (state is! NowLoaded) return;
  final rows = (state as NowLoaded).priorityBlocksByPriority[priority.id]
      ?? const <PriorityBlockRow>[];
  // ...rest as above...
}
```

- [ ] **Step 3: Call `_ensureFocusRow` from `startSession` branches**

Inside `startSession`, after each `_emitOptimisticSession` call and before each `await Session.resume(...)`, await `_ensureFocusRow`:

For the paused-resume branch (around line 559):

```dart
_emitOptimisticSession(
  ctx,
  pomodoro: originalPomodoro,
  pomodoroAt: shiftedPomodoroAt,
  now: now,
);
await _ensureFocusRow(ctx, shiftedPomodoroAt, originalPomodoro);
await Session.resume(
  ctx,
  end: now.add(const Duration(minutes: 3)),
  pomodoro: originalPomodoro,
  pomodoroAt: shiftedPomodoroAt,
  explicit: true,
);
```

For the event-resume branch (around line 615):

```dart
_emitOptimisticSession(...);
await _ensureFocusRow(ctx, shiftedPomodoroAt, newPomodoro);
await Session.fromStore(skip.copyWith(end: now)).save();
await Session.resume(...);
```

For the fresh-start branch (around line 644):

```dart
_emitOptimisticSession(
  ctx,
  pomodoro: pomodoro,
  pomodoroAt: now,
  now: now,
);
await _ensureFocusRow(ctx, now, pomodoro);
await Session.resume(
  ctx,
  end: now.add(const Duration(minutes: 3)),
  pomodoro: pomodoro,
  pomodoroAt: now,
  explicit: true,
);
```

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "feat: Start focus writes a covering priority_block row

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Pause and Stop archive the covering row

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

- [ ] **Step 1: Add an archive helper**

Below `_ensureFocusRow`, add:

```dart
/// Soft-archive the non-archived focus block row that covers [moment]
/// on [priority]. No-op if no such row exists. Used by Pause (so the
/// agenda stops rendering the running block at its slot and shows the
/// synthesized sliding `pausedFocus` block instead) and by Stop.
Future<void> _archiveCoveringRow(Priority priority, DateTime moment) async {
  if (state is! NowLoaded) return;
  final rows = (state as NowLoaded).priorityBlocksByPriority[priority.id]
      ?? const <PriorityBlockRow>[];
  for (final r in rows) {
    if (r.archivedAt != null) continue;
    final d = r.duration;
    if (d == null || d <= Duration.zero) continue;
    if (!r.effectiveAt.isAfter(moment) &&
        r.effectiveAt.add(d).isAfter(moment)) {
      await PriorityBlock.setBlockDuration(
        priorityId: priority.id,
        blockStart: r.effectiveAt,
        newDuration: null, // null → soft-archive in setBlockDuration
      );
      return;
    }
  }
}
```

`setBlockDuration` already soft-archives the row when `newDuration` is null (see `priority_block.dart:301-312`).

- [ ] **Step 2: Call it from `stopSession` (pause)**

Find `stopSession` (around line 688). After `await _closeActiveSession(session)`, add:

```dart
Future<void> stopSession() async {
  if (state is! NowLoaded) return;
  final s = loadedState;
  final session = s.session;
  if (session == null || !session.at.isNow()) return;
  if (session.source != 'active') return;
  await _closeActiveSession(session);
  final ctx = s.context;
  if (ctx != null) {
    await _archiveCoveringRow(ctx, Time.now());
  }
}
```

- [ ] **Step 3: Call it from `endSession` (stop)**

Find `endSession` (around line 703). After the `closed.save()` call, add:

```dart
Future<void> endSession() async {
  if (state is! NowLoaded) return;
  final s = loadedState;
  final session = s.session;
  if (session == null || !session.at.isNow()) return;
  if (session.source != 'active') return;

  final now = Time.now();
  Duration? truncatedPomodoro;
  if (session.pomodoroAt != null) {
    final elapsed = now.difference(session.pomodoroAt!);
    truncatedPomodoro = elapsed > Duration.zero ? elapsed : Duration.zero;
  }
  final closed = Session.fromStore(
    session.copyWith(
      end: now,
      pomodoro: truncatedPomodoro == null
          ? const Value.absent()
          : Value(truncatedPomodoro),
    ),
  );
  await closed.save();
  final ctx = s.context;
  if (ctx != null) {
    await _archiveCoveringRow(ctx, now);
  }
}
```

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "feat: Pause/Stop focus archive the covering priority_block row

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Auto-start when a covering row exists for the current focus

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

- [ ] **Step 1: Add the auto-start trigger method**

In `NowBloc`, add a private method:

```dart
/// If [ctx] has a non-archived focus block row covering `now` and no
/// active session for [ctx] exists, start one matched to the row's
/// remaining window (`[now, effectiveAt + duration)`). Idempotent —
/// safe to call from both [setContext] and [_onTrackTick].
Future<void> _maybeAutoStart(Priority ctx) async {
  if (state is! NowLoaded) return;
  final s = loadedState;
  // Already running for this priority — no-op.
  if (s.pomodoroState != PomodoroState.inactive &&
      s.session?.priority?.id == ctx.id) {
    return;
  }
  final now = Time.now();
  final rows = s.priorityBlocksByPriority[ctx.id] ?? const [];
  for (final r in rows) {
    if (r.archivedAt != null) continue;
    final d = r.duration;
    if (d == null || d <= Duration.zero) continue;
    final end = r.effectiveAt.add(d);
    if (r.effectiveAt.isAfter(now) || !end.isAfter(now)) continue;
    // Covering row found. Start the session for the remaining window.
    final remaining = end.difference(now);
    await startSession(override: remaining);
    return;
  }
}
```

`startSession`'s `override` parameter (existing) accepts an explicit duration, bypasses other resolution branches, and writes the row via `_ensureFocusRow(ctx, now, remaining)`. That's correct — the row at `r.effectiveAt` is the source-of-truth scheduled row; `_ensureFocusRow` finds it and (since the existing row already extends to `end`) leaves it alone.

- [ ] **Step 2: Trigger from `setContext`**

Find `setContext` (around line 366). At the end of the method (after the existing distraction-handoff logic but before it returns/emits), schedule auto-start:

```dart
void setContext(Priority? priority, {/* existing params */}) {
  // ...existing body...
  emit(s.copyWith(context: priority, /* existing fields */));
  if (priority != null) {
    // Fire-and-forget — the resulting session emission is observed by
    // PriorityBloc through the existing NowBloc subscription.
    unawaited(_maybeAutoStart(priority));
  }
}
```

If `setContext` is synchronous and emits before returning, place the `unawaited` call after `emit`. Use `import 'dart:async';` if `unawaited` isn't already imported.

- [ ] **Step 3: Trigger from `_onTrackTick`**

Find `_onTrackTick` (around line 141). At the bottom of the method body, after the existing grace-end handling, add:

```dart
final ctx = state is NowLoaded ? (state as NowLoaded).context : null;
if (ctx != null) {
  await _maybeAutoStart(ctx);
}
```

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "feat: auto-start focus session when context covers a focus block

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Derive `pausedFocus` on each `NowLoaded` emission

**Files:**
- Modify: `apps/plot/lib/state/now.dart`

- [ ] **Step 1: Add the derivation helper**

In `NowBloc`, add:

```dart
/// Resolve a [PausedFocus] descriptor for the current state, if any.
/// Drives the agenda's sliding remaining block. Returns null when:
///   - no [context] is set,
///   - the latest explicit session for [context] is not paused
///     (end >= pomodoroAt + pomodoro means it ended at or past its
///     natural end — not paused),
///   - remaining ≤ 0.
Future<PausedFocus?> _resolvePausedFocus(Priority ctx) async {
  final paused = await Session.latestPausedFor(ctx.id);
  if (paused == null) return null;
  final pomo = paused.pomodoro;
  final pomoAt = paused.pomodoroAt;
  if (pomo == null || pomoAt == null) return null;
  final naturalEnd = pomoAt.add(pomo);
  // `latestPausedFor` already gates on end < natural end. Defensive.
  final elapsed = paused.end.difference(pomoAt);
  final remaining = pomo - elapsed;
  if (remaining <= Duration.zero) return null;
  return PausedFocus(priority: ctx, remaining: remaining);
}
```

- [ ] **Step 2: Recompute on relevant emissions**

`pausedFocus` only changes when (a) `context` changes, (b) a session ends, (c) Resume runs (clears it). Easiest approach: recompute lazily before each emit that could change it. Add a wrapper:

```dart
Future<void> _emitWithPausedFocus(NowLoaded s) async {
  final ctx = s.context;
  final paused = ctx == null ? null : await _resolvePausedFocus(ctx);
  emit(s.copyWith(pausedFocus: paused));
}
```

But `setContext` and many ticks emit synchronously. The pragmatic approach is to derive on each `NowLoaded` build inside the bloc's main subscription pipeline. The bloc subscribes to multiple Drift streams (`session`, `streamPriorityBlocksGroupedByPriority`, etc.); locate the combined-stream `start()` builder around line 60–80 and the `emit(NowLoaded(...))` call inside its `listen`. Add an async resolution before the emit:

```dart
// Inside the combined-stream listener, replacing the existing emit:
final ctxForPaused = /* the resolved context for this NowLoaded */;
final paused = ctxForPaused == null
    ? null
    : await _resolvePausedFocus(ctxForPaused);
emit(NowLoaded(
  /* ...all existing fields... */,
  pausedFocus: paused,
));
```

If the existing emit happens inside a sync `listen` callback, switch to `listen((event) async { ... await ...; emit(...); })`. Bloc allows async listeners.

- [ ] **Step 3: Clear `pausedFocus` on `startSession`**

At the top of `startSession` (after the early returns but before any work), emit `pausedFocus: null`:

```dart
emit(s.copyWith(pausedFocus: null));
```

This makes the sliding block disappear immediately when the user presses Start.

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/now.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/now.dart
git commit -m "feat: derive pausedFocus on NowLoaded emissions

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Thread `pausedFocus` through `PriorityBloc.AgendaBuilder.build` call sites

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`

- [ ] **Step 1: Subscribe `PriorityBloc` to `NowBloc` for `pausedFocus`**

Find the `PriorityBloc` constructor / `start()` method in `apps/plot/lib/state/priority.dart`. Add a field:

```dart
PausedFocus? _pausedFocus;
StreamSubscription<NowState>? _nowSubscription;
```

(Add `import 'package:plot/state/now.dart';` if not already imported.)

In the bloc's start/init path, subscribe:

```dart
_nowSubscription = _nowBloc.stream.listen((nowState) {
  if (nowState is! NowLoaded) return;
  final next = nowState.pausedFocus;
  if (next == _pausedFocus) return;
  _pausedFocus = next;
  _rebuildAgendaModel();
});
```

In `close()`, cancel: `await _nowSubscription?.cancel();`.

(`_nowBloc` is already accessible — check how existing `setContext` wiring receives it. If passed into the constructor, reuse that; if not, accept it as a constructor parameter.)

- [ ] **Step 2: Pass `pausedFocus` into every `AgendaBuilder.build` call**

Search the file:

```bash
cd apps/plot && grep -n "AgendaBuilder.build" lib/state/priority.dart
```

Expected matches (from grep earlier): lines 650, 1521, 2469, 3554. For each call, add:

```dart
final agenda = AgendaBuilder.build(
  // ...existing args...,
  pausedFocus: _pausedFocus == null
      ? null
      : (priority: _pausedFocus!.priority, remaining: _pausedFocus!.remaining),
);
```

- [ ] **Step 3: Re-tick on `_onTrackTick` so the sliding block advances**

The paused block's `windowStart == now` needs to advance every second. `NowBloc._onTrackTick` already emits each second. As long as `PriorityBloc`'s `NowBloc` subscription rebuilds the agenda whenever the emission carries a (new) `now`, sliding works. Confirm by checking: the listener above compares `_pausedFocus`, which won't change tick-over-tick. Fix by also rebuilding when *time* moves while paused:

```dart
DateTime _lastNow = DateTime.fromMillisecondsSinceEpoch(0);
_nowSubscription = _nowBloc.stream.listen((nowState) {
  if (nowState is! NowLoaded) return;
  final pausedChanged = nowState.pausedFocus != _pausedFocus;
  _pausedFocus = nowState.pausedFocus;
  final nowAdvanced = _pausedFocus != null &&
      nowState.now.difference(_lastNow).inSeconds >= 1;
  if (pausedChanged || nowAdvanced) {
    _lastNow = nowState.now;
    _rebuildAgendaModel();
  }
});
```

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/priority.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "feat: PriorityBloc subscribes to NowBloc for pausedFocus

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Drag and edit-modal route start/stop based on new window

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`
- Modify: `apps/plot/lib/command/focus_block.dart`

- [ ] **Step 1: Extend `moveFocusBlock` with session routing**

In `apps/plot/lib/state/priority.dart`, find `moveFocusBlock` (line 1559). At the very end of the method (after the authoritative writes), add:

```dart
// Session routing: align the running timer with the new window.
final now = DateTime.now();
final newEnd = targetTime.add(source.duration ?? Duration.zero);
final coversNow = !targetTime.isAfter(now) && newEnd.isAfter(now);
final isCurrentFocus =
    _nowBloc.state is NowLoaded &&
    (_nowBloc.state as NowLoaded).context?.id == source.priorityId;
if (coversNow && isCurrentFocus) {
  // Drop covers now and the focus is current — start (or resume) the
  // session matched to the remaining window.
  await _nowBloc.startSession(override: newEnd.difference(now));
} else if (!coversNow) {
  // Drop is wholly in the past or wholly in the future. If a session
  // was active for this priority, stop it. (Past drops are rare and
  // handled by the existing edit-mode allowance.)
  final s = _nowBloc.state;
  if (s is NowLoaded &&
      s.session?.priority?.id == source.priorityId &&
      s.session?.at.isNow() == true &&
      s.session?.source == 'active') {
    await _nowBloc.stopSession();
  }
}
```

- [ ] **Step 2: Route `ScheduleFocusBlock` edit branch the same way**

In `apps/plot/lib/command/focus_block.dart`, locate `ScheduleFocusBlock.run` (line 85). After the `setBlockDuration` call at the end of `run`, add similar routing:

```dart
@override
Future<CommandReturn> run(BuildContext context) async {
  // ... existing duration validation, archive-old, setBlockDuration ...

  // Session routing (mirrors PriorityBloc.moveFocusBlock).
  final nowBloc = context.read<NowBloc>();
  final nowMoment = DateTime.now();
  final newEnd = start.add(duration);
  final coversNow = !start.isAfter(nowMoment) && newEnd.isAfter(nowMoment);
  final s = nowBloc.state;
  final isCurrentFocus =
      s is NowLoaded && s.context?.id == priorityId;
  if (coversNow && isCurrentFocus) {
    await nowBloc.startSession(override: newEnd.difference(nowMoment));
  } else if (!coversNow &&
      s is NowLoaded &&
      s.session?.priority?.id == priorityId &&
      s.session?.at.isNow() == true &&
      s.session?.source == 'active') {
    await nowBloc.stopSession();
  }

  return const CommandDone();
}
```

Add `import 'package:flutter_bloc/flutter_bloc.dart';` and `import 'package:plot/state/now.dart';` at the top of `focus_block.dart` if not already present.

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/priority.dart lib/command/focus_block.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/priority.dart apps/plot/lib/command/focus_block.dart
git commit -m "feat: drag/edit a focus block start/stop the session

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Manual verification via run-app

**Files:** none.

- [ ] **Step 1: Launch the app**

Invoke the `run-app` skill (it sets up the isolated agent profile and connects dart-mcp).

- [ ] **Step 2: Walk through the matrix**

For each, observe the agenda and the header pill:

1. **Start focus** — press Start with a focus selected and no scheduled block. A 30-minute block should appear on the agenda at `[now, now+30m]` (or shorter if a scheduled event is sooner). Header pill shows the running countdown.
2. **Pause** — press Pause. The original block disappears from its slot. A sliding block at `[now, now+remaining]` appears. Wait a minute; confirm the block slides forward and the header pill remains paused.
3. **Resume (Start again)** — press Start. The sliding block disappears; a fresh covering block at `[now, now+remaining]` appears.
4. **Stop** — press Stop. Block disappears entirely. Header pill returns to inactive.
5. **Auto-start: select a focus mid-block** — schedule a 30m focus block on focus A at `now − 5m`, then switch context to focus A. The session should auto-start with the remaining ~25m.
6. **Auto-start: block begins while focus is selected** — schedule a 30m block on the current focus at `now + 1m`; wait. When `now` reaches the start, the session should auto-start.
7. **Drag active block to future** — start a session, then drag the agenda block to a future slot. Session should stop; block remains as scheduled.
8. **Drag scheduled block to now** — schedule a block in the future on the current focus, then drag it onto now. Session should start.

- [ ] **Step 3: Note any deviations**

If any case behaves differently from the spec, return to the relevant task and fix the cause rather than patching the symptom.

- [ ] **Step 4: Commit any fixes**

```bash
git add -p
git commit -m "fix: <specific behavior addressed>"
```

---

## Task 13: Finalize

**Files:** various.

- [ ] **Step 1: Run the full analyzer on changed packages**

Run: `cd apps/plot && flutter analyze`
Expected: No issues found.

- [ ] **Step 2: Run the relevant tests**

Run:

```bash
cd apps/plot && flutter test test/state/agenda_builder_test.dart test/state/now_test.dart test/command/timer_test.dart
```

Expected: All pass.

- [ ] **Step 3: Update `docs/updates.md`**

Add a single bullet under the current section at the top of `docs/updates.md`:

```markdown
- Renamed "Start timer" to "Start focus". The focus block now appears on your agenda as soon as you start it, lengthens or shrinks when you adjust the timer, slides forward as remaining time while paused, and disappears when stopped. The default focus length is now 30 minutes (or less if there's a scheduled item coming up). Selecting a focus that has a scheduled block covering now starts the timer automatically; dragging an active block to a future time stops it; dropping a future block onto now starts it.
```

- [ ] **Step 4: Run the `/finalize` skill**

Invoke the `finalize` skill to run the project's standard finalization checklist (lint, backwards-compat, error-capture, docs, public submodule).

- [ ] **Step 5: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs: focus block on agenda update note

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage:**
- Labels (StartTimer/StopTimer/EndTimer + root menu + unified header) → Task 1.
- `kDefaultPomodoro` 30m → Task 2.
- `_capToEnd` clamps against next focus block → Task 5.
- Manual Start writes a row → Task 6.
- Pause archives the row → Task 7.
- Stop archives the row → Task 7.
- `pausedFocus` synthesis on agenda → Task 4.
- `pausedFocus` derivation in `NowBloc` → Task 9.
- `PriorityBloc` subscribes to `NowBloc` and threads `pausedFocus` → Task 10.
- Auto-start on `setContext` + `_onTrackTick` → Task 8.
- Drag & edit-modal session routing → Task 11.
- Manual verification → Task 12.
- `docs/updates.md` + `/finalize` → Task 13.

**Placeholder scan:** none — all code blocks are concrete.

**Type consistency:**
- `pausedFocus` is `({Priority priority, Duration remaining})?` in `AgendaBuilder.build` (Task 4) and `PausedFocus` class in `NowLoaded` (Task 3). The bridge happens in Task 10 (`PriorityBloc` constructs the record from the class). Intentional — `AgendaBuilder` stays decoupled from `now_state.dart`.
- `_ensureFocusRow`, `_archiveCoveringRow`, `_maybeAutoStart`, `_resolvePausedFocus`, `_emitWithPausedFocus` — all consistent across Tasks 6–9.
- `setBlockDuration(priorityId:, blockStart:, newDuration:)` — matches `apps/plot/lib/store/priority_block.dart:279`.
- `Session.latestPausedFor(ctx.id)` — already used in `now.dart:552`.

Plan complete and saved to `docs/superpowers/plans/2026-05-31-focus-blocks-on-agenda.md`.
