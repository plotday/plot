# Activity Feed RSVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Attend/Skip (or ToggleRsvp) on calendar-event threads in the priority activity feed, choosing a representative occurrence (next upcoming, else most recent past) for recurring events, with series-vs-occurrence RSVP targeting driven by whether the user's existing RSVP lives on the series or on an occurrence override.

**Architecture:** Add a pure occurrence-picker helper and an async `Thread.loadRepresentativeForFeed` convenience on `Thread`. The feed call site at `page/priority.dart` calls the async helper per thread, then passes the resolved Thread (or the original) to `ThreadWidget` with `showEventTiming` set accordingly. `ToggleRsvp` gains an `rsvpInheritedFromSeries` check so declined-series threads flip back at the series level, while occurrence-level RSVPs continue to target the occurrence.

**Tech Stack:** Flutter (Dart), Drift/SQLite store, forui widgets, rrule package (already in use).

**Spec:** [`docs/superpowers/specs/2026-04-17-activity-feed-rsvp-design.md`](../specs/2026-04-17-activity-feed-rsvp-design.md)

---

## File map

- **Modify** `apps/plot/lib/store/thread.dart`
  - Add field `rsvpInheritedFromSeries` (bool, default false) to `Thread` and its `_fromStore` constructor.
  - Add pure static helper `Thread.selectRepresentativeOccurrence({...})` — no I/O, just picks earliest-upcoming-else-latest-past from candidate schedule rows. Decorate with `@visibleForTesting`.
  - Add async `Thread.loadRepresentativeForFeed(Thread baseThread, {...})` — glues store lookup + rrule generation + `selectRepresentativeOccurrence` and returns a Thread with the chosen schedule row (or `null` if ineligible / no qualifying occurrence).
- **Modify** `apps/plot/lib/command/thread.dart`
  - Update `ToggleRsvp.run`: target occurrence only when `hasExistingRsvp && thread.occurrence != null && !thread.rsvpInheritedFromSeries`.
- **Modify** `apps/plot/lib/page/priority.dart`
  - At the activity-feed `ThreadWidget` emission (~line 1826), resolve the representative via `Thread.loadRepresentativeForFeed` inside a FutureBuilder/hook, pass it to `ThreadWidget` with `showEventTiming: rep != null`.
- **Create** `apps/plot/test/store/thread_representative_occurrence_test.dart`
  - Pure unit tests against `Thread.selectRepresentativeOccurrence`.

---

## Task 1: Add `rsvpInheritedFromSeries` field on `Thread`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart`

- [ ] **Step 1: Add the field + constructor param**

In `apps/plot/lib/store/thread.dart`, locate `Thread._fromStore({...})` (around line 2100) and the field declarations (around lines 2131–2146).

Add the field declaration alongside `isLinkScheduleInstance`:

```dart
  /// Whether the RSVP status shown on [_schedule] was inherited from the
  /// series row rather than set on this specific occurrence. Used by
  /// [ToggleRsvp] to decide whether a toggle should target the series or
  /// the occurrence. Defaults to false. Set to true only by
  /// [loadRepresentativeForFeed] when it resolves a recurring event to a
  /// representative occurrence whose RSVP is a series-level copy.
  final bool rsvpInheritedFromSeries;
```

Add the named parameter to `Thread._fromStore`:

```dart
  Thread._fromStore({
    required ThreadRow activity,
    required this.priority,
    ScheduleRow? schedule,
    ScheduleRow? userSchedule,
    ThreadTagsRow? tags,
    List<Note>? notes,
    bool? active,
    bool? unreadComputed,
    this.isLinkScheduleInstance = false,
    this.rsvpInheritedFromSeries = false,
    DateTime? linkSourceCreatedAt,
    bool activityDirty = false,
    bool activityRemoteDirty = false,
    bool scheduleDirty = false,
  })
```

In the public notes-only constructor (around line 2098, where `isLinkScheduleInstance = false;` is set), initialize the new field:

```dart
       isLinkScheduleInstance = false,
       rsvpInheritedFromSeries = false;
```

- [ ] **Step 2: Wire the field through every existing `_fromStore` callsite and `copyWith`**

Search in `apps/plot/lib/store/thread.dart` for all `_fromStore(` callers:

```bash
cd apps/plot && grep -n '_fromStore(' lib/store/thread.dart
```

