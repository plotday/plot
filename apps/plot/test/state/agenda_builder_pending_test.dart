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

  group('AgendaBuilder per-block durations', () {
    setUp(() => Time.setFrozenTime(DateTime(2026, 5, 14, 14, 0)));
    tearDown(() => Time.unfreeze());

    test('only the first chronological block of a priority receives a '
        'duration row written at its window start', () {
      // Use two different priorities so each lands in a separate
      // PriorityBlock on today's section (same window start = today
      // midnight). The row for p1 has effectiveAt = today midnight;
      // a second row for p2 is absent. After _attachBlockDurations:
      //   • p1's block gets cascadeDuration = 30m
      //   • p2's block gets cascadeDuration = null
      // This exercises that per-block resolution attaches only to the
      // block whose window start satisfies the row, and does not bleed
      // the duration onto other priorities' blocks.
      final p1 = _testPriority(path: 'p1', order: 0);
      final p2 = _testPriority(path: 'p2', order: 1);
      final t1 = Thread(priority: p1, title: 'thread on p1');
      final t2 = Thread(priority: p2, title: 'thread on p2');
      final rows = {
        p1.id: [
          PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: p1.id,
            createdBy: Uuid.generate(),
            orderValue: Order(0),
            effectiveAt: DateTime(2026, 5, 14),  // today midnight
            duration: const Duration(minutes: 30),
            archivedAt: null,
            createdAt: DateTime(2026, 5, 14),
            updatedAt: DateTime(2026, 5, 14),
          ),
        ],
      };
      final model = AgendaBuilder.build(
        threads: [t1, t2],
        context: p1,
        horizonDays: 1,
        priorityBlocksByPriority: rows,
      );
      final blocks = model.allBlocks.whereType<ui.PriorityBlock>().toList();
      expect(blocks.length, 2,
          reason: 'one PriorityBlock per priority');
      final p1Block = blocks.firstWhere((b) => b.priority.id == p1.id);
      final p2Block = blocks.firstWhere((b) => b.priority.id == p2.id);
      expect(p1Block.cascadeDuration, const Duration(minutes: 30),
          reason: 'p1 block consumes its row');
      expect(p2Block.cascadeDuration, isNull,
          reason: 'p2 has no row so its block gets no duration');
    });

    test('GapBlock receives cascadeDuration when its priority has a row at '
        'the gap start', () {
      final p = _testPriority();
      // Two events frame a gap: event 11-12 and laterEvent 15-16.
      // The agenda produces:
      //   PriorityBlock   start=midnight (before the 11am event)
      //   EventBlock      laterEvent at 15:00
      //   GapBlock        start=16:00 (after laterEvent)
      // A row with effectiveAt=16:00 must attach to the GapBlock only.
      // The PriorityBlock at midnight is chronologically earlier, so the
      // row walker won't advance to it (effectiveAt 16:00 > block start
      // midnight). The GapBlock's start == effectiveAt, so it picks up
      // the 45m duration.
      final event = Thread(
        priority: p,
        title: 'meeting',
        at: DateTimeRange(
          DateTime(2026, 5, 14, 11),
          DateTime(2026, 5, 14, 12),
        ),
      );
      final laterEvent = Thread(
        priority: p,
        title: 'later',
        at: DateTimeRange(
          DateTime(2026, 5, 14, 15),
          DateTime(2026, 5, 14, 16),
        ),
      );
      final gapStart = DateTime(2026, 5, 14, 16); // GapBlock.range.start
      final rows = {
        p.id: [
          PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: p.id,
            createdBy: Uuid.generate(),
            orderValue: Order(0),
            effectiveAt: gapStart,
            duration: const Duration(minutes: 45),
            archivedAt: null,
            createdAt: gapStart,
            updatedAt: gapStart,
          ),
        ],
      };
      final model = AgendaBuilder.build(
        threads: [event, laterEvent],
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: rows,
      );
      // The GapBlock at gapStart gets the duration.
      final gap = model.allBlocks.whereType<ui.GapBlock>().firstWhere(
        (b) => b.range.start == gapStart,
      );
      expect(gap.cascadeDuration, const Duration(minutes: 45),
          reason: 'GapBlock at the row\'s effective_at picks up the duration');
      // The PriorityBlock at midnight should NOT get it (row is after its start).
      final priorityBlocks = model.allBlocks.whereType<ui.PriorityBlock>().toList();
      for (final b in priorityBlocks) {
        expect(b.cascadeDuration, isNull,
            reason: 'PriorityBlock at midnight has no row at or before its start');
      }
    });

    test('row at today midnight attaches to today\'s block only, not to '
        'subsequent days\' blocks of the same priority', () {
      final p = _testPriority();
      // Today: an event so we get a PriorityBlock before it (gap before 10am).
      // Tomorrow: an event + trailing GapBlock for the same priority.
      // A row at today midnight attaches only to today's PriorityBlock.
      // The sum of all cascadeDurations across all blocks for p == 30m.
      final todayEvent = Thread(
        priority: p,
        title: 'today',
        at: DateTimeRange(
          DateTime(2026, 5, 14, 10),
          DateTime(2026, 5, 14, 11),
        ),
      );
      final tomorrowEvent = Thread(
        priority: p,
        title: 'tomorrow',
        at: DateTimeRange(
          DateTime(2026, 5, 15, 10),
          DateTime(2026, 5, 15, 11),
        ),
      );
      final rows = {
        p.id: [
          PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: p.id,
            createdBy: Uuid.generate(),
            orderValue: Order(0),
            effectiveAt: DateTime(2026, 5, 14), // today midnight
            duration: const Duration(minutes: 30),
            archivedAt: null,
            createdAt: DateTime(2026, 5, 14),
            updatedAt: DateTime(2026, 5, 14),
          ),
        ],
      };
      final model = AgendaBuilder.build(
        threads: [todayEvent, tomorrowEvent],
        context: p,
        horizonDays: 3,
        priorityBlocksByPriority: rows,
      );
      // Sum cascadeDurations across all PriorityBlock + GapBlock for p.
      // Exactly one block should consume the row — total must equal 30m.
      final blocksForP = model.allBlocks
          .where((b) =>
              (b is ui.PriorityBlock || b is ui.GapBlock) &&
              b.priority.id == p.id)
          .toList();
      final totalCascade = blocksForP.fold<Duration>(
        Duration.zero,
        (acc, b) {
          if (b is ui.PriorityBlock) {
            return acc + (b.cascadeDuration ?? Duration.zero);
          }
          if (b is ui.GapBlock) {
            return acc + (b.cascadeDuration ?? Duration.zero);
          }
          return acc;
        },
      );
      expect(totalCascade, const Duration(minutes: 30),
          reason: 'exactly one block consumes the row');
    });
  });
}
