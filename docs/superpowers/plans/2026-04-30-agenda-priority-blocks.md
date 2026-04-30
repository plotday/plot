# Agenda Priority Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the agenda data pipeline around `Block` as a first-class type, render combined block headers with priority breadcrumbs and accent borders, and remove the inline priority label from agenda thread tiles.

**Architecture:** Introduce `AgendaModel` (sections → blocks → threads) as a sealed type hierarchy. Port `_makeAgenda`'s ordering rules into a pure `AgendaBuilder.build` function emitting blocks. Wire `PriorityBloc` to consume the model and replace imperative splice mutation handlers with rebuild-from-source. Render sections → blocks → threads with a combined header per block. Rewrite the reorder closure to operate on block ids. Remove `_PriorityHoverArea` from the agenda call site only (activity feed keeps its inline label).

**Tech Stack:** Flutter, Dart, Drift (SQLite), flutter_bloc, forui, equatable. Tests use `flutter_test` (unit only — Flutter widget tests for agenda are skipped here per repo conventions; manual interaction in the running app is the validation gate).

**Reference spec:** `docs/superpowers/specs/2026-04-30-agenda-priority-blocks-design.md`

**Working directory:** `apps/plot`. Use `flutter analyze` (not the full test suite) for fast validation.

**Important conventions:**
- All Dart classes that participate in equality/state extend `Equatable` (the project pattern).
- Imports use `flutter/widgets.dart` and `forui/forui.dart` only — never `flutter/material.dart`.
- After each task, run `flutter analyze apps/plot/lib` and confirm zero new errors before committing.
- Commit messages follow the repo style (lowercase prefix `app:` for app-scope changes).

---

## Phase A — Data model (no behavior change to user)

### Task 1: Add `AgendaModel`, `AgendaSection`, `AgendaBlock` types

**Files:**
- Create: `apps/plot/lib/state/agenda_model.dart`

- [ ] **Step 1: Create the file with the type hierarchy**

```dart
import 'package:equatable/equatable.dart';
import 'package:plot/store/store.dart';

/// The agenda's canonical view: an ordered list of sections, each
/// containing an ordered list of blocks, each containing threads.
class AgendaModel extends Equatable {
  const AgendaModel({required this.sections});

  final List<AgendaSection> sections;

  static const empty = AgendaModel(sections: []);

  Iterable<AgendaBlock> get allBlocks =>
      sections.expand((s) => s.blocks);

  Iterable<Thread> get allThreads =>
      allBlocks.expand((b) => b.threads);

  AgendaBlock? blockById(String id) {
    for (final s in sections) {
      for (final b in s.blocks) {
        if (b.id == id) return b;
      }
    }
    return null;
  }

  @override
  List<Object?> get props => [sections];
}

sealed class AgendaSection extends Equatable {
  const AgendaSection();

  String get id;
  List<AgendaBlock> get blocks;

  @override
  List<Object?> get props => [id, blocks];
}

/// Section anchored to a date. `isNow == true` flags the synthetic
/// "Today" section that today's `_makeAgenda` inserts before any
/// future day when today has no other content.
class DateSection extends AgendaSection {
  const DateSection({
    required this.date,
    required this.blocks,
    this.isNow = false,
    this.scheduleAt,
  });

  final Date date;
  @override
  final List<AgendaBlock> blocks;
  final bool isNow;
  final DateTime? scheduleAt;

  @override
  String get id => 'date_${date.toIso8601String()}';

  @override
  List<Object?> get props => [date, blocks, isNow, scheduleAt];
}

/// Section with a non-date label (e.g. "From the server").
class TextSection extends AgendaSection {
  const TextSection({required this.text, required this.blocks});

  final String text;
  @override
  final List<AgendaBlock> blocks;

  @override
  String get id => 'text_${text.toLowerCase().replaceAll(' ', '_')}';

  @override
  List<Object?> get props => [text, blocks];
}

sealed class AgendaBlock extends Equatable {
  const AgendaBlock();

  String get id;
  Priority get priority;
  List<Thread> get threads;
  bool get isOutside;

  @override
  List<Object?> get props => [id, priority, threads, isOutside];
}

class PriorityBlock extends AgendaBlock {
  const PriorityBlock({
    required this.id,
    required this.priority,
    required this.threads,
    this.isOutside = false,
  });

  @override
  final String id;
  @override
  final Priority priority;
  @override
  final List<Thread> threads;
  @override
  final bool isOutside;
}

class EventBlock extends AgendaBlock {
  const EventBlock({
    required this.id,
    required this.priority,
    required this.event,
    required this.associated,
    this.isCurrent = false,
    this.isOutside = false,
  });

  @override
  final String id;
  @override
  final Priority priority;
  final Thread event;
  final List<Thread> associated;
  final bool isCurrent;
  @override
  final bool isOutside;

  @override
  List<Thread> get threads => [event, ...associated];

  @override
  List<Object?> get props =>
      [id, priority, event, associated, isCurrent, isOutside];
}

class GapBlock extends AgendaBlock {
  const GapBlock({
    required this.id,
    required this.priority,
    required this.range,
    required this.threads,
    this.isOutside = false,
  });

  @override
  final String id;
  @override
  final Priority priority;
  final DateTimeRange range;
  @override
  final List<Thread> threads;
  @override
  final bool isOutside;

  @override
  List<Object?> get props => [id, priority, range, threads, isOutside];
}
```

