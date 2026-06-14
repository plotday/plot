import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/order_repair.dart';
import 'package:plot/store/store.dart';

Priority _priority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    root: false,
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  final priority = _priority();
  Thread thread(String title, double order) => Thread(
    priority: priority,
    title: title,
    active: true,
    stateOn: Date(2026, 6, 20),
    stateOrder: Order(order),
  );

  /// Apply [result] to [bucket], re-sort by (order, tie-rank) the way the
  /// feed does — the bucket's incoming order IS the id tie-break order for
  /// rows that tie — and expect the displayed sequence to be the original
  /// bucket with the dropped row inserted at [gap]. Repairs may leave the
  /// unrewritten side of a run tied; what matters is that nothing
  /// re-sorts and the drop lands exactly in its gap.
  void expectDropLandsInGap(
    List<Thread> bucket,
    int gap,
    DropOrderResolution result,
  ) {
    final entries = <(double order, int tieRank, String title)>[];
    for (var i = 0; i < bucket.length; i++) {
      final t = bucket[i];
      final rewritten = result.rewrites
          .where((r) => r.$1.id == t.id)
          .map((r) => r.$2.value)
          .firstOrNull;
      entries.add((rewritten ?? t.order.value, i, t.title ?? ''));
    }
    // The dropped row's order is strictly between its neighbours, so its
    // tie rank never matters.
    entries.add((result.dropOrder.value, -1, 'DROPPED'));
    entries.sort((a, b) {
      final byOrder = a.$1.compareTo(b.$1);
      if (byOrder != 0) return byOrder;
      return a.$2.compareTo(b.$2);
    });
    final expected = [
      for (final t in bucket.sublist(0, gap)) t.title ?? '',
      'DROPPED',
      for (final t in bucket.sublist(gap)) t.title ?? '',
    ];
    expect(
      [for (final e in entries) e.$3],
      expected,
      reason: 'post-repair sort must show the drop exactly in its gap',
    );
  }

  group('resolveDropOrderWithRepair', () {
    test('distinct neighbours need no rewrites', () {
      final bucket = [thread('a', 10), thread('b', 20), thread('c', 30)];
      final result = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 1);
      expect(result.rewrites, isEmpty);
      expect(result.dropOrder.value, greaterThan(10));
      expect(result.dropOrder.value, lessThan(20));
    });

    test('empty bucket and edge gaps work like plain Order.between', () {
      final empty = resolveDropOrderWithRepair(bucket: [], gapIndex: 0);
      expect(empty.rewrites, isEmpty);

      final bucket = [thread('a', 10)];
      final top = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 0);
      expect(top.rewrites, isEmpty);
      expect(top.dropOrder.value, lessThan(10));
      final bottom = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 1);
      expect(bottom.rewrites, isEmpty);
      expect(bottom.dropOrder.value, greaterThan(10));
    });

    test('tied run: drop near the end rewrites only the after side', () {
      final bucket = [
        thread('a', 5),
        thread('t1', 7),
        thread('t2', 7),
        thread('t3', 7),
        thread('t4', 7),
        thread('z', 9),
      ];
      // Drop between t3 and t4 → after side (t4) is smaller than before
      // side (t1..t3).
      final result = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 4);
      expect(result.rewrites, hasLength(1));
      expect(result.rewrites.single.$1.title, 't4');
      expectDropLandsInGap(bucket, 4, result);
    });

    test('tied run: drop near the start rewrites only the before side', () {
      final bucket = [
        thread('a', 5),
        thread('t1', 7),
        thread('t2', 7),
        thread('t3', 7),
        thread('t4', 7),
        thread('z', 9),
      ];
      // Drop between t1 and t2 → before side (t1) is smaller.
      final result = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 2);
      expect(result.rewrites, hasLength(1));
      expect(result.rewrites.single.$1.title, 't1');
      expectDropLandsInGap(bucket, 2, result);
    });

    test('rewrites stay strictly between the run-bounding orders', () {
      final bucket = [
        thread('a', 5),
        thread('t1', 7),
        thread('t2', 7),
        thread('t3', 7),
        thread('z', 9),
      ];
      final result = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 2);
      for (final (_, order) in result.rewrites) {
        expect(order.value, greaterThan(5));
        expect(order.value, lessThan(9));
      }
      expect(result.dropOrder.value, greaterThan(5));
      expect(result.dropOrder.value, lessThan(9));
      expectDropLandsInGap(bucket, 2, result);
    });

    test('whole-bucket tie (legacy NULL-order fallback) repairs correctly',
        () {
      // Mirrors the real corruption: every row shares Order.lowerBound.
      final bucket = [
        for (var i = 0; i < 6; i++) thread('t$i', Order.lowerBound),
      ];
      final result = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 3);
      expectDropLandsInGap(bucket, 3, result);
      // The smaller side (before: 3 rows vs after: 3 rows → before wins
      // ties) is rewritten, the other side keeps its values.
      expect(result.rewrites.length, 3);
    });

    test('drop at the very top of a tied run', () {
      final bucket = [
        thread('t1', 7),
        thread('t2', 7),
        thread('t3', 7),
      ];
      final result = resolveDropOrderWithRepair(bucket: bucket, gapIndex: 0);
      // Gap is above the run — prev is null, so no tie brackets the gap
      // and a plain between(null, 7) suffices.
      expect(result.rewrites, isEmpty);
      expectDropLandsInGap(bucket, 0, result);
    });
  });

  group('feedDropGapIndex', () {
    final a = thread('a', 1);
    final b = thread('b', 2);
    final c = thread('c', 3);

    test('resolves from next, then prev, then end', () {
      final bucket = [a, b, c];
      expect(
        feedDropGapIndex(bucket, prevId: a.id, nextId: b.id),
        1,
      );
      expect(
        feedDropGapIndex(bucket, prevId: c.id, nextId: null),
        3,
      );
      expect(
        feedDropGapIndex(bucket, prevId: null, nextId: a.id),
        0,
      );
      expect(
        feedDropGapIndex(bucket, prevId: null, nextId: null),
        0,
      );
    });
  });
}
