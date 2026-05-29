import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Unit tests for [activeFocusBlockPriorityAt] — picks the priority whose
/// user-scheduled focus block (`priority_block` row with a positive
/// duration and a real time-of-day) covers a given moment. Mirrors the
/// agenda's focus-block selection: window is `[effectiveAt, effectiveAt +
/// duration)`, midnight-anchored and pre-today rows are ignored.
void main() {
  group('activeFocusBlockPriorityAt', () {
    final priorityA = Uuid.generate();
    final priorityB = Uuid.generate();
    final userId = Uuid.generate();

    PriorityBlockRow row({
      required Uuid priorityId,
      required DateTime at,
      Duration? duration,
      DateTime? archivedAt,
    }) =>
        PriorityBlockRow(
          id: Uuid.generate(),
          priorityId: priorityId,
          createdBy: userId,
          orderValue: Order(0),
          effectiveAt: at,
          duration: duration,
          archivedAt: archivedAt,
          createdAt: at,
          updatedAt: at,
        );

    test('no rows → null', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 12),
        blocksByPriority: const {},
      );
      expect(got, isNull);
    });

    test('moment before the block start → null', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 8),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1),
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('moment inside the block window → that priority', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 9, 30),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1),
            ),
          ],
        },
      );
      expect(got, priorityA);
    });

    test('moment exactly at the block start counts as inside', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 9),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1),
            ),
          ],
        },
      );
      expect(got, priorityA);
    });

    test('moment exactly at the block end is outside (end exclusive) → null',
        () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 10),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1),
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('moment after the block end → null (regression: no carry-forward)',
        () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 15),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1),
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('archived rows are ignored', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 9, 30),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1),
              archivedAt: DateTime(2026, 5, 1, 9, 15),
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('rows with null or non-positive duration are ignored', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 9, 30),
        blocksByPriority: {
          priorityA: [
            row(priorityId: priorityA, at: DateTime(2026, 5, 1, 9)),
            row(
              priorityId: priorityB,
              at: DateTime(2026, 5, 1, 9),
              duration: Duration.zero,
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('midnight-anchored rows are ignored (order anchors, not blocks)', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 9, 30),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1),
              duration: const Duration(hours: 12),
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('rows starting before the moment\'s local midnight are ignored', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 1),
        blocksByPriority: {
          priorityA: [
            // Started yesterday evening, nominally still running, but the
            // agenda only renders focus blocks anchored on or after today.
            row(
              priorityId: priorityA,
              at: DateTime(2026, 4, 30, 23),
              duration: const Duration(hours: 4),
            ),
          ],
        },
      );
      expect(got, isNull);
    });

    test('when two priorities both cover the moment, latest start wins', () {
      final got = activeFocusBlockPriorityAt(
        moment: DateTime(2026, 5, 1, 10, 30),
        blocksByPriority: {
          priorityA: [
            row(
              priorityId: priorityA,
              at: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 3), // 9–12, covers 10:30
            ),
          ],
          priorityB: [
            row(
              priorityId: priorityB,
              at: DateTime(2026, 5, 1, 10),
              duration: const Duration(hours: 1), // 10–11, started later
            ),
          ],
        },
      );
      expect(got, priorityB);
    });
  });
}