- [ ] **Step 2: Verify analyze**

Run: `flutter analyze apps/plot/lib/state/agenda_model.dart`
Expected: `No issues found!`

If `Date`, `Priority`, `Thread`, or `DateTimeRange` aren't found at the imported path, replace `import 'package:plot/store/store.dart';` with the correct re-export module — check what `apps/plot/lib/store/store.dart` exports.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/state/agenda_model.dart
git commit -m "app: add AgendaModel data types (sections, blocks)"
```

---

### Task 2: Add `AgendaBuilder` skeleton + a smoke test

**Files:**
- Create: `apps/plot/lib/state/agenda_builder.dart`
- Create: `apps/plot/test/state/agenda_builder_test.dart`

- [ ] **Step 1: Write the skeleton builder**

```dart
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

class AgendaBuilder {
  /// Pure, deterministic, ~O(n) builder for the agenda model.
  /// Ports the ordering rules from PriorityState._makeAgenda.
  static AgendaModel build({
    required List<Thread> threads,
    required Priority context,
    required int horizonDays,
    Map<Uuid, List<ThreadAssociationRow>>? associationsByParentId,
    DateTime? now,
  }) {
    if (threads.isEmpty) return AgendaModel.empty;
    // Implementation populated in Task 3.
    return AgendaModel.empty;
  }
}
```

- [ ] **Step 2: Write a smoke test (empty input → empty model)**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_builder.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

void main() {
  test('empty threads list produces empty model', () {
    final model = AgendaBuilder.build(
      threads: const [],
      context: Priority.viewer(),  // or appropriate root constructor
      horizonDays: 30,
    );
    expect(model.sections, isEmpty);
    expect(model, AgendaModel.empty);
  });
}
```

If `Priority.viewer()` isn't the right empty/test constructor, look at how `_makeAgenda`'s callers construct context priorities — the test only needs *any* valid Priority; replace with whatever works.

- [ ] **Step 3: Run analyze and the test**

```bash
flutter analyze apps/plot/lib/state/agenda_builder.dart \
  apps/plot/test/state/agenda_builder_test.dart
flutter test apps/plot/test/state/agenda_builder_test.dart
```

