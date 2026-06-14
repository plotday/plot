import 'package:flutter_test/flutter_test.dart';
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
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

/// New to-do and newly scheduled threads append to the BOTTOM of their
/// section / day. Bottom placement uses [Order.last] — a positive
/// timestamp — while top placement ([Order.first]) is negative, so the
/// sign is a deterministic proxy for "appended at the bottom".
void main() {
  group('bottom placement on activation', () {
    test('marking to-do without an explicit order appends at the bottom', () {
      final inactive = Thread(priority: _priority());
      final activated = inactive.copyWith(todo: true);
      expect(activated.todo, isTrue);
      expect(activated.rawStateOrder, isNotNull);
      expect(activated.order.value, greaterThan(0));
    });

    test('marking to-do honors an explicitly passed order', () {
      final inactive = Thread(priority: _priority());
      final activated = inactive.copyWith(todo: true, order: const Order(-5));
      expect(activated.order.value, -5);
    });

    test('date promotion of an inactive thread appends at the bottom', () {
      final draft = Thread(priority: _priority(), draft: true);
      final scheduled = draft.copyWith(
        on: Value(CustomDateRange(Date(2026, 1, 1), null)),
      );
      expect(scheduled.active, isTrue);
      expect(scheduled.rawStateOrder, isNotNull);
      expect(scheduled.order.value, greaterThan(0));
    });

    test('asActiveToday with no prior state order appends at the bottom', () {
      final inactive = Thread(priority: _priority());
      expect(inactive.rawStateOrder, isNull);
      final active = inactive.asActiveToday();
      expect(active.order.value, greaterThan(0));
    });

    test('asScheduled with no prior state order appends at the bottom', () {
      final inactive = Thread(priority: _priority());
      final scheduled = inactive.asScheduled(Date(2026, 6, 20));
      expect(scheduled.order.value, greaterThan(0));
    });
  });
}
