import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/activity_feed_drag.dart';

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

void main() {
  final p = _testPriority();

  test('dragging an active thread opens no slots between unread rows', () {
    final active = Thread(priority: p).asActiveToday(order: const Order(1));
    final u1 = Thread(priority: p)
        .asUnreadInDoing(order: const Order(2), urgent: false, importance: 0);
    final u2 = Thread(priority: p)
        .asUnreadInDoing(order: const Order(3), urgent: false, importance: 0);
    final items = <AgendaItem>[
      AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
      AgendaThreadItem(active),
      AgendaThreadItem(u1),
      AgendaThreadItem(u2),
    ];

    final res = computeActivityFeedDropBoundaries(
      items: items,
      draggingActive: true,
      unreadClusterIds: {u1.id, u2.id},
    );
    // A "before" slot exists above u1 (the end-of-active boundary) but NOT above u2.
    final indexOfU1 = items.indexWhere(
        (i) => i is AgendaThreadItem && i.thread.id == u1.id);
    final indexOfU2 = items.indexWhere(
        (i) => i is AgendaThreadItem && i.thread.id == u2.id);
    expect(res.before.containsKey(indexOfU1), isTrue);
    expect(res.before.containsKey(indexOfU2), isFalse);
  });

  test('dragging an unread thread keeps slots between unread rows', () {
    final u1 = Thread(priority: p)
        .asUnreadInDoing(order: const Order(2), urgent: false, importance: 0);
    final u2 = Thread(priority: p)
        .asUnreadInDoing(order: const Order(3), urgent: false, importance: 0);
    final items = <AgendaItem>[
      AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
      AgendaThreadItem(u1),
      AgendaThreadItem(u2),
    ];
    final res = computeActivityFeedDropBoundaries(
      items: items,
      draggingActive: false,
      unreadClusterIds: {u1.id, u2.id},
    );
    final indexOfU2 = items.indexWhere(
        (i) => i is AgendaThreadItem && i.thread.id == u2.id);
    expect(res.before.containsKey(indexOfU2), isTrue);
  });
}