Expected: analyze clean, test passes.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/agenda_builder.dart apps/plot/test/state/agenda_builder_test.dart
git commit -m "app: add AgendaBuilder skeleton and smoke test"
```

---

### Task 3: Port `_makeAgenda` into `AgendaBuilder.build` (emits blocks)

This is the largest task. The goal is **bit-identical visual ordering** to today, with threads grouped into blocks.

**Files:**
- Modify: `apps/plot/lib/state/agenda_builder.dart`
- Reference (read-only): `apps/plot/lib/state/priority_state.dart:310-1100` (existing `_makeAgenda`)

- [ ] **Step 1: Set up the helper that emits priority blocks from a thread sequence**

Add this private helper inside `AgendaBuilder`. It walks a sequence of threads (already in their final order) and groups consecutive same-priority threads into `PriorityBlock`s.

```dart
static List<PriorityBlock> _priorityBlocks({
  required List<Thread> threads,
  required String sectionId,
  required Priority context,
  required Priority Function(Thread) outsideCheck,
}) {
  final blocks = <PriorityBlock>[];
  var i = 0;
  while (i < threads.length) {
    final priority = threads[i].priority;
    final start = i;
    while (i < threads.length && threads[i].priority == priority) {
      i++;
    }
    final group = threads.sublist(start, i);
    final isOutside =
        priority.path != context.path && !context.path.isParent(priority.path);
    blocks.add(PriorityBlock(
      id: 'p_${sectionId}_${priority.path.value}',
      priority: priority,
      threads: group,
      isOutside: isOutside,
    ));
  }
  return blocks;
}
```

- [ ] **Step 2: Port the date-partition + scheduled/unscheduled logic**

Replace the body of `build` with the full port of `_makeAgenda`. This is a mechanical translation — every place today's code does `items.add(AgendaHeaderItem(...))` or `items.add(AgendaThreadItem(...))`, instead accumulate into the appropriate block.

Mapping:
- `AgendaHeaderItem(date: ..., now: ..., scheduleAt: ...)` → start a new `DateSection` with `isNow`/`scheduleAt`
- `AgendaHeaderItem(thread: event, dateTimeRange: ...)` followed by `AgendaThreadItem(event)` (and any `isAssociated` items) → one `EventBlock`
- `AgendaHeaderItem(dateTimeRange: ...)` (gap) followed by zero-or-more threads in that gap → one `GapBlock` (with `priority = first thread's priority`; if zero threads, omit the block — the spec only requires gap headers when there is a gap *between* events; a zero-thread gap was a UI marker only and stays, see step 4)
- `addThreadsGrouped(threads, ...)` calls → run `_priorityBlocks(...)` on the post-`Thread.prioritize` ordering

The current flow inside today's `_makeAgenda` (`priority_state.dart:604-1100`) iterates dates and within each date alternates: scheduled events with gap headers, unscheduled todo block, before/after-now special handling. Walk that flow line-by-line and translate emissions into block construction.

Keep the same:
- Dedup by `(id, isLinkScheduleInstance, occurrence)` (`priority_state.dart:351-359`)
- Sort key `getSortKey` (`:378-383`)
- `addThreadsGrouped` rules — todos flat sorted, non-todos via `Thread.prioritize` (`:388-438`)
- Outside-priority detection (`:320-322`)
- Association handling inside `makeBlock` (`:483-504`)
- Today-specific before/after-now logic (`:660-796`)
- Gap iteration (`:798-...`)

- [ ] **Step 3: Construct stable block ids**

For each block, compute `id` as specified in the spec:
- `PriorityBlock`: `p_<sectionId>_<priorityPath>`
- `EventBlock`:    `e_<sectionId>_<eventId>[_<occurrence>]`
- `GapBlock`:      `g_<sectionId>_<rangeStartEpochMs>`

`<sectionId>` = the containing section's `id` (computed before block construction).

- [ ] **Step 4: Preserve the empty-gap-as-marker case**

Today, gap headers can render with no following threads — purely as a visual time marker between two events. With `GapBlock`, an empty gap is still meaningful: it's a header with no rows. Emit `GapBlock(threads: const [], priority: <fallback>)`. For `priority` in the empty case, use the *next event's priority* (the gap visually leads into that event). If no next event, use `context`.

- [ ] **Step 5: Run analyze and the test**

```bash
flutter analyze apps/plot/lib/state/agenda_builder.dart
flutter test apps/plot/test/state/agenda_builder_test.dart
```

