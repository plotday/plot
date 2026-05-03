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
}
