import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/feed_move_diff.dart';
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

AgendaHeaderItem _header(ActivitySection s, {Date? date}) => AgendaHeaderItem(
  date: date,
  text: ActivitySectionMarker.encode(s),
);

void main() {
  final priority = _priority();
  Thread thread(String title) => Thread(priority: priority, title: title);
  AgendaThreadItem row(Thread t) => AgendaThreadItem(t);

  final a = thread('a');
  final b = thread('b');
  final c = thread('c');
  final hDoing = _header(ActivitySection.doing);
  final hDone = _header(ActivitySection.activity);

  group('computeFeedMoveDiff', () {
    test('single move within the list: one ghost, one expander', () {
      final oldItems = [hDoing, row(a), row(b), row(c)];
      final newItems = [hDoing, row(a), row(c), row(b)];
      final diff = computeFeedMoveDiff(oldItems, newItems, {b.id});
      expect(diff.ghosts, hasLength(1));
      expect(diff.ghosts.single.anchorKey, feedItemKey(row(a)));
      expect(diff.expandingKeys, {feedItemKey(row(b))});
    });

    test('cross-section move with a header removal ghosts the header too',
        () {
      final day = _header(ActivitySection.scheduled, date: Date(2026, 6, 20));
      final oldItems = [hDoing, row(a), day, row(b), hDone, row(c)];
      // b marked done: its day bucket disappears, b lands at top of Done.
      final newItems = [hDoing, row(a), hDone, row(b), row(c)];
      final diff = computeFeedMoveDiff(oldItems, newItems, {b.id});
      // Ghosts: the day header and b's old row, both anchored after a.
      expect(diff.ghosts, hasLength(2));
      expect(
        diff.ghosts.map((g) => g.anchorKey),
        everyElement(feedItemKey(row(a))),
      );
      expect(diff.expandingKeys, {feedItemKey(row(b))});
    });

    test('thread leaving the feed: ghost only, no expander', () {
      final oldItems = [hDoing, row(a), row(b)];
      final newItems = [hDoing, row(a)];
      final diff = computeFeedMoveDiff(oldItems, newItems, {b.id});
      expect(diff.ghosts, hasLength(1));
      expect(diff.expandingKeys, isEmpty);
    });

    test('identical lists produce an empty diff even with movedIds', () {
      final items = [hDoing, row(a), row(b)];
      final diff = computeFeedMoveDiff(items, items, {b.id});
      expect(diff.isEmpty, isTrue);
    });

    test('reordered stable rows bail out to an empty diff', () {
      final oldItems = [hDoing, row(a), row(b), row(c)];
      final newItems = [hDoing, row(b), row(a), row(c)];
      // c is "moved" but a and b also swapped — ambiguous, snap.
      final diff = computeFeedMoveDiff(oldItems, newItems, {c.id});
      expect(diff.isEmpty, isTrue);
    });

    test('mass changes beyond the cap bail out', () {
      final oldItems = [
        hDoing,
        for (var i = 0; i < 14; i++) row(thread('o$i')),
      ];
      final newItems = [
        hDoing,
        for (var i = 0; i < 14; i++) row(thread('n$i')),
      ];
      final diff = computeFeedMoveDiff(oldItems, newItems, const {});
      expect(diff.isEmpty, isTrue);
    });
  });
}