Expected: analyze clean; smoke test passes.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/agenda_builder.dart
git commit -m "app: port _makeAgenda rules into AgendaBuilder.build"
```

---

### Task 4: Add `flatItems` getter on `AgendaModel` (compatibility shim)

`page/priority.dart` currently consumes a flat `List<AgendaItem>`. Until that's rewritten in Phase C, expose a getter that flattens the model into the *same* atom shape `_makeAgenda` produces today.

**Files:**
- Modify: `apps/plot/lib/state/agenda_model.dart`

- [ ] **Step 1: Add the getter**

```dart
// inside class AgendaModel
List<AgendaItem> get flatItems {
  final out = <AgendaItem>[];
  for (final section in sections) {
    switch (section) {
      case DateSection s:
        out.add(AgendaHeaderItem(
          date: s.date,
          now: s.isNow,
          scheduleAt: s.scheduleAt,
        ));
      case TextSection s:
        out.add(AgendaHeaderItem(text: s.text));
    }
    for (final block in section.blocks) {
      switch (block) {
        case PriorityBlock b:
          // No header atom yet — Phase C adds priority headers.
          for (final t in b.threads) {
            out.add(AgendaThreadItem(t,
                isOutsidePriority: b.isOutside));
          }
        case GapBlock b:
          out.add(AgendaHeaderItem(
            dateTimeRange: b.range,
            isOutsidePriority: b.isOutside,
          ));
          for (final t in b.threads) {
            out.add(AgendaThreadItem(t, isOutsidePriority: b.isOutside));
          }
        case EventBlock b:
          out.add(AgendaHeaderItem(
            dateTimeRange: b.event.at,
            thread: b.event,
            now: b.isCurrent,
            isOutsidePriority: b.isOutside,
          ));
          out.add(AgendaThreadItem(b.event,
              now: b.isCurrent, isOutsidePriority: b.isOutside));
          for (final child in b.associated) {
            out.add(AgendaThreadItem(child,
                isAssociated: true,
                associationParentId:
                    '${b.event.id}${b.event.occurrence != null ? '_${b.event.occurrence}' : ''}'));
          }
      }
    }
  }
  return out;
}
```

Add `import 'package:plot/state/priority_state.dart';` for `AgendaItem`/`AgendaHeaderItem`/`AgendaThreadItem`.

- [ ] **Step 2: Verify analyze**

```bash
flutter analyze apps/plot/lib/state/agenda_model.dart
```

Expected: no issues. If a circular import warning appears, move `AgendaItem` declarations to `agenda_model.dart` (delete from `priority_state.dart`) and update imports.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/state/agenda_model.dart
git commit -m "app: add AgendaModel.flatItems compatibility getter"
```

---

### Task 5: Wire `PriorityBloc` to use `AgendaBuilder.build`

**Files:**
- Modify: `apps/plot/lib/state/priority_state.dart`
- Modify: `apps/plot/lib/state/priority.dart`

- [ ] **Step 1: Carry the model on `PriorityState`**

In `priority_state.dart`, add an `AgendaModel agenda` field to `PriorityState` (default `AgendaModel.empty`). Change `agendaItems` from a stored field to a derived getter: `List<AgendaItem> get agendaItems => agenda.flatItems;`. Update `copyWith` to take `AgendaModel? agenda` and drop `agendaItems` from the constructor's parameter list (callers using `agendaItems:` will need to be updated to `agenda:`).

- [ ] **Step 2: Replace `_makeAgenda` call sites with `AgendaBuilder.build`**

In `priority.dart`, find every site that calls `PriorityState._makeAgenda(...)` (grep `_makeAgenda`) and replace with:

```dart
final agenda = AgendaBuilder.build(
  threads: patchedThreads,
  context: priorityToLoad,
  horizonDays: _agendaHorizonDays,
  associationsByParentId: _associations,
);
emit(state.copyWith(agenda: agenda, agendaLoaded: true));
```

Add `import 'package:plot/state/agenda_builder.dart';` and `'package:plot/state/agenda_model.dart';` at the top.

- [ ] **Step 3: Update `_makeAgenda` to delegate (then delete in Task 8)**

Keep `PriorityState._makeAgenda` for now as `(...) => AgendaBuilder.build(...).flatItems` so any straggler call sites keep compiling. We delete it once Phase B is done.

- [ ] **Step 4: Verify analyze**

```bash
flutter analyze apps/plot/lib
```

Fix any compilation errors revealed by the field rename. Expected: clean.

- [ ] **Step 5: Manual smoke test**