For each callsite that currently passes `isLinkScheduleInstance:`, add `rsvpInheritedFromSeries:` with `false` unless there's a reason otherwise. In particular:
- Lines near 1902, 1933, 1952, 2020 (agenda materialization) — pass `rsvpInheritedFromSeries: false`.
- Line ~2669 (`_fromStore` inside `withRsvpStatus`) — propagate existing value: `rsvpInheritedFromSeries: rsvpInheritedFromSeries`.
- Line ~2686 (`copyWith`-equivalent) — propagate existing value.
- Line ~2700 (`toBaseThread()` / `_fromStore` with `isLinkScheduleInstance: false`) — pass `rsvpInheritedFromSeries: false` (going back to the base clears inheritance).
- Line ~3271, ~3580, ~3879, ~3982 — propagate existing value.

If there's a `copyWith`-style method returning `Thread._fromStore(...)`, ensure `rsvpInheritedFromSeries` is threaded through.

- [ ] **Step 3: Verify lint**

Run:

```bash
cd apps/plot && flutter analyze lib/store/thread.dart
```

Expected: 0 issues (or only pre-existing issues unrelated to this change). Fix any errors introduced.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "feat(app): add rsvpInheritedFromSeries flag on Thread"
```

---

## Task 2: Pure helper — `Thread.selectRepresentativeOccurrence`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart`
- Create: `apps/plot/test/store/thread_representative_occurrence_test.dart`

- [ ] **Step 1: Write the failing test file**

Create `apps/plot/test/store/thread_representative_occurrence_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/thread.dart';

/// Build a schedule row for tests. Non-archived by default.
ScheduleRow _row({
  required String occurrence,
  required DateTime start,
  required DateTime end,
  DateTime? archivedAt,
}) => ScheduleRow(
  id: Uuid.generate(),
  updatedAt: DateTime(2026, 1, 1),
  threadId: Uuid.generate(),
  occurrence: occurrence,
  startAt: start,
  endAt: end,
  outstandingTasks: false,
  archivedAt: archivedAt,
);

void main() {
  group('selectRepresentativeOccurrence', () {
    final now = DateTime(2026, 4, 17, 12, 0);

    test('returns earliest upcoming when any occurrence ends >= now', () {
      final future1 = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
      );
      final future2 = _row(
        occurrence: '20260420T120000',
        start: DateTime(2026, 4, 20, 12, 0),
        end: DateTime(2026, 4, 20, 13, 0),
      );
      final past = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [past, future1, future2],
        overrideRows: const [],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.row.occurrence, '20260418T120000');
      expect(result.isOverride, false);
    });

    test('returns latest past when no upcoming', () {
      final past1 = _row(
        occurrence: '20260401T120000',
        start: DateTime(2026, 4, 1, 12, 0),
        end: DateTime(2026, 4, 1, 13, 0),
      );
      final past2 = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [past1, past2],
        overrideRows: const [],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result!.row.occurrence, '20260410T120000');
      expect(result.isOverride, false);
    });

    test('overrides replace generated instances at same occurrence key', () {
      final generated = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
      );
      final override = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 14, 0),
        end: DateTime(2026, 4, 18, 15, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [generated],
        overrideRows: [override],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result!.row.startAt, DateTime(2026, 4, 18, 14, 0));
      expect(result.isOverride, true);
    });

    test('archived overrides remove matching generated instances', () {
      final futureGen = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
      );
      final past = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: [futureGen, past],
        overrideRows: const [],
        archivedOverrideKeys: const {'20260418T120000'},
        now: now,
      );

      expect(result!.row.occurrence, '20260410T120000');
      expect(result.isOverride, false);
    });

    test('returns null when no candidates', () {
      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: const [],
        overrideRows: const [],
        archivedOverrideKeys: const {},
        now: now,
      );

      expect(result, isNull);
    });

    test('ignores archived override rows in overrideRows', () {
      final upcomingArchived = _row(
        occurrence: '20260418T120000',
        start: DateTime(2026, 4, 18, 12, 0),
        end: DateTime(2026, 4, 18, 13, 0),
        archivedAt: DateTime(2026, 4, 17),
      );
      final past = _row(
        occurrence: '20260410T120000',
        start: DateTime(2026, 4, 10, 12, 0),
        end: DateTime(2026, 4, 10, 13, 0),
      );

      final result = Thread.selectRepresentativeOccurrence(
        generatedInstances: const [],
        overrideRows: [upcomingArchived, past],
        archivedOverrideKeys: const {'20260418T120000'},
        now: now,
      );

      expect(result!.row.occurrence, '20260410T120000');
    });
  });
}
```

