import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Unit tests for [effectivePriorityOrderAt] — the timeline lookup that
/// resolves a priority's order at a given moment from its `priority_block`
/// rows. Still used when a focus block inherits its neighbours' order.
void main() {
  group('effectivePriorityOrderAt', () {
    final priorityId = Uuid.generate();
    final userId = Uuid.generate();

    PriorityBlockRow row(double value, DateTime at, {DateTime? archivedAt}) =>
        PriorityBlockRow(
          id: Uuid.generate(),
          priorityId: priorityId,
          createdBy: userId,
          orderValue: Order(value),
          effectiveAt: at,
          archivedAt: archivedAt,
          createdAt: at,
          updatedAt: at,
        );

    test('no rows → falls back', () {
      final got = effectivePriorityOrderAt(
        moment: DateTime(2026, 5, 1, 12),
        blocksForPriority: const [],
        fallback: 999.0,
      );
      expect(got, 999.0);
    });

    test('single row whose effective_at is in the past → that row applies', () {
      final got = effectivePriorityOrderAt(
        moment: DateTime(2026, 5, 1, 12),
        blocksForPriority: [row(0.5, DateTime(2026, 5, 1, 8))],
        fallback: 999.0,
      );
      expect(got, 0.5);
    });

    test('single row whose effective_at is in the future → fallback', () {
      final got = effectivePriorityOrderAt(
        moment: DateTime(2026, 5, 1, 12),
        blocksForPriority: [row(0.5, DateTime(2026, 5, 1, 16))],
        fallback: 999.0,
      );
      expect(got, 999.0);
    });

    test('multiple rows: latest past row wins', () {
      final got = effectivePriorityOrderAt(
        moment: DateTime(2026, 5, 1, 12),
        blocksForPriority: [
          row(0.1, DateTime(2026, 5, 1, 8)),
          row(0.3, DateTime(2026, 5, 1, 10)), // latest before noon
          row(0.7, DateTime(2026, 5, 1, 14)), // future
        ],
        fallback: 999.0,
      );
      expect(got, 0.3);
    });

    test('archived rows are skipped', () {
      final got = effectivePriorityOrderAt(
        moment: DateTime(2026, 5, 1, 12),
        blocksForPriority: [
          row(0.1, DateTime(2026, 5, 1, 8)),
          row(0.3, DateTime(2026, 5, 1, 10),
              archivedAt: DateTime(2026, 5, 1, 11)),
          row(0.5, DateTime(2026, 5, 1, 9)),
        ],
        fallback: 999.0,
      );
      expect(got, 0.5);
    });

    test('moment exactly at effective_at counts as in-effect', () {
      final atTime = DateTime(2026, 5, 1, 12);
      final got = effectivePriorityOrderAt(
        moment: atTime,
        blocksForPriority: [row(0.5, atTime)],
        fallback: 999.0,
      );
      expect(got, 0.5);
    });
  });
}