Hot-restart the running app, open the agenda. Expect: visually identical to before. No new headers, no missing threads. Reorder still works (using the old closure on `flatItems`).

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/priority_state.dart apps/plot/lib/state/priority.dart
git commit -m "app: wire PriorityBloc to AgendaBuilder.build via flatItems shim"
```

---

## Phase B — Mutation handler simplification

### Task 6: Replace `_handleThreadUpdate` splice paths with rebuild-from-source

**Files:**
- Modify: `apps/plot/lib/state/priority.dart` (lines ~759-985)

- [ ] **Step 1: Identify the source thread list**

`_handleThreadUpdate` receives `updatedThread` and currently mutates `state.agendaItems`. The "source" of truth is the most recent stream emission of threads, which is currently captured in the closure of `_loadAgenda`'s `.listen` callback as `patchedThreads`. Promote that to an instance field on the bloc:

```dart
List<Thread> _lastAgendaThreads = const [];
```

In `_loadAgenda`'s `.listen`, set `_lastAgendaThreads = patchedThreads;` before emitting.

- [ ] **Step 2: Rewrite `_handleThreadUpdate` to rebuild**

Replace the entire splice-based body (the schedule-changed reposition, the in-place replacement, the link-instance-becomes-todo splice) with:

```dart
void _handleThreadUpdate(Thread updatedThread) {
  // Update source threads.
  final updated = _lastAgendaThreads
      .map((t) => t.id == updatedThread.id ? updatedThread : t)
      .toList();
  if (!updated.any((t) => t.id == updatedThread.id)) {
    updated.add(updatedThread);
  }
  _lastAgendaThreads = updated;
  // Rebuild model from source.
  final agenda = AgendaBuilder.build(
    threads: updated,
    context: state.context,
    horizonDays: _agendaHorizonDays,
    associationsByParentId: _associations,
  );
  emit(state.copyWith(agenda: agenda));
}
```

Delete the old code (lines ~759-985).

- [ ] **Step 3: Verify analyze + manual test**

```bash
flutter analyze apps/plot/lib/state/priority.dart
```

Hot-restart. Verify: schedule changes, in-place updates, archive, finishing a todo all work without flicker.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "app: rebuild agenda from source instead of splicing on thread update"
```

---

### Task 7: Replace remaining splice paths

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`

- [ ] **Step 1: `optimisticallyRemoveThread`**

Locate the function (grep `optimisticallyRemoveThread`). Replace its body with:

```dart
void optimisticallyRemoveThread(Uuid threadId, {bool finishTodo = false}) {
  _lastAgendaThreads =
      _lastAgendaThreads.where((t) => t.id != threadId).toList();
  final agenda = AgendaBuilder.build(
    threads: _lastAgendaThreads,
    context: state.context,
    horizonDays: _agendaHorizonDays,
    associationsByParentId: _associations,
  );
  emit(state.copyWith(agenda: agenda));
  // Preserve any existing optimistic-override entry for the thread
  // (so the stream re-fire doesn't re-add it before the DB write lands).
  _optimisticOverrides[threadId] = ...; // keep existing override semantics
}
```

Read the existing function carefully — keep any `_optimisticOverrides` interaction unchanged; only the list-mutation half is replaced.

- [ ] **Step 2: `archiveThread` / archive-related mutations**

Same pattern. Replace splice with rebuild from `_lastAgendaThreads.where(...)`.

- [ ] **Step 3: `moveAgendaItem` (data-mutation half only)**

`moveAgendaItem` does two things: persist a new `Order` value (via `Thread.copyWith(order: ...)`) and update `state.agendaItems` for immediate visual feedback. Replace the second half with: update the moved thread inside `_lastAgendaThreads`, rebuild model, emit. Keep the persistence half (the DB write through commands) untouched.

- [ ] **Step 4: Delete `PriorityState._makeAgenda`**

Once all callers go through `AgendaBuilder.build`, remove `_makeAgenda` from `priority_state.dart`. Verify no stragglers: `git grep '_makeAgenda' apps/plot/lib`. Should be empty.

- [ ] **Step 5: Verify analyze + manual test**

```bash
flutter analyze apps/plot/lib
```

Hot-restart. Test: archive, finish todo, drag to reorder. Visual identical.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/priority.dart apps/plot/lib/state/priority_state.dart
git commit -m "app: rebuild agenda for optimistic, archive, and reorder mutations"
```

---

## Phase C — Render priority headers (user-visible change)

### Task 8: Extend `AgendaHeader` widget with `blockPriority`

**Files:**
- Modify: `apps/plot/lib/widget/agenda.dart`

- [ ] **Step 1: Add the parameter**

In `AgendaHeader`, add an optional `Priority? blockPriority` parameter alongside the existing fields. Update the constructor.

