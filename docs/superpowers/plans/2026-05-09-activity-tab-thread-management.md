# Activity Tab Thread Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate thread management on the Activity tab of `PriorityPage` so it owns Active (Today), Scheduled (relative dates), New (unread), and Done sections, with full drag-and-drop reordering between and within sections.

**Architecture:** A new section taxonomy (`active` / `scheduled` / `unread` / `inactive`) replaces the current "unread + time-ago" buckets. The bloc combines two streams — one for `todo=true` threads (all of them, no pagination) and one for the existing reverse-chronological feed — and partitions them into the four sections. A new `ThreadDragController` (built with the same height-conserving slot mechanism the agenda uses, by **reusing** `BlockDragController` from `agenda_block_drag.dart` — that file is shared infrastructure that the parallel agenda redesign keeps) wraps each `_ActivityFeedItem` row, with `BlockDropZone`s tiled between rows. The drop dispatcher decodes the target's section and applies the right state mutation (`todo=true` w/ sentinel, `todo=true` w/ specific date, `unread=true`, or `todo=false && unread=false`) plus a fractional-order rewrite for intra-section reorder.

**Tech Stack:** Flutter / Dart, Drift (SQLite), Bloc, fractional `Order` for stable reorder, existing `BlockDragController` reused as the drag substrate.

**Coordination note:** A parallel agent is implementing `2026-05-09-agenda-priority-block-redesign.md`, which removes the `Agenda/Activity` tab strip from `PriorityPage` and moves the agenda to a dedicated `/agenda` route. That spec explicitly says: *"The activity feed view is left as-is in this spec; another agent will redesign it to incorporate active threads."* — that's this plan. Touch only the Activity-feed code paths in `priority.dart` (`_buildActivityFeed`, `_loadActivityFeed`, `_ActivityFeedItem`, related state). Do **not** edit `agenda.dart`, `agenda_block_drag.dart`, the `PriorityTab` enum, or the desktop tab strip code (lines ~2911–2975 of `priority.dart`) — those are the parallel agent's territory.

---

## Terminology (to be used in code/comments/docs going forward)

- **Active** — threads marked "Do today" via the sentinel (`_userSchedule.startOn == Thread.todoNowDate`) **OR** threads with `todo=true` whose user-schedule date is today or in the past. Rendered under the **Today** section header.
- **Scheduled** — threads with `todo=true` whose user-schedule date is a future day. Rendered under one section per future day (relative date label: "Tomorrow", "Friday", "Apr 28", etc.).
- **Unread** — threads with `unread=true` that are **neither active nor scheduled**. Rendered under the **New** section header.
- **Inactive** — threads that are none of the above (read, no active todo). Rendered under the **Done** section header.

The legacy field `Thread.todo` continues to exist; it equals `active || scheduled` (i.e. thread has a non-archived user schedule with a date). The legacy getter `Thread.done` (= "not todo") continues to exist; it overlaps `inactive` ∪ `unread`.

## File Structure

**Created:**
- `apps/plot/lib/widget/thread_drag_zone.dart` — thin wrapper over `BlockDropZone`/`BlockDragScope`/`BlockDragHidden` that exposes `ThreadDragSection` enum and translates section-aware drop targets into the `BlockDropTarget` shape the controller expects.
- `apps/plot/lib/widget/thread_drag_dispatcher.dart` — pure function `dispatchThreadDrop(BuildContext, List<AgendaItem>, BlockDragPayload, BlockDropTarget)` mirroring `_dispatchBlockDrop` but operating on threads and section transitions.
- `apps/plot/lib/state/activity_section.dart` — `enum ActivitySection { today, scheduled, newSection, done }` plus `ActivitySection sectionFor(Thread)`, `String relativeDateLabel(Date)`, and a small data class `ActivitySectionMarker` carried on `AgendaHeaderItem.text` so the dispatcher can identify section boundaries.

**Modified:**
- `apps/plot/lib/store/thread.dart` — add `bool get isActiveThread`, `bool get isScheduledThread`, `bool get isUnreadOnly`, `bool get isInactiveThread` getters; add `Thread.todoNowDate` doc; add `Thread asUnread()` / `asInactive()` / `asActiveToday()` / `asScheduled(Date)` helpers that produce a copy with the right field combo.
- `apps/plot/lib/command/thread.dart` — rename string titles "Add to agenda" → "Do today" and "Remove from agenda" → "Finish"; add new `MarkUnreadThread` command; reword internal comments that still reference "agenda" as the user-facing concept.
- `apps/plot/lib/widget/thread.dart` — rename leading-icon tooltip strings; nothing structural.
- `apps/plot/lib/widget/unified_header.dart` — rename "Remove from agenda" → "Finish" string only.
- `apps/plot/lib/state/priority.dart` — add `_loadTodoThreads` stream subscription; rewrite `_loadActivityFeed`'s grouping pass (lines ~2380–2436) to produce the four sections; add `applyThreadDrop(...)` method on `PriorityBloc` that the dispatcher calls.
- `apps/plot/lib/page/priority.dart` — wrap `_buildActivityFeed`'s body in a `BlockDragScope`; render `BlockDropZone`s between rows; wrap each `_ActivityFeedItem` in a `Draggable<BlockDragPayload>` (single-thread payload, `visibleThreadCount: 1`); wire dispatcher and `previewBuilder`.
- `docs/features.md` — describe drag-and-drop section management.
- `docs/updates.md` — user-facing changelog bullet.

**Not touched (owned by parallel agent or out of scope):**
- `apps/plot/lib/widget/agenda.dart`
- `apps/plot/lib/widget/agenda_block_drag.dart` (consumed only as a public API)
- `apps/plot/lib/state/agenda_model.dart` / `agenda_builder.dart`
- The desktop tab strip in `priority.dart` (~lines 2911–2975)

---

