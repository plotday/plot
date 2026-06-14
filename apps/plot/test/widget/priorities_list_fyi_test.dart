import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/priorities_list.dart';

/// [PrioritiesList] does its filtering in the constructor: it splits the
/// passed-in priorities into the flat/accordion [PrioritiesList.focuses] list
/// and captures the single, role-less global "FYI" focus into
/// [PrioritiesList.fyi]. These tests pin that split so the FYI focus is never
/// shown in the accordion and always lands in its fixed row above "Everything".
Priority _priority({
  required String title,
  bool root = false,
  bool isInbox = false,
  bool isFyi = false,
  bool unread = false,
  DateTime? archivedAt,
}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(title.toLowerCase()),
    order: const Order(0),
    root: root,
    unread: unread,
    role: 'member',
    isInbox: isInbox,
    isFyi: isFyi,
    archivedAt: archivedAt,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  group('PrioritiesList FYI focus', () {
    test('captures the FYI focus into `fyi` and excludes it from `focuses`', () {
      final inbox = _priority(title: 'Inbox', root: true, isInbox: true);
      final normal = _priority(title: 'Work');
      final fyi = _priority(title: 'FYI', isFyi: true, unread: true);

      final widget = PrioritiesList(
        root: inbox,
        priorities: [normal, inbox, fyi],
      );

      // The FYI focus is captured separately for its fixed row.
      expect(widget.fyi?.id, fyi.id);

      // …and never appears in the flat/accordion focus list.
      final focusIds = widget.focuses.map((p) => p.id).toList();
      expect(focusIds, isNot(contains(fyi.id)));

      // The ordinary focus and the Inbox still render through the list.
      expect(focusIds, contains(normal.id));
      expect(focusIds, contains(inbox.id));
    });

    test('`fyi` is null when no FYI focus is present', () {
      final inbox = _priority(title: 'Inbox', root: true, isInbox: true);
      final normal = _priority(title: 'Work');

      final widget = PrioritiesList(
        root: inbox,
        priorities: [normal, inbox],
      );

      expect(widget.fyi, isNull);
      expect(widget.focuses.map((p) => p.id), contains(normal.id));
    });

    test('an archived FYI focus is ignored (not captured)', () {
      final inbox = _priority(title: 'Inbox', root: true, isInbox: true);
      final archivedFyi = _priority(
        title: 'FYI',
        isFyi: true,
        archivedAt: DateTime(2026, 1, 2),
      );

      final widget = PrioritiesList(
        root: inbox,
        priorities: [inbox, archivedFyi],
      );

      // Archived FYI is neither surfaced as the fixed row…
      expect(widget.fyi, isNull);
      // …nor leaked into the accordion list.
      expect(
        widget.focuses.map((p) => p.id),
        isNot(contains(archivedFyi.id)),
      );
    });
  });
}