- [ ] **Step 2: Render the combined header when `blockPriority` is set**

Wrap the header content in a `Container` that adds the borders, and render the breadcrumb in the main area:

```dart
if (blockPriority != null) {
  final accent = context.colour.colours.fromTheme(blockPriority!.displayColor);
  final veryMuted = context.theme.plotColors.veryMuted;
  return Container(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: accent, width: 1),
        bottom: BorderSide(color: veryMuted, width: 1),
      ),
    ),
    padding: EdgeInsets.symmetric(
      vertical: context.theme.spacing.sm,
      horizontal: context.theme.spacing.md,
    ),
    child: Row(
      children: [
        // Time column (only when this header has a time/range)
        if (dateTimeRange != null) ...[
          SizedBox(
            width: agendaLeadingWidth(context),
            child: Padding(
              padding: EdgeInsets.only(right: context.theme.spacing.sm),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  dateTimeRange!.start?.toTimeOfDay().formatShort(context) ?? '',
                  style: TextStyle(
                    color: accent,
                    fontSize: context.theme.typography.xs.fontSize,
                  ),
                ),
              ),
            ),
          ),
        ],
        Expanded(
          child: PriorityLabel(
            priority: blockPriority,
            context: priorityContext,
            fontSize: context.theme.typography.xs.fontSize,
            height: 1,
          ),
        ),
        if (dateTimeRange?.duration?.inSeconds != null &&
            dateTimeRange!.duration!.inSeconds > 0) ...[
          Text(
            dateTimeRange!.duration!.format(),
            style: TextStyle(
              color: veryMuted,
              fontSize: context.theme.typography.xs.fontSize,
            ),
          ),
        ],
      ],
    ),
  );
}
// fall through to existing date / now / text / gap rendering when blockPriority is null
```

Headers with `blockPriority` set must not be focusable — do not wrap in any `FocusNode`-bearing widget, and do not wrap in `Tapable` or `GestureDetector` (no click affordance, per spec).

- [ ] **Step 3: Add `PriorityLabel` import**

```dart
import 'package:plot/widget/priority.dart' show PriorityLabel;
```

- [ ] **Step 4: Verify analyze**

```bash
flutter analyze apps/plot/lib/widget/agenda.dart
```

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/agenda.dart
git commit -m "app: add blockPriority rendering to AgendaHeader"
```

---

### Task 9: Update `flatItems` to emit block-priority headers

**Files:**
- Modify: `apps/plot/lib/state/agenda_model.dart`
- Modify: `apps/plot/lib/state/priority_state.dart` (extend `AgendaHeaderItem`)

- [ ] **Step 1: Add `blockPriority` to `AgendaHeaderItem`**

In `priority_state.dart`, add a `final Priority? blockPriority;` field to `AgendaHeaderItem`. Update constructor, props, `toString`, and the `stableKey` switch (priority headers get key `'header_priority_${blockPriority!.path.value}_${...}'`).

- [ ] **Step 2: Update `flatItems` to emit block-priority headers**

In `agenda_model.dart`, change the `PriorityBlock` branch to emit a header before the threads:

```dart
case PriorityBlock b:
  out.add(AgendaHeaderItem(
    blockPriority: b.priority,
    isOutsidePriority: b.isOutside,
  ));
  for (final t in b.threads) {
    out.add(AgendaThreadItem(t, isOutsidePriority: b.isOutside));
  }