## Task 1: Add active/scheduled/unread-only/inactive getters on Thread

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` — add four boolean getters after the existing `done` getter (~line 2822).

- [ ] **Step 1: Add the getters**

Insert directly below the `bool get done` getter (currently at `apps/plot/lib/store/thread.dart:2822`):

```dart
  /// Active = marked "Do today" (user schedule with `todoNowDate` sentinel)
  /// or todo with a user-schedule date that is today or in the past.
  ///
  /// This is the primary state for threads currently being worked on; they
  /// render in the Today section of the Activity feed and continue to use
  /// `Thread.todoNowDate` (epoch sentinel) when no explicit date is set.
  bool get isActiveThread => todo && !isFuture;

  /// Scheduled = todo with a user-schedule date in the future. Rendered in
  /// per-day sections of the Activity feed ("Tomorrow", "Friday", etc.).
  bool get isScheduledThread => todo && isFuture;

  /// Unread but not active or scheduled. Rendered in the "New" section.
  /// Active and scheduled threads that happen to be unread render in their
  /// own date-anchored section instead.
  bool get isUnreadOnly => unread && !todo;

  /// Inactive = neither active, scheduled, nor unread. Rendered in the
  /// "Done" section. Includes threads with no user schedule (e.g. archived
  /// todos) and read non-todo threads.
  bool get isInactiveThread => !todo && !unread;
```

- [ ] **Step 2: Verify the file analyzes**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors related to the new getters.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "$(cat <<'EOF'
Add active/scheduled/unread-only/inactive getters on Thread

Defines the four-section taxonomy used by the Activity tab grouping logic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Rename "Add to agenda" / "Remove from agenda" strings

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart:289-291`
- Modify: `apps/plot/lib/widget/unified_header.dart:613` (and the "Remove from agenda" instances on the file)
- Modify: `apps/plot/lib/command/thread.dart:807, 827, 845, 911`

- [ ] **Step 1: Update `widget/thread.dart`**

Replace the `leadingTitle` ternary at `apps/plot/lib/widget/thread.dart:289-291`:

```dart
        final String leadingTitle = !isTodo ? 'Do today' : 'Finish';
```

- [ ] **Step 2: Update `widget/unified_header.dart`**

In `apps/plot/lib/widget/unified_header.dart`, search for the literal `'Remove from agenda'` and replace with `'Finish'`. Also search for `'Add to agenda'` and replace with `'Do today'`. (Use `Edit` with `replace_all: true` per literal.)

- [ ] **Step 3: Update `command/thread.dart`**

In `apps/plot/lib/command/thread.dart`:

1. `ToggleThreadToDo` constructor body (~line 807):
   ```dart
         title: title ?? (thread.todo ? 'Finish' : 'Do today'),
   ```

2. `StartThread` constructor body (~line 827):
   ```dart
           title: 'Do today',
   ```

3. `DisassociateThread` constructor body (~line 845):
   ```dart
           title: finish ? 'Finish' : 'Remove from event',
   ```

4. `FinishThread` constructor body (~line 911):
   ```dart
            title: 'Finish',
   ```

- [ ] **Step 4: Search for any remaining occurrences**

Run:
```bash
grep -rn "Add to agenda\|Remove from agenda" apps/plot/lib --include="*.dart"
```
Expected: No matches. Replace any stragglers verbatim.

- [ ] **Step 5: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/thread.dart lib/widget/unified_header.dart lib/command/thread.dart`
Expected: No errors.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/thread.dart apps/plot/lib/widget/unified_header.dart apps/plot/lib/command/thread.dart
git commit -m "$(cat <<'EOF'
Rename agenda commands: "Add to agenda" → "Do today", "Remove from agenda" → "Finish"

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `MarkUnreadThread` command

**Files:**
- Modify: `apps/plot/lib/command/thread.dart` — append after `MarkReadThread` (~line 901)

- [ ] **Step 1: Add the command class**

Insert immediately after the `MarkReadThread` class (~line 901) in `apps/plot/lib/command/thread.dart`:

```dart
class MarkUnreadThread extends _UpdateThreadCommand {
  MarkUnreadThread(super.thread, {super.onUpdate})
    : super(
        title: 'Mark unread',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: FontAwesomeIcons.eyeSlash,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (thread.unread) return const CommandDone();
    // Clear `readAt` so the unread state isn't suppressed by the
    // local-override that the activity feed query checks alongside
    // `unread = true`.
    await saveOptimistically(
      context,
      thread.copyWith(unread: true, readAt: const Value(null)),
    );
    return const CommandDone();
  }
}
```

- [ ] **Step 2: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/command/thread.dart`
Expected: No errors. If `Value` isn't imported in this file, add `import 'package:plot/util/value.dart';` (re-export of `drift.Value`).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/thread.dart
git commit -m "$(cat <<'EOF'
Add MarkUnreadThread command

Inverse of MarkReadThread; needed for drag-into-New section in the
Activity tab.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add Thread state-mutation helpers (`asActiveToday`, `asScheduled`, `asUnread`, `asInactive`)

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` — append below `withScheduleRestored` (~line 3034)

- [ ] **Step 1: Add the helpers**

Insert after `withScheduleRestored` (~line 3034) in `apps/plot/lib/store/thread.dart`:

```dart
  /// Returns a copy in the "active" state (todo with `todoNowDate`
  /// sentinel). Preserves `order` if a user schedule already exists;
  /// callers set `order` explicitly when they want to reorder at the
  /// same time as activating.
  Thread asActiveToday({Order? order}) {
    final effectiveOrder =
        order ?? _userSchedule?.order ?? Order.first();
    return withScheduleRestored(order: effectiveOrder);
  }

  /// Returns a copy in the "scheduled" state for [date]. Sets the user
  /// schedule's `startOn` to the given date and clears time fields so
  /// the thread renders under the Tomorrow/Friday/etc. header.
  Thread asScheduled(Date date, {Order? order}) {
    final effectiveOrder =
        order ?? _userSchedule?.order ?? Order.first();
    return withScheduleRestored(order: effectiveOrder, date: date);
  }

  /// Returns a copy in the "new (unread-only)" state — flips `unread`
  /// to true and archives any user schedule so the thread isn't classed
  /// as active or scheduled.
  Thread asUnread() {
    final base = _userSchedule == null
        ? this
        : _withUserSchedule(
            _userSchedule.copyWith(
              archivedAt: Value(DateTime.now()),
              updatedAt: DateTime.now(),
            ),
          );
    return base.copyWith(unread: true, readAt: const Value(null));
  }

  /// Returns a copy in the "inactive (done)" state — clears unread and
  /// archives any user schedule. Used when a thread is dropped into the
  /// Done section.
  Thread asInactive() {
    final base = _userSchedule == null
        ? this
        : _withUserSchedule(
            _userSchedule.copyWith(
              archivedAt: Value(DateTime.now()),
              updatedAt: DateTime.now(),
            ),
          );
    return base.copyWith(unread: false);
  }