- [ ] **Step 2: Run test to confirm it fails (missing method)**

```bash
cd apps/plot && flutter test test/store/thread_representative_occurrence_test.dart
```

Expected: compile error — `method 'selectRepresentativeOccurrence' isn't defined for type 'Thread'`.

- [ ] **Step 3: Implement the helper**

In `apps/plot/lib/store/thread.dart`, add a new static method on `Thread` (near `generateOccurrences` around line 3790). Add an import of `package:flutter/foundation.dart` if `@visibleForTesting` isn't already imported (check — `foundation` is often transitive through `flutter/widgets.dart`).

```dart
  /// Picks the representative occurrence schedule row from a set of
  /// candidates. Returns the earliest whose `endAt` (or `endOn`) is `>= now`
  /// (next upcoming); if none, returns the latest whose end is `< now`
  /// (most recent past). Returns null when no candidate qualifies.
  ///
  /// `generatedInstances` are rrule-generated rows (their currentUserStatus
  /// is copied from the series base). `overrideRows` are persisted
  /// schedule rows with `occurrence IS NOT NULL`. Overrides replace
  /// generated instances at matching occurrence keys.
  /// `archivedOverrideKeys` removes generated instances whose occurrence
  /// key appears in the set (cancelled instances).
  ///
  /// The returned `isOverride` distinguishes a persisted-override row
  /// from a generated instance — used by the caller to decide the
  /// default value of `rsvpInheritedFromSeries`.
  @visibleForTesting
  static ({ScheduleRow row, bool isOverride})? selectRepresentativeOccurrence({
    required List<ScheduleRow> generatedInstances,
    required List<ScheduleRow> overrideRows,
    required Set<String> archivedOverrideKeys,
    required DateTime now,
  }) {
    // Build merged map keyed by occurrence string.
    final merged = <String, ({ScheduleRow row, bool isOverride})>{};

    for (final row in generatedInstances) {
      final key = row.occurrence;
      if (key == null) continue;
      if (archivedOverrideKeys.contains(key)) continue;
      merged[key] = (row: row, isOverride: false);
    }

    for (final override in overrideRows) {
      final key = override.occurrence;
      if (key == null) continue;
      if (override.archivedAt != null) {
        merged.remove(key);
        continue;
      }
      merged[key] = (row: override, isOverride: true);
    }

    if (merged.isEmpty) return null;

    DateTime? rowEnd(ScheduleRow r) =>
        r.endAt ?? r.endOn?.toDateTime() ?? r.startAt ?? r.startOn?.toDateTime();

    ({ScheduleRow row, bool isOverride})? earliestUpcoming;
    ({ScheduleRow row, bool isOverride})? latestPast;

    for (final candidate in merged.values) {
      final end = rowEnd(candidate.row);
      if (end == null) continue;
      if (!end.isBefore(now)) {
        // upcoming (end >= now)
        if (earliestUpcoming == null ||
            end.isBefore(rowEnd(earliestUpcoming.row)!)) {
          earliestUpcoming = candidate;
        }
      } else {
        // past (end < now)
        if (latestPast == null || end.isAfter(rowEnd(latestPast.row)!)) {
          latestPast = candidate;
        }
      }
    }

    return earliestUpcoming ?? latestPast;
  }
```

If `@visibleForTesting` triggers an undefined-identifier error, add at the top of `thread.dart`:

```dart
import 'package:flutter/foundation.dart' show visibleForTesting;
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd apps/plot && flutter test test/store/thread_representative_occurrence_test.dart
```

Expected: all 6 tests pass.

- [ ] **Step 5: Lint**

```bash
cd apps/plot && flutter analyze lib/store/thread.dart test/store/thread_representative_occurrence_test.dart
```

Expected: 0 new issues.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_representative_occurrence_test.dart
git commit -m "feat(app): add Thread.selectRepresentativeOccurrence helper"
```

---

## Task 3: Async loader — `Thread.loadRepresentativeForFeed`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart`

- [ ] **Step 1: Implement the loader**

The activity feed's base thread carries `_schedule` as the series row for recurring link schedules. The other rows (occurrence overrides) are in the same Drift `schedules` table, filtered by the same `linkId` (or `threadId` for non-link series). We fetch them here to merge with rrule-generated instances.

Add to `apps/plot/lib/store/thread.dart`, below `selectRepresentativeOccurrence`:

