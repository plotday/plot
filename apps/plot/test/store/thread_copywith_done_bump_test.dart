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

/// The Done section sorts by `activity_at`, which folds in `bumpedAt`. So a
/// non-null `bumpedAt` after an operation means "this thread will surface at
/// the top of Done." The rule (per product spec): bump exactly when a thread
/// moves INTO the Done section from outside it — explicit completion of an
/// Active/Scheduled thread, or an unread no-active-state thread leaving the
/// unread cluster on read/mute. A thread already sitting in Done must never
/// re-bump (no-op completions, re-opens). The flat Everything/search feeds
/// sort by `contentActivityAt` (bump excluded), so bumps never move rows
/// there.
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

    test('reading an unread inactive thread bumps it to the top of Done', () {
      // Unread + inactive: the thread renders in the unread cluster (top of
      // Active) and leaves it on read. It should land at the TOP of Done,
      // not sink to its old recency slot. Safe for the flat feeds — their
      // sort uses contentActivityAt, which excludes the bump.
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
        isNotNull,
        reason: 'leaving the unread cluster into Done lands at the top',
      );
    });

    test('muting an unread inactive thread bumps it to the top of Done', () {
      // Mirrors MuteSimilarThreads: asInactive() then the unread/readAt
      // clear. The mute moves the row from the unread cluster to Done, so
      // it lands at the top.
      final unreadMail = Thread(
        priority: _priority(),
        active: false,
        unread: true,
      );
      final muted = unreadMail
          .asInactive()
          .copyWith(
            unread: false,
            readAt: Value(unreadMail.contentTimestamp),
          );
      expect(muted.unread, isFalse);
      expect(
        muted.bumpedAt,
        isNotNull,
        reason: 'a muted unread thread enters Done at the top',
      );
    });

    test('re-reading an already-read inactive thread does NOT bump it', () {
      // The original top-of-Done bug: opening a thread already sitting in
      // Done must not move it. The cluster-exit bump requires the thread to
      // have been unread before this write.
      final inDone = Thread(priority: _priority(), active: false);
      expect(inDone.unread, isFalse, reason: 'precondition: already read');

      final reopened = inDone.copyWith(
        unread: false,
        readAt: Value(inDone.contentTimestamp),
      );

      expect(
        reopened.bumpedAt,
        isNull,
        reason: 'opening a Done thread must not reposition it',
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

  group('Thread.copyWith read-receipt push path (stateDirty)', () {
    // Reads on active (Doing) threads must push via /sync/thread-state, not
    // /sync/thread-read (Thread.push deliberately excludes active threads —
    // see store/thread.dart). Without stateDirty, opening a Doing thread
    // marks it read locally but never reaches the server, so every other
    // device keeps showing it unread. Regression guard for the cross-device
    // unread sync bug.
    test('reading an unread ACTIVE thread is state-dirty (thread-state push)',
        () {
      final unreadTask = Thread(
        priority: _priority(),
        active: true,
        unread: true,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );

      final read = unreadTask.copyWith(
        unread: false,
        readAt: Value(unreadTask.contentTimestamp),
      );

      expect(
        read.stateDirty,
        isTrue,
        reason: 'an active-thread read must ride /sync/thread-state so the '
            'read receipt reaches the server and other devices',
      );
    });

    test('reading an unread INACTIVE thread is NOT state-dirty (thread-read)',
        () {
      final unreadMail = Thread(
        priority: _priority(),
        active: false,
        unread: true,
      );

      final read = unreadMail.copyWith(
        unread: false,
        readAt: Value(unreadMail.contentTimestamp),
      );

      expect(
        read.stateDirty,
        isFalse,
        reason: 'inactive reads still ride /sync/thread-read unchanged',
      );
    });

    test('re-reading an already-read ACTIVE thread is NOT state-dirty', () {
      // Already read (unread false): opening it again must not generate a
      // spurious thread-state push. The trigger is the unread→read
      // transition, not every readAt write.
      final readTask = Thread(
        priority: _priority(),
        active: true,
        unread: false,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );

      final reopened = readTask.copyWith(
        unread: false,
        readAt: Value(readTask.contentTimestamp),
      );

      expect(
        reopened.stateDirty,
        isFalse,
        reason: 'no read transition occurred, so no extra push is needed',
      );
    });

    test('a state-dirty copyWith stamps the persisted statePending marker', () {
      final unreadTask = Thread(
        priority: _priority(),
        active: true,
        unread: true,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );
      expect(unreadTask.statePending, isFalse, reason: 'precondition: clean');

      final read = unreadTask.copyWith(
        unread: false,
        readAt: Value(unreadTask.contentTimestamp),
      );

      expect(read.stateDirty, isTrue);
      expect(
        read.statePending,
        isTrue,
        reason: 'the persisted marker is what drives the durable push',
      );
    });

    test('a non-state copyWith leaves statePending false', () {
      final inDone = Thread(priority: _priority(), active: false);
      final reopened = inDone.copyWith(
        unread: false,
        readAt: Value(inDone.contentTimestamp),
      );

      expect(reopened.stateDirty, isFalse);
      expect(reopened.statePending, isFalse);
    });
  });
}