```

- [ ] **Step 2: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors. If `_withUserSchedule` is private, the same-class call works fine.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "$(cat <<'EOF'
Add Thread.asActiveToday/asScheduled/asUnread/asInactive helpers

State-transition helpers used by the Activity tab drag dispatcher.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Create `ActivitySection` enum and section-classification helpers

**Files:**
- Create: `apps/plot/lib/state/activity_section.dart`

- [ ] **Step 1: Create the file**

```dart
import 'package:plot/store/store.dart';
import 'package:plot/util/date.dart' show Date;

/// The four sections of the Activity tab. Each thread belongs to exactly
/// one section, computed from `Thread.isActiveThread` /
/// `isScheduledThread` / `isUnreadOnly` / `isInactiveThread`.
enum ActivitySection { today, scheduled, newSection, done }

/// Classify a thread into its Activity-tab section. Mirrors the four
/// boolean getters on Thread; centralized here so callers can switch on
/// the result without re-deriving the booleans.
ActivitySection sectionFor(Thread thread) {
  if (thread.isActiveThread) return ActivitySection.today;
  if (thread.isScheduledThread) return ActivitySection.scheduled;
  if (thread.isUnreadOnly) return ActivitySection.newSection;
  return ActivitySection.done;
}

/// Marker sentinel embedded in `AgendaHeaderItem.text` so the drag
/// dispatcher can identify which section a header belongs to without
/// string-matching. The actual displayed label is also stored on
/// `AgendaHeaderItem.text` (for headers that want a non-default label,
/// the marker prefix is stripped at render time).
///
/// We use a string sentinel rather than a new field on AgendaHeaderItem
/// to avoid changes to the agenda-shared item model that the parallel
/// agent is concurrently modifying.
class ActivitySectionMarker {
  static const String prefix = '__activity_section__';

  static String encode(ActivitySection section, {String? label}) {
    return '$prefix:${section.name}:${label ?? defaultLabel(section)}';
  }

  static ({ActivitySection section, String label})? tryDecode(String text) {
    if (!text.startsWith('$prefix:')) return null;
    final parts = text.substring(prefix.length + 1).split(':');
    if (parts.length < 2) return null;
    final section = ActivitySection.values
        .where((s) => s.name == parts[0])
        .firstOrNull;
    if (section == null) return null;
    final label = parts.sublist(1).join(':');
    return (section: section, label: label);
  }

  static String defaultLabel(ActivitySection section) {
    switch (section) {
      case ActivitySection.today:
        return 'Today';
      case ActivitySection.scheduled:
        return 'Scheduled';
      case ActivitySection.newSection:
        return 'New';
      case ActivitySection.done:
        return 'Done';
    }
  }
}

/// Human-readable relative-date label for a scheduled-section header.
/// "Tomorrow" for today+1, weekday name for the next 6 days, "MMM d"
/// otherwise.
String relativeDateLabel(Date date) {
  final today = Date.today();
  final days = date.difference(today).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days >= 2 && days <= 6) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return weekdays[date.weekday - 1];
  }
  // Fallback: "MMM d" / "MMM d, yyyy" if not in current year.
  final months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final m = months[date.month - 1];
  if (date.year != today.year) return '$m ${date.day}, ${date.year}';
  return '$m ${date.day}';
}
```

- [ ] **Step 2: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/state/activity_section.dart`
Expected: No errors. If `Date.weekday` doesn't exist on the Date type, replace with `date.toDateTime().weekday` (which is 1–7 for Mon–Sun).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/state/activity_section.dart
git commit -m "$(cat <<'EOF'
Add ActivitySection enum + classification + relative-date label helpers

Centralizes the four-section taxonomy for the Activity tab.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add a separate `_loadTodoThreads` stream so all `todo=true` threads are loaded regardless of pagination

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`

The existing `_loadActivityFeed` stream uses `ThreadOrder.reverse` with a row LIMIT — it's chronological by `activityAt` and may exclude `todo=true` threads whose `activityAt` is older than the page boundary. We need every active and scheduled thread on screen, so we add a parallel stream that filters to `todo=true` threads with no limit.

- [ ] **Step 1: Add a `Thread.watchTodos` streaming static**

In `apps/plot/lib/store/thread.dart`, find the existing `Thread.watch` static (~line 1500–1700 region). Add a new static method directly after it:

```dart
  /// Streams every non-archived todo (`todo=true`) for the priority,
  /// without a LIMIT. The Activity tab uses this in parallel with the
  /// reverse-chronological feed to ensure all Active/Scheduled threads
  /// are present regardless of pagination.
  static Stream<List<Thread>> watchTodos({
    required PriorityPath priorityPath,
    bool archived = false,
  }) {
    final query = _buildBaseQuery(
      priorityPath: priorityPath,
      archived: archived,
      order: ThreadOrder.sorted,
      includeUnscheduled: false,
    );
    // includeUnscheduled: false already restricts to threads with a
    // schedule. Of those, todo=true is exactly the set with a non-archived
    // user schedule with a date — the same condition the existing
    // `_buildBaseQuery(order: ThreadOrder.sorted)` builds (see
    // condition setup around line 1727).
    return query.watch().map((rows) => _hydrateRows(rows));
  }
```

If the file does not have a `_buildBaseQuery`/`_hydrateRows` factoring, replicate the existing query in `Thread.watch` for the no-limit case but filter on `userSched.archivedAt.isNull() & (userSched.startOn.isNotNull() | userSched.startAt.isNotNull())`. **Look at the actual file** for the canonical pattern — this step's exact shape depends on the existing helpers — and conform to it.

- [ ] **Step 2: Add the subscription in PriorityBloc**

In `apps/plot/lib/state/priority.dart`, find `_loadActivityFeed` (~line 2317). Above it, add:

```dart
  StreamSubscription<List<Thread>>? _todoThreadsSubscription;
  List<Thread> _todoThreads = const [];

  void _loadTodoThreads() {
    final priorityToLoad = state.context;
    _todoThreadsSubscription?.cancel();
    _todoThreadsSubscription =
        Thread.watchTodos(
          priorityPath: priorityToLoad.path,
          archived: state.showArchived,
        ).listen((threads) {
          _todoThreads = threads;
          // Re-build the activity feed sectioning whenever the todo set
          // changes; the activity feed stream re-fires on its own when
          // its rows change.
          _rebuildActivityFeedSections();
        });
  }