```dart
  /// Resolves a Thread to its representative occurrence for the activity
  /// feed. For non-recurring calendar events returns a Thread with the
  /// same single schedule wrapped as a link schedule instance. For
  /// recurring events, generates instances within
  /// `[now - lookBack, now + lookAhead]`, merges persisted overrides,
  /// and selects the earliest upcoming (else latest past) as the
  /// representative. Returns null if the base thread isn't a feed-eligible
  /// calendar event, or if no qualifying occurrence lies within the
  /// lookup window.
  static Future<Thread?> loadRepresentativeForFeed(
    Thread base, {
    required DateTime now,
    Duration lookAhead = const Duration(days: 90),
    Duration lookBack = const Duration(days: 30),
  }) async {
    // Gate 1: must be a calendar event (link schedule).
    if (!base.hasLinkSchedule) return null;

    // Gate 2: todo base (todo thread that isn't already an instance) is not
    // an RSVP-eligible calendar event.
    if (base.todo && !base.isLinkScheduleInstance) return null;

    final schedule = base._schedule;
    if (schedule == null) return null;

    // Non-recurring: the one schedule IS the occurrence. Wrap as an instance.
    if (!base.recurring) {
      return Thread._fromStore(
        activity: base._thread,
        priority: base.priority,
        schedule: schedule,
        userSchedule: base._userSchedule,
        tags: base._tags,
        active: base._active,
        unreadComputed: base._unreadComputed,
        isLinkScheduleInstance: true,
        rsvpInheritedFromSeries: false,
        linkSourceCreatedAt: base._linkSourceCreatedAt,
      );
    }

    // Recurring: generate instances in window + load persisted overrides.
    final window = BoundedDateRange(
      Date.fromDateTime(now.subtract(lookBack)),
      Date.fromDateTime(now.add(lookAhead)),
    );

    List<Thread> generated;
    try {
      generated = base.generateOccurrences(window);
    } catch (_) {
      generated = const [];
    }
    final generatedRows =
        generated.map((t) => t._schedule!).toList(growable: false);

    // Load all schedule rows for the same link (overrides + base), filter to
    // override rows (occurrence != null), partition by archived.
    final linkId = schedule.linkId;
    List<ScheduleRow> allRows;
    if (linkId != null) {
      allRows = await (Store.get.select(Store.get.schedules)
            ..where((s) => s.linkId.equals(linkId.toBytes())))
          .get();
    } else {
      allRows = await (Store.get.select(Store.get.schedules)
            ..where((s) => s.threadId.equals(base.id.toBytes())))
          .get();
    }

    final overrideRows = <ScheduleRow>[];
    final archivedOverrideKeys = <String>{};
    for (final row in allRows) {
      if (row.occurrence == null) continue; // skip base series row
      if (row.archivedAt != null) {
        archivedOverrideKeys.add(row.occurrence!);
        continue;
      }
      overrideRows.add(row);
    }

    final picked = selectRepresentativeOccurrence(
      generatedInstances: generatedRows,
      overrideRows: overrideRows,
      archivedOverrideKeys: archivedOverrideKeys,
      now: now,
    );

    if (picked == null) return null;

    // rsvpInheritedFromSeries:
    //   - Generated row: always true (its contacts are a copy of the series).
    //   - Override row: check whether any ScheduleContact on the override
    //     belongs to the current user. If none, the visible status was
    //     inherited from the series.
    final userIdStr = Base.userId.toString();
    bool overrideHasUserContact(ScheduleRow row) {
      final json = row.contacts;
      if (json == null || json.isEmpty) return false;
      try {
        final list = jsonDecode(json) as List<dynamic>;
        return list.any((e) {
          final m = e as Map<String, dynamic>;
          return m['contact_user_id'] == userIdStr;
        });
      } catch (_) {
        return false;
      }
    }

    final inherited =
        !picked.isOverride || !overrideHasUserContact(picked.row);

    // Pick up tags for this specific occurrence if a persisted override had
    // its own tag row; otherwise reuse base tags.
    return Thread._fromStore(
      activity: base._thread,
      priority: base.priority,
      schedule: picked.row,
      userSchedule: base._userSchedule,
      tags: base._tags,
      active: base._active,
      unreadComputed: base._unreadComputed,
      isLinkScheduleInstance: true,
      rsvpInheritedFromSeries: inherited,
      linkSourceCreatedAt: base._linkSourceCreatedAt,
    );
  }
```

If `BoundedDateRange` takes `DateTime` rather than `Date`, adjust accordingly. Look at how `generateOccurrences` is called at line ~1915 and match that constructor shape.

