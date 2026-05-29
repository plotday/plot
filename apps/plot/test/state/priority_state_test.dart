import 'package:flutter_test/flutter_test.dart';
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
}
