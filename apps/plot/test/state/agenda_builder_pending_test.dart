import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_builder.dart';
import 'package:plot/state/agenda_model.dart' as ui;
import 'package:plot/store/store.dart';

Priority _testPriority({String path = 'p1', double order = 0}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
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
  group('AgendaBlock window getters', () {
    test('GapBlock.start/end come from range', () {
      final p = _testPriority();
      final start = DateTime(2026, 5, 14, 9);
      final end = DateTime(2026, 5, 14, 10);
      final block = ui.GapBlock(
        id: 'g',
        priority: p,
        range: DateTimeRange(start, end),
        threads: const [],
      );
      expect(block.start, start);
      expect(block.end, end);
    });

    test('PriorityBlock.start/end come from windowStart/windowEnd', () {
      final p = _testPriority();
      final start = DateTime(2026, 5, 14);
      final end = DateTime(2026, 5, 15);
      final block = ui.PriorityBlock(
        id: 'p',
        priority: p,
        threads: const [],
        windowStart: start,
        windowEnd: end,
      );
      expect(block.start, start);
      expect(block.end, end);
    });

    test('EventBlock.start/end come from event.at', () {
      final p = _testPriority();
      final start = DateTime(2026, 5, 14, 9);
      final end = DateTime(2026, 5, 14, 10);
      final event = Thread(
        priority: p,
        title: 'meeting',
        at: DateTimeRange(start, end),
      );
      final block = ui.EventBlock(
        id: 'e',
        priority: p,
        event: event,
        associated: const [],
      );
      expect(block.start, start);
      expect(block.end, end);
    });
  });

  group('AgendaBuilder block windows', () {
    setUp(() => Time.setFrozenTime(DateTime(2026, 5, 14, 14, 0)));
    tearDown(() => Time.unfreeze());

    test('standalone PriorityBlock with no time-anchored siblings uses '
        'section midnight to next midnight', () {
      final p = _testPriority();
      final t = Thread(priority: p, title: 't');
      final model = AgendaBuilder.build(
        threads: [t],
        context: p,
        horizonDays: 1,
      );
      final block = model.allBlocks.whereType<ui.PriorityBlock>().firstWhere(
        (b) => b.priority.id == p.id,
      );
      expect(block.start, DateTime(2026, 5, 14));
      expect(block.end, DateTime(2026, 5, 15));
    });
  });
}
