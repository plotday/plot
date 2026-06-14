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
    isInbox: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

/// Build a [PriorityState] in tests without invoking [Note.draft] (which
/// reaches into the [Base] injector for `actorId`). We supply explicit
/// [draft] and [draftNote] values so the state constructor never calls
/// the `Base`-dependent factories.
PriorityState _stateWith({
  required Priority priority,
  required List<AgendaItem> agendaItems,
  bool everything = false,
  Map<ActivityTab, ActivityFeedTabData> activityFeedByTab = const {},
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
    agendaItems: agendaItems,
    everything: everything,
    activityFeedByTab: activityFeedByTab,
  );
}

void main() {
  group('PriorityState.agendaViewItems', () {
    setUp(() {
      // Freeze time so the "now event" range deterministically includes
      // Time.now() in every assertion.
      Time.setFrozenTime(DateTime(2026, 5, 2, 14, 0));
    });
    tearDown(() => Time.unfreeze());

    test('passes builder output through without stripping past content', () {
      final priority = _testPriority();

      // A thread happening "now" — the AgendaHeaderItem carries the
      // dateTimeRange directly (Thread() doesn't materialize a schedule
      // row in tests, so we supply the time range on the header).
      final nowThread = Thread(priority: priority, title: 'Standup');
      final nowRange = DateTimeRange(
        DateTime(2026, 5, 2, 13, 30),
        DateTime(2026, 5, 2, 14, 30),
      );

      final today = Date.today();
      final tomorrow = today.addDays(1);

      // Simulate the flat agenda items the builder emits: today's date
      // header, then a past event header for today, then the now-event
      // header, then a future section.
      final items = <AgendaItem>[
        AgendaHeaderItem(date: today),
        AgendaHeaderItem(
          dateTimeRange: DateTimeRange(
            DateTime(2026, 5, 2, 9, 0),
            DateTime(2026, 5, 2, 10, 0),
          ),
        ),
        AgendaHeaderItem(
          dateTimeRange: nowRange,
          thread: nowThread,
          now: true,
        ),
        AgendaThreadItem(nowThread, now: true),
        AgendaHeaderItem(date: tomorrow),
      ];

      final state = _stateWith(priority: priority, agendaItems: items);

      // The builder now owns dedup/window/gap synthesis and the today
      // header, so agendaViewItems no longer collapses past content — it
      // passes the builder's output through (only stripping the legacy
      // "Now" text header and marking the next block). The agenda still
      // opens with today's date header because the builder emits it first.
      final view = state.agendaViewItems;
      expect(view, isNotEmpty);
      expect(
        view.first,
        isA<AgendaHeaderItem>().having((h) => h.date, 'date', today),
        reason: 'agenda must open with today\'s date header',
      );

      // The now-event header (and everything after it) is preserved.
      expect(
        view.any((item) =>
            item is AgendaHeaderItem && item.now && item.thread != null),
        isTrue,
      );

      // The past-event header at 9am is preserved — past content is no
      // longer stripped at the view layer.
      expect(
        view.any((item) =>
            item is AgendaHeaderItem &&
            item.dateTimeRange?.start == DateTime(2026, 5, 2, 9, 0)),
        isTrue,
        reason: 'view getter must not fast-forward past past content',
      );
    });

    test('strips the legacy standalone "Now" text header', () {
      final priority = _testPriority();
      final today = Date.today();

      // A bare "Now" text header with no thread is the legacy marker that
      // agendaViewItems removes (today's date header carries the
      // "we're here now" signal instead).
      final items = <AgendaItem>[
        AgendaHeaderItem(date: today),
        AgendaHeaderItem(now: true, text: 'Now'),
        AgendaHeaderItem(date: today.addDays(1)),
      ];
      final state = _stateWith(priority: priority, agendaItems: items);

      final view = state.agendaViewItems;
      expect(
        view.any((item) =>
            item is AgendaHeaderItem &&
            item.now &&
            item.text == 'Now' &&
            item.thread == null),
        isFalse,
        reason: 'the legacy "Now" text header must be stripped',
      );
      expect(view.length, 2);
    });

    test('preserves today\'s date header when no now-event is collapsed',
        () {
      final priority = _testPriority();
      final today = Date.today();
      final items = <AgendaItem>[
        AgendaHeaderItem(date: today),
        AgendaHeaderItem(date: today.addDays(1)),
      ];
      final state = _stateWith(priority: priority, agendaItems: items);

      final view = state.agendaViewItems;
      expect(view.length, 2);
      expect(
        view.first,
        isA<AgendaHeaderItem>().having((h) => h.date, 'date', today),
      );
    });
  });

  // The page leads the feed with the "Everything" header off
  // `activeTabEverythingFeed` rather than the live `everything` flag, so the
  // header and the items always belong to the same generation. This is what
  // prevents the double-header frame (both "Everything" and "Active") during a
  // focus→Everything switch, where the flag flips a frame before the feed
  // rebuilds.
  group('PriorityState.activeTabEverythingFeed', () {
    test(
        'follows the active tab data, not the live everything flag (no '
        'Everything header over still-sectioned focus data mid-switch)', () {
      final priority = _testPriority();
      final thread = Thread(priority: priority, title: 'Active item');

      // The exact frame between setEverything(true) and the feed rebuilding:
      // the live flag has flipped to true, but the active tab still holds the
      // previous focus's SECTIONED data (built with everythingFeed: false).
      final state = _stateWith(
        priority: priority,
        agendaItems: const [],
        everything: true,
        activityFeedByTab: {
          ActivityTab.catchUp: ActivityFeedTabData(
            items: [
              AgendaHeaderItem(
                text: ActivitySectionMarker.encode(ActivitySection.doing),
              ),
              AgendaThreadItem(thread),
            ],
            everythingFeed: false,
          ),
        },
      );

      expect(state.everything, isTrue);
      expect(
        state.activeTabEverythingFeed,
        isFalse,
        reason: 'header must not lead the stale sectioned list before the '
            'unsectioned Everything data arrives',
      );
    });

    test('true once the active tab holds the dedicated Everything data', () {
      final priority = _testPriority();
      final thread = Thread(priority: priority, title: 'Anywhere');
      final state = _stateWith(
        priority: priority,
        agendaItems: const [],
        everything: true,
        activityFeedByTab: {
          ActivityTab.catchUp: ActivityFeedTabData(
            items: [AgendaThreadItem(thread)],
            everythingFeed: true,
          ),
        },
      );
      expect(state.activeTabEverythingFeed, isTrue);
    });

    test('false when the active tab has no data yet', () {
      final priority = _testPriority();
      final state = _stateWith(priority: priority, agendaItems: const []);
      expect(state.activeTabEverythingFeed, isFalse);
    });
  });

  // The per-row focus label keys on `activeTabContext` (the context the
  // displayed items were built for), not the live `context`, so the previous
  // focus's kept rows don't flash the previous focus's label during a switch.
  group('PriorityState.activeTabContext', () {
    test(
        'follows the active tab data, not the live context (no focus label '
        'flash on kept rows mid-switch)', () {
      final previousFocus = _testPriority();
      final newFocus = _testPriority();
      final thread = Thread(priority: previousFocus, title: 'Kept item');

      // The exact frame between setPriority(newFocus) and the feed rebuilding:
      // the live context has flipped to newFocus, but the active tab still
      // holds the previous focus's items (built under previousFocus).
      final state = _stateWith(
        priority: newFocus,
        agendaItems: const [],
        activityFeedByTab: {
          ActivityTab.catchUp: ActivityFeedTabData(
            items: [AgendaThreadItem(thread)],
            context: previousFocus,
          ),
        },
      );

      expect(state.context.id, newFocus.id);
      expect(
        state.activeTabContext?.id,
        previousFocus.id,
        reason: 'the kept rows must compare against the context they were '
            'built for so they keep their pre-switch appearance',
      );
    });

    test('null when the active tab has no data yet', () {
      final priority = _testPriority();
      final state = _stateWith(priority: priority, agendaItems: const []);
      expect(state.activeTabContext, isNull);
    });
  });

  // Multi-select getters that drive the bulk-operations header bar and the
  // shift-click range selection (see PriorityBloc.toggleSelected/selectRange).
  group('PriorityState selection', () {
    PriorityState selState({
      required Priority priority,
      required List<Thread> feed,
      Set<ThreadId> selected = const {},
      Thread? open,
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
        agendaItems: const [],
        thread: open,
        selected: selected,
        activityFeedByTab: {
          ActivityTab.catchUp: ActivityFeedTabData(
            items: [
              AgendaHeaderItem(
                text: ActivitySectionMarker.encode(ActivitySection.doing),
              ),
              ...feed.map((t) => AgendaThreadItem(t)),
            ],
          ),
        },
      );
    }

    test('multiSelecting reflects whether anything is selected', () {
      final p = _testPriority();
      final t = Thread(priority: p, title: 'A');
      expect(selState(priority: p, feed: [t]).multiSelecting, isFalse);
      expect(
        selState(priority: p, feed: [t], selected: {t.id}).multiSelecting,
        isTrue,
      );
    });

    test('orderedFeedThreadIds lists visible thread rows in order, skipping '
        'section headers', () {
      final p = _testPriority();
      final a = Thread(priority: p, title: 'A');
      final b = Thread(priority: p, title: 'B');
      final c = Thread(priority: p, title: 'C');
      final state = selState(priority: p, feed: [a, b, c]);
      expect(state.orderedFeedThreadIds, [a.id, b.id, c.id]);
    });

    test('selectedThreads resolves selected ids in feed order', () {
      final p = _testPriority();
      final a = Thread(priority: p, title: 'A');
      final b = Thread(priority: p, title: 'B');
      final c = Thread(priority: p, title: 'C');
      final state =
          selState(priority: p, feed: [a, b, c], selected: {c.id, a.id});
      expect(state.selectedThreads.map((t) => t.id).toList(), [a.id, c.id]);
    });

    test('selectedThreads includes the open thread when selected but absent '
        'from the feed', () {
      final p = _testPriority();
      final a = Thread(priority: p, title: 'A');
      final open = Thread(priority: p, title: 'Open elsewhere');
      final state = selState(
        priority: p,
        feed: [a],
        selected: {a.id, open.id},
        open: open,
      );
      final ids = state.selectedThreads.map((t) => t.id).toList();
      expect(ids, containsAll(<ThreadId>[a.id, open.id]));
      expect(ids.length, 2);
    });

    test('selectedThreads is empty when nothing is selected', () {
      final p = _testPriority();
      final a = Thread(priority: p, title: 'A');
      expect(selState(priority: p, feed: [a]).selectedThreads, isEmpty);
    });
  });
}
