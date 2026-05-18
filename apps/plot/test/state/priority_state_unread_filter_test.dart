import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: const Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinRequestsSet: false,
    seeWithinUpdatesSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

PriorityState _stateWith({
  required Priority priority,
  required List<AgendaItem> activityFeedItems,
  bool unreadFilterActive = false,
  bool unreadFilterPending = false,
  bool activityFeedDoneEnd = false,
}) {
  final draft = Thread(priority: priority, draft: true);
  final draftNote = Note(
    id: Uuid.generate(),
    threadId: draft.id,
    authorId: ActorId(Uuid.generate()),
    draft: true,
    createdAt: DateTime(2026, 1, 1),
    sourceCreatedAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
  return PriorityState(
    context: priority,
    draft: draft,
    draftNote: draftNote,
    activityFeedItems: activityFeedItems,
    unreadFilterActive: unreadFilterActive,
    unreadFilterPending: unreadFilterPending,
    activityFeedDoneEnd: activityFeedDoneEnd,
  );
}

Thread _thread(Priority p, {required bool unread, String title = 't'}) {
  return Thread(priority: p, title: title).copyWith(unread: unread);
}

AgendaHeaderItem _sectionHeader(ActivitySection section) {
  return AgendaHeaderItem(text: ActivitySectionMarker.encode(section));
}

void main() {
  group('PriorityState unread filter', () {
    test('hasUnreadInFeed is false when no thread item is unread', () {
      final p = _testPriority();
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          AgendaThreadItem(_thread(p, unread: false, title: 'a')),
        ],
      );
      expect(state.hasUnreadInFeed, isFalse);
    });

    test('hasUnreadInFeed is true when any thread item is unread', () {
      final p = _testPriority();
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          AgendaThreadItem(_thread(p, unread: false, title: 'a')),
          _sectionHeader(ActivitySection.newSection),
          AgendaThreadItem(_thread(p, unread: true, title: 'b')),
        ],
      );
      expect(state.hasUnreadInFeed, isTrue);
    });

    test('activityFeedViewItems returns full list when filter inactive', () {
      final p = _testPriority();
      final items = <AgendaItem>[
        _sectionHeader(ActivitySection.today),
        AgendaThreadItem(_thread(p, unread: false)),
        AgendaThreadItem(_thread(p, unread: true)),
      ];
      final state = _stateWith(priority: p, activityFeedItems: items);
      expect(state.activityFeedViewItems, equals(items));
    });

    test('activityFeedViewItems drops read threads when filter active', () {
      final p = _testPriority();
      final readT = AgendaThreadItem(_thread(p, unread: false, title: 'r'));
      final unreadT = AgendaThreadItem(_thread(p, unread: true, title: 'u'));
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          readT,
          unreadT,
        ],
        unreadFilterActive: true,
      );
      final view = state.activityFeedViewItems;
      expect(view.length, 2);
      expect(view[0], isA<AgendaHeaderItem>());
      expect(view[1], same(unreadT));
    });

    test('activityFeedViewItems drops empty section headers', () {
      final p = _testPriority();
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          AgendaThreadItem(_thread(p, unread: false, title: 'r1')),
          _sectionHeader(ActivitySection.scheduled),
          AgendaThreadItem(_thread(p, unread: false, title: 'r2')),
          _sectionHeader(ActivitySection.newSection),
          AgendaThreadItem(_thread(p, unread: true, title: 'u')),
        ],
        unreadFilterActive: true,
      );
      final view = state.activityFeedViewItems;
      // Only the New header + the unread thread should survive.
      expect(view.length, 2);
      expect(view[0], isA<AgendaHeaderItem>());
      final header = view[0] as AgendaHeaderItem;
      final decoded = ActivitySectionMarker.tryDecode(header.text!);
      expect(decoded?.section, ActivitySection.newSection);
    });

    test('activityFeedViewItems keeps date sub-header above kept thread', () {
      final p = _testPriority();
      final tomorrow = Date.today().addDays(1);
      final unreadT = AgendaThreadItem(_thread(p, unread: true, title: 'u'));
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.scheduled),
          AgendaHeaderItem(date: tomorrow),
          unreadT,
        ],
        unreadFilterActive: true,
      );
      final view = state.activityFeedViewItems;
      // Section header + date sub-header + unread thread.
      expect(view.length, 3);
      expect(view[0], isA<AgendaHeaderItem>());
      expect(view[1], isA<AgendaHeaderItem>());
      expect(view[2], same(unreadT));
    });

    test(
      'activityFeedViewDoneEnd mirrors activityFeedDoneEnd when filter inactive',
      () {
        final p = _testPriority();
        final unfinished = _stateWith(
          priority: p,
          activityFeedItems: const [],
          activityFeedDoneEnd: false,
        );
        expect(unfinished.activityFeedViewDoneEnd, isFalse);
        final finished = _stateWith(
          priority: p,
          activityFeedItems: const [],
          activityFeedDoneEnd: true,
        );
        expect(finished.activityFeedViewDoneEnd, isTrue);
      },
    );

    test(
      'activityFeedViewDoneEnd is true when filter active even if raw feed not done',
      () {
        // Reproduces the bug: with the unread filter on, the InfiniteList's
        // bottom spinner would otherwise spin forever because the fetcher
        // early-returns against the raw thread count while the filtered
        // count stays small.
        final p = _testPriority();
        final state = _stateWith(
          priority: p,
          activityFeedItems: [
            _sectionHeader(ActivitySection.newSection),
            AgendaThreadItem(_thread(p, unread: true)),
          ],
          unreadFilterActive: true,
          activityFeedDoneEnd: false,
        );
        expect(state.activityFeedViewDoneEnd, isTrue);
      },
    );

    test('copyWith propagates unreadFilterActive', () {
      final p = _testPriority();
      final state = _stateWith(priority: p, activityFeedItems: const []);
      expect(state.unreadFilterActive, isFalse);
      expect(state.copyWith(unreadFilterActive: true).unreadFilterActive,
          isTrue);
      expect(
        state
            .copyWith(unreadFilterActive: true)
            .copyWith()
            .unreadFilterActive,
        isTrue,
      );
    });

    test('copyWith propagates unreadFilterPending', () {
      final p = _testPriority();
      final state = _stateWith(priority: p, activityFeedItems: const []);
      expect(state.unreadFilterPending, isFalse);
      expect(
        state.copyWith(unreadFilterPending: true).unreadFilterPending,
        isTrue,
      );
      expect(
        state
            .copyWith(unreadFilterPending: true)
            .copyWith()
            .unreadFilterPending,
        isTrue,
      );
    });
  });
}
