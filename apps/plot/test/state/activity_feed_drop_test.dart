import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_feed_drop.dart';
import 'package:plot/store/store.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'p',
    path: Path('p'),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
    sendWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  const read = DoingCluster.read();
  const unreadHi = DoingCluster.unread(urgent: false, importance: 100);
  const unreadMid = DoingCluster.unread(urgent: false, importance: 75);
  const unreadLo = DoingCluster.unread(urgent: false, importance: 50);
  const unreadUrgent = DoingCluster.unread(urgent: true, importance: 50);

  group('DoingCluster equality', () {
    test('read clusters compare equal regardless of urgent/importance', () {
      // The constructor pins urgent=false, importance=0 — but the
      // operator should be tolerant. Sanity check the equality:
      expect(const DoingCluster.read(), equals(const DoingCluster.read()));
    });

    test('unread clusters distinguish on urgent', () {
      expect(unreadUrgent, isNot(equals(unreadLo)));
    });

    test('unread clusters distinguish on importance', () {
      expect(unreadHi, isNot(equals(unreadMid)));
    });

    test('read != unread', () {
      expect(read, isNot(equals(unreadHi)));
    });
  });

  group('resolveDoingDrop', () {
    test('empty Doing (no neighbours) → read destination, no bounds', () {
      final r = resolveDoingDrop(prev: null, next: null, dragged: unreadHi);
      expect(r.destination, equals(read));
      expect(r.usePrev, isFalse);
      expect(r.useNext, isFalse);
    });

    test('only prev exists → prev cluster wins', () {
      final r = resolveDoingDrop(prev: unreadHi, next: null, dragged: read);
      expect(r.destination, equals(unreadHi));
      expect(r.usePrev, isTrue);
      expect(r.useNext, isFalse);
    });

    test('only next exists → next cluster wins', () {
      final r =
          resolveDoingDrop(prev: null, next: unreadMid, dragged: unreadHi);
      expect(r.destination, equals(unreadMid));
      expect(r.usePrev, isFalse);
      expect(r.useNext, isTrue);
    });

    test('both neighbours same cluster → that cluster, both bounds', () {
      final r =
          resolveDoingDrop(prev: unreadMid, next: unreadMid, dragged: read);
      expect(r.destination, equals(unreadMid));
      expect(r.usePrev, isTrue);
      expect(r.useNext, isTrue);
    });

    group('unread/read boundary', () {
      test('read thread dragged in stays read, anchor = read side', () {
        final r = resolveDoingDrop(
          prev: unreadMid,
          next: read,
          dragged: read,
        );
        expect(r.destination, equals(read));
        expect(r.usePrev, isFalse);
        expect(r.useNext, isTrue);
      });

      test('unread thread dragged in stays unread, anchor = unread side', () {
        final r = resolveDoingDrop(
          prev: unreadMid,
          next: read,
          dragged: unreadMid,
        );
        expect(r.destination, equals(unreadMid));
        expect(r.usePrev, isTrue);
        expect(r.useNext, isFalse);
      });
    });

    group('importance sub-cluster boundary inside unread', () {
      test('dragged matches next sub-cluster → stay there, anchor next', () {
        // This is the case from the third bug report: dragged is
        // imp=75, prev is imp=100, next is imp=75 (the first imp=75).
        // Dragged should stay imp=75 and sort to the very top of the
        // imp=75 sub-cluster (just under prev).
        final r = resolveDoingDrop(
          prev: unreadHi,
          next: unreadMid,
          dragged: unreadMid,
        );
        expect(r.destination, equals(unreadMid));
        expect(r.usePrev, isFalse);
        expect(r.useNext, isTrue);
      });

      test('dragged matches prev sub-cluster → stay there, anchor prev', () {
        // Dragged is imp=100; user drops between the last imp=100 and
        // the first imp=75 — dragged stays imp=100 at the bottom of
        // its sub-cluster.
        final r = resolveDoingDrop(
          prev: unreadHi,
          next: unreadMid,
          dragged: unreadHi,
        );
        expect(r.destination, equals(unreadHi));
        expect(r.usePrev, isTrue);
        expect(r.useNext, isFalse);
      });

      test(
        'dragged matches neither sub-cluster → absorb prev (explicit '
        'cross-bucket move)',
        () {
          // Dragged is imp=50; user drops between imp=100 and imp=75.
          // No clear preserve-side, so absorb prev (imp=100).
          final r = resolveDoingDrop(
            prev: unreadHi,
            next: unreadMid,
            dragged: unreadLo,
          );
          expect(r.destination, equals(unreadHi));
          expect(r.usePrev, isTrue);
          expect(r.useNext, isFalse);
        },
      );
    });

    test('urgent/non-urgent boundary preserves dragged when matching', () {
      // Dragged is urgent=true, drop slot is between an urgent unread
      // and a non-urgent unread → stay urgent.
      final r = resolveDoingDrop(
        prev: unreadUrgent,
        next: unreadMid,
        dragged: unreadUrgent,
      );
      expect(r.destination, equals(unreadUrgent));
      expect(r.usePrev, isTrue);
      expect(r.useNext, isFalse);
    });

    test('mid-cluster drop forces dragged into that cluster', () {
      // Dragged is read; both neighbours are imp=75 unread. Mid-cluster
      // drop is an explicit "make this unread imp=75" move.
      final r = resolveDoingDrop(
        prev: unreadMid,
        next: unreadMid,
        dragged: read,
      );
      expect(r.destination, equals(unreadMid));
      expect(r.usePrev, isTrue);
      expect(r.useNext, isTrue);
    });
  });

  group('clampDraggedActiveDestination', () {
    test('active dragged, destination=unread → clamped to read', () {
      expect(
        clampDraggedActiveDestination(
          draggedActive: true,
          destination: unreadHi,
        ),
        equals(read),
      );
    });

    test('active dragged, destination=read → unchanged', () {
      expect(
        clampDraggedActiveDestination(
          draggedActive: true,
          destination: read,
        ),
        equals(read),
      );
    });

    test('non-active dragged, destination=unread → unchanged (unread reorder)', () {
      expect(
        clampDraggedActiveDestination(
          draggedActive: false,
          destination: unreadMid,
        ),
        equals(unreadMid),
      );
    });
  });

  group('doingClusterFor', () {
    test('active thread → read cluster regardless of unread', () {
      final p = _testPriority();
      final activeUnread = Thread(priority: p)
          .asActiveToday(order: const Order(1), markRead: false)
          .copyWith(unread: true);
      expect(doingClusterFor(activeUnread), const DoingCluster.read());
    });

    test('non-active unread → unread cluster with its bucket', () {
      final p = _testPriority();
      final u = Thread(priority: p)
          .asUnreadInDoing(order: const Order(1), urgent: true, importance: 3);
      expect(doingClusterFor(u), const DoingCluster.unread(urgent: true, importance: 3));
    });
  });
}
