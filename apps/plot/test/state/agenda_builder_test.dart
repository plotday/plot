import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_builder.dart';
// `agenda_model.dart` and `store.dart` both export a `PriorityBlock`
// (the UI block vs the persisted block-order row). The store form
// isn't used here, so alias the model import.
import 'package:plot/state/agenda_model.dart' as ui;
import 'package:plot/store/store.dart';

/// Build a minimal [Priority] usable in unit tests.
Priority _testPriority({
  String title = 'Test',
  String path = 'test',
  double order = 0,
}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(path),
    order: Order(order),
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

PriorityBlockRow _focusRow(Priority p, DateTime at, Duration d) =>
    PriorityBlockRow(
      id: Uuid.generate(),
      priorityId: p.id,
      createdBy: Uuid.generate(),
      orderValue: Order(0),
      effectiveAt: at,
      duration: d,
      archivedAt: null,
      createdAt: DateTime(2026, 5, 14),
      updatedAt: DateTime(2026, 5, 14),
    );

void main() {
  test('empty threads list produces empty model', () {
    final context = _testPriority();
    final model = AgendaBuilder.build(
      threads: const [],
      context: context,
      horizonDays: 30,
    );
    expect(model.sections, isEmpty);
    expect(model, ui.AgendaModel.empty);
  });

  // `PriorityBloc.moveFocusBlock` relies on `blockById(...).threads`
  // returning only that block's threads. Anchors that contract.
  test(
      'blockById returns only that block\'s threads when one priority has '
      'multiple blocks on different dates', () {
    final priority = _testPriority();
    final today = Date(2026, 5, 2);
    final tomorrow = today.addDays(1);

    final todayThreadA = Thread(priority: priority, title: 'today A');
    final todayThreadB = Thread(priority: priority, title: 'today B');
    final tomorrowThread = Thread(priority: priority, title: 'tomorrow');

    final todayBlock = ui.PriorityBlock(
      id: 'p_today_${priority.path.value}_0',
      priority: priority,
      threads: [todayThreadA, todayThreadB],
      windowStart: DateTime(2026, 5, 2),
      windowEnd: DateTime(2026, 5, 3),
    );
    final tomorrowBlock = ui.PriorityBlock(
      id: 'p_tomorrow_${priority.path.value}_0',
      priority: priority,
      threads: [tomorrowThread],
      windowStart: DateTime(2026, 5, 3),
      windowEnd: DateTime(2026, 5, 4),
    );

    final model = ui.AgendaModel(sections: [
      ui.DateSection(date: today, blocks: [todayBlock]),
      ui.DateSection(date: tomorrow, blocks: [tomorrowBlock]),
    ]);

    final fetchedToday = model.blockById(todayBlock.id);
    expect(fetchedToday, isNotNull);
    expect(
      fetchedToday!.threads.map((t) => t.id).toSet(),
      {todayThreadA.id, todayThreadB.id},
    );
    expect(fetchedToday.threads, isNot(contains(tomorrowThread)));
    expect(model.blockById('does-not-exist'), isNull);
  });

  group('explicit-only agenda', () {
    setUp(() => Time.setFrozenTime(DateTime(2026, 5, 14, 14, 0)));
    tearDown(() => Time.unfreeze());

    Iterable<Uuid> threadIdsOf(ui.AgendaModel model) =>
        model.allThreads.map((t) => t.id);

    // Frozen now = 2026-05-14 14:00 (group setUp).
    final today = Date(2026, 5, 14);

    // Gaps filed under [date]'s section. Empty days now each carry a
    // full-day gap, so gap assertions scope to one day rather than counting
    // every gap in the model.
    List<ui.GapBlock> gapsOn(ui.AgendaModel model, Date date) => model.sections
        .whereType<ui.DateSection>()
        .where((s) => s.date == date)
        .expand((s) => s.blocks)
        .whereType<ui.GapBlock>()
        .toList();

    test('a timed event appears as an EventBlock at its time', () {
      final p = _testPriority();
      final event = Thread(
        priority: p,
        title: 'meeting',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
      );
      final model = AgendaBuilder.build(
        threads: [event],
        context: p,
        horizonDays: 1,
      );
      final blocks = model.allBlocks.whereType<ui.EventBlock>().toList();
      expect(blocks, hasLength(1));
      expect(blocks.single.event.id, event.id);
      expect(blocks.single.start, DateTime(2026, 5, 14, 15));
    });

    test('a todo scheduled for a day creates NO block (the implicit '
        'priority-block bug)', () {
      final p = _testPriority();
      // A task the user scheduled for today via per-user state_on. The old
      // agenda grouped it into a timeless PriorityBlock; the explicit-only
      // agenda must not show it at all.
      final scheduledTodo = Thread(
        priority: p,
        title: 'do this today',
        active: true,
        stateOrder: Order.first(),
        stateOn: Date(2026, 5, 14),
      );
      expect(scheduledTodo.todo, isTrue);
      final model = AgendaBuilder.build(
        threads: [scheduledTodo],
        context: p,
        horizonDays: 1,
      );
      expect(model.allBlocks.whereType<ui.PriorityBlock>(), isEmpty,
          reason: 'scheduling a task must not create a priority block');
      expect(model.allBlocks.whereType<ui.EventBlock>(), isEmpty);
      expect(threadIdsOf(model), isNot(contains(scheduledTodo.id)));
    });

    test('a todo pinned to a time creates NO block', () {
      final p = _testPriority();
      final pinned = Thread(
        priority: p,
        title: 'pinned task',
        active: true,
        stateOrder: Order.first(),
        stateAt: DateTime(2026, 5, 14, 15),
      );
      expect(pinned.todo, isTrue);
      final model = AgendaBuilder.build(
        threads: [pinned],
        context: p,
        horizonDays: 1,
      );
      expect(model.allBlocks.where((b) => b is! ui.GapBlock), isEmpty,
          reason: 'a pinned task must not create a content block');
      expect(threadIdsOf(model), isNot(contains(pinned.id)));
    });

    test('a plain note with no schedule creates NO block', () {
      final p = _testPriority();
      final note = Thread(priority: p, title: 'just a note');
      final model = AgendaBuilder.build(
        threads: [note],
        context: p,
        horizonDays: 1,
      );
      expect(threadIdsOf(model), isNot(contains(note.id)));
      expect(model.allBlocks.where((b) => b is! ui.GapBlock), isEmpty);
    });

    test('events from priorities outside the context subtree still appear', () {
      final p1 = _testPriority(title: 'P1', path: 'p1', order: 0);
      final p2 = _testPriority(title: 'P2', path: 'p2', order: 1);
      final e1 = Thread(
        priority: p1,
        title: 'on p1',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
      );
      final e2 = Thread(
        priority: p2,
        title: 'on p2',
        at: DateTimeRange(DateTime(2026, 5, 14, 17), DateTime(2026, 5, 14, 18)),
      );
      final model = AgendaBuilder.build(
        threads: [e1, e2],
        context: p1, // p2 is outside p1's subtree
        horizonDays: 1,
      );
      expect(threadIdsOf(model), containsAll(<Uuid>{e1.id, e2.id}));
    });

    test('a past-dated event is not recovered onto today', () {
      final p = _testPriority();
      final pastEvent = Thread(
        priority: p,
        title: 'yesterday meeting',
        at: DateTimeRange(DateTime(2026, 5, 13, 9), DateTime(2026, 5, 13, 10)),
      );
      final todayEvent = Thread(
        priority: p,
        title: 'today meeting',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
      );
      final model = AgendaBuilder.build(
        threads: [pastEvent, todayEvent],
        context: p,
        horizonDays: 1,
      );
      final todaySection = model.sections
          .whereType<ui.DateSection>()
          .firstWhere((s) => s.isNow);
      final ids = todaySection.blocks.expand((b) => b.threads).map((t) => t.id);
      expect(ids, isNot(contains(pastEvent.id)));
      expect(ids, contains(todayEvent.id));
    });

    test('an explicit focus block appears as a PriorityBlock at its time', () {
      final p = _testPriority();
      final row = _focusRow(p, DateTime(2026, 5, 14, 16), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
        priorityById: {p.id: p},
      );
      final fb = model.allBlocks
          .whereType<ui.PriorityBlock>()
          .firstWhere((b) => b.id == 'fb_${row.id}');
      expect(fb.windowStart, DateTime(2026, 5, 14, 16));
      expect(fb.windowEnd, DateTime(2026, 5, 14, 17));
      expect(fb.sourceRow?.id, row.id);
    });

    test('a focus block scheduled at exactly midnight renders at the top of '
        'its day with no leading gap before it', () {
      final p = _testPriority();
      final tomorrow = today.addDays(1);
      // Midnight (00:00) focus block, 1h long — a real user-scheduled block,
      // not an order-timeline anchor.
      final row = _focusRow(p, tomorrow.toDateTime(), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 2,
        priorityBlocksByPriority: {
          p.id: [row],
        },
        priorityById: {p.id: p},
      );
      final fb = model.allBlocks
          .whereType<ui.PriorityBlock>()
          .firstWhere((b) => b.id == 'fb_${row.id}');
      expect(fb.windowStart, tomorrow.toDateTime());
      expect(
        fb.windowEnd,
        tomorrow.toDateTime().add(const Duration(hours: 1)),
      );
      // No leading-edge gap before it (its start IS the day boundary); only
      // the trailing gap from 01:00 to the next midnight.
      final gaps = gapsOn(model, tomorrow);
      expect(
        gaps.where((g) => g.range.start == tomorrow.toDateTime()),
        isEmpty,
        reason: 'a midnight block suppresses the leading-edge gap',
      );
      expect(gaps, hasLength(1));
      expect(
        gaps.single.range.start,
        tomorrow.toDateTime().add(const Duration(hours: 1)),
      );
      expect(gaps.single.range.end, tomorrow.addDays(1).toDateTime());
    });

    test('a focus block renders from priorityById without any threads '
        '(root-priority regression)', () {
      // The root priority's agenda shows only descendants' events, so the
      // root never has a thread of its own in `threads`. A focus block on
      // it must still render — its Priority comes from `priorityById`, not
      // from threads. (Regression: it was silently dropped.)
      final root = _testPriority(title: 'Root', path: 'root');
      final row =
          _focusRow(root, DateTime(2026, 5, 14, 16), const Duration(hours: 2));
      final model = AgendaBuilder.build(
        threads: const [],
        context: root,
        horizonDays: 1,
        priorityBlocksByPriority: {
          root.id: [row],
        },
        priorityById: {root.id: root},
      );
      final fb = model.allBlocks.whereType<ui.PriorityBlock>().toList();
      expect(fb, hasLength(1), reason: 'block must render with no threads');
      expect(fb.single.id, 'fb_${row.id}');
      expect(fb.single.priority.id, root.id);
      expect(fb.single.threads, isEmpty);
    });

    test('a focus block whose priority is absent from priorityById is skipped',
        () {
      final p = _testPriority();
      final row =
          _focusRow(p, DateTime(2026, 5, 14, 16), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
        // priorityById intentionally omitted.
      );
      expect(model.allBlocks.whereType<ui.PriorityBlock>(), isEmpty);
    });

    test('a read-only gap marks the free space between two events', () {
      final p = _testPriority();
      // `morning` is in progress (13:30–14:30 spans the frozen now 14:00),
      // so no leading "Now" gap precedes it; the free space until the
      // evening event is the only gap.
      final morning = Thread(
        priority: p,
        title: 'morning',
        at: DateTimeRange(
            DateTime(2026, 5, 14, 13, 30), DateTime(2026, 5, 14, 14, 30)),
      );
      final evening = Thread(
        priority: p,
        title: 'evening',
        at: DateTimeRange(DateTime(2026, 5, 14, 18), DateTime(2026, 5, 14, 19)),
      );
      final model = AgendaBuilder.build(
        threads: [morning, evening],
        context: p,
        horizonDays: 1,
      );
      // Today's gaps: the between-events gap, plus a trailing edge gap from
      // the evening event's end (19:00) to midnight.
      final gaps = gapsOn(model, today);
      expect(gaps, hasLength(2));
      final between = gaps.firstWhere(
        (g) => g.range.start == DateTime(2026, 5, 14, 14, 30),
      );
      expect(between.range.end, DateTime(2026, 5, 14, 18));
      expect(between.threads, isEmpty, reason: 'gaps are read-only');
      final trailing = gaps.firstWhere(
        (g) => g.range.start == DateTime(2026, 5, 14, 19),
      );
      expect(trailing.range.end, DateTime(2026, 5, 15));
    });

    // Frozen now = 2026-05-14 14:00 (see group setUp).

    test('an event that already ended today is dropped', () {
      final p = _testPriority();
      final ended = Thread(
        priority: p,
        title: 'this morning',
        at: DateTimeRange(DateTime(2026, 5, 14, 9), DateTime(2026, 5, 14, 10)),
      );
      final upcoming = Thread(
        priority: p,
        title: 'this afternoon',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
      );
      final model = AgendaBuilder.build(
        threads: [ended, upcoming],
        context: p,
        horizonDays: 1,
      );
      final ids = threadIdsOf(model);
      expect(ids, isNot(contains(ended.id)),
          reason: 'a non-link event that ended before now is removed');
      expect(ids, contains(upcoming.id));
    });

    test('an in-progress event is kept and marked current', () {
      final p = _testPriority();
      final ongoing = Thread(
        priority: p,
        title: 'happening now',
        at: DateTimeRange(
            DateTime(2026, 5, 14, 13, 30), DateTime(2026, 5, 14, 14, 30)),
      );
      final model = AgendaBuilder.build(
        threads: [ongoing],
        context: p,
        horizonDays: 1,
      );
      final events = model.allBlocks.whereType<ui.EventBlock>().toList();
      expect(events, hasLength(1));
      expect(events.single.event.id, ongoing.id);
      expect(events.single.isCurrent, isTrue);
    });

    test('an in-progress focus block is marked current', () {
      final p = _testPriority();
      // 13:00–15:00 spans the frozen now (14:00).
      final row =
          _focusRow(p, DateTime(2026, 5, 14, 13), const Duration(hours: 2));
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
        priorityById: {p.id: p},
      );
      final blocks = model.allBlocks.whereType<ui.PriorityBlock>().toList();
      expect(blocks, hasLength(1));
      expect(blocks.single.isCurrent, isTrue);
    });

    test('a future focus block is not marked current', () {
      final p = _testPriority();
      final row =
          _focusRow(p, DateTime(2026, 5, 14, 16), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
        priorityById: {p.id: p},
      );
      final blocks = model.allBlocks.whereType<ui.PriorityBlock>().toList();
      expect(blocks, hasLength(1));
      expect(blocks.single.isCurrent, isFalse);
    });

    test('a focus block that already ended today is dropped', () {
      final p = _testPriority();
      // 9:00–10:00 ended before the frozen now (14:00).
      final row =
          _focusRow(p, DateTime(2026, 5, 14, 9), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: const [],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
        priorityById: {p.id: p},
      );
      expect(model.allBlocks.whereType<ui.PriorityBlock>(), isEmpty,
          reason: 'a focus block that ended before now is removed');
    });

    test('free time before the next block surfaces as a current ("Now") gap',
        () {
      final p = _testPriority();
      // No in-progress block, next event at 16:00 → the agenda synthesizes
      // a gap from now (14:00) to 16:00, marked current.
      final later = Thread(
        priority: p,
        title: 'late meeting',
        at: DateTimeRange(DateTime(2026, 5, 14, 16), DateTime(2026, 5, 14, 17)),
      );
      final model = AgendaBuilder.build(
        threads: [later],
        context: p,
        horizonDays: 1,
      );
      // The current "Now" gap, plus a trailing edge gap from the event's
      // end (17:00) to midnight.
      final gaps = gapsOn(model, today);
      expect(gaps, hasLength(2));
      final nowGap = gaps.firstWhere(
        (g) => g.range.start == DateTime(2026, 5, 14, 14),
      );
      expect(nowGap.range.end, DateTime(2026, 5, 14, 16));
      expect(nowGap.isCurrent, isTrue);
      final trailing = gaps.firstWhere(
        (g) => g.range.start == DateTime(2026, 5, 14, 17),
      );
      expect(trailing.range.end, DateTime(2026, 5, 15));
      expect(trailing.isCurrent, isFalse);
    });

    test('no "Now" gap when the first block is already in progress', () {
      final p = _testPriority();
      final ongoing = Thread(
        priority: p,
        title: 'happening now',
        at: DateTimeRange(
            DateTime(2026, 5, 14, 13, 30), DateTime(2026, 5, 14, 15)),
      );
      final model = AgendaBuilder.build(
        threads: [ongoing],
        context: p,
        horizonDays: 1,
      );
      // No leading "Now" gap is synthesized before the in-progress event;
      // the only gap is the trailing edge gap from its end (15:00) to
      // midnight.
      final gaps = gapsOn(model, today);
      expect(gaps, hasLength(1));
      expect(gaps.single.range.start, DateTime(2026, 5, 14, 15));
      expect(gaps.single.range.end, DateTime(2026, 5, 15));
      expect(gaps.single.isCurrent, isFalse);
    });

    test('a future empty day gets one full-day (midnight→midnight) gap', () {
      final p = _testPriority();
      // One event today keeps the agenda non-empty; tomorrow is empty and
      // should surface a single full-day gap.
      final event = Thread(
        priority: p,
        title: 'standup',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
      );
      final model = AgendaBuilder.build(
        threads: [event],
        context: p,
        horizonDays: 30,
      );
      final tomorrow = today.addDays(1);
      final gaps = gapsOn(model, tomorrow);
      expect(gaps, hasLength(1));
      expect(gaps.single.range.start, tomorrow.toDateTime());
      expect(gaps.single.range.end, tomorrow.addDays(1).toDateTime());
      expect(gaps.single.threads, isEmpty);
      expect(gaps.single.isCurrent, isFalse);
    });

    test('an empty today gets the same full-day gap, not "Now"', () {
      final p = _testPriority();
      // Content only on a later day, so today renders but is empty.
      final later = Thread(
        priority: p,
        title: 'later',
        at: DateTimeRange(DateTime(2026, 5, 17, 10), DateTime(2026, 5, 17, 11)),
      );
      final model = AgendaBuilder.build(
        threads: [later],
        context: p,
        horizonDays: 30,
      );
      final gaps = gapsOn(model, today);
      expect(gaps, hasLength(1));
      expect(gaps.single.range.start, today.toDateTime());
      expect(gaps.single.range.end, today.addDays(1).toDateTime());
      // "Now" is reserved for an in-progress block; an empty day has none.
      expect(gaps.single.isCurrent, isFalse);
    });

    test('a day with a scheduled event gets no full-day empty-day gap', () {
      final p = _testPriority();
      final event = Thread(
        priority: p,
        title: 'standup',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
      );
      final model = AgendaBuilder.build(
        threads: [event],
        context: p,
        horizonDays: 1,
      );
      // The full-day empty-day gap spans the whole day; edge gaps never do.
      final fullDay = gapsOn(model, today).where(
        (g) =>
            g.range.start == today.toDateTime() &&
            g.range.end == today.addDays(1).toDateTime(),
      );
      expect(fullDay, isEmpty);
    });
  });
}
