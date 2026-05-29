import 'package:flutter_test/flutter_test.dart';

import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/agenda_block_drag.dart';

/// Regression tests for the Margot seed scenario:
///
///   12:00 gap (financial admin, 2 todos)
///   12:30 lunch event
///   13:30 gap (personal_dev, 2 todos)   ← "1:30 pm block"
///   14:00 FA call event
///   14:30 gap (media_pr, 2 todos)        ← "2:30 pm block" (SOURCE)
///   15:30 gap (commercial)
///
/// The user can't drag the 14:30 block "into the 1:30 pm block (either
/// before or after the existing block there)." The pre-fix dispatch
/// landed top-half drops in the *previous* period (12:00) instead of the
/// gap's own period (13:30), which felt like the drop didn't merge.

Priority _priority(String title) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(title.toLowerCase().replaceAll(' ', '_')),
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

/// Build an [AgendaHeaderItem] for a gap header (priority-tinted block
/// header). Mirrors what `AgendaModel.flatItems` emits for a [GapBlock]
/// with threads.
AgendaHeaderItem _gapHeader({
  required DateTime gapStart,
  required DateTime gapEnd,
  required Priority priority,
  required String blockId,
  required Date date,
  required int visibleCount,
}) =>
    AgendaHeaderItem(
      dateTimeRange: DateTimeRange(gapStart, gapEnd),
      blockPriority: priority,
      parentBlockId: blockId,
      sourceDate: date,
      sourcePeriodStart: gapStart,
      parentBlockVisibleCount: visibleCount,
    );

AgendaHeaderItem _eventHeader({
  required Thread event,
  required DateTime start,
  required DateTime end,
  required Priority priority,
  required String blockId,
  required Date date,
  required DateTime? periodStart,
}) =>
    AgendaHeaderItem(
      dateTimeRange: DateTimeRange(start, end),
      thread: event,
      blockPriority: priority,
      parentBlockId: blockId,
      sourceDate: date,
      sourcePeriodStart: periodStart,
      parentBlockVisibleCount: 1,
    );

AgendaThreadItem _thread(Thread t, String blockId) =>
    AgendaThreadItem(t, parentBlockId: blockId);