```

For `GapBlock` and `EventBlock` branches, set `blockPriority: b.priority` on the existing header `AgendaHeaderItem` so the renderer draws the combined header.

- [ ] **Step 3: Pass `blockPriority` through in the renderer**

In `apps/plot/lib/page/priority.dart`, find the existing `AgendaHeader(...)` construction site (around line 1409) and pass through the new field:

```dart
AgendaHeader(
  // ...existing args...
  blockPriority: header.blockPriority,
),
```

- [ ] **Step 4: Update `stableKey` for the new variant**

In `priority_state.dart`'s `AgendaItem.stableKey`:

```dart
String get stableKey => when(
  header: (h) => h.date != null
      ? 'header_date_${h.date}'
      : h.dateTimeRange != null
      ? 'header_event_${h.dateTimeRange}_${h.blockPriority?.path.value ?? ""}'
      : h.blockPriority != null
      ? 'header_priority_${h.blockPriority!.path.value}'
      : 'header_other',
  activity: (a) => /* unchanged */,
);
```

- [ ] **Step 5: Verify `agendaViewItems` and `getAgendaItem` still work**

`agendaViewItems` (`priority_state.dart:155`) derives from `agendaItems` and strips the leading "Now" header to truncate to "now and after". With the new shim, it should keep working — but it iterates `AgendaHeaderItem`s with specific shapes, so confirm:
- An `AgendaHeaderItem` with `blockPriority` set but no other fields does not get mistakenly stripped.
- Test by switching priorities while a "now" event is active and verifying the agenda still truncates to the current event.

`getAgendaItem(offset)` (`priority.dart:1282`) walks `agendaItems` looking for `AgendaThreadItem`. New priority-only headers are `AgendaHeaderItem`s and will be skipped naturally. Test by pressing the keyboard navigation shortcut (likely arrow keys) and verifying focus moves between threads, never landing on a priority header.

If either regresses, fix in this task before commit.

- [ ] **Step 6: Verify analyze + manual test**

```bash
flutter analyze apps/plot/lib
```

Hot-restart. Open agenda. **Expect**: priority headers now appear above each priority block, with accent-colored top border, veryMuted bottom border, and the priority breadcrumb. Gap and event headers carry the same borders + breadcrumb. Date headers unchanged.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/state/agenda_model.dart apps/plot/lib/state/priority_state.dart apps/plot/lib/page/priority.dart
git commit -m "app: emit block-priority headers via flatItems shim"
```

---

## Phase D — Remove inline priority label from agenda thread tile

### Task 10: Stop passing `showSubPriority: true` from the agenda site

**Files:**
- Modify: `apps/plot/lib/page/priority.dart`

- [ ] **Step 1: Edit the agenda call site only**

At `apps/plot/lib/page/priority.dart:1454`, remove `showSubPriority: true,` from the `ThreadWidget(...)` constructor.

**Important**: leave the activity-feed call site at `:2285` untouched — it must continue to render the inline label.

- [ ] **Step 2: Verify analyze + manual test**

```bash
flutter analyze apps/plot/lib/page/priority.dart
```

Hot-restart. **Expect**:
- Agenda: thread tiles no longer show the inline priority breadcrumb above the title row. The breadcrumb is now only on the block header.
- Activity feed: thread tiles still show the inline priority breadcrumb (unchanged).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "app: remove inline priority label from agenda thread tiles"
```

---

## Phase E — Block-aware reorder

### Task 11: Rewrite the reorder closure on block ids

**Files:**
- Modify: `apps/plot/lib/page/priority.dart` (lines ~1483-1820)

- [ ] **Step 1: Replace the section-scanning logic**

Today's closure scans `listItems` to find date sections, gap headers, and event boundaries to compute `pinnedAfterTime`/`targetDate`/`prevTodo`/`nextTodo`. Replace with: look up the source block from the model.

```dart
return (int newIndex) {
  final agenda = context.read<PriorityBloc>().state.agenda;

  // Find which block the drop position lands in.
  AgendaBlock? targetBlock;
  AgendaSection? targetSection;
  int positionInBlockThreads = 0;
  // Walk the flat list correlated with sections/blocks to find drop location.
  // Build an index map once: flatIndex -> (section, block, threadIndexInBlock).
  // (Helper produced inline; keep it simple.)
  final indexMap = _buildFlatIndexMap(agenda);
  if (newIndex < indexMap.length) {
    final loc = indexMap[newIndex];
    targetSection = loc.section;
    targetBlock = loc.block;
    positionInBlockThreads = loc.threadIndex;
  }

  if (targetBlock == null || targetSection == null) return;

  Thread? prevThread;
  Thread? nextThread;
  if (positionInBlockThreads > 0) {
    prevThread = targetBlock.threads[positionInBlockThreads - 1];
  }
  if (positionInBlockThreads < targetBlock.threads.length) {
    nextThread = targetBlock.threads[positionInBlockThreads];
  }

  final newOrder = Order.between(prevThread?.order, nextThread?.order);

  // Per-block-kind drop semantics:
  switch (targetBlock) {
    case PriorityBlock _:
      // Today's behavior: order only — no priority change.
      // (Future: switch to Option A or B per spec §"Cross-block drops".)
      context.run(SetThreadOrder(activity, newOrder));
    case GapBlock b:
      context.run(SetThreadOrder(activity, newOrder));
      context.run(PinThreadAfterTime(activity, b.range.start));
    case EventBlock b:
      context.run(AssociateThread(activity, b.event, order: newOrder));
  }

  // Date change: if targetSection.date != activity's current date, also reschedule.
  if (targetSection is DateSection &&
      targetSection.date != (activity.on?.start ?? activity.at?.start?.toDate())) {
    context.run(MoveThreadToDate(activity, targetSection.date));
  }
};
```

The exact command names (`SetThreadOrder`, `PinThreadAfterTime`, `MoveThreadToDate`, `AssociateThread`) may differ in the codebase — find the existing commands the old closure called (search `command/thread.dart` and the existing closure body) and reuse them.

- [ ] **Step 2: Add the `_buildFlatIndexMap` helper**

A small helper that walks the model and builds an index from the flat list position → (section, block, thread index in block). Either at the top of `page/priority.dart` or as a static on `AgendaModel`.

- [ ] **Step 3: Delete the old scanning code**

Delete the ~350 lines of section/gap scanning that this replaces.

- [ ] **Step 4: Verify analyze + manual test**

```bash
flutter analyze apps/plot/lib/page/priority.dart
```

Hot-restart. **Test thoroughly**:
- Reorder a todo within its priority block (same priority, same day).
- Reorder a todo to a different position within the same priority's block.
- Drag a todo to a gap → it should pin to that gap's start time.
- Drag a thread onto an event → it should associate with the event.
- Drag a todo to a different date → date should change.

If any of these regress, fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "app: rewrite agenda reorder on block ids"
```

