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

void main() {
  group('Thread.copyWith active promotion', () {
    test(
      'clearing at/on on an inactive draft does NOT mark it active (To do)',
      () {
        // Mirrors the new-thread reset path (`_resetToFreshStart`), which
        // wipes scheduling with `at: Value(null), on: Value(null)`. This must
        // not flip a freshly composed draft into the "To do" / active state.
        final draft = Thread(priority: _priority(), draft: true);
        expect(draft.active, isFalse, reason: 'precondition: draft inactive');

        final cleared = draft.copyWith(
          at: const Value(null),
          on: const Value(null),
        );

        expect(cleared.active, isFalse);
        expect(cleared.todo, isFalse);
        expect(cleared.rawStateOrder, isNull);
      },
    );

    test('setting a date on an inactive draft still promotes it to active', () {
      final draft = Thread(priority: _priority(), draft: true);

      final scheduled = draft.copyWith(
        on: Value(CustomDateRange(Date(2026, 1, 1), null)),
      );

      expect(scheduled.active, isTrue);
      expect(scheduled.todo, isTrue);
      // Promotion populates a deterministic state_order.
      expect(scheduled.rawStateOrder, isNotNull);
    });

    test('clearing at/on on an already-active thread keeps it active', () {
      final active = Thread(
        priority: _priority(),
        active: true,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );
      expect(active.active, isTrue, reason: 'precondition: active');

      final cleared = active.copyWith(
        at: const Value(null),
        on: const Value(null),
      );

      expect(cleared.active, isTrue);
      // The per-user date intent is cleared.
      expect(cleared.on, isNull);
    });
  });
}