```

- [ ] **Step 3: Call `_loadTodoThreads` from `_loadPriority`**

In `_loadPriority` (a few hundred lines above `_loadActivityFeed`), find the existing call to `_loadActivityFeed()` and add `_loadTodoThreads()` immediately before/after it. Search for the literal `_loadActivityFeed(` to find every call site. Mirror the same lifecycle (cancel + recreate when `priority` or `showArchived` change).

- [ ] **Step 4: Cancel the subscription on close**

In `PriorityBloc.close()`, add `_todoThreadsSubscription?.cancel();` next to the existing `_activityFeedSubscription?.cancel();`.

- [ ] **Step 5: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart lib/state/priority.dart`
Expected: No errors. The `_rebuildActivityFeedSections` symbol is a forward reference — Task 7 introduces it. Temporarily stub:

```dart
  void _rebuildActivityFeedSections() {
    // Implemented in Task 7.
  }
```

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/lib/state/priority.dart
git commit -m "$(cat <<'EOF'
Add unbounded todo-threads stream for Activity tab section building

The reverse-chronological activity feed paginates by activityAt, which
can push older todos past the page boundary. The new watchTodos stream
returns every todo regardless of activityAt so Active and Scheduled
sections always render the full set.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Rewrite Activity feed sectioning into Today / Scheduled / New / Done

**Files:**
- Modify: `apps/plot/lib/state/priority.dart` — replace the body of `_loadActivityFeed` from the end of the stream `.listen` callback's section-building block.

- [ ] **Step 1: Extract section building into `_rebuildActivityFeedSections`**

Replace the existing section-building region of `_loadActivityFeed` (currently lines ~2380–2436, starting from `final items = <AgendaItem>[];` and ending at the `emit(state.copyWith(...))` call) with:

```dart
          _activityFeedRawThreads = allThreads;
          _activityFeedDoneEnd = doneEnd;
          _rebuildActivityFeedSections();
        });
```

(`_activityFeedRawThreads` and `_activityFeedDoneEnd` are new private fields on `PriorityBloc`; declare them next to the existing `_lastAgendaThreads` field with type `List<Thread>` / `bool`, default `[]`/`false`.)

- [ ] **Step 2: Implement `_rebuildActivityFeedSections`**

Replace the stub from Task 6 with the full implementation. Insert at the same call site:

```dart
  List<Thread> _activityFeedRawThreads = const [];
  bool _activityFeedDoneEnd = false;

  void _rebuildActivityFeedSections() {
    // Merge: todo threads (Active + Scheduled) come from _todoThreads,
    // everyone else from the reverse-chronological feed.
    final todoIds = _todoThreads.map((t) => t.id).toSet();
    final feedNonTodo = _activityFeedRawThreads
        .where((t) => !todoIds.contains(t.id))
        .toList();

    final active = <Thread>[];
    final scheduledByDate = <Date, List<Thread>>{};
    for (final t in _todoThreads) {
      if (t.isActiveThread) {
        active.add(t);
      } else if (t.isScheduledThread) {
        // Scheduled date = the user-schedule date or pinned-after date.
        final date =
            t.on?.start ?? t.at?.start?.toDate() ?? Date.today();
        scheduledByDate.putIfAbsent(date, () => []).add(t);
      }
    }

    // Sort active by `userSchedule.order` (existing convention).
    active.sort((a, b) => a.todoCompareTo(b));

    // Sort each scheduled bucket by order, and the buckets by date.
    final scheduledDates = scheduledByDate.keys.toList()..sort();
    for (final d in scheduledDates) {
      scheduledByDate[d]!.sort((a, b) => a.todoCompareTo(b));
    }

    final unread = <Thread>[];
    final done = <Thread>[];
    for (final t in feedNonTodo) {
      if (t.isUnreadOnly) {
        unread.add(t);
      } else {
        done.add(t);
      }
    }
    // Unread sorted by existing urgency-rank/importance/activityAt
    // tiebreaker (preserve current ordering for parity with the legacy
    // unread cluster).
    unread.sort((a, b) {
      final urgencyCmp = a.urgencyRank.compareTo(b.urgencyRank);
      if (urgencyCmp != 0) return urgencyCmp;
      final importanceCmp = b.importance.compareTo(a.importance);
      if (importanceCmp != 0) return importanceCmp;
      return b.activityAt.compareTo(a.activityAt);
    });
    // Done already arrives in activityAt-desc order from the reverse
    // feed; preserve.

    final items = <AgendaItem>[];

    if (active.isNotEmpty) {
      items.add(AgendaHeaderItem(
        text: ActivitySectionMarker.encode(ActivitySection.today),
      ));
      for (final t in active) {
        items.add(AgendaThreadItem(t));
      }
    }

    for (final d in scheduledDates) {
      items.add(AgendaHeaderItem(
        date: d,
        text: ActivitySectionMarker.encode(
          ActivitySection.scheduled,
          label: relativeDateLabel(d),
        ),
      ));
      for (final t in scheduledByDate[d]!) {
        items.add(AgendaThreadItem(t));
      }
    }

    if (unread.isNotEmpty) {
      items.add(AgendaHeaderItem(
        text: ActivitySectionMarker.encode(ActivitySection.newSection),
      ));
      for (final t in unread) {
        items.add(AgendaThreadItem(t));
      }
    }

    if (done.isNotEmpty) {
      items.add(AgendaHeaderItem(
        text: ActivitySectionMarker.encode(ActivitySection.done),
      ));
      for (final t in done) {
        items.add(AgendaThreadItem(t));
      }
    }

    emit(
      state.copyWith(
        activityFeedItems: items,
        activityFeedDoneEnd: _activityFeedDoneEnd,
        activityFeedLoaded: true,
      ),
    );
  }
```

Add the imports at the top of `priority.dart`:

```dart
import 'package:plot/state/activity_section.dart';
```

- [ ] **Step 3: Update `AgendaHeader` rendering to handle the marker**

In `apps/plot/lib/widget/agenda.dart`, find `AgendaHeader.build`'s text resolution. **DO NOT modify `agenda.dart`** — instead, render the activity feed section header in `_buildActivityFeed` (`page/priority.dart`) by intercepting the header item and stripping the marker before passing to `AgendaHeader`:

In `apps/plot/lib/page/priority.dart`, in `_buildActivityFeed`'s `builder` closure, replace the `header: (header) {` branch (~line 2818):

```dart
              header: (header) {
                String displayText = header.text ?? '';
                final marker = displayText.isEmpty
                    ? null
                    : ActivitySectionMarker.tryDecode(displayText);
                if (marker != null) displayText = marker.label;
                return [
                  AgendaHeader(
                    priorityContext: state.context,
                    dateTimeRange: header.dateTimeRange,
                    date: header.date,
                    now: header.now,
                    thread: header.thread,
                    focusNode: focusNode,
                    text: displayText,
                    scheduleAt: header.scheduleAt,
                  ),
                ];
              },
```

Add the import at the top of `page/priority.dart`:

```dart
import 'package:plot/state/activity_section.dart';
```

- [ ] **Step 4: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/state/priority.dart lib/page/priority.dart`
Expected: No errors.

- [ ] **Step 5: Manual visual smoke**

The Flutter app is already running with hot reload. Navigate to a priority and confirm:
- Today section appears at top with todos (when any are todo with sentinel/today)
- Tomorrow / weekday / "MMM d" sections appear for future-scheduled todos
- New section shows unread non-todo threads
- Done section shows the rest

If Today/Scheduled is empty, the New/Done sections still render correctly.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/priority.dart apps/plot/lib/page/priority.dart
git commit -m "$(cat <<'EOF'
Restructure Activity tab into Today / Scheduled / New / Done sections

The Activity feed bloc now merges two streams (todo threads + reverse
chronological non-todo threads) into four sections per the new
taxonomy. Section headers carry an ActivitySectionMarker prefix so the
drag dispatcher can identify them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Wrap each `_ActivityFeedItem` with a `Draggable<BlockDragPayload>`

**Files:**
- Modify: `apps/plot/lib/page/priority.dart` — `_ActivityFeedItem` and the surrounding builder.

- [ ] **Step 1: Convert `_ActivityFeedItem` to a draggable row**

In `apps/plot/lib/page/priority.dart`, replace the `_ActivityFeedItemState.build` method (~line 3168) with a version that wraps the result in a `Draggable<BlockDragPayload>`:

```dart
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Thread?>(
      future: _representative,
      builder: (context, snapshot) {
        final rep = snapshot.data;
        final display = rep ?? widget.baseThread;
        final core = ThreadWidget(
          key: ValueKey(
            'feed_activitywidget_${widget.baseThread.id}_'
            '${rep?.scheduleId ?? widget.baseThread.scheduleId}',
          ),
          activity: display,
          selected: widget.selected,
          now: widget.now,
          focusNode: widget.focusNode,
          context: widget.priorityContext,
          showSubPriority: true,
          bump: false,
          showEventTiming: rep != null,
        );
        return _ActivityFeedDraggableRow(
          threadId: widget.baseThread.id,
          priorityContext: widget.priorityContext,
          parentBlockId: widget.baseThread.id.toString(),
          child: core,
        );
      },
    );
  }