---

## Phase F — Cleanup

### Task 12: Remove dead code and finalize

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart`

- [ ] **Step 1: Audit `hasSubPriorityLabel` paths**

Search for `hasSubPriorityLabel` in `thread.dart`. If its only true value comes from `showSubPriority`, and nothing else, the variable can stay (the activity feed still uses `showSubPriority: true`). Don't remove `_PriorityHoverArea` — it's still used by the activity feed.

- [ ] **Step 2: Look for any other call sites of `_makeAgenda` or stale references**

```bash
git grep -nE 'agendaItems:|_makeAgenda' apps/plot/lib | head -20
```

If any remain (other than the derived `agendaItems` getter), update them.

- [ ] **Step 3: `/finalize` checklist**

Run the project's finalization checks:

```bash
flutter analyze apps/plot/lib
```

Expected: clean.

Per `AGENTS.md` §"Change Finalization", run `/finalize` (or its checks) before declaring done. Specifically: lint, error-capture review (none needed here — pure UI/state refactor), updates.md entry.

- [ ] **Step 4: Update `docs/updates.md`**

Add a brief user-facing line at the top of the current section:

```markdown
- Threads in the agenda are now grouped under shared headers by priority,
  event, or schedule gap, with each block carrying its priority's accent
  color.
```

- [ ] **Step 5: Manual end-to-end validation**

In the running app, exercise:
- Open the agenda; threads grouped correctly under priority headers.
- Schedule a thread to a different time; layout updates without flicker.
- Archive a thread; row collapses cleanly.
- Toggle to the activity feed; inline priority labels still present.
- Outside-priority calendar events; still dimmed.
- Today's "now" marker present at the top of the day.
- Drag-and-drop interactions work for each block kind (priority, gap, event).

If any of these regress, fix before final commit.

- [ ] **Step 6: Final commit**

```bash
git add docs/updates.md apps/plot/lib/widget/thread.dart
git commit -m "app: finalize agenda priority blocks (updates.md, cleanup)"
```

---

## Validation summary

After Task 12:
- `flutter analyze apps/plot/lib` clean.
- `flutter test apps/plot/test/state/agenda_builder_test.dart` passes.
- Agenda renders with combined block headers (priority breadcrumb + accent + veryMuted borders) on every priority/gap/event block; date headers unchanged; "now" marker preserved.
- Activity feed unchanged (inline priority label still present).
- Reorder within a block, across blocks, into gaps, onto events all behave per spec.
- ~600 lines of imperative splice/scan code deleted from `priority.dart` and the agenda reorder closure.
