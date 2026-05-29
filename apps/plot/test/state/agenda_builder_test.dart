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
      expect(model.allBlocks, isEmpty,
          reason: 'today section is the only section and it carries no blocks');
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

    test('a focus block renders from priorityById without any threads '
        '(root-priority regression)', () {
      // The root priority's agenda shows only descendants' events, so the
      // root never has a thread of its own in `threads`. A focus block on
      // it must still render — its Priority comes from `priorityById`, not
      // from threads. (Regression: it was silently dropped.)
      final root = _testPriority(title: 'Root', path: 'root');
      final row =
          _focusRow(root, DateTime(2026, 5, 14, 10), const Duration(hours: 2));
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
      final morning = Thread(
        priority: p,
        title: 'morning',
        at: DateTimeRange(DateTime(2026, 5, 14, 15), DateTime(2026, 5, 14, 16)),
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
      final gaps = model.allBlocks.whereType<ui.GapBlock>().toList();
      expect(gaps, hasLength(1));
      expect(gaps.single.range.start, DateTime(2026, 5, 14, 16));
      expect(gaps.single.range.end, DateTime(2026, 5, 14, 18));
      expect(gaps.single.threads, isEmpty, reason: 'gaps are read-only');
    });
  });
}