```

- [ ] **Step 2: Add `_ActivityFeedDraggableRow`**

Append at the bottom of `apps/plot/lib/page/priority.dart`:

```dart
class _ActivityFeedDraggableRow extends StatefulWidget {
  const _ActivityFeedDraggableRow({
    required this.threadId,
    required this.priorityContext,
    required this.parentBlockId,
    required this.child,
  });

  final ThreadId threadId;
  final Priority priorityContext;
  final String parentBlockId;
  final Widget child;

  @override
  State<_ActivityFeedDraggableRow> createState() =>
      _ActivityFeedDraggableRowState();
}

class _ActivityFeedDraggableRowState
    extends State<_ActivityFeedDraggableRow> {
  final GlobalKey _rowKey = GlobalKey();

  BlockDragPayload _payload() => BlockDragPayload(
        blockId: widget.parentBlockId,
        priorityId: widget.priorityContext.id,
        sourceDate: null,
        sourcePeriodStart: null,
        visibleThreadCount: 1,
      );

  void _onDragStarted() {
    final controller = BlockDragScope.maybeOf(context);
    controller?.start(
      _payload(),
      sourceContextProvider: () => _rowKey.currentContext ?? context,
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    BlockDragScope.maybeOf(context)?.updatePointer(details.globalPosition);
  }

  void _onDragEnd(DraggableDetails details) {
    BlockDragScope.maybeOf(context)?.end();
  }

  void _onDragCancelled() {
    BlockDragScope.maybeOf(context)?.end(dispatch: false);
  }

  @override
  Widget build(BuildContext context) {
    final source = KeyedSubtree(key: _rowKey, child: widget.child);
    final hidden = BlockDragHidden(
      parentBlockId: widget.parentBlockId,
      child: source,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final feedback = SizedBox(
          width: constraints.maxWidth,
          child: Material(
            type: MaterialType.transparency,
            child: widget.child,
          ),
        );
        if (hasPhysicalKeyboard()) {
          return Draggable<BlockDragPayload>(
            data: _payload(),
            feedback: feedback,
            childWhenDragging: hidden,
            onDragStarted: _onDragStarted,
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEnd,
            onDraggableCanceled: (_, _) => _onDragCancelled(),
            child: hidden,
          );
        }
        return LongPressDraggable<BlockDragPayload>(
          data: _payload(),
          feedback: feedback,
          childWhenDragging: hidden,
          onDragStarted: _onDragStarted,
          onDragUpdate: _onDragUpdate,
          onDragEnd: _onDragEnd,
          onDraggableCanceled: (_, _) => _onDragCancelled(),
          child: hidden,
        );
      },
    );
  }
}
```

Add imports at the top of `page/priority.dart` (if missing):

```dart
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/util/platform.dart' show hasPhysicalKeyboard;
```

(`Material` is from `flutter/widgets.dart`? No — it's from `flutter/material.dart`. Per `AGENTS.md`, never import material. **Substitute with a plain `Container` wrapper** if needed:

```dart
        final feedback = SizedBox(
          width: constraints.maxWidth,
          child: widget.child,
        );
```

— remove the `Material` wrapper entirely; the agenda's `_buildFeedback` doesn't use one either (see `apps/plot/lib/widget/agenda.dart:752`).)

- [ ] **Step 3: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart`
Expected: No errors. Fix any missing imports.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "$(cat <<'EOF'
Wrap Activity tab thread rows in Draggable<BlockDragPayload>

Threads in the activity feed can now be picked up; drag start/update/end
hooks delegate to BlockDragController. No drop targets are wired up yet
(next commit).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Compute drop boundaries and render `BlockDropZone`s in the Activity feed

**Files:**
- Modify: `apps/plot/lib/page/priority.dart` — `_buildActivityFeed` body.

- [ ] **Step 1: Add an Activity-feed boundary builder**

Append at the bottom of `apps/plot/lib/page/priority.dart`:

