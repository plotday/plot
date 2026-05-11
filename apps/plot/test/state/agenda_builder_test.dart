import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_builder.dart';
// `agenda_model.dart` and `store.dart` both export a `PriorityBlock`
// (the UI block vs the persisted block-order row). The store form
// isn't used here, so alias the model import.
import 'package:plot/state/agenda_model.dart' as ui;
import 'package:plot/store/store.dart';

/// Build a minimal [Priority] usable in unit tests.
/// Uses [Priority.fromStore] with [draft] = true so the constructor
/// does not try to register the priority with a parent or the Store.
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
    seeWithinRequestsSet: false,
    seeWithinUpdatesSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

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

  // Regression for the "drag one Using-Plot block, lose its other-day
  // siblings" bug. `PriorityBloc.moveBlock` used to filter
  // `_lastAgendaThreads` by priority alone, so a drag of one block
  // pulled in every same-priority thread across the whole agenda. The
  // fix scopes the move to `AgendaModel.blockById(blockId).threads`,
  // which already groups by `(date, period, priority)`. This test
  // anchors the contract `moveBlock` now relies on.
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
    );
    final tomorrowBlock = ui.PriorityBlock(
      id: 'p_tomorrow_${priority.path.value}_0',
      priority: priority,
      threads: [tomorrowThread],
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
      reason: 'today block must not include tomorrow\'s thread',
    );
    expect(fetchedToday.threads, isNot(contains(tomorrowThread)));

    final fetchedTomorrow = model.blockById(tomorrowBlock.id);
    expect(fetchedTomorrow, isNotNull);
    expect(
      fetchedTomorrow!.threads.map((t) => t.id).toSet(),
      {tomorrowThread.id},
    );

    expect(model.blockById('does-not-exist'), isNull);
  });

  group('AgendaBuilder.build is universal across priorities', () {
    setUp(() {
      // Freeze time so today's date and "now" placement are deterministic.
      Time.setFrozenTime(DateTime(2026, 5, 2, 14, 0));
    });
    tearDown(() => Time.unfreeze());

    test('produces a block per priority even when the priority is outside '
        'the in-context subtree', () {
      // Two different priorities, neither a parent of the other.
      final p1 = _testPriority(title: 'P1', path: 'p1', order: 0);
      final p2 = _testPriority(title: 'P2', path: 'p2', order: 1);

      // Two threads filed today (Thread() default createdAt = now).
      // Both are unscheduled / non-todo / unread=false: the simplest case.
      final t1 = Thread(priority: p1, title: 'on p1');
      final t2 = Thread(priority: p2, title: 'on p2');

      // Build with `context = p1`. Under the old behavior the agenda only
      // surfaced threads belonging to `context` or its descendants, so a
      // thread filed on `p2` (outside the subtree) would not appear in
      // any block. The universal builder must produce a block for both
      // priorities regardless of context.
      final model = AgendaBuilder.build(
        threads: [t1, t2],
        context: p1,
        horizonDays: 30,
      );

      // Find every PriorityBlock / GapBlock / EventBlock the model emits
      // and group them by priority.
      final blockPriorityIds = model.allBlocks.map((b) => b.priority.id).toSet();
      expect(
        blockPriorityIds,
        containsAll(<Uuid>{p1.id, p2.id}),
        reason: 'Both p1 and p2 must contribute at least one block, even '
            'though p2 is outside p1\'s subtree (context=$p1).',
      );

      // The thread filed on p2 must end up inside a block whose priority
      // is p2 — not silently bucketed into a p1 block.
      final p2Threads = model.allBlocks
          .where((b) => b.priority.id == p2.id)
          .expand((b) => b.threads)
          .toList();
      expect(p2Threads.map((t) => t.id), contains(t2.id));
    });

    test('recovers an unread thread whose agendaAt falls before today onto '
        'today\'s block via _mergeUnreadIntoToday', () {
      final p1 = _testPriority(title: 'P1', path: 'p1', order: 0);

      // An unread thread scheduled on a date BEFORE the frozen "today"
      // (2026-05-02). [PriorityState.makeAgendaItems] groups by
      // `agendaAt.toDate()` and then drops any group whose date is
      // before today (`!date.isBefore(today)`), so this thread never
      // makes it into the atom stream. Only the post-pass merge in
      // [AgendaBuilder._mergeUnreadIntoToday] can recover it onto the
      // today section — which is exactly what this test exercises.
      final pastUnread = Thread(
        priority: p1,
        title: 'forgotten unread',
        on: Day(Date(2026, 5, 1)),
      ).copyWith(unread: true);

      // A second thread that lands on today so the today section exists
      // with at least one PriorityBlock for `p1`. Without this, the merge
      // would still create a fresh PriorityBlock, but the explicit
      // setup keeps the test honest about the "merge into existing
      // same-priority block" path that production hits in the common
      // case.
      final todayThread = Thread(priority: p1, title: 'today note');

      final model = AgendaBuilder.build(
        threads: [pastUnread, todayThread],
        context: p1,
        horizonDays: 30,
      );

      // Locate the today section.
      final todaySection = model.sections
          .whereType<ui.DateSection>()
          .firstWhere((s) => s.isNow,
              orElse: () => throw StateError(
                  'expected a today (isNow) section in the model'));

      // The past-dated unread thread must surface inside today's p1
      // block. Without `_mergeUnreadIntoToday` it would be silently
      // dropped by the date-cutoff in `makeAgendaItems`.
      final p1Blocks = todaySection.blocks
          .whereType<ui.PriorityBlock>()
          .where((b) => b.priority.id == p1.id)
          .toList();
      expect(p1Blocks, isNotEmpty,
          reason: 'today must contain a p1 PriorityBlock to merge into');
      final mergedThreadIds =
          p1Blocks.expand((b) => b.threads).map((t) => t.id).toSet();
      expect(mergedThreadIds, contains(pastUnread.id),
          reason: 'past-dated unread thread must be recovered onto today '
              'by _mergeUnreadIntoToday');
      expect(mergedThreadIds, contains(todayThread.id),
          reason: 'today\'s own thread must remain in today\'s block');
    });
  });
}
