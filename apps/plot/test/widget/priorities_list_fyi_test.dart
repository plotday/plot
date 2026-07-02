import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/priorities_list.dart';

/// The per-role FYI is an ordinary focus: it renders through
/// [PrioritiesList.focuses] (no separate fixed tile) and sorts purely by its
/// `order`. Its name shows as "FYI" and it defaults just below its role's Inbox
/// via large server-seeded sentinel orders (Inbox 1e15, FYI 2e15), so a freshly
/// added focus (a now()-epoch-ms order) lands above both. These tests pin that.
Priority _priority({
  required String title,
  bool isInbox = false,
  bool isFyi = false,
  bool unread = false,
  double order = 0,
  DateTime? archivedAt,
}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(title.toLowerCase()),
    order: Order(order),
    unread: unread,
    role: 'member',
    isInbox: isInbox,
    isFyi: isFyi,
    archivedAt: archivedAt,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
    sendWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  group('PrioritiesList per-role FYI', () {
    test('the FYI renders as an ordinary focus (included in `focuses`)', () {
      final inbox = _priority(
        title: 'Inbox',
        isInbox: true,
        order: 1e15,
      );
      final normal = _priority(title: 'Work', order: 1000);
      final fyi = _priority(title: 'FYI', isFyi: true, unread: true, order: 2e15);

      final widget = PrioritiesList(
        root: inbox,
        priorities: [normal, inbox, fyi],
      );

      // No separate fixed FYI row — it is one of the ordinary focuses now.
      final focusIds = widget.focuses.map((p) => p.id).toList();
      expect(focusIds, contains(fyi.id));
      expect(focusIds, contains(inbox.id));
      expect(focusIds, contains(normal.id));
    });

    test('the Inbox then the FYI default to the bottom two (sentinel orders)', () {
      final inbox = _priority(
        title: 'Inbox',
        isInbox: true,
        order: 1e15,
      );
      final normal = _priority(title: 'Work', order: 1000);
      final fyi = _priority(title: 'FYI', isFyi: true, order: 2e15);

      // Pass them out of order; the pure-order sort fixes the layout.
      final widget = PrioritiesList(
        root: inbox,
        priorities: [fyi, inbox, normal],
      );

      expect(
        widget.focuses.map((p) => p.displayTitle).toList(),
        ['Work', 'Inbox', 'FYI'],
      );
    });

    test('a freshly added focus (now()-order) lands above the Inbox and FYI', () {
      final inbox = _priority(
        title: 'Inbox',
        isInbox: true,
        order: 1e15,
      );
      final fyi = _priority(title: 'FYI', isFyi: true, order: 2e15);
      final fresh = _priority(
        title: 'Fresh',
        order: DateTime.now().millisecondsSinceEpoch.toDouble(),
      );

      final widget = PrioritiesList(
        root: inbox,
        priorities: [inbox, fyi, fresh],
      );

      expect(
        widget.focuses.map((p) => p.displayTitle).toList(),
        ['Fresh', 'Inbox', 'FYI'],
      );
    });
  });
}
