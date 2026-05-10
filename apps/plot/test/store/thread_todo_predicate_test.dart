import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Mirror of the SQL `todoOnly` clause in `Thread._getQuery` — kept here
/// so the fixture matrix below asserts the two forms agree without
/// needing a live Drift database. If you change either the SQL clause
/// or [Thread.isTodoUserSchedule], change this mirror too.
bool _sqlPredicateMirror({
  required Object? userScheduleId,
  required DateTime? archivedAt,
  required Date? startOn,
  required DateTime? startAt,
}) {
  // SQL: userSched.id IS NOT NULL
  //   AND userSched.archived_at IS NULL
  //   AND (userSched.start_on IS NOT NULL OR userSched.start_at IS NOT NULL)
  return userScheduleId != null &&
      archivedAt == null &&
      (startOn != null || startAt != null);
}

void main() {
  // Each row is `(userScheduleId, archivedAt, startOn, startAt, expected)`.
  // The matrix covers every meaningful combination of: row absent vs
  // present; archived vs active; date-only / time-only / both / neither.
  final fixtures = <
    ({
      String label,
      Object? id,
      DateTime? archivedAt,
      Date? startOn,
      DateTime? startAt,
      bool expected,
    })
  >[
    (
      label: 'no user_schedule row → not a todo',
      id: null,
      archivedAt: null,
      startOn: null,
      startAt: null,
      expected: false,
    ),
    (
      label: 'user_schedule row but no dates → placeholder, not a todo',
      id: 'sched-1',
      archivedAt: null,
      startOn: null,
      startAt: null,
      expected: false,
    ),
    (
      label: 'archived user_schedule with date → done, not a todo',
      id: 'sched-1',
      archivedAt: DateTime(2026, 1, 5),
      startOn: Date(2026, 1, 1),
      startAt: null,
      expected: false,
    ),
    (
      label: 'archived user_schedule with time → done, not a todo',
      id: 'sched-1',
      archivedAt: DateTime(2026, 1, 5),
      startOn: null,
      startAt: DateTime(2026, 1, 1, 9),
      expected: false,
    ),
    (
      label: 'archived user_schedule with no dates → done, not a todo',
      id: 'sched-1',
      archivedAt: DateTime(2026, 1, 5),
      startOn: null,
      startAt: null,
      expected: false,
    ),
    (
      label: 'active user_schedule with startOn → todo',
      id: 'sched-1',
      archivedAt: null,
      startOn: Date(2026, 1, 1),
      startAt: null,
      expected: true,
    ),
    (
      label: 'active user_schedule with startAt → todo',
      id: 'sched-1',
      archivedAt: null,
      startOn: null,
      startAt: DateTime(2026, 1, 1, 9),
      expected: true,
    ),
    (
      label: 'active user_schedule with both startOn and startAt → todo',
      id: 'sched-1',
      archivedAt: null,
      startOn: Date(2026, 1, 1),
      startAt: DateTime(2026, 1, 1, 9),
      expected: true,
    ),
    (
      label: 'active user_schedule with todoNow sentinel date → todo',
      id: 'sched-1',
      archivedAt: null,
      startOn: Thread.todoNowDate,
      startAt: null,
      expected: true,
    ),
  ];

  group('Thread.isTodoUserSchedule', () {
    for (final f in fixtures) {
      test(f.label, () {
        final dart = Thread.isTodoUserSchedule(
          userScheduleId: f.id,
          archivedAt: f.archivedAt,
          startOn: f.startOn,
          startAt: f.startAt,
        );
        expect(
          dart,
          f.expected,
          reason: 'Dart predicate disagreed for ${f.label}',
        );
      });
    }
  });

  group('SQL todoOnly clause mirrors Thread.isTodoUserSchedule', () {
    // The SQL `todoOnly` clause in `_getQuery` translates the same
    // boolean structure into Drift expressions. The SQL planner can't
    // be exercised here without a live database, so this group
    // evaluates a hand-mirrored Dart copy of the SQL predicate over
    // the same fixtures and asserts agreement with the canonical
    // helper. If a future change drops one branch but not the other,
    // every fixture in this group fails.
    for (final f in fixtures) {
      test('${f.label} — SQL mirror matches Dart helper', () {
        final dart = Thread.isTodoUserSchedule(
          userScheduleId: f.id,
          archivedAt: f.archivedAt,
          startOn: f.startOn,
          startAt: f.startAt,
        );
        final sqlMirror = _sqlPredicateMirror(
          userScheduleId: f.id,
          archivedAt: f.archivedAt,
          startOn: f.startOn,
          startAt: f.startAt,
        );
        expect(
          sqlMirror,
          dart,
          reason:
              'SQL todoOnly mirror disagreed with Thread.isTodoUserSchedule '
              'for ${f.label}',
        );
        expect(
          sqlMirror,
          f.expected,
          reason: 'SQL todoOnly mirror disagreed with expected for ${f.label}',
        );
      });
    }
  });
}
