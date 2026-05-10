import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/widget/agenda_block_drag.dart';

/// Helper: build a list of test slots.
typedef _Slot = ({Object key, double y, BlockDropTarget target});

_Slot _slot({
  required String key,
  required double y,
  String? prev,
  String? next,
  bool nextIsEvent = false,
}) =>
    (
      key: key,
      y: y,
      target: BlockDropTarget(
        targetDate: null,
        targetPeriodStart: null,
        prevBlockId: prev,
        prevPriorityId: null,
        nextBlockId: next,
        nextPriorityId: null,
        nextIsEvent: nextIsEvent,
      ),
    );

void main() {
  group('computeBlockDragActivation — default rule (cursor in X → after X)', () {
    test(
        'cursor in a non-source block activates K_after_block, regardless of '
        'which half the cursor is in (threshold at next block top, not center)',
        () {
      // Section: [A, B, C]. Source = X (not in section).
      // Slots at block tops: before_A=100, before_B=200, before_C=300, after_C=400.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 400, prev: 'C', next: null),
      ];

      // Cursor at B's top (Y=200), middle (Y=250), or bottom (Y=299) all
      // map to "cursor in B" → K_after_B = before_C.
      for (final y in [200, 250, 299]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'X',
          pointerY: y.toDouble(),
        );
        expect(result.key, 'before_C',
            reason: 'cursor in B (Y=$y) activates K_after_B = before_C');
      }
    });

    test(
        'crossing into the next block immediately swaps to its K_after slot '
        '— threshold at the next block top, not at the current block center',
        () {
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 400, prev: 'C', next: null),
      ];

      // Y=199 (still in A) → K_after_A = before_B.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 199,
      );
      expect(result.key, 'before_B');

      // Y=200 (just crossed into B) → K_after_B = before_C.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 200,
      );
      expect(result.key, 'before_C',
          reason: 'cursor crossing into B at its top edge → K_after_B');
    });
  });

  group('computeBlockDragActivation — tie-breakers', () {
    test(
        'cursor strictly inside source\'s at-rest region (boundaries excluded) '
        'returns BlockDragActivation.none — preview stays at source (no swap)',
        () {
      // Section: [A, source, B, C]. Source at [200, 300]. Boundaries
      // (Y=200 and Y=300) belong to the neighboring blocks per the
      // upper-inclusive convention; only the strict interior is the
      // source's region.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_source', y: 200, prev: 'A', next: 'source'),
        _slot(key: 'before_B', y: 300, prev: 'source', next: 'B'),
        _slot(key: 'before_C', y: 400, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 500, prev: 'C', next: null),
      ];

      for (final y in [201, 250, 299]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'source',
          pointerY: y.toDouble(),
        );
        expect(result.key, isNull,
            reason: 'cursor in source\'s region (Y=$y), no active → no swap');
      }
    });

    test(
        'cursor in active slot\'s expansion band keeps it active — placeholder '
        'never moves out from under the cursor',
        () {
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 400, prev: 'C', next: null),
      ];

      // before_B is active with a 100px expansion. Sticky band [200, 300].
      // Cursor in this band keeps before_B active.
      for (final y in [200, 250, 299]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'X',
          pointerY: y.toDouble(),
          activeSlotKey: 'before_B',
          activeSlotExpansion: 100,
        );
        expect(result.key, 'before_B',
            reason: 'sticky preview band keeps before_B active at Y=$y');
      }
    });

    test(
        'cursor in source\'s region with a prior active slot HOLDS the prior '
        'active — preview never bounces back to source',
        () {
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_source', y: 200, prev: 'A', next: 'source'),
        _slot(key: 'before_B', y: 300, prev: 'source', next: 'B'),
        _slot(key: 'after_B', y: 400, prev: 'B', next: null),
      ];

      // before_B has been active. Cursor moves back into source's
      // region (Y=250). Per "no bounce back," before_B holds.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 250,
        activeSlotKey: 'before_B',
      );
      expect(result.key, 'before_B',
          reason: 'cursor returning to source\'s region holds last active');
    });
  });

  group('computeBlockDragActivation — upper-neighbor fall-back', () {
    test(
        'cursor in the upper neighbor of source (block whose K_after is '
        'filtered) falls back to K_above_X — swaps source with that neighbor',
        () {
      // [A, B (upper neighbor of source), source, C].
      // K_after_B = before_source has next=source → filtered.
      // K_above_B = before_B is valid → fall-back activates it.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_source', y: 300, prev: 'B', next: 'source'),
        _slot(key: 'after_source', y: 400, prev: 'source', next: 'C'),
        _slot(key: 'after_C', y: 500, prev: 'C', next: null),
      ];

      // Cursor in B (201..299, exclusive of boundaries). Default rule
      // K_after_B is filtered → fall back to K_above_B = before_B.
      // Drop = before B = source moves to position before B (= swap).
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 250,
      );
      expect(result.key, 'before_B',
          reason: 'cursor in upper neighbor of source → K_above of that '
              'neighbor activates (swap with the neighbor)');
    });
  });

  group('computeBlockDragActivation — first-block-of-agenda split', () {
    test(
        'cursor in the first block\'s top H pixels activates K_above_first; '
        'remaining pixels fall through to K_after_first — avoids needing '
        'off-agenda above',
        () {
      // [A (first, valid K_above), source]. A is 60px, source is 40px (H=40).
      // Slots: K_above_A=0 (valid), K_above_source=60 (filtered, next=source),
      // K_after_source=100 (filtered, prev=source).
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_source', y: 60, prev: 'A', next: 'source'),
        _slot(key: 'after_source', y: 100, prev: 'source', next: null),
      ];

      // Cursor in A's top H=40 pixels [0, 40] → K_above_A = before_A.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 20,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A',
          reason: 'cursor in first block top H pixels → K_above_first');

      // Cursor in A's bottom portion (Y=50, in [40, 60]) → K_after_A
      // is filtered (next=source). Fall-back activates K_above_A
      // (= before_A). Drop = before A = top of agenda. (When A is
      // also the source's upper neighbor, the first-block split's
      // top-H pixels and the upper-neighbor fall-back collapse to
      // the same answer: K_above_A activates throughout A.)
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 50,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A',
          reason: 'cursor in first block bottom portion → K_above_A via '
              'upper-neighbor fall-back');
    });

    test(
        'tie-breaker scenario: A=20px, source B=40px. Cursor at pickup (Y=40, '
        'in source\'s region) shows no swap even though Y<=H would otherwise '
        'place it in K_above_A\'s zone',
        () {
      // [A (20px), B (40px source)]. H=40.
      // K_above_A=0 valid. K_above_B=20 filtered. K_after_B=60 filtered.
      // Source's at-rest region = [20, 60]. A's region = [0, 20].
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 20, prev: 'A', next: 'B'),
        _slot(key: 'after_B', y: 60, prev: 'B', next: null),
      ];

      // Cursor at Y=40 (B's middle). Tie-breaker: cursor in source's
      // region [20, 60] → no swap, even though Y=40 <= H=40 first-block
      // threshold would otherwise activate before_A.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 40,
        activeSlotExpansion: 40,
      );
      expect(result.key, isNull,
          reason: 'tie-breaker: cursor in source\'s region wins over '
              'first-block split');

      // Cursor at Y=15 (in A's region) — A is the first block, K_above_A
      // valid. A is only 20px tall but H=40. Top H pixels of A clamps to
      // [0, 20] (whole region). Cursor in A → K_above_A.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 15,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A',
          reason: 'cursor in A activates K_above_A (first-block split)');
    });
  });

  group('computeBlockDragActivation — combined event deadzone', () {
    test(
        'two adjacent events with no gap form a combined deadzone: cursor in '
        'top half holds at slot above first event; bottom half snaps to '
        'first valid slot below the chain',
        () {
      // [G (gap), E1 (event), E2 (event), G2 (gap)]. E1 and E2 adjacent.
      // Slots:
      // - before_G (y=0) prev=null next=G
      // - before_E1 (y=100) prev=G next=E1, nextIsEvent=true
      // - before_E2 (y=200) prev=E1 next=E2, nextIsEvent=true (makes it
      //   the "between two events" slot — should be treated as filtered)
      // - before_G2 (y=300) prev=E2 next=G2
      // - after_G2 (y=400) prev=G2 next=null
      final slots = <_Slot>[
        _slot(key: 'before_G', y: 0, prev: null, next: 'G'),
        _slot(
          key: 'before_E1',
          y: 100,
          prev: 'G',
          next: 'E1',
          nextIsEvent: true,
        ),
        _slot(
          key: 'before_E2',
          y: 200,
          prev: 'E1',
          next: 'E2',
          nextIsEvent: true,
        ),
        _slot(key: 'before_G2', y: 300, prev: 'E2', next: 'G2'),
        _slot(key: 'after_G2', y: 400, prev: 'G2', next: null),
      ];

      // Combined region [100, 300]. Midpoint = 200.
      // Y=150 (top half) → before_E1 (slot above first event of chain).
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 150,
      );
      expect(result.key, 'before_E1',
          reason: 'top half of event chain holds at slot above chain');

      // Y=250 (bottom half) → before_G2 (first valid below chain).
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 250,
      );
      expect(result.key, 'before_G2',
          reason: 'bottom half of event chain snaps to first valid below');
    });
  });

  group('computeBlockDragActivation — off-agenda + edge cases', () {
    test('pointer above first slot with no active returns no activation', () {
      final slots = <_Slot>[
        _slot(key: 's0', y: 100, prev: null, next: 'A'),
        _slot(key: 's1', y: 200, prev: 'A', next: 'B'),
      ];
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 50,
      );
      expect(result.key, isNull);
    });

    test('pointer below last slot with no active returns no activation', () {
      final slots = <_Slot>[
        _slot(key: 's0', y: 100, prev: null, next: 'A'),
        _slot(key: 's1', y: 200, prev: 'A', next: 'B'),
      ];
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 250,
      );
      expect(result.key, isNull);
    });

    test(
        'cross-section drag opens drop slots even when target section has '
        'a block of the same priority — slots are filtered by block ID, '
        'not priority',
        () {
      // Sunday section with [Another, Plot Partners (source)].
      // Monday section with [Using Plot, Plot Partners (different block id)].
      // Source = sunday_partners. Target = monday's blocks.
      final slots = <_Slot>[
        _slot(
          key: 'before_another_sun',
          y: 100,
          prev: null,
          next: 'another_sun',
        ),
        _slot(
          key: 'before_partners_sun',
          y: 200,
          prev: 'another_sun',
          next: 'sunday_partners',
        ),
        _slot(
          key: 'after_partners_sun',
          y: 300,
          prev: 'sunday_partners',
          next: null,
        ),
        _slot(
          key: 'before_usingplot_mon',
          y: 350,
          prev: null,
          next: 'usingplot_mon',
        ),
        _slot(
          key: 'before_partners_mon',
          y: 450,
          prev: 'usingplot_mon',
          next: 'monday_partners',
        ),
        _slot(
          key: 'after_partners_mon',
          y: 550,
          prev: 'monday_partners',
          next: null,
        ),
      ];

      // Cursor in Monday Using Plot (Y=380, in [350, 450]) → K_after =
      // before_partners_mon. No filter applies (block IDs differ).
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'sunday_partners',
        pointerY: 380,
      );
      expect(result.key, 'before_partners_mon',
          reason: 'cursor in Monday Using Plot → drop after Using Plot');

      // Cursor in Monday Plot Partners (Y=500, in [450, 550]) → K_after =
      // after_partners_mon.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'sunday_partners',
        pointerY: 500,
      );
      expect(result.key, 'after_partners_mon');
    });

    test('empty section drop slot activates when cursor lands inside it', () {
      // Mon ends; Tue is empty (slot only); Wed starts.
      final slots = <_Slot>[
        _slot(key: 'end_mon', y: 100, prev: 'monLast', next: null),
        _slot(key: 'empty_tue', y: 200, prev: null, next: null),
        _slot(key: 'top_wed', y: 300, prev: null, next: 'wedFirst'),
      ];

      // Cursor in [100, 200) — that's the block between end_mon and
      // empty_tue → K_after = empty_tue.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 160,
      );
      expect(result.key, 'empty_tue');

      // Cursor in [200, 300) → K_after = top_wed.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 260,
      );
      expect(result.key, 'top_wed');
    });
  });

  group('BlockDropZone widget integration', () {
    testWidgets(
      'slot snaps to 0 height when drag ends mid-collapse',
      (tester) async {
        final controller = BlockDragController();
        final sourceKey = GlobalKey();
        final pid = Uuid.fromString('00000000-0000-0000-0000-000000000001');

        const slot0Key = ValueKey('S0');
        const slot1Key = ValueKey('S1');

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: BlockDragScope(
                controller: controller,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Slot above source so cursor can reach source's
                    // at-rest region from above for tie-breaker.
                    const BlockDropZone(
                      slotKey: 'pre',
                      target: BlockDropTarget(
                        targetDate: null,
                        targetPeriodStart: null,
                        prevBlockId: null,
                        prevPriorityId: null,
                        nextBlockId: 'source',
                        nextPriorityId: null,
                      ),
                    ),
                    SizedBox(key: sourceKey, height: 100, width: 200),
                    const BlockDropZone(
                      key: slot0Key,
                      slotKey: 'S0',
                      target: BlockDropTarget(
                        targetDate: null,
                        targetPeriodStart: null,
                        prevBlockId: 'source',
                        prevPriorityId: null,
                        nextBlockId: 'B',
                        nextPriorityId: null,
                      ),
                    ),
                    const SizedBox(height: 50, width: 200),
                    const BlockDropZone(
                      key: slot1Key,
                      slotKey: 'S1',
                      target: BlockDropTarget(
                        targetDate: null,
                        targetPeriodStart: null,
                        prevBlockId: 'B',
                        prevPriorityId: null,
                        nextBlockId: null,
                        nextPriorityId: null,
                      ),
                    ),
                    const SizedBox(height: 50, width: 200),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final payload = BlockDragPayload(
          blockId: 'source',
          priorityId: pid,
          sourceDate: null,
          sourcePeriodStart: null,
          visibleThreadCount: 0,
        );

        controller.start(
          payload,
          sourceContextProvider: () => sourceKey.currentContext!,
        );
        expect(controller.sourceTotalHeight, 100);

        // Activate S1: cursor in B's region (Y in [100, 150]) → K_after_B = S1.
        controller.updatePointer(const Offset(100, 130));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getSize(find.byKey(slot1Key)).height,
          100,
          reason: 'S1 should be fully expanded',
        );

        // Move pointer into source's at-rest region [0, 100]. With S1
        // already active, this hits the active sticky band first
        // (S1.y in K_above_S1-active live shifted). To reliably
        // deactivate, move into the pre-source region in live coords.
        // After S1 expansion source collapses; layout shifts. Move
        // pointer to the upper area where source would have been.
        // Per tie-breaker, cursor in source's region with active = hold
        // S1. So we need cursor to leave the deadzone PROPER and enter
        // a real block's region for deactivation.
        // Here we instead end the drag mid-way to verify the snap-to-0.
        controller.end(dispatch: false);
        await tester.pump();
        expect(
          tester.getSize(find.byKey(slot1Key)).height,
          0,
          reason: 'S1 must snap to 0 on drag end',
        );
      },
    );
  });

  group('BlockDragController source-height fallback', () {
    // Activity-feed-shaped source: the draggable IS the entire row
    // (no separate breadcrumb header). When the dragged thread sits
    // in a section that doesn't register a `K_after_source` slot
    // (e.g. the activity feed's Done section, which collapses to a
    // single boundary at the top with prevBlockId=null), height
    // capture must fall back to the source RO's own height — NOT
    // `sourceHeaderHeight + visibleThreadCount * row`, which would
    // double-count.
    testWidgets(
      'falls back to source RO height when visibleThreadCount=0 '
      '(activity-feed shape, no K_after_source slot)',
      (tester) async {
        final controller = BlockDragController();
        final sourceKey = GlobalKey();
        final pid = Uuid.fromString('00000000-0000-0000-0000-000000000001');

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: BlockDragScope(
                controller: controller,
                // No BlockDropZone whose target.prevBlockId == 'source':
                // forces the height fallback path.
                child: SizedBox(key: sourceKey, height: 64, width: 200),
              ),
            ),
          ),
        );
        await tester.pump();

        controller.start(
          BlockDragPayload(
            blockId: 'source',
            priorityId: pid,
            sourceDate: null,
            sourcePeriodStart: null,
            visibleThreadCount: 0,
          ),
          sourceContextProvider: () => sourceKey.currentContext!,
        );

        expect(
          controller.sourceTotalHeight,
          64,
          reason: 'source RO already covers the row; fallback must NOT '
              'add an extra row height (would produce 64 + 56 = 120)',
        );
      },
    );

    // Agenda-shaped source: the draggable is the small priority-
    // breadcrumb header (~28 px) and N thread rows live below it.
    // visibleThreadCount = N, so the fallback adds N row heights to
    // estimate the block's full footprint.
    testWidgets(
      'adds visibleThreadCount × row height when source is a header only '
      '(agenda shape, no K_after_source slot)',
      (tester) async {
        final controller = BlockDragController();
        final headerKey = GlobalKey();
        final pid = Uuid.fromString('00000000-0000-0000-0000-000000000001');

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: BlockDragScope(
                controller: controller,
                child: SizedBox(key: headerKey, height: 28, width: 200),
              ),
            ),
          ),
        );
        await tester.pump();

        controller.start(
          BlockDragPayload(
            blockId: 'source',
            priorityId: pid,
            sourceDate: null,
            sourcePeriodStart: null,
            visibleThreadCount: 3,
          ),
          sourceContextProvider: () => headerKey.currentContext!,
        );

        expect(
          controller.sourceTotalHeight,
          28 + 3 * kThreadRowApproxHeight,
          reason: 'header height + 3 thread rows ≈ block footprint',
        );
      },
    );
  });
}
