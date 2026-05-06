import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart';

PriorityBlockRow _row({
  required DateTime effectiveAt,
  required double order,
  DateTime? archivedAt,
}) {
  final priorityId = Uuid.fromString('00000000-0000-0000-0000-000000000001');
  return PriorityBlockRow(
    id: Uuid.generate(),
    priorityId: priorityId,
    createdBy: Uuid.fromString('00000000-0000-0000-0000-000000000002'),
    orderValue: Order(order),
    effectiveAt: effectiveAt,
    archivedAt: archivedAt,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('effectivePriorityOrderAt — past-gap reorder regression', () {
    test(
        'a row written at `now` does NOT take effect when sorting a gap '
        'whose moment is in the past — this was the snap-back bug: '
        'reorderBlockWithinPeriod for a past gap wrote a priority_block at '
        'effectiveAt=now, but the gap visualization queries with moment=gap '
        '(past), so the new row was filtered out and the source fell back '
        "to its natural priority order, visually 'snapping back'",
        () {
      final pastGap = DateTime(2026, 5, 1, 13, 30);
      final now = DateTime(2026, 5, 5, 13, 55);

      final naturalOrder = 0.7;
      final newOrder = -1.778e12;

      final rowAtNow = _row(effectiveAt: now, order: newOrder);

      final result = effectivePriorityOrderAt(
        moment: pastGap,
        blocksForPriority: [rowAtNow],
        fallback: naturalOrder,
      );

      expect(result, naturalOrder,
          reason: 'row at future effectiveAt is skipped — fallback wins');
    });

    test(
        'writing the row at `effectiveAt = periodReferenceTime` (past) '
        'makes the new order take effect for that past gap, fixing the '
        'snap-back',
        () {
      final pastGap = DateTime(2026, 5, 1, 13, 30);

      final naturalOrder = 0.7;
      final newOrder = -1.778e12;

      final rowAtGap = _row(effectiveAt: pastGap, order: newOrder);

      final result = effectivePriorityOrderAt(
        moment: pastGap,
        blocksForPriority: [rowAtGap],
        fallback: naturalOrder,
      );

      expect(result, newOrder,
          reason: 'row at moment-or-earlier is the latest — its order wins');
    });

    test(
        'a row at periodReferenceTime applies to that moment AND any later '
        'moment with no later row — so reordering a past gap also affects '
        'subsequent gaps without an intervening reorder',
        () {
      final pastGap = DateTime(2026, 5, 1, 13, 30);
      final laterGap = DateTime(2026, 5, 3, 9, 0);

      final rowAtGap = _row(effectiveAt: pastGap, order: -1.778e12);

      final atPast = effectivePriorityOrderAt(
        moment: pastGap,
        blocksForPriority: [rowAtGap],
        fallback: 0.7,
      );
      final atLater = effectivePriorityOrderAt(
        moment: laterGap,
        blocksForPriority: [rowAtGap],
        fallback: 0.7,
      );

      expect(atPast, -1.778e12);
      expect(atLater, -1.778e12,
          reason: 'no later row exists — the past row is still the latest');
    });
  });
}