```dart
/// Walks the Activity tab item list and emits a [BlockDropTarget] for
/// each drop boundary (above each thread row, plus a tail per section).
///
/// Returns:
///   * `before[i]` — boundary rendered ABOVE item i (every thread row
///     and every section header gets one).
///   * `afterList` — boundary rendered after the last item in the list.
({
  Map<int, BlockDropTarget> before,
  BlockDropTarget? afterList,
}) computeActivityFeedDropBoundaries({
  required List<AgendaItem> items,
}) {
  final before = <int, BlockDropTarget>{};
  BlockDropTarget? afterList;

  ActivitySection? currentSection;
  Date? currentScheduledDate;
  String? prevThreadId;

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is AgendaHeaderItem) {
      final marker = item.text == null
          ? null
          : ActivitySectionMarker.tryDecode(item.text!);
      if (marker != null) {
        // Emit a boundary above the section header so users can drop
        // at the very top of a section even when it's preceded by
        // another section's last row.
        before[i] = BlockDropTarget(
          targetDate: marker.section == ActivitySection.scheduled
              ? item.date
              : null,
          targetPeriodStart: null,
          prevBlockId: prevThreadId,
          prevPriorityId: null,
          nextBlockId: null,
          nextPriorityId: null,
        );
        currentSection = marker.section;
        currentScheduledDate = item.date;
        prevThreadId = null;
      }
      continue;
    }
    if (item is AgendaThreadItem) {
      final section = currentSection;
      if (section == null) continue;
      final threadIdStr = item.thread.id.toString();
      before[i] = BlockDropTarget(
        targetDate: section == ActivitySection.scheduled
            ? currentScheduledDate
            : null,
        targetPeriodStart: null,
        prevBlockId: prevThreadId,
        prevPriorityId: null,
        nextBlockId: threadIdStr,
        nextPriorityId: null,
      );
      prevThreadId = threadIdStr;
    }
  }

  if (prevThreadId != null && currentSection != null) {
    afterList = BlockDropTarget(
      targetDate: currentSection == ActivitySection.scheduled
          ? currentScheduledDate
          : null,
      targetPeriodStart: null,
      prevBlockId: prevThreadId,
      prevPriorityId: null,
      nextBlockId: null,
      nextPriorityId: null,
    );
  }

  return (before: before, afterList: afterList);
}
```

- [ ] **Step 2: Wrap `_buildActivityFeed` in a `BlockDragScope`**

In `apps/plot/lib/page/priority.dart`, modify `_buildActivityFeed` to provide a `BlockDragScope` and a `BlockDragController`. Add a lazy-init field on the enclosing `_PriorityPageState`:

```dart
  final BlockDragController _activityFeedDragController =
      BlockDragController();
```

In `dispose()` of that state class, add `_activityFeedDragController.dispose();`. Then in `_buildActivityFeed`, change the return to:

```dart
    return BlockDragScope(
      controller: _activityFeedDragController,
      child: InfiniteList(
        ... (existing args)
      ),
    );
```

If `_PriorityPageState` does not exist with this exact name, locate the State subclass that owns `_buildActivityFeed` (search for `_buildActivityFeed`) and add the field there.

- [ ] **Step 3: Render `BlockDropZone`s in the builder**

Replace the existing `builder: (context, index, focusNode, ...)` body of the InfiniteList with a wrapper that renders the `BlockDropZone` *above* the row:

Modify the body (around `if (index < 0 || index >= totalCount)` to the `return Column(...)`):

```dart
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= totalCount) {
          return null;
        }
        if (index == footerIndex) {
          return _SearchFooter(state: state);
        }
        final current = displayItems[index];
        final boundaries =
            computeActivityFeedDropBoundaries(items: displayItems);
        final dropAbove = boundaries.before[index];

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(
            current.when(
              header: (h) => h.date != null
                  ? 'feed_header_date_${h.date}'
                  : 'feed_header_${h.text}',
              activity: (a) => 'feed_activity_${a.thread.id}',
            ),
          ),
          children: [
            if (dropAbove != null)
              BlockDropZone(
                target: dropAbove,
                slotKey: 'feed_drop_above_$index',
              ),
            ...current.when(
              header: (header) {
                ... (existing header rendering with marker stripping)
              },
              activity: (agendaActivity) {
                ... (existing activity rendering)
              },
            ),
          ],
        );
      },
```

After the InfiniteList returns the last item, render the trailing `afterList` boundary as a footer if non-null. The simplest path: wrap the `InfiniteList` in a `Column` and append a trailing `BlockDropZone` whose key is `'feed_drop_tail'`.

Pull `boundaries` out of the per-item builder so it's computed once per build:

```dart
    final boundaries =
        computeActivityFeedDropBoundaries(items: displayItems);
```

— place it just above the `return BlockDragScope(...)` call. Use `boundaries.before[index]` inside the builder. Append `BlockDropZone` for `boundaries.afterList` after the list (if non-null).

- [ ] **Step 4: Wire the `previewBuilder` so the active drop zone shows a dimmed copy of the dragged thread**

Inside `_buildActivityFeed`, after `final boundaries = ...`, set:

```dart
    _activityFeedDragController.previewBuilder = (payload) {
      Thread? source;
      for (final item in displayItems) {
        if (item is AgendaThreadItem &&
            item.thread.id.toString() == payload.blockId) {
          source = item.thread;
          break;
        }
      }
      if (source == null) return null;
      return ThreadWidget(
        activity: source,
        selected: false,
        now: false,
        focusNode: FocusNode(skipTraversal: true),
        context: state.context,
        showSubPriority: true,
        bump: false,
        showEventTiming: false,
      );
    };
```

