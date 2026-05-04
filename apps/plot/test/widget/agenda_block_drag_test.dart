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
  group('computeBlockDragActivation', () {
    test('pointer above first slot returns no activation', () {
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
      expect(result.target, isNull);
    });

    test('pointer at or below last slot returns no activation', () {
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
        'top half of a non-source block activates the "before" slot',
        () {
      // Section: [A, B, C]. Source = X (not in section, e.g. dragged
      // from another section). Slot Ys at 100, 200, 300, 400.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 400, prev: 'C', next: null),
      ];

      // Pointer in B's top half (Y=210). Block region (200, 300),
      // center=250. Y=210 < 250 → top half → "before B" slot.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 210,
      );
      expect(result.key, 'before_B');
      expect(result.target?.prevBlockId, 'A');
      expect(result.target?.nextBlockId, 'B');
    });

    test(
        'bottom half of a non-source block activates the "after" slot',
        () {
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 400, prev: 'C', next: null),
      ];

      // Pointer in B's bottom half (Y=290). Block region (200, 300),
      // center=250. Y=290 > 250 → bottom half → "before C" slot.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 290,
      );
      expect(result.key, 'before_C');
      expect(result.target?.prevBlockId, 'B');
      expect(result.target?.nextBlockId, 'C');
    });

    test('pointer in source block region returns null (deadzone)', () {
      // Section: [A, source, B, C]. Source flanked by filtered slots.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_source', y: 200, prev: 'A', next: 'source'),
        _slot(key: 'before_B', y: 300, prev: 'source', next: 'B'),
        _slot(key: 'before_C', y: 400, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 500, prev: 'C', next: null),
      ];

      // Pointer in source's range (200..300), top half.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 220,
      );
      expect(result.key, isNull,
          reason: 'top half "before source" is filtered (next=source)');

      // Pointer in source's range, bottom half.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 280,
      );
      expect(result.key, isNull,
          reason: 'bottom half "before B" is filtered (prev=source)');
    });

    test(
        'cross-section drag opens drop slots even when target section has '
        'a block of the same priority — slots are filtered by block ID, '
        'not priority',
        () {
      // Sunday section with [Another, Plot Partners (source)].
      // Monday section with [Using Plot, Plot Partners (different block id)].
      // Source = sunday_partners. Target = monday's slots.
      final slots = <_Slot>[
        // Sunday
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
        // Monday
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

      // Pointer in Monday's Using Plot top half (350..450, mid=400).
      // Y=380 < 400 → top half → "before Using Plot" (NOT filtered;
      // its prev=null and next=usingplot_mon, neither is the dragged
      // block sunday_partners). The fact that Monday already has its
      // own Plot Partners block must NOT prevent activation here.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'sunday_partners',
        pointerY: 380,
      );
      expect(result.key, 'before_usingplot_mon',
          reason: 'top half of Monday Using Plot must activate even when '
              'the dragged priority already exists on Monday — block IDs '
              'differ between sections, so no filter applies');

      // Pointer in Using Plot's bottom half (Y=430 > 400) →
      // "before Plot Partners (Mon)". Also not filtered.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'sunday_partners',
        pointerY: 430,
      );
      expect(result.key, 'before_partners_mon');
    });

    test('event-block region is a deadzone via nextIsEvent', () {
      // Slots flanking an event block: before_event then after_event.
      // The before_event boundary's nextIsEvent = true → pointer in
      // (before_event, after_event) gap activates nothing.
      final slots = <_Slot>[
        _slot(
          key: 'before_priorblock',
          y: 100,
          prev: null,
          next: 'priorblock',
        ),
        _slot(
          key: 'before_event',
          y: 200,
          prev: 'priorblock',
          next: 'event_id',
          nextIsEvent: true,
        ),
        _slot(
          key: 'after_event',
          y: 300,
          prev: 'event_id',
          next: null,
        ),
      ];

      // Pointer anywhere in event block (200..300).
      for (final y in [210, 250, 290]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'X',
          pointerY: y.toDouble(),
        );
        expect(result.key, isNull,
            reason: 'pointer Y=$y is over an event — must not activate');
      }
    });

    test(
        'symmetric activation: PB top half does NOT shift when source is '
        'directly above PB (the slot between source and PB is filtered)',
        () {
      // Layout: [source, PB, Another]. Boundaries:
      // - before_source (next=source, filtered)
      // - before_PB (prev=source, filtered)
      // - before_Another (prev=PB, valid)
      // - after_Another (prev=Another, valid)
      final slots = <_Slot>[
        _slot(key: 'before_source', y: 100, prev: null, next: 'source'),
        _slot(key: 'before_PB', y: 200, prev: 'source', next: 'PB'),
        _slot(key: 'before_Another', y: 300, prev: 'PB', next: 'Another'),
        _slot(key: 'after_Another', y: 400, prev: 'Another', next: null),
      ];

      // Pointer at PB's top (Y=210, just past source's bottom). PB's
      // region is (200, 300), center=250. Y=210 < 250 → top half →
      // "before PB" slot, which is filtered (prev=source).
      // Result: null, NOT "before Another". The user's expectation is
      // that PB doesn't shift until pointer crosses PB's center.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 210,
      );
      expect(result.key, isNull,
          reason: 'pointer at top of next-after-source must not activate '
              'anything (PB stays put until pointer crosses PB center)');
    });

    test(
        'symmetric activation: PB bottom half DOES activate "before Another" '
        'when source is directly above PB',
        () {
      final slots = <_Slot>[
        _slot(key: 'before_source', y: 100, prev: null, next: 'source'),
        _slot(key: 'before_PB', y: 200, prev: 'source', next: 'PB'),
        _slot(key: 'before_Another', y: 300, prev: 'PB', next: 'Another'),
        _slot(key: 'after_Another', y: 400, prev: 'Another', next: null),
      ];

      // Pointer at PB's bottom half (Y=270 > center=250).
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 270,
      );
      expect(result.key, 'before_Another');
    });

    test(
        'same-section reorder: dragging a block past its next neighbour '
        'activates a swap target',
        () {
      // [A, source, B]. Drag source down past B to reach end-of-section.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_source', y: 200, prev: 'A', next: 'source'),
        _slot(key: 'before_B', y: 300, prev: 'source', next: 'B'),
        _slot(key: 'after_B', y: 400, prev: 'B', next: null),
      ];

      // Pointer in B's bottom half (Y=370 > center=350).
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 370,
      );
      expect(result.key, 'after_B',
          reason: 'dragging past B should activate the end-of-section slot, '
              'producing the source→after-B swap');
      expect(result.target?.prevBlockId, 'B');
      expect(result.target?.nextBlockId, isNull);
    });

    test(
        'empty section drop slot: dragging onto an empty day activates the '
        'after-date-header boundary',
        () {
      // Mon ends; Tue is empty (no blocks); Wed starts.
      // Boundaries:
      // - end-of-Mon (prev=monLast, next=null, targetDate=Mon)
      // - empty-Tue after-date (prev=null, next=null, targetDate=Tue)
      //   This is the "drop on empty Tuesday" slot.
      // - top-of-Wed (prev=null, next=wedFirst, targetDate=Wed)
      final slots = <_Slot>[
        _slot(key: 'end_mon', y: 100, prev: 'monLast', next: null),
        _slot(key: 'empty_tue', y: 200, prev: null, next: null),
        _slot(key: 'top_wed', y: 300, prev: null, next: 'wedFirst'),
      ];

      // Pointer above empty_tue: Y=150. Block region (100, 200),
      // center=150. Y=150 not < 150 → bottom half → empty_tue.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 160,
      );
      expect(result.key, 'empty_tue');

      // Pointer below empty_tue: Y=250 → block region (200, 300),
      // center=250. Y=250 not < 250 → bottom half → top_wed.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 260,
      );
      expect(result.key, 'top_wed');
    });

    testWidgets(
      'slot snaps to 0 height when drag ends mid-collapse — without this, '
      'a leftover in-flight collapse animation shifts the layout and forces '
      'the user to drag farther on subsequent drags before activation triggers',
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
        expect(
          controller.sourceTotalHeight,
          100,
          reason: 'sourceTotalHeight = afterSourceY (S0 at Y=100) - sourceTopY (0)',
        );

        // Activate S1: pointer in B's block region (S0=100, S1=150) at
        // Y=130 → bottom half → afterSlot = S1.
        controller.updatePointer(const Offset(100, 130));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getSize(find.byKey(slot1Key)).height,
          100,
          reason: 'S1 should be fully expanded after the open animation',
        );

        // Move pointer above the agenda's first slot — pointer at Y=50
        // is past the agenda's top edge (S0 is at Y=100), so activation
        // is none and S1 starts collapsing 100 → 0.
        controller.updatePointer(const Offset(100, 50));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        final mid = tester.getSize(find.byKey(slot1Key)).height;
        expect(
          mid,
          greaterThan(0),
          reason: 'S1 should still be mid-collapse (animating 100 → 0)',
        );
        expect(mid, lessThan(100));

        // End drag mid-animation. The slot must snap to 0 immediately so
        // a subsequent drag sees the natural at-rest layout.
        controller.end(dispatch: false);
        await tester.pump();

        expect(
          tester.getSize(find.byKey(slot1Key)).height,
          0,
          reason: 'S1 must snap to 0 on drag end — otherwise the next drag '
              'sees a partially-expanded slot, shifting block-center '
              'thresholds and forcing the user to drag farther',
        );
      },
    );

    test(
        'oscillation guard: live reads with shifting layout still pick the '
        'same slot when pointer is near a block boundary',
        () {
      // Simulate the layout AFTER active=before_C set: source has
      // collapsed (Y1=Y2 same position), before_C has expanded.
      //
      // Original layout: A 100..200, source 200..300, B 300..400, C 400..500.
      // Slots at-rest: before_A=100, before_source=200, before_B=300,
      // before_C=400, after_C=500.
      //
      // After source collapse + before_C expansion (height 100):
      // - before_A=100 (unchanged).
      // - before_source=200 (unchanged — source's top stays).
      // - before_B=200 (was 300, source removed 100 above).
      // - before_C=300 (was 400, source removed 100 above) — top of
      //   the expanded slot.
      // - after_C=500 (unchanged — expansion offsets collapse).
      //
      // Pointer at Y=380 was in B's bottom half (in original layout)
      // and activated before_C. In the new layout, pointer's screen
      // position is unchanged, and slot positions reflect the shift.
      // The block-center model on the new positions should keep
      // before_C active (no oscillation).
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 100, prev: null, next: 'A'),
        _slot(key: 'before_source', y: 200, prev: 'A', next: 'source'),
        _slot(key: 'before_B', y: 200, prev: 'source', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'after_C', y: 500, prev: 'C', next: null),
      ];

      // Pointer at Y=380, in (300, 500) gap = block C with the
      // expanded slot at top. center=400. Y=380 < 400 → top half →
      // before_C. SAME slot active.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 380,
      );
      expect(result.key, 'before_C',
          reason: 'block-center activation must remain stable across the '
              'layout shift caused by source collapse + slot expansion');
    });
  });
}