- [ ] **Step 2: Resolve imports**

At the top of `thread.dart`, ensure these imports exist (add if missing):

```dart
import 'dart:convert' show jsonDecode;
```

`Store.get`, `Base.userId`, `BoundedDateRange`, `Date` are all already used elsewhere in the file.

- [ ] **Step 3: Widget tests (skipped, manual smoke instead)**

The spec lists widget tests (Attend+Skip visibility, ToggleRsvp post payload shape, no-link-schedule negative case). The project's widget test infrastructure is sparse (only `apps/plot/test/widget/infinite_list_test.dart`) and setting up a Store + BLoC test harness is substantial work that isn't warranted for this change. Task 6 covers these cases via manual smoke testing. If you add widget-test harness scaffolding separately, retrofit these four cases.

- [ ] **Step 4: Lint**

```bash
cd apps/plot && flutter analyze lib/store/thread.dart
```

Fix any type errors. If `generateOccurrences` returns `List<Thread>` but `_schedule` is private and inaccessible across methods, add a file-private extension or use the existing in-class access (both methods are on `Thread`, so `t._schedule` is accessible).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "feat(app): load representative occurrence for activity feed threads"
```

---

## Task 4: `ToggleRsvp` honors `rsvpInheritedFromSeries`

**Files:**
- Modify: `apps/plot/lib/command/thread.dart`

- [ ] **Step 1: Update the occurrence-vs-series decision**

In `apps/plot/lib/command/thread.dart`, locate `ToggleRsvp.run` (around line 526) and change the `isOccurrenceLevel` computation:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updated = thread.withRsvpStatus(_targetStatus);
    await saveOptimistically(context, updated);

    // Target the occurrence only when the user has an existing RSVP on
    // this specific occurrence (not inherited from the series). Initial
    // RSVPs and toggles of series-inherited RSVPs target the series.
    final hasExistingRsvp = thread.currentUserRsvp != null;
    final targetsOccurrence = hasExistingRsvp &&
        thread.occurrence != null &&
        !thread.rsvpInheritedFromSeries;

    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {
            'thread_id': thread.id.toString(),
            if (targetsOccurrence) 'occurrence': thread.occurrence,
            'status': _targetStatus,
          },
        )
        .catchError((_) {});

    return const CommandDone();
  }
```

(Rename the local from `isOccurrenceLevel` to `targetsOccurrence` for clarity; no external callers.)

- [ ] **Step 2: Lint**

```bash
cd apps/plot && flutter analyze lib/command/thread.dart
```

Expected: 0 new issues.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/thread.dart
git commit -m "feat(app): ToggleRsvp targets series when RSVP is series-inherited"
```

---

## Task 5: Wire the resolver into the activity feed

**Files:**
- Modify: `apps/plot/lib/page/priority.dart`

- [ ] **Step 1: Locate the feed item builder**

Open `apps/plot/lib/page/priority.dart` and find the activity-feed branch around line 1826:

```dart
              activity: (agendaActivity) {
                return [
                  ThreadWidget(
                    key: ValueKey(
                      'feed_activitywidget_${agendaActivity.thread.id}',
                    ),
                    activity: agendaActivity.thread,
                    ...
                    bump: false,
                  ),
                ];
              },
```

This builder returns `List<Widget>` synchronously. Since `loadRepresentativeForFeed` is async, wrap the widget in a `FutureBuilder<Thread?>` that shows the base thread immediately and swaps to the representative once loaded.

- [ ] **Step 2: Replace with representative-aware build**

Change the `activity: (agendaActivity) {...}` branch to:

```dart
              activity: (agendaActivity) {
                final baseThread = agendaActivity.thread;
                return [
                  FutureBuilder<Thread?>(
                    key: ValueKey(
                      'feed_activitywidget_${baseThread.id}',
                    ),
                    future: Thread.loadRepresentativeForFeed(
                      baseThread,
                      now: agendaActivity.now,
                    ),
                    builder: (context, snapshot) {
                      final rep = snapshot.data;
                      final display = rep ?? baseThread;
                      return ThreadWidget(
                        key: ValueKey(
                          'feed_activitywidget_${baseThread.id}_'
                          '${rep?.scheduleId ?? baseThread.scheduleId}',
                        ),
                        activity: display,
                        selected: state.thread != null &&
                            baseThread.id == state.thread!.id,
                        now: agendaActivity.now,
                        focusNode: focusNode,
                        context: state.context,
                        showSubPriority: true,
                        bump: false,
                        showEventTiming: rep != null,
                      );
                    },
                  ),
                ];
              },