- [ ] **Step 5: Verify analyzer + visual smoke**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart`
Expected: No errors.

Visual smoke (hot reload): pick up a thread row. Confirm the dragged feedback floats under the cursor, the source row dims/collapses, and `BlockDropZone` gaps appear between rows when the cursor hovers near them.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "$(cat <<'EOF'
Render BlockDropZones between Activity feed rows

Drop boundaries are emitted above each thread/header and after the last
item. The activity feed dragController shares BlockDragController with
the agenda's drop infrastructure, including the height-conserving
slot expansion.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Implement the drop dispatcher (state + order mutations per target section)

**Files:**
- Create: `apps/plot/lib/widget/thread_drag_dispatcher.dart`
- Modify: `apps/plot/lib/state/priority.dart` — add `applyActivityFeedThreadDrop`.

- [ ] **Step 1: Add `applyActivityFeedThreadDrop` on `PriorityBloc`**

In `apps/plot/lib/state/priority.dart`, add:

```dart
  /// Apply an Activity-feed drag-and-drop. Decodes the target's section
  /// and applies the right state transition + intra-section order.
  ///
  /// Section transitions:
  ///   * Today      → todo=true, schedule = todoNowDate sentinel
  ///   * Scheduled  → todo=true, schedule.startOn = targetDate
  ///   * New        → unread=true, archive user schedule
  ///   * Done       → unread=false, archive user schedule
  ///
  /// Intra-section order is computed from prev/next thread orders
  /// (fractional indexing). For New/Done where threads have no
  /// `userSchedule.order`, the drop simply mutates state — the
  /// resulting display order is governed by the bloc's existing sort.
  Future<void> applyActivityFeedThreadDrop({
    required ThreadId draggedId,
    required ActivitySection targetSection,
    required Date? targetScheduledDate,
    required ThreadId? prevId,
    required ThreadId? nextId,
  }) async {
    final dragged = (_todoThreads
            .followedBy(_activityFeedRawThreads))
        .where((t) => t.id == draggedId)
        .firstOrNull;
    if (dragged == null) return;

    // Compute order from neighbours when both have user-schedule order
    // (Today / Scheduled sections). Otherwise default.
    Order? newOrder;
    if (targetSection == ActivitySection.today ||
        targetSection == ActivitySection.scheduled) {
      Thread? above;
      Thread? below;
      if (prevId != null) {
        above = (_todoThreads)
            .where((t) => t.id == prevId)
            .firstOrNull;
      }
      if (nextId != null) {
        below = (_todoThreads)
            .where((t) => t.id == nextId)
            .firstOrNull;
      }
      newOrder = Order.between(
        above?.order,
        below?.order,
      );
    }

    Thread updated;
    switch (targetSection) {
      case ActivitySection.today:
        updated = dragged.asActiveToday(order: newOrder);
        break;
      case ActivitySection.scheduled:
        if (targetScheduledDate == null) return;
        updated = dragged.asScheduled(
          targetScheduledDate,
          order: newOrder,
        );
        break;
      case ActivitySection.newSection:
        updated = dragged.asUnread();
        break;
      case ActivitySection.done:
        updated = dragged.asInactive();
        break;
    }

    optimisticallyUpdateThread(updated);
    await updated.save();
    refreshAgenda();
  }
```

(The `Order.between` API exists; it lives in `apps/plot/lib/store/order.dart`. The `Thread.order` getter returns the user-schedule order — confirm with grep before using; if it's named differently, use the correct accessor.)

- [ ] **Step 2: Create `thread_drag_dispatcher.dart`**

```dart
import 'package:flutter/widgets.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/agenda_block_drag.dart';

/// Decodes a [BlockDropTarget] (emitted by the Activity feed boundary
/// builder) into a section-aware drop call on PriorityBloc. The target
/// carries `targetDate` for Scheduled drops; the section itself is
/// inferred from the surrounding context (the boundary builder marks
/// scheduled targets with a non-null targetDate; everything else maps
/// to the section based on `prevBlockId`/`nextBlockId` lookups).
///
/// Pure: takes the bloc, the items list (so the section of each prev/
/// next id can be recovered), and the payload+target.
void dispatchActivityFeedThreadDrop({
  required PriorityBloc bloc,
  required List<AgendaItem> items,
  required BlockDragPayload payload,
  required BlockDropTarget target,
}) {
  // Find the target section by walking items: the section of the slot
  // is the section of the most recent header at-or-before the slot's
  // prevBlockId (or the first header if prevBlockId is null).
  ActivitySection? section;
  Date? scheduledDate;
  String? prevBlockId = target.prevBlockId;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is AgendaHeaderItem) {
      final marker = item.text == null
          ? null
          : ActivitySectionMarker.tryDecode(item.text!);
      if (marker != null) {
        section = marker.section;
        scheduledDate = item.date;
      }
    } else if (item is AgendaThreadItem) {
      if (prevBlockId != null &&
          item.thread.id.toString() == prevBlockId) {
        // Slot is just below this thread; its section is the most
        // recent header above (already tracked).
        break;
      }
    }
  }
  // If prevBlockId is null, the slot is at the top of a section — the
  // first header we encountered while walking is our section. (We
  // continued past it into items; this is fine.)
  // If section couldn't be identified, no-op.
  if (section == null) return;

  final draggedId = ThreadId.fromString(payload.blockId);
  final prevId = prevBlockId == null
      ? null
      : ThreadId.fromString(prevBlockId);
  final nextId = target.nextBlockId == null
      ? null
      : ThreadId.fromString(target.nextBlockId!);

  bloc.applyActivityFeedThreadDrop(
    draggedId: draggedId,
    targetSection: section,
    targetScheduledDate: scheduledDate,
    prevId: prevId,
    nextId: nextId,
  );
}
```

(`ThreadId.fromString` may not exist with that exact name. The actual constructor is likely `ThreadId(uuidString)` — check via `grep "class ThreadId\|typedef ThreadId" apps/plot/lib/store/`. Adjust the call to match.)

- [ ] **Step 3: Wire the dispatcher in `_buildActivityFeed`**

In `apps/plot/lib/page/priority.dart`, just before `return BlockDragScope(...)`, set:

```dart
    _activityFeedDragController.dispatcher = (payload, target) {
      dispatchActivityFeedThreadDrop(
        bloc: bloc,
        items: displayItems,
        payload: payload,
        target: target,
      );
    };
```

Add the import:

```dart
import 'package:plot/widget/thread_drag_dispatcher.dart';
```

- [ ] **Step 4: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/state/priority.dart lib/page/priority.dart lib/widget/thread_drag_dispatcher.dart`
Expected: No errors. Address any type mismatches around `ThreadId` construction by inspecting the actual definition.

- [ ] **Step 5: Visual smoke — drag through every section pair**

With hot reload:

1. Drag a thread from Done → Today. Expect: `todo=true`, sentinel set, thread re-renders under Today.
2. Drag from Today → Done. Expect: `todo=false`, thread under Done.
3. Drag from Today → Tomorrow header (or whatever scheduled date). Expect: `todo=true`, `userSchedule.startOn=tomorrow`, thread under Tomorrow.
4. Drag from Done → New. Expect: `unread=true`, thread under New.
5. Drag from New → Today. Expect: `unread` may auto-clear via the engagement path; thread under Today.
6. Within Today: reorder two threads. Expect: order persists after refresh.

