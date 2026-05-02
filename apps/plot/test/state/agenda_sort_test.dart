import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_sort.dart';
import 'package:plot/store/store.dart';

void main() {
  // ---------------- comparePure: two-arg sort comparator ----------------

  group('AgendaSort.comparePure', () {
    final moment = DateTime(2026, 5, 1, 14, 0); // 2pm

    test('arrived thread sorts above un-arrived', () {
      final cmp = AgendaSort.comparePure(
        aPromotion: DateTime(2026, 5, 1, 13, 0), // 1pm — arrived
        aOrder: const Order(2.0),
        bPromotion: null, // untimed
        bOrder: const Order(1.0),
        moment: moment,
      );
      expect(cmp, isNegative); // a above b
    });

    test('un-arrived (future) sorts below arrived', () {
      final cmp = AgendaSort.comparePure(
        aPromotion: DateTime(2026, 5, 1, 16, 0), // 4pm — future
        aOrder: const Order(1.0),
        bPromotion: DateTime(2026, 5, 1, 10, 0), // 10am — arrived
        bOrder: const Order(2.0),
        moment: moment,
      );
      expect(cmp, isPositive); // a below b (b arrived)
    });

    test('among arrived, more-recent-arrival sits on top', () {
      final cmp = AgendaSort.comparePure(
        aPromotion: DateTime(2026, 5, 1, 13, 0), // 1pm
        aOrder: const Order(5.0),
        bPromotion: DateTime(2026, 5, 1, 10, 0), // 10am
        bOrder: const Order(1.0),
        moment: moment,
      );
      // a (1pm) is more-recently-arrived than b (10am) → a on top
      expect(cmp, isNegative);
    });

    test('arrived at the same time → tiebreak by manual order ASC', () {
      final cmp = AgendaSort.comparePure(
        aPromotion: DateTime(2026, 5, 1, 14, 0),
        aOrder: const Order(2.0),
        bPromotion: DateTime(2026, 5, 1, 14, 0),
        bOrder: const Order(1.0),
        moment: moment,
      );
      // both arrived at 2pm, b has lower order → b above a
      expect(cmp, isPositive);
    });

    test('two untimed threads sort by manual order ASC', () {
      final cmp = AgendaSort.comparePure(
        aPromotion: null,
        aOrder: const Order(2.0),
        bPromotion: null,
        bOrder: const Order(1.0),
        moment: moment,
      );
      expect(cmp, isPositive); // b first
    });

    test('threads at promotion-time-equal-to-moment count as arrived', () {
      // boundary: scheduledAt == moment
      final cmp = AgendaSort.comparePure(
        aPromotion: moment,
        aOrder: const Order(1.0),
        bPromotion: null,
        bOrder: const Order(0.0),
        moment: moment,
      );
      expect(cmp, isNegative); // a (just arrived) above b (untimed)
    });
  });

  // ----------- effectivePriorityOrderAt: timeline lookup ----------------

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
      // 0.3 row is archived; 0.5 row at 9am, 0.1 at 8am — latest non-archived
      // before noon is 0.5 (9am).
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
