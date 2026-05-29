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
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
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

  group('AgendaBuilder explicit focus blocks (single time, no cascade)', () {
    setUp(() => Time.setFrozenTime(DateTime(2026, 5, 14, 14, 0)));
    tearDown(() => Time.unfreeze());

    PriorityBlockRow mkRow(Priority p, DateTime at, Duration d) =>
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

    test('a focus row renders as a standalone block at its own time, '
        'carrying its duration and source row', () {
      final p = _testPriority();
      final t = Thread(priority: p, title: 't');
      final row = mkRow(p, DateTime(2026, 5, 14, 16), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: [t],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );
      final fb = model.allBlocks
          .whereType<ui.PriorityBlock>()
          .firstWhere((b) => b.id == 'fb_${row.id}');
      expect(fb.windowStart, DateTime(2026, 5, 14, 16),
          reason: 'renders at its own effective_at');
      expect(fb.windowEnd, DateTime(2026, 5, 14, 17));
      expect(fb.cascadeDuration, const Duration(hours: 1));
      expect(fb.sourceRow?.id, row.id,
          reason: 'carries its row so drag-reschedule can move it');
    });

    test('a focus row renders at its own time even when it coincides with '
        'another block (no cascade onto a later slot)', () {
      // The row time (16:00) coincides with an event start. Previously the
      // focus block was suppressed and its duration cascaded onto the next
      // same-priority block. Now it always renders as its own block.
      final p = _testPriority();
      final event = Thread(
        priority: p,
        title: 'meeting',
        at: DateTimeRange(DateTime(2026, 5, 14, 16), DateTime(2026, 5, 14, 17)),
      );
      final row =
          mkRow(p, DateTime(2026, 5, 14, 16), const Duration(minutes: 30));
      final model = AgendaBuilder.build(
        threads: [event],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );
      final fbs = model.allBlocks
          .whereType<ui.PriorityBlock>()
          .where((b) => b.id == 'fb_${row.id}')
          .toList();
      expect(fbs.length, 1, reason: 'the row renders as its own block');
      expect(fbs.single.windowStart, DateTime(2026, 5, 14, 16));
    });

    test('a midnight row does not render (it is an order anchor, not a '
        'focus block)', () {
      final p = _testPriority();
      final t = Thread(priority: p, title: 't');
      final row = mkRow(p, DateTime(2026, 5, 14), const Duration(minutes: 30));
      final model = AgendaBuilder.build(
        threads: [t],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );
      expect(
        model.allBlocks
            .whereType<ui.PriorityBlock>()
            .where((b) => b.id == 'fb_${row.id}'),
        isEmpty,
      );
    });

    test('a row before today does not render', () {
      final p = _testPriority();
      final t = Thread(priority: p, title: 't');
      final row =
          mkRow(p, DateTime(2026, 5, 13, 16), const Duration(minutes: 30));
      final model = AgendaBuilder.build(
        threads: [t],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );
      expect(
        model.allBlocks
            .whereType<ui.PriorityBlock>()
            .where((b) => b.id == 'fb_${row.id}'),
        isEmpty,
      );
    });
  });
}
