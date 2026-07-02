import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

Priority _priority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'p',
    path: Path('p'),
    order: const Order(0),
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
  test('asActiveToday(markRead: false) keeps an unread thread unread', () {
    final t = Thread(priority: _priority())
        .asUnreadInDoing(order: const Order(1), urgent: false, importance: 0);
    expect(t.unread, isTrue);

    final reordered = t.asActiveToday(order: const Order(2), markRead: false);
    expect(reordered.unread, isTrue, reason: 'reorder must not mark read');
    expect(reordered.active, isTrue);
    expect(reordered.order, const Order(2));
  });

  test('asActiveToday() default still marks an unread thread read', () {
    final t = Thread(priority: _priority())
        .asUnreadInDoing(order: const Order(1), urgent: false, importance: 0);
    final activated = t.asActiveToday(order: const Order(2));
    expect(activated.unread, isFalse);
    expect(activated.active, isTrue);
  });
}
