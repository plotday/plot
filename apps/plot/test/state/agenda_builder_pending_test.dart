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

  group('AgendaBuilder focus blocks split surrounding gaps', () {
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

    // Two future events leave a free gap [17:00, 19:00] between them.
    List<Thread> twoEvents(Priority p) => [
          Thread(
            priority: p,
            title: 'morning',
            at: DateTimeRange(
                DateTime(2026, 5, 14, 16), DateTime(2026, 5, 14, 17)),
          ),
          Thread(
            priority: p,
            title: 'evening',
            at: DateTimeRange(
                DateTime(2026, 5, 14, 19), DateTime(2026, 5, 14, 20)),
          ),
        ];

    test('a focus block dropped at the gap start shrinks the gap to the '
        'remaining time and moves it below the focus block', () {
      final p = _testPriority();
      // Focus block at the gap's start (17:00) for one hour.
      final row =
          mkRow(p, DateTime(2026, 5, 14, 17), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: twoEvents(p),
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );

      final blocks = model.allBlocks.toList();
      final fbIndex = blocks.indexWhere((b) => b.id == 'fb_${row.id}');
      // The inter-event gap is the one ending when the next event starts.
      final gapIndex = blocks.indexWhere(
        (b) => b is ui.GapBlock && b.range.end == DateTime(2026, 5, 14, 19),
      );

      expect(fbIndex, isNonNegative, reason: 'focus block renders');
      expect(gapIndex, isNonNegative, reason: 'a residual gap remains');
      expect(gapIndex, greaterThan(fbIndex),
          reason: 'the gap header moves below the focus block');

      final gap = blocks[gapIndex] as ui.GapBlock;
      expect(gap.range.start, DateTime(2026, 5, 14, 18),
          reason: 'gap now starts when the focus block ends');
      expect(gap.range.end, DateTime(2026, 5, 14, 19),
          reason: 'gap still ends at the next event');
    });

    test('a residual gap keeps the original gap start as its period anchor',
        () {
      final p = _testPriority();
      final row =
          mkRow(p, DateTime(2026, 5, 14, 17), const Duration(hours: 1));
      final model = AgendaBuilder.build(
        threads: twoEvents(p),
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );
      final gap = model.allBlocks.whereType<ui.GapBlock>().firstWhere(
            (g) => g.range.end == DateTime(2026, 5, 14, 19),
          );
      expect(gap.periodAnchor, DateTime(2026, 5, 14, 17),
          reason: 'drops into the residual still anchor at the original gap');
    });

    test('a focus block that fills the whole gap removes the gap header', () {
      final p = _testPriority();
      // Focus block spans the entire [17:00, 19:00] gap.
      final row =
          mkRow(p, DateTime(2026, 5, 14, 17), const Duration(hours: 2));
      final model = AgendaBuilder.build(
        threads: twoEvents(p),
        context: p,
        horizonDays: 1,
        priorityBlocksByPriority: {
          p.id: [row],
        },
      );
      // The inter-event gap should be gone; the trailing end-of-day gap
      // is unaffected.
      expect(
        model.allBlocks
            .whereType<ui.GapBlock>()
            .where((g) => g.range.end == DateTime(2026, 5, 14, 19)),
        isEmpty,
        reason: 'no time remains, so the gap header is removed',
      );
      expect(
        model.allBlocks.where((b) => b.id == 'fb_${row.id}'),
        isNotEmpty,
        reason: 'the focus block still renders',
      );
    });
  });
}