void main() {
  // Constants matching the seed (May 1, 2026 EDT).
  final date = Date(2026, 5, 1);
  final t1200 = DateTime(2026, 5, 1, 12, 0);
  final t1230 = DateTime(2026, 5, 1, 12, 30);
  final t1330 = DateTime(2026, 5, 1, 13, 30);
  final t1400 = DateTime(2026, 5, 1, 14, 0);
  final t1430 = DateTime(2026, 5, 1, 14, 30);
  final t1500 = DateTime(2026, 5, 1, 15, 0);
  final t1530 = DateTime(2026, 5, 1, 15, 30);
  final t1800 = DateTime(2026, 5, 1, 18, 0);

  final financialMgmt = _priority('financial');
  final commercial = _priority('commercial');
  final boardProcess = _priority('board');
  final personalDev = _priority('personal');
  final mediaPr = _priority('media');

  // Block ids — match the format `AgendaBuilder` produces for gap and
  // event blocks. Tests don't need to match exactly; uniqueness is enough.
  const block1200 = 'g_may1_1200';
  const block1230 = 'e_may1_lunch';
  const block1330 = 'g_may1_1330';
  const block1400 = 'e_may1_fa';
  const block1430 = 'g_may1_1430';
  const block1530 = 'g_may1_1530';

  final lunchEvent = Thread(priority: commercial, title: 'Avenir lunch');
  final faEvent = Thread(priority: boardProcess, title: 'FA call');

  final capex = Thread(priority: financialMgmt, title: 'CapEx');
  final embry = Thread(priority: financialMgmt, title: 'Embry digest');
  final pen = Thread(priority: personalDev, title: 'Pen brunch');
  final noteToSelf = Thread(priority: personalDev, title: 'Note to self');
  final posy = Thread(priority: mediaPr, title: 'Posy');
  final sentiment = Thread(priority: mediaPr, title: 'Sentiment');
  final avenir = Thread(priority: commercial, title: 'Avenir follow-up');
  final sponsor = Thread(priority: commercial, title: 'Sponsor pipeline');

  final items = <AgendaItem>[
    AgendaHeaderItem(date: date),
    _gapHeader(
      gapStart: t1200,
      gapEnd: t1230,
      priority: financialMgmt,
      blockId: block1200,
      date: date,
      visibleCount: 2,
    ),
    _thread(capex, block1200),
    _thread(embry, block1200),
    _eventHeader(
      event: lunchEvent,
      start: t1230,
      end: t1330,
      priority: commercial,
      blockId: block1230,
      date: date,
      periodStart: t1200,
    ),
    _thread(lunchEvent, block1230),
    _gapHeader(
      gapStart: t1330,
      gapEnd: t1400,
      priority: personalDev,
      blockId: block1330,
      date: date,
      visibleCount: 2,
    ),
    _thread(pen, block1330),
    _thread(noteToSelf, block1330),
    _eventHeader(
      event: faEvent,
      start: t1400,
      end: t1430,
      priority: boardProcess,
      blockId: block1400,
      date: date,
      periodStart: t1330,
    ),
    _thread(faEvent, block1400),
    _gapHeader(
      gapStart: t1430,
      gapEnd: t1500,
      priority: mediaPr,
      blockId: block1430,
      date: date,
      visibleCount: 2,
    ),
    _thread(posy, block1430),
    _thread(sentiment, block1430),
    _gapHeader(
      gapStart: t1530,
      gapEnd: t1800,
      priority: commercial,
      blockId: block1530,
      date: date,
      visibleCount: 2,
    ),
    _thread(avenir, block1530),
    _thread(sponsor, block1530),
  ];

  group('Margot seed boundary builder', () {
    test(
        'boundary above the 1:30 pm gap header lands drops in the 1:30 pm '
        "period — not the previous (12:00) period. Pre-fix this was the bug "
        'that made dragging the 2:30 block "before the 1:30 block" silently '
        'land the threads in the 12:00 period instead of merging into 1:30.',
        () {
      final boundaries = computeBlockDropBoundaries(items: items);

      // Find the index of the 13:30 gap header.
      final idx1330 = items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1330,
      );
      expect(idx1330, isNonNegative);

      final boundary = boundaries.before[idx1330];
      expect(boundary, isNotNull,
          reason: 'gap header must have a before-boundary');
      expect(boundary!.targetPeriodStart, t1330,
          reason: 'boundary above 1:30 pm gap header must use 1:30 (the '
              "gap's own period), not 12:00 (the previous period)");
      expect(boundary.nextBlockId, block1330);
      expect(boundary.nextIsEvent, false);
    });

    test(
        'boundary above the 14:00 FA event header still uses the 13:30 period '
        '(events do not own a period of their own)', () {
      final boundaries = computeBlockDropBoundaries(items: items);

      final idx1400 = items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1400,
      );
      expect(idx1400, isNonNegative);

      final boundary = boundaries.before[idx1400];
      expect(boundary, isNotNull);
      expect(boundary!.targetPeriodStart, t1330,
          reason: 'event headers do not own a period — boundary keeps the '
              'surrounding (1:30 pm) period');
      expect(boundary.nextIsEvent, true);
    });

    test(
        'boundary above the 14:30 gap header (the source itself in this '
        "scenario) uses 14:30 — the gap's own period — so the source's slot "
        'is correctly attributed to its block', () {
      final boundaries = computeBlockDropBoundaries(items: items);

      final idx1430 = items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1430,
      );
      expect(idx1430, isNonNegative);

      final boundary = boundaries.before[idx1430];
      expect(boundary, isNotNull);
      expect(boundary!.targetPeriodStart, t1430);
    });

    test(
        'boundary above the 15:30 gap header uses 15:30 (its own period), so '
        'a drop just above it lands in the 15:30 period — not 14:30',
        () {
      final boundaries = computeBlockDropBoundaries(items: items);

      final idx1530 = items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1530,
      );
      expect(idx1530, isNonNegative);

      final boundary = boundaries.before[idx1530];
      expect(boundary, isNotNull);
      expect(boundary!.targetPeriodStart, t1530,
          reason: 'gap headers always own their period in the boundary above');
    });

    test(
        'boundary above the lunch event uses 12:00 (the surrounding period), '
        'unchanged from earlier behavior', () {
      final boundaries = computeBlockDropBoundaries(items: items);

      final idx1230 = items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1230,
      );
      expect(idx1230, isNonNegative);

      final boundary = boundaries.before[idx1230];
      expect(boundary, isNotNull);
      expect(boundary!.targetPeriodStart, t1200,
          reason: 'event headers keep the surrounding period');
      expect(boundary.nextIsEvent, true);
    });

    test(
        'boundary above the 12:00 gap header (first block of the day) uses '
        '12:00 (the gap\'s own period), giving the user a meaningful drop '
        'target at the very top of the day instead of a null anchor',
        () {
      final boundaries = computeBlockDropBoundaries(items: items);

      final idx1200 = items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1200,
      );
      expect(idx1200, isNonNegative);

      final boundary = boundaries.before[idx1200];
      expect(boundary, isNotNull);
      expect(boundary!.targetPeriodStart, t1200,
          reason: 'first gap of the day owns its period — drops above it '
              "land in 12:00, not in null/fallback");
    });
  });

  group('Margot seed activation', () {
    // Under the block-region drop-area model, cursor anywhere in the
    // 1:30 pm region activates the slot AFTER the 1:30 block (= the
    // slot just before the 14:00 FA event). The dispatched target's
    // `targetPeriodStart` is t1330 because the FA event inherits the
    // 1:30 gap's period — so dropping there still merges the dragged
    // block into the 1:30 period.
    test(
        'cursor in the 1:30 pm region (any half) activates the slot before '
        'the 14:00 FA event — drop dispatches moveBlock(13:30), merging into '
        'the 1:30 period',
        () {
      final boundaries = computeBlockDropBoundaries(items: items);
      final s1330 = boundaries.before[items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1330,
      )]!;
      final s1400 = boundaries.before[items.indexWhere(
        (e) => e is AgendaHeaderItem && e.parentBlockId == block1400,
      )]!;

      final slots = <({Object key, double y, BlockDropTarget target})>[
        (key: 's_1200', y: 100, target: boundaries.before[items.indexWhere(
          (e) => e is AgendaHeaderItem && e.parentBlockId == block1200,
        )]!),
        (key: 's_1230', y: 240, target: boundaries.before[items.indexWhere(
          (e) => e is AgendaHeaderItem && e.parentBlockId == block1230,
        )]!),
        (key: 's_1330', y: 290, target: s1330),
        (key: 's_1400', y: 430, target: s1400),
        (key: 's_1430', y: 480, target: boundaries.before[items.indexWhere(
          (e) => e is AgendaHeaderItem && e.parentBlockId == block1430,
        )]!),
        (key: 's_1530', y: 620, target: boundaries.before[items.indexWhere(
          (e) => e is AgendaHeaderItem && e.parentBlockId == block1530,
        )]!),
        (key: 's_after', y: 760, target: boundaries.afterList!),
      ];

      // 1:30 pm region spans [290, 430]. Cursor anywhere in this band
      // → cursor is in the 1:30 gap block → K_after = s_1400.
      for (final y in [290, 320, 360, 400, 429]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: block1430,
          pointerY: y.toDouble(),
        );
        expect(result.key, 's_1400',
            reason: 'cursor in 1:30 pm region (Y=$y) → s_1400');
        expect(result.target?.targetPeriodStart, t1330,
            reason: 'drop dispatches moveBlock(13:30) so the merge into '
                'the 1:30 period works at Y=$y');
      }
    });
  });
}
