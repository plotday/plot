import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/priority.dart';
import 'package:plot/page/priority.dart' show kEverythingRouteSegment;
import 'package:plot/store/store.dart';

void main() {
  Priority focus(String title, {bool isInbox = false}) => Priority.fromStore(
        PriorityRow(
          id: Uuid.generate(),
          createdBy: Uuid.generate(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          title: title,
          path: Path(title.toLowerCase()),
          order: const Order(0),
          unread: false,
          role: 'member',
          isInbox: isInbox,
          isFyi: false,
          attentionWindowSet: false,
          seeWithinSet: false,
          earlyNotificationsEnabledSet: false,
          notifyWindowSet: false,
          sendWindowSet: false,
        ),
        draft: true,
      );

  test('Everything targets the reserved segment', () {
    expect(
      everythingCommandTarget(everything: true, priority: null),
      kEverythingRouteSegment,
    );
  });

  test('a scoped focus targets its own id', () {
    final work = focus('Work');
    expect(
      everythingCommandTarget(everything: false, priority: work),
      work.id.toShortString(),
    );
  });
}