If any of these fail, debug the `applyActivityFeedThreadDrop` switch.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/priority.dart apps/plot/lib/widget/thread_drag_dispatcher.dart apps/plot/lib/page/priority.dart
git commit -m "$(cat <<'EOF'
Dispatch Activity-feed drag drops to bloc state mutations

Section-aware: dropping into Today/Scheduled/New/Done applies the
right combination of todo/unread/userSchedule changes. Intra-section
reorder uses fractional Order between neighbour threads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Bump dropped-into-Done threads to top via `bumpedAt`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` — `asInactive` helper.

The spec says: "It's okay if threads dropped to Done always appear at the top unless it's easy enough to place them in the order where they're dropped." Setting `bumpedAt = now()` on `asInactive` is the easiest path to "appears at the top of Done."

- [ ] **Step 1: Update `asInactive` to bump**

Replace the body of `asInactive` (added in Task 4) with:

```dart
  Thread asInactive() {
    final base = _userSchedule == null
        ? this
        : _withUserSchedule(
            _userSchedule.copyWith(
              archivedAt: Value(DateTime.now()),
              updatedAt: DateTime.now(),
            ),
          );
    return base.copyWith(unread: false, bumpedAt: Value(DateTime.now()));
  }
```

- [ ] **Step 2: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors. If `bumpedAt` isn't a writable column on `copyWith`, look at how the existing `bump=true` flag in `FinishThread` mutates it and replicate the pattern.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "$(cat <<'EOF'
Bump dropped-into-Done threads to top of Done section

Sets bumpedAt=now() so the activity feed's chronological sort places
the thread above older Done items, matching the user expectation when
dragging-to-Done.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Update docs

**Files:**
- Modify: `docs/features.md`
- Modify: `docs/updates.md`

- [ ] **Step 1: Update `docs/features.md`**

Find the section that describes priorities / threads / activity views and add (or update) a paragraph describing the four sections plus drag-and-drop. The Activity tab is the consolidated home for thread management; users see Today (active), per-day Scheduled, New (unread), and Done. Threads can be dragged within and between sections; dropping a thread into a section assigns the appropriate state (today, a scheduled day, unread, or done).

- [ ] **Step 2: Update `docs/updates.md`**

Add a bullet at the top of the in-progress section (above the most recent `---` divider):

```
- The Activity tab is now the home for managing threads on a priority. Threads are organized into Today, Scheduled (Tomorrow / Friday / etc.), New, and Done sections. Drag a thread between sections to move it — drop on Today to work on it now, on a future day to schedule it, on New to mark it unread, or on Done to finish.
- Renamed the agenda commands: "Add to agenda" is now "Do today" and "Remove from agenda" is now "Finish".
```

- [ ] **Step 3: Commit**

```bash
git add docs/features.md docs/updates.md
git commit -m "$(cat <<'EOF'
Document Activity-tab consolidation and drag-and-drop

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Run `/finalize` checks

- [ ] **Step 1: Lint**

Run: `cd apps/plot && flutter analyze`
Expected: Clean. Fix any lingering analyzer issues across the modified files.

- [ ] **Step 2: Backwards compatibility check**

The new code only adds fields/getters/methods — no removed/renamed fields on synced models. Confirm by `git diff main -- apps/plot/lib/store/thread.dart` shows only additions to public API.

- [ ] **Step 3: Error capture**

Confirm any new `try/catch` blocks added for unexpected errors call `Tracker.captureException`. (None expected in this plan; `applyActivityFeedThreadDrop` catches no errors — `save()` errors propagate to the existing global handler.)

- [ ] **Step 4: Manual end-to-end smoke**

Walk through every drag transition documented in Task 10 Step 5 once more after all tasks land. Confirm:
- The dragged row collapses to zero while a slot expands.
- No oscillation when hovering between adjacent rows.
- Drop persists across hot reload.
- Section labels show as "Today", "Tomorrow", "Friday" (or the actual weekday), "Apr 28", "New", "Done".
- Renamed commands ("Do today" / "Finish") show up in the leading icon's tooltip and command palette.

- [ ] **Step 5: Final commit (if any cleanup)**

If steps above produced fixes, commit as `Polish Activity-tab thread management` with the standard footer.

---

## Self-Review

**Spec coverage:**
- "Rename 'Add to agenda' → 'Do today' and 'Remove from agenda' → 'Finish'" → Task 2.
- "Use these clear terms in code, comments, and docs" → Tasks 1, 5, 12 establish active/scheduled/unread-only/inactive in Thread getters, ActivitySection enum, and docs.
- "Active threads are threads marked 'Do today' (sentinel) along with threads scheduled for past/today" → covered by `Thread.isActiveThread = todo && !isFuture` (Task 1), since `isFuture` returns false for sentinel and for past/today schedules.
- "Scheduled threads are threads scheduled for a future day" → `isScheduledThread = todo && isFuture`.
- "Unread threads are self explanatory" → `isUnreadOnly = unread && !todo`.
- "Inactive threads are none of the above" → `isInactiveThread = !todo && !unread`.
- "Sections: Today, New, relative dates, Done" → Task 7 emits exactly these section headers in this order.
- "Enable thread dragging using same techniques as agenda" → Tasks 8–9 reuse `BlockDragController` / `BlockDropZone` directly (the same height-conservation infrastructure).
- "Allow dragging within and between any of the sections" → Task 10's dispatcher handles every section combination via the switch.
- "Will require adding support for marking thread unread" → Task 3 adds `MarkUnreadThread`; Task 4 adds `Thread.asUnread()`.
- "Allow Done threads to be dragged elsewhere" → `_ActivityFeedDraggableRow` wraps every thread row regardless of section.
- "It's okay if threads dropped to Done always appear at the top" → Task 11 sets `bumpedAt=now()` on `asInactive`.

**Placeholder scan:** Tasks contain concrete code blocks for every implementation step. Comments referring to "look at the actual file" appear in Task 6 Step 1 and Task 10 Step 1 — these are intentional because the helper signatures depend on existing private factoring; the engineer can adapt without ambiguity.

**Type consistency:** `ActivitySection`, `BlockDragPayload`, `BlockDropTarget`, `Thread.todoCompareTo`, `Order.between`, `_userSchedule.order`, `Value` are referenced consistently. The `ThreadId` construction in Task 10 Step 2 has an explicit "verify the constructor name" note.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-05-09-activity-tab-thread-management.md`.
