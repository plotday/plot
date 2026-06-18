import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_feed_layout.dart';
import 'package:plot/store/store.dart';

Priority _testPriority() {
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
  );
  return Priority.fromStore(row, draft: true);
}

final _p = _testPriority();

Thread _active(int order, {bool unread = false}) {
  var t = Thread(priority: _p).asActiveToday(order: Order(order.toDouble()));
  if (unread) t = t.copyWith(unread: true);
  return t;
}

Thread _unread(int order, {bool urgent = false, int importance = 0}) =>
    Thread(priority: _p)
        .asUnreadInDoing(order: Order(order.toDouble()), urgent: urgent, importance: importance);

void main() {
  test('active to-dos sort by order; unread active stays among them', () {
    final a1 = _active(1);
    final a2 = _active(2, unread: true);
    final a3 = _active(3);
    final split = splitDoingSection([a3, a1, a2]);
    expect(split.active.map((t) => t.order.value), [1.0, 2.0, 3.0]);
    expect(split.unreadCluster, isEmpty);
  });

  test('non-active unread cluster sorts urgent, importance, order', () {
    final u1 = _unread(5, urgent: false, importance: 0);
    final u2 = _unread(1, urgent: true, importance: 0);
    final u3 = _unread(9, urgent: false, importance: 7);
    final split = splitDoingSection([u1, u2, u3]);
    // urgent first (u2), then higher importance (u3), then u1
    expect(split.unreadCluster, [u2, u3, u1]);
    expect(split.active, isEmpty);
  });

  test('active and unread are separated regardless of input order', () {
    final a = _active(1);
    final u = _unread(1);
    final split = splitDoingSection([u, a]);
    expect(split.active, [a]);
    expect(split.unreadCluster, [u]);
  });
}
