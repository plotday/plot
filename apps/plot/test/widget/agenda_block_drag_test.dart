import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart' show Date;
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

  group(
      'computeBlockDragActivation — single-direction stability (no '
      'oscillation)', () {
    test(
        'downward drag holds the active slot when its live top Y lags '
        'mid-animation — pointerDirection prevents the ping-pong flip back '
        'to the slot above',
        () {
      // Source B0 already collapsed; just after a downward swap activated
      // s3 its live top Y still lags at 220 (the just-collapsed s2 above it
      // has not finished shrinking) though its settled band is [180, 220].
      // s0/s1 are B0's filtered flanks.
      final slots = <_Slot>[
        _slot(key: 's0', y: 100, prev: null, next: 'B0'),
        _slot(key: 's1', y: 100, prev: 'B0', next: 'B1'),
        _slot(key: 's2', y: 140, prev: 'B1', next: 'B2'),
        _slot(key: 's3', y: 220, prev: 'B2', next: null),
      ];

      // The controller supplies the pointer's travel direction (+1 = down).
      // Cursor at 190 sits in s3's settled band but below its lagging live
      // top — the fix must HOLD s3, not flip back up to s2.
      final fixed = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B0',
        pointerY: 190,
        activeSlotKey: 's3',
        activeSlotExpansion: 40,
        sourceAtRestTopY: 100,
        pointerDirection: 1,
      );
      expect(fixed.key, 's3',
          reason: 'downward drag holds s3 despite the mid-animation lag');

      // Without a direction (legacy geometry path) the lagging live top
      // flips it back to s2 — the oscillation the controller now avoids.
      final legacy = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B0',
        pointerY: 190,
        activeSlotKey: 's3',
        activeSlotExpansion: 40,
        sourceAtRestTopY: 100,
      );
      expect(legacy.key, 's2',
          reason: 'documents the geometry-only fallback the controller no '
              'longer uses');
    });
  });

  group('computeBlockDragActivation — direction-aware drag-up rule', () {
    test(
        'drag-up (cursor above source\'s at-rest top): cursor in block X '
        'activates K_above_X (drop just before X) — entering each block from '
        'below advances source one position immediately, no thread-height '
        'overshoot',
        () {
      // Section: [A, B, C, D, source]. Source at Y=400 (height H=100).
      // Slots: before_A=0, before_B=100, before_C=200, before_D=300,
      // before_source=400 (filtered next=source),
      // after_source=500 (filtered prev=source).
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 100, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 200, prev: 'B', next: 'C'),
        _slot(key: 'before_D', y: 300, prev: 'C', next: 'D'),
        _slot(key: 'before_source', y: 400, prev: 'D', next: 'source'),
        _slot(key: 'after_source', y: 500, prev: 'source', next: null),
      ];

      // Cursor in D (350, the upper neighbor of source) → K_above_D =
      // before_D. Same as the source-flank fall-back, but reached via
      // the direction-aware rule directly.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 350,
        sourceAtRestTopY: 400,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_D',
          reason: 'drag-up: cursor in upper neighbor → K_above_neighbor');

      // Cursor in C (250) → K_above_C = before_C. Without the
      // direction-aware rule, the old default would have activated
      // before_D (= K_after_C, the slot already active from the
      // previous swap), forcing the user to drag the cursor a full
      // thread-height further up to swap.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 250,
        activeSlotKey: 'before_D',
        sourceAtRestTopY: 400,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_C',
          reason: 'drag-up: cursor in C swaps to K_above_C (the bug fix — '
              'old rule held before_D until cursor crossed C\'s top)');

      // Cursor in B (150) → K_above_B = before_B.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 150,
        activeSlotKey: 'before_C',
        sourceAtRestTopY: 400,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_B',
          reason: 'drag-up: cursor in B swaps to K_above_B');

      // Cursor in A (50) → K_above_A = before_A (top of section).
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 50,
        activeSlotKey: 'before_B',
        sourceAtRestTopY: 400,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_A',
          reason: 'drag-up: cursor in A swaps to top of section');
    });

    test(
        'drag-down (cursor at or below source\'s at-rest top) keeps '
        'K_after_X semantics — symmetric to drag-up',
        () {
      // Section: [source, A, B, C, D]. Source at Y=0 (height H=100).
      final slots = <_Slot>[
        _slot(key: 'before_source', y: 0, prev: null, next: 'source'),
        _slot(key: 'after_source', y: 100, prev: 'source', next: 'A'),
        _slot(key: 'before_B', y: 200, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 300, prev: 'B', next: 'C'),
        _slot(key: 'before_D', y: 400, prev: 'C', next: 'D'),
        _slot(key: 'after_D', y: 500, prev: 'D', next: null),
      ];

      // Cursor in B (250) → K_after_B = before_C.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 250,
        sourceAtRestTopY: 0,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_C',
          reason: 'drag-down: cursor in B → K_after_B (same as old rule)');
    });

    test(
        'drag-down then drag-up: direction reference tracks the active '
        'slot\'s live position, not source\'s at-rest top — cursor above the '
        'active band uses K_above (drag-up rule) even when the cursor is '
        'below source\'s original at-rest top',
        () {
      // Scenario from the bug report: source originally at position 3.
      // User dragged source down to position 6 (active = before_G,
      // which means "drop between F and G"). Cursor moves up to
      // position 4 in the current list.
      //
      // Slot ys here are the LIVE layout values (what the controller
      // reads from RenderBoxes during the drag). With C collapsed
      // (height 0 at its original Y=200) and before_G expanded by
      // H=100 below F, the relevant live ys are:
      //   - before_C: 200 (C\'s old top, still anchored there)
      //   - before_D: 200 (sits flush against C\'s collapse point)
      //   - before_E: 300 (E shifted up by H from C\'s collapse)
      //   - before_F: 400
      //   - before_G: 500 (was 600, shifted up by H), active band
      //     extends to 600
      //   - before_H: 700
      // The original at-rest layout would have had before_G at 600
      // and before_C/before_D split apart by C\'s 100px height.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 100, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 200, prev: 'B', next: 'C'),
        _slot(key: 'before_D', y: 200, prev: 'C', next: 'D'),
        _slot(key: 'before_E', y: 300, prev: 'D', next: 'E'),
        _slot(key: 'before_F', y: 400, prev: 'E', next: 'F'),
        _slot(key: 'before_G', y: 500, prev: 'F', next: 'G'),
        _slot(key: 'before_H', y: 700, prev: 'G', next: 'H'),
        _slot(key: 'after_H', y: 800, prev: 'H', next: null),
      ];

      // Cursor at Y=350 → over E in the live layout (E at 300-400).
      // sourceAtRestTopY=200 (C\'s original top). Active slot is
      // before_G at live y=500.
      //
      // The bug: using sourceAtRestTopY as the direction reference,
      // 350 > 200 → drag-down → preferred=K_after_E=before_F → drop
      // between E and F = position 5. Placeholder one too low.
      //
      // The fix: using the active slot\'s live y as the reference,
      // 350 < 500 → drag-up → preferred=K_above_E=before_E → drop
      // between D and E = position 4.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'C',
        pointerY: 350,
        activeSlotKey: 'before_G',
        sourceAtRestTopY: 200,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_E',
          reason: 'cursor over E in live layout activates K_above_E '
              '(position 4), not K_after_E (position 5) — direction '
              'reference must follow source\'s preview, not at-rest');
    });

    test(
        'drag-up threshold sits at the entered block\'s TOP — crossing out of '
        'the active slot\'s expanded band into the block above activates the '
        'new K_above immediately',
        () {
      // [A, B, C, source]. H=100. sourceAtRestTopY=300.
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 100, prev: 'A', next: 'B'),
        _slot(key: 'before_C', y: 200, prev: 'B', next: 'C'),
        _slot(key: 'before_source', y: 300, prev: 'C', next: 'source'),
        _slot(key: 'after_source', y: 400, prev: 'source', next: null),
      ];

      // Active before_C has expansion band [200, 300). At Y=200 the
      // tie-breaker still holds (cursor sits at the band's top edge,
      // inside the placeholder).
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 200,
        activeSlotKey: 'before_C',
        sourceAtRestTopY: 300,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_C',
          reason: 'tie-breaker: cursor at active slot\'s top edge is still '
              'inside the placeholder band');

      // Cursor at Y=199 (just outside the active band, in B\'s region in
      // the live layout): bracket = (before_B, before_C). drag-up →
      // K_above = before_B. This is the moment the swap fires —
      // crossing the active band\'s top edge advances source by one
      // position with no extra overshoot.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'source',
        pointerY: 199,
        activeSlotKey: 'before_C',
        sourceAtRestTopY: 300,
        activeSlotExpansion: 100,
      );
      expect(result.key, 'before_B',
          reason: 'drag-up: cursor 1px above active band immediately swaps '
              'to K_above_B (the bug fix — old rule would have held '
              'before_C until cursor reached Y < 100)');
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

  group('BlockSlotCollapse', () {
    testWidgets(
      'collapses while a drop adjacent to the gap is active (even when the '
      'active slot is the one AFTER the gap), restores on drag end',
      (tester) async {
        final controller = BlockDragController();
        final sourceKey = GlobalKey();
        final gapKey = GlobalKey();
        final pid = Uuid.fromString('00000000-0000-0000-0000-000000000001');

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
                    // A "gap row" for gap block 'B', placed below every
                    // activation slot so its collapse never shifts the
                    // geometry the activation reads. S1's target has
                    // prevBlockId == 'B' (a drop just AFTER the gap, which
                    // anchors to the gap start), so activating S1 must
                    // collapse this gap even though S1 is not the gap's own
                    // in-gap slot — the case the old slotKey-only logic
                    // missed ("sometimes the gap is not merged").
                    BlockSlotCollapse(
                      blockId: 'B',
                      child: SizedBox(key: gapKey, height: 30, width: 200),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        // The collapse swaps its child for [SizedBox.shrink] when active,
        // so measure the [BlockSlotCollapse]'s own box (whose height
        // tracks its child) rather than the now-detachable keyed child.
        expect(
          tester.getSize(find.byType(BlockSlotCollapse)).height,
          30,
          reason: 'gap row is at full height before any drag',
        );

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

        // Activate S1: cursor in B's region (Y in [100, 150]).
        controller.updatePointer(const Offset(100, 130));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getSize(find.byKey(slot1Key)).height,
          100,
          reason: 'S1 should be fully expanded',
        );
        expect(
          tester.getSize(find.byType(BlockSlotCollapse)).height,
          0,
          reason: 'gap row collapses while a drop adjacent to it (S1, '
              'prevBlockId==B) is active',
        );
        expect(
          find.byKey(gapKey),
          findsNothing,
          reason: 'collapsed gap row detaches its child entirely',
        );

        controller.end(dispatch: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getSize(find.byType(BlockSlotCollapse)).height,
          30,
          reason: 'gap row restores to full height on drag end',
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

    // Single-tile block (agenda focus block) immediately followed by an
    // empty gap. The gap's drop slot is rendered BELOW the gap tile (so
    // the drop preview lands inside the gap), so the K_after_source slot
    // sits past the gap row. With visibleThreadCount=0 the source's own
    // RenderBox already spans the full block, so the captured height must
    // be the source height (100) — NOT the distance to the slot below the
    // gap tile (100 + 40), which would reserve too much space and inflate
    // the activation expansion band.
    testWidgets(
      'uses source RO height (not the gap-below slot) when '
      'visibleThreadCount=0 and the next slot sits below a gap tile',
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Source focus-block tile (full block height).
                    SizedBox(key: sourceKey, height: 100, width: 200),
                    // The empty gap's tile sits between the source and its
                    // in-gap drop slot.
                    const SizedBox(height: 40, width: 200),
                    // In-gap drop slot: prevBlockId == source, but rendered
                    // 40px below the source's true bottom.
                    const BlockDropZone(
                      slotKey: 'in_gap',
                      target: BlockDropTarget(
                        targetDate: null,
                        targetPeriodStart: null,
                        prevBlockId: 'source',
                        prevPriorityId: null,
                        nextBlockId: 'gap',
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
          100,
          reason: 'single-tile block uses its own RO height; the slot '
              'below the gap tile (at y=140) must NOT inflate it to 140',
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

  group('resolveFocusBlockDropAnchor — focus-block drop time', () {
    const duration = Duration(hours: 1);

    test('drop into a gap anchors at the gap start (the free time start), '
        'even when the next block is an event', () {
      // The slot inside a gap that sits before an event (e.g. the 9:35
      // gap before a 10:00 event). The block starts where the user dropped
      // it — the gap start — not "duration before the next event".
      final result = resolveFocusBlockDropAnchor(
        prevStart: DateTime(2026, 5, 29, 9, 35),
        prevEnd: DateTime(2026, 5, 29, 10), // gap end = next event start
        nextStart: DateTime(2026, 5, 29, 10),
        prevIsGap: true,
        duration: const Duration(minutes: 30),
      );
      expect(result.anchor, DateTime(2026, 5, 29, 9, 35),
          reason: 'lands at the gap start, where it was dropped');
      expect(result.isExact, isTrue);
    });

    test('drop into a trailing gap anchors at the gap start, not its end '
        '(which is the next day midnight)', () {
      final result = resolveFocusBlockDropAnchor(
        prevStart: DateTime(2026, 5, 31, 11, 30),
        prevEnd: DateTime(2026, 6, 1), // trailing gap fills to next midnight
        nextStart: null,
        prevIsGap: true,
        duration: duration,
      );
      expect(result.anchor, DateTime(2026, 5, 31, 11, 30),
          reason: 'gap start, never the midnight end (builder drops midnight)');
      expect(result.isExact, isTrue);
    });

    test('drop after an event/block starts exactly when that block ends', () {
      final prevEnd = DateTime(2026, 5, 28, 10);
      final result = resolveFocusBlockDropAnchor(
        prevStart: DateTime(2026, 5, 28, 9),
        prevEnd: prevEnd,
        nextStart: DateTime(2026, 5, 28, 14),
        duration: duration,
      );
      expect(result.anchor, prevEnd, reason: 'lands at the prev block end');
      expect(result.isExact, isTrue);
    });

    test(
        'drop before the first block of the day starts the focus block its '
        'own duration before that block', () {
      final nextStart = DateTime(2026, 5, 28, 9);
      final result = resolveFocusBlockDropAnchor(
        prevStart: null,
        prevEnd: null,
        nextStart: nextStart,
        duration: duration,
      );
      expect(
        result.anchor,
        DateTime(2026, 5, 28, 8),
        reason: '9:00 first event − 1h duration = 8:00 start',
      );
      expect(result.isExact, isTrue);
    });

    test('a gap start takes precedence over the previous block end', () {
      // prevIsGap means the block above the slot is the gap itself; its
      // start wins over its (midnight/next-event) end.
      final result = resolveFocusBlockDropAnchor(
        prevStart: DateTime(2026, 5, 28, 11, 30),
        prevEnd: DateTime(2026, 5, 28, 15),
        nextStart: DateTime(2026, 5, 28, 15),
        prevIsGap: true,
        duration: duration,
      );
      expect(result.anchor, DateTime(2026, 5, 28, 11, 30));
      expect(result.isExact, isTrue);
    });

    test('epoch-zero prev end is ignored, falls through to next start', () {
      final nextStart = DateTime(2026, 5, 28, 13);
      final result = resolveFocusBlockDropAnchor(
        prevStart: null,
        prevEnd: DateTime.fromMillisecondsSinceEpoch(0),
        nextStart: nextStart,
        duration: duration,
      );
      expect(result.anchor, DateTime(2026, 5, 28, 12));
      expect(result.isExact, isTrue);
    });

    test('no time-anchored neighbors yields no exact anchor', () {
      final result = resolveFocusBlockDropAnchor(
        prevStart: null,
        prevEnd: null,
        nextStart: null,
        duration: duration,
      );
      expect(result.anchor, isNull);
      expect(result.isExact, isFalse);
    });

    test('next start without a duration cannot resolve an exact anchor', () {
      final result = resolveFocusBlockDropAnchor(
        prevStart: null,
        prevEnd: null,
        nextStart: DateTime(2026, 5, 28, 9),
        duration: null,
      );
      expect(result.anchor, isNull);
      expect(result.isExact, isFalse);
    });
  });

  group('resolveFocusBlockDropAnchorOnDate — keep dropped block on its day', () {
    final targetDate = Date(2026, 6, 1);

    test(
        'a midnight anchor (leading-edge / empty-day gap start) is moved to '
        'the source time-of-day on the dropped day — otherwise the builder '
        'drops it as an order-timeline anchor and the block disappears', () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 6, 1), // June 1 midnight
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 14, 30),
      );
      expect(result, DateTime(2026, 6, 1, 14, 30));
    });

    test(
        'an anchor on the previous evening (before-first-block computed '
        'against a day-boundary gap) is moved onto the target day', () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 5, 31, 23), // June 1 midnight − 1h
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 9),
      );
      expect(result, DateTime(2026, 6, 1, 9));
    });

    test('a valid same-day, non-midnight anchor is returned unchanged', () {
      final raw = DateTime(2026, 6, 1, 10, 15);
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: raw,
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 9),
      );
      expect(result, raw);
    });

    test('falls back to 09:00 when the source is itself midnight-anchored', () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 6, 1),
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28), // midnight
      );
      expect(result, DateTime(2026, 6, 1, 9));
    });

    test('before the first row: keeps the source time when the block fits',
        () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 5, 31, 23), // leading-gap raw anchor (off-day)
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 8),
        duration: const Duration(hours: 1),
        nextRowStart: DateTime(2026, 6, 1, 10),
      );
      expect(result, DateTime(2026, 6, 1, 8));
    });

    test('before the first row: shifts earlier to fit when it would overlap',
        () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 5, 31, 23),
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 9, 30),
        duration: const Duration(hours: 1),
        nextRowStart: DateTime(2026, 6, 1, 10),
      );
      expect(result, DateTime(2026, 6, 1, 9));
    });

    test('before the first row: never shifts earlier than midnight (clamps)',
        () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 5, 31, 23),
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 9, 30),
        duration: const Duration(hours: 11),
        nextRowStart: DateTime(2026, 6, 1, 10),
      );
      expect(result, DateTime(2026, 6, 1)); // clamped to midnight
    });

    test('empty day keeps the source time (next-day-midnight is no '
        'constraint)', () {
      final result = resolveFocusBlockDropAnchorOnDate(
        rawAnchor: DateTime(2026, 5, 31, 23),
        targetDate: targetDate,
        sourceEffectiveAt: DateTime(2026, 5, 28, 16),
        duration: const Duration(hours: 2),
        nextRowStart: DateTime(2026, 6, 2), // next-day midnight (empty day)
      );
      expect(result, DateTime(2026, 6, 1, 16));
    });
  });
}
