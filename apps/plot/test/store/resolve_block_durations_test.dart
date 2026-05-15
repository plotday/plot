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
        _row(effectiveAt: DateTime(2026, 5, 14, 9)), // duration null
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

    test('zero-duration rows are ignored', () {
      final blocks = [
        (id: 'a', start: DateTime(2026, 5, 14, 9)),
      ];
      final rows = [
        _row(effectiveAt: DateTime(2026, 5, 14, 9), duration: Duration.zero),
      ];
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: blocks,
        blocksForPriority: rows,
      );
      expect(result['a'], isNull,
          reason: 'zero is the same as no pending');
    });

    test('empty blocks list returns empty map', () {
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: const [],
        blocksForPriority: [
          _row(
            effectiveAt: DateTime(2026, 5, 14, 9),
            duration: const Duration(minutes: 30),
          ),
        ],
      );
      expect(result, isEmpty);
    });

    test('empty rows gives null for every block', () {
      final result = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: [(id: 'a', start: DateTime(2026, 5, 14, 9))],
        blocksForPriority: const [],
      );
      expect(result['a'], isNull);
    });
  });
}