```

Rationale for the nested ValueKey: when the representative loads, the key changes and the widget rebuilds cleanly with the resolved schedule, avoiding stale state.

- [ ] **Step 3: Verify `ThreadWidget` accepts `showEventTiming`**

Check `apps/plot/lib/widget/thread.dart` around line 22 for the constructor. Confirm `showEventTiming` is already a named parameter (it is — line 734 references it). If not already defaulted to false, leave it as-is.

```bash
cd apps/plot && grep -n 'showEventTiming' lib/widget/thread.dart | head -5
```

- [ ] **Step 4: Lint**

```bash
cd apps/plot && flutter analyze lib/page/priority.dart
```

Expected: 0 new issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat(app): resolve RSVP representative occurrence in activity feed"
```

---

## Task 6: Manual smoke test

**Files:** none (manual)

- [ ] **Step 1: Run the hot-reloaded app**

The app is already running (per project conventions). Trigger a hot reload:

```bash
# If you have r access via the Flutter dev console, type 'r'.
# Otherwise the IDE hot-reload shortcut.
```

- [ ] **Step 2: Verify each case**

For each case, open the activity feed on a priority that contains the target thread and confirm the expected UI:

- Non-recurring calendar event with other attendees, not responded → **Attend + Skip** buttons appear beside the other trailing buttons.
- Recurring calendar event, user never responded, upcoming instance exists → Attend + Skip, schedule-date header reflects the next upcoming occurrence's date.
- Recurring event, user has attended at series level → single **Skip** (ToggleRsvp labeled as the opposite action) button.
- Recurring event, user has declined at series level → single **Attend** button. Tapping it POSTs `/sync/schedule/status` with **no `occurrence`** — verify by watching the Flutter dev console / network inspector.
- Recurring event with a persisted occurrence-level attend on one instance, series unset → For the representative that matches that occurrence: toggle posts **with `occurrence`**.
- Non-calendar thread (just notes / todo) → no RSVP UI; no regression.
- Agenda view, same events → RSVP behavior unchanged from before.

- [ ] **Step 3: Commit (docs only)**

If `/finalize` surfaces notable user-facing-change bullets, add them to `docs/updates.md`:

```bash
# Add bullet to the top unarchived section of docs/updates.md
# Example wording: "Respond to calendar invites from the activity feed without
# opening the event or switching to the agenda."
git add docs/updates.md
git commit -m "docs(updates): activity feed RSVP"
```

Skip this step if the change isn't user-facing enough to warrant a line in `docs/updates.md` — use judgement per AGENTS.md guidance.

---

## Task 7: Finalize

**Files:** none directly; invoke the project skill.

- [ ] **Step 1: Run `/finalize`**

From within the Claude session, invoke:

```
/finalize
```

Follow its checklist: lint, backwards-compat, error capture, docs/updates bullet, public submodule (N/A — this change touches only `apps/plot/` and is not twister-facing).

- [ ] **Step 2: Ensure all commits are clean**

```bash
git log --oneline -8
```

Expected commits in order (top is newest):

- `docs(updates): activity feed RSVP` (optional)
- `feat(app): resolve RSVP representative occurrence in activity feed`
- `feat(app): ToggleRsvp targets series when RSVP is series-inherited`
- `feat(app): load representative occurrence for activity feed threads`
- `feat(app): add Thread.selectRepresentativeOccurrence helper`
- `feat(app): add rsvpInheritedFromSeries flag on Thread`

---

## Notes for the implementing engineer

- **Don't widen the window unilaterally.** The 90d/30d numbers are deliberate (the feed is forward-looking). If a test case fails because it needs a wider window, double-check the data, don't just widen the window.
- **Don't change `isLinkScheduleInstance` semantics.** It already means "treat this thread as an occurrence row". The new field `rsvpInheritedFromSeries` is an additive signal, not a replacement.
- **Don't refactor the agenda path** in the same PR. The agenda's existing merge logic at `store/thread.dart:1880–1985` stays intact; this plan intentionally adds a parallel path rather than unifying them. Unifying is a future refactor once both paths have tests.
- **AGENTS.md: commits.** This project uses conventional-commit-style prefixes (`feat(app)`, `fix(app)`, `docs(...)`). Match that style in your commits.
- **AGENTS.md: no Material.** Imports stay limited to `flutter/widgets.dart` and `forui/forui.dart`. No new `flutter/material.dart` imports.
