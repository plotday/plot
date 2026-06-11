import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Build a minimal [Priority] usable in unit tests.
Priority _priority({String path = 'test'}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path(path),
    order: Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

/// The Done section sorts by `activity_at`, which folds in `bumpedAt`. So a
/// non-null `bumpedAt` after an operation means "this thread will surface at
/// the top of Done." The rule (per product spec): bump ONLY when a thread
/// moves INTO the Done section from outside it (Active or the unread cluster).
/// A thread already sitting in Done must never re-bump.
void main() {
  group('Thread.copyWith Done bump (bumpedAt)', () {
    test('completing an active thread bumps it into Done', () {
      final active = Thread(
        priority: _priority(),
        active: true,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );
      expect(active.active, isTrue, reason: 'precondition: in Doing');
      expect(active.bumpedAt, isNull, reason: 'precondition: not yet bumped');

      final done = active.copyWith(todo: false, bump: true);

      expect(done.active, isFalse);
      expect(
        done.bumpedAt,
        isNotNull,
        reason: 'a thread moving out of Active into Done lands at the top',
      );
    });

    test('completing a thread already in Done does NOT re-bump it', () {
      // Inactive + read = already sitting in the Done section.
      final inDone = Thread(priority: _priority(), active: false);
      expect(inDone.active, isFalse, reason: 'precondition: already in Done');
      expect(inDone.unread, isFalse, reason: 'precondition: read');
      expect(inDone.bumpedAt, isNull);

      final again = inDone.copyWith(todo: false, bump: true);

      expect(
        again.bumpedAt,
        isNull,
        reason: 'a thread already in Done must not jump to the top on a '
            'no-op Done action',
      );
    });

    test('reading an unread inactive thread does NOT bump it', () {
      // Unread + inactive. In a focus, reading drops it into Done (by recency);
      // in the flat "Everything" feed it is already inline — bumping it would
      // yank a visible row to the top. Reading must never set bumpedAt.
      final unreadDone = Thread(
        priority: _priority(),
        active: false,
        unread: true,
      );
      expect(unreadDone.unread, isTrue, reason: 'precondition: unread');
      expect(unreadDone.active, isFalse, reason: 'precondition: home is Done');
      expect(unreadDone.bumpedAt, isNull);

      final read = unreadDone.copyWith(
        unread: false,
        readAt: Value(unreadDone.contentTimestamp),
      );

      expect(read.unread, isFalse, reason: 'reading still clears unread');
      expect(
        read.bumpedAt,
        isNull,
        reason: 'reading must not reposition the thread in any feed',
      );
    });

    test('reading an unread active to-do does NOT bump it', () {
      // Unread + active = a to-do; reading leaves it in Doing, not Done.
      final unreadTask = Thread(
        priority: _priority(),
        active: true,
        unread: true,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );
      expect(unreadTask.unread, isTrue);
      expect(unreadTask.active, isTrue, reason: 'precondition: home is Doing');

      final read = unreadTask.copyWith(
        unread: false,
        readAt: Value(unreadTask.contentTimestamp),
      );

      expect(
        read.bumpedAt,
        isNull,
        reason: 'reading a to-do keeps it in Doing — it never entered Done',
      );
    });
  });
}
