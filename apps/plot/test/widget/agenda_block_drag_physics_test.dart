import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/agenda_block_drag.dart';

/// Tests for the consistent block-drag physics:
///
///   Default: cursor in block X → preview at K_after_X. Threshold at
///   each next block's TOP edge in live layout.
///
///   Tie-breaker: cursor in current placeholder (active expansion or
///   source's at-rest region) → no transition.
///
///   Source-flank no-swap: cursor in upper neighbor of source (block
///   whose K_after is filtered) → hold last active or no swap.
///
///   First-block-of-agenda split: top H pixels of first block →
///   K_above_first; rest → K_after_first. Avoids needing off-agenda.
///
///   Combined event deadzone: back-to-back events form a deadzone
///   with halfway flip between flanking valid slots.

typedef _Slot = ({Object key, double y, BlockDropTarget target});

_Slot _slot({
  required String key,
  required double y,
  String? prev,
  String? next,
  bool nextIsEvent = false,
}) => (
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
  group('Scenario A: source A at top, B C D below (each 40px)', () {
    final slots = <_Slot>[
      _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
      _slot(key: 'before_B', y: 40, prev: 'A', next: 'B'),
      _slot(key: 'before_C', y: 80, prev: 'B', next: 'C'),
      _slot(key: 'before_D', y: 120, prev: 'C', next: 'D'),
      _slot(key: 'after_D', y: 160, prev: 'D', next: null),
    ];

    test('Y=20 (A\'s middle, source) → no swap', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 20,
        activeSlotExpansion: 40,
      );
      expect(result.key, isNull);
    });

    test('Y=40 (B\'s top) → after B = before_C', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 40,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_C');
    });

    test('Y=79 (B\'s bottom) → after B = before_C (same as Y=40)', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 79,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_C');
    });

    test('Y=80 (C\'s top) → after C = before_D', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 80,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_D');
    });

    test('Y=120 (D\'s top) → after D = after_D', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 120,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'after_D');
    });
  });

  group('Scenario B: source A, event E, gap C (each 40px)', () {
    final slots = <_Slot>[
      _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
      _slot(
        key: 'before_E',
        y: 40,
        prev: 'A',
        next: 'E',
        nextIsEvent: true,
      ),
      _slot(key: 'before_C', y: 80, prev: 'E', next: 'C'),
      _slot(key: 'after_C', y: 120, prev: 'C', next: null),
    ];

    test('Y=20 (A\'s middle, source) → no swap', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 20,
        activeSlotExpansion: 40,
      );
      expect(result.key, isNull);
    });

    test('Y=40 (E\'s top) → after E = before_C', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 40,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_C');
    });

    test('Y=60 (E\'s middle) → after E = before_C (same)', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 60,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_C');
    });

    test('Y=79 (E\'s bottom) → after E = before_C (same)', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 79,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_C');
    });

    test('Y=80 (C\'s top) → after C = after_C', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 80,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'after_C');
    });
  });

  group('Boundary case: A=40px, B=40px source (drag B up)', () {
    // Layout: A at [0, 40], B (source) at [40, 80]. H=40.
    // Slots: K_above_A=0 (valid), K_above_B=40 (filtered, next=B),
    // K_after_B=80 (filtered, prev=B).
    // The boundary at Y=40 is between A and source — it belongs to
    // A (the non-source side), so cursor at exactly Y=40 should
    // activate K_above_A.
    final slots = <_Slot>[
      _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
      _slot(key: 'before_B', y: 40, prev: 'A', next: 'B'),
      _slot(key: 'after_B', y: 80, prev: 'B', next: null),
    ];

    test('Y=40 (exactly at A/source boundary) → activate K_above_A', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 40,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A',
          reason: 'cursor at Y=H=40 (= A/source boundary) belongs to A '
              'and triggers the first-block split immediately');
    });

    test('Y=39 (just inside A) → activate K_above_A', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 39,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A');
    });

    test('Y=41 (just inside source) → no swap', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 41,
        activeSlotExpansion: 40,
      );
      expect(result.key, isNull);
    });

    test('Y=0 (very top) → activate K_above_A', () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 0,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A');
    });
  });

  group('Tie-breaker: A=20px, B=40px source', () {
    // K_above_B (y=20) is filtered (next=B=source).
    // K_after_B (y=60) is filtered (prev=B=source).
    // Source's at-rest region = [20, 60].
    final slots = <_Slot>[
      _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
      _slot(key: 'before_B', y: 20, prev: 'A', next: 'B'),
      _slot(key: 'after_B', y: 60, prev: 'B', next: null),
    ];

    test(
        'pickup at Y=40 (in source\'s region) — tie-breaker beats first-block '
        'split, returns no swap',
        () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 40,
        activeSlotExpansion: 40,
      );
      expect(result.key, isNull);
    });

    test(
        'cursor at Y=15 (in A\'s region, above source) — first-block split '
        'activates K_above_A',
        () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 15,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A');
    });

    test(
        'after K_above_A active, cursor moves back to Y=40 (source region) — '
        'sticky preview band keeps it active (preview never bounces back)',
        () {
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'B',
        pointerY: 40,
        activeSlotKey: 'before_A',
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_A',
          reason: 'sticky preview band [0, 40] keeps before_A active');
    });
  });

  group('Upper-neighbor swap (K_after fallback)', () {
    test(
        'cursor in the block immediately above source falls back to K_above '
        '— swap source with that neighbor (without this, the block sits in '
        'a no-swap zone because K_after_X = K_above_source is filtered)',
        () {
      // Layout: aKNy, XWZX (upper neighbor of source), rzVP (source).
      // K_after_XWZX = K_above_rzVP is filtered (next=source).
      // K_above_XWZX is valid (prev=aKNy, next=XWZX).
      final slots = <_Slot>[
        _slot(key: 'before_aKNy', y: 0, prev: null, next: 'aKNy'),
        _slot(key: 'before_XWZX', y: 100, prev: 'aKNy', next: 'XWZX'),
        _slot(key: 'before_rzVP', y: 150, prev: 'XWZX', next: 'rzVP'),
        _slot(key: 'after_rzVP', y: 250, prev: 'rzVP', next: null),
      ];

      // Cursor in XWZX [100, 150]. K_after_XWZX is filtered, so the
      // fallback activates K_above_XWZX (drop before XWZX = swap with
      // XWZX, source moves to position 1).
      for (final y in [100, 125, 149]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'rzVP',
          pointerY: y.toDouble(),
          activeSlotExpansion: 100,
          sourceAtRestTopY: 150,
        );
        expect(result.key, 'before_XWZX',
            reason: 'cursor in XWZX (Y=$y) → K_above_XWZX (fallback) '
                'because K_after_XWZX is source-flank-filtered');
      }
    });
  });

  group('Swap-back: cursor returns to source\'s at-rest region', () {
    // Layout: aKNy [123, 258], XWZX (source) [258, 327], rzVP [327, 462].
    // Source has neighbors above (aKNy) and below (rzVP).
    final slots = <_Slot>[
      _slot(key: 'before_aKNy', y: 123, prev: null, next: 'aKNy'),
      _slot(key: 'before_XWZX', y: 258, prev: 'aKNy', next: 'XWZX'),
      _slot(key: 'before_rzVP', y: 327, prev: 'XWZX', next: 'rzVP'),
      _slot(key: 'after_rzVP', y: 462, prev: 'rzVP', next: null),
    ];

    test(
        'cursor returns to source\'s at-rest screen region while a slot is '
        'active → deactivates (swap-back)',
        () {
      // before_aKNy is active (= XWZX swapped to position 0). Cursor
      // moves back down into XWZX's original at-rest region [258, 327].
      for (final y in [259, 290, 326]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'XWZX',
          pointerY: y.toDouble(),
          activeSlotKey: 'before_aKNy',
          activeSlotExpansion: 69,
          sourceAtRestTopY: 258,
        );
        expect(result.key, isNull,
            reason: 'cursor at Y=$y is inside source\'s at-rest region '
                '[258, 327] → deactivate, source returns visible');
      }
    });

    test(
        'boundaries with adjacent neighbors are exclusive (belong to the '
        'neighbor); cursor at exactly the boundary activates the neighbor',
        () {
      // Y=258 = aKNy/source boundary, belongs to aKNy.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'XWZX',
        pointerY: 258,
        activeSlotKey: 'before_aKNy',
        activeSlotExpansion: 69,
        sourceAtRestTopY: 258,
      );
      expect(result.key, isNot(isNull),
          reason: 'Y=258 = aKNy/source boundary, should NOT trigger '
              'tie-breaker (boundary belongs to aKNy, not source)');

      // Y=327 = source/rzVP boundary, belongs to rzVP.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'XWZX',
        pointerY: 327,
        activeSlotKey: 'before_aKNy',
        activeSlotExpansion: 69,
        sourceAtRestTopY: 258,
      );
      expect(result.key, isNot(isNull),
          reason: 'Y=327 = source/rzVP boundary, should NOT trigger '
              'tie-breaker (boundary belongs to rzVP, not source)');
    });

    test(
        'source at top of agenda — top boundary is INCLUSIVE since there\'s '
        'no neighbor above to claim it',
        () {
      // Layout: A (source) [0, 40], B [40, 80].
      final topSlots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_B', y: 40, prev: 'A', next: 'B'),
        _slot(key: 'after_B', y: 80, prev: 'B', next: null),
      ];

      // Active = after_B (drop after B). Cursor at Y=0 (= A's top, agenda top).
      final result = computeBlockDragActivation(
        slots: topSlots,
        draggingId: 'A',
        pointerY: 0,
        activeSlotKey: 'after_B',
        activeSlotExpansion: 40,
        sourceAtRestTopY: 0,
      );
      expect(result.key, isNull,
          reason: 'source at top → Y=0 is inside source\'s region '
              '(top boundary inclusive when no neighbor above) → deactivate');
    });
  });

  group('Cross-day swap-back: source\'s at-rest screen overlap', () {
    test(
        'when an active slot is in a different DATE than source, cursor in '
        'source\'s at-rest screen region does NOT trigger swap-back — the '
        'overlapping live block (a different day\'s first block) keeps its '
        'first-block split active',
        () {
      // Source rzVP on May 5 at [327, 462]. May 6 starts with efqay
      // at-rest [512, 647]. With K_above_event_15:00 active on May 6,
      // efqay shifts up to [377, 512] in live coords, partially
      // overlapping source's at-rest [327, 462] in [377, 462].
      // Cursor at Y=461 is in efqay's live region but ALSO in
      // source's at-rest screen range. Different dates → cursor in
      // efqay's first-block split zone → K_above_efqay activates.
      // Must NOT trigger swap-back to source.
      final may5 = Date(2026, 5, 5);
      final may6 = Date(2026, 5, 6);
      _Slot dated(_Slot s, Date date) => (
        key: s.key,
        y: s.y,
        target: BlockDropTarget(
          targetDate: date,
          targetPeriodStart: null,
          prevBlockId: s.target.prevBlockId,
          prevPriorityId: null,
          nextBlockId: s.target.nextBlockId,
          nextPriorityId: null,
          nextIsEvent: s.target.nextIsEvent,
        ),
      );

      final slots = <_Slot>[
        // May 5 (source's day)
        dated(_slot(key: 'before_aKNy', y: 192, prev: null, next: 'aKNy'),
            may5),
        dated(_slot(key: 'before_rzVP', y: 327, prev: 'aKNy', next: 'rzVP'),
            may5),
        // After May 5
        dated(_slot(key: 'before_date_06', y: 462, prev: 'rzVP', next: null),
            may5),
        // May 6 — efqay live position (after source-collapse shifted up)
        dated(_slot(key: 'before_efqay', y: 377, prev: null, next: 'efqay'),
            may6),
        dated(
            _slot(
                key: 'before_event_15',
                y: 512,
                prev: 'efqay',
                next: 'event_15',
                nextIsEvent: true),
            may6),
      ];

      // Cursor Y=461 is inside source's at-rest [327, 462] AND
      // inside efqay's first-block-split zone [377, 512] (top H=135).
      // Date mismatch (May 5 vs May 6) → swap-back skipped, first-block
      // split fires.
      final result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'rzVP',
        pointerY: 461,
        activeSlotKey: 'before_event_15',
        activeSlotExpansion: 135,
        sourceAtRestTopY: 327,
      );
      expect(result.key, 'before_efqay',
          reason: 'cursor in source\'s at-rest screen overlap with a '
              'different-day block → activate that block\'s first-block '
              'split, NOT swap-back to source');
    });

  });

  group('Swap-back stability (no oscillation)', () {
    test(
        'cursor in source\'s at-rest region returns none in BOTH active and '
        'inactive states (same-day) — prevents the deactivate→reactivate '
        'oscillation that mid-animation layout shifts can otherwise cause',
        () {
      // Source rzVP on May 5 at [327, 462]. Layout: XWZX, aKNy, rzVP.
      final may5 = Date(2026, 5, 5);
      _Slot dated(_Slot s, Date date) => (
        key: s.key,
        y: s.y,
        target: BlockDropTarget(
          targetDate: date,
          targetPeriodStart: null,
          prevBlockId: s.target.prevBlockId,
          prevPriorityId: null,
          nextBlockId: s.target.nextBlockId,
          nextPriorityId: null,
          nextIsEvent: s.target.nextIsEvent,
        ),
      );

      final slots = <_Slot>[
        dated(_slot(key: 'before_XWZX', y: 123, prev: null, next: 'XWZX'),
            may5),
        dated(_slot(key: 'before_aKNy', y: 192, prev: 'XWZX', next: 'aKNy'),
            may5),
        dated(_slot(key: 'before_rzVP', y: 327, prev: 'aKNy', next: 'rzVP'),
            may5),
        dated(
            _slot(key: 'after_rzVP', y: 462, prev: 'rzVP', next: null), may5),
      ];

      // Cursor at Y=400 (inside source's at-rest [327, 462]).
      // BOTH the inactive case AND the active case return none — that's
      // what prevents oscillation during the layout settle animation.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'rzVP',
        pointerY: 400,
        activeSlotExpansion: 135,
        sourceAtRestTopY: 327,
      );
      expect(result.key, isNull,
          reason: 'inactive + cursor in source\'s at-rest → none');

      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'rzVP',
        pointerY: 400,
        activeSlotKey: 'before_aKNy',
        activeSlotExpansion: 135,
        sourceAtRestTopY: 327,
      );
      expect(result.key, isNull,
          reason: 'active + cursor in source\'s at-rest → none (same as '
              'inactive — no flip-flop between states)');
    });
  });

  group('Combined event deadzone (back-to-back events)', () {
    test(
        'two adjacent events with no gap form combined deadzone — top half '
        'holds at slot above first event; bottom half snaps below chain',
        () {
      // [G, E1, E2, G2]. E1 at [100, 200], E2 at [200, 300]. No gap between.
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

      // Combined region [100, 300]. Midpoint=200.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 150,
      );
      expect(result.key, 'before_E1',
          reason: 'top half of combined chain → slot above first event');

      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'X',
        pointerY: 250,
      );
      expect(result.key, 'before_G2',
          reason: 'bottom half of combined chain → first valid slot below');
    });

    test(
        'single event (with gaps before and after) does NOT form a combined '
        'deadzone — falls through to default rule (cursor in E → after E)',
        () {
      final slots = <_Slot>[
        _slot(key: 'before_G1', y: 0, prev: null, next: 'G1'),
        _slot(
          key: 'before_E',
          y: 100,
          prev: 'G1',
          next: 'E',
          nextIsEvent: true,
        ),
        _slot(key: 'before_G2', y: 200, prev: 'E', next: 'G2'),
        _slot(key: 'after_G2', y: 300, prev: 'G2', next: null),
      ];

      // Cursor in E [100, 200] → K_after_E = before_G2 (regardless of half).
      for (final y in [100, 150, 199]) {
        final result = computeBlockDragActivation(
          slots: slots,
          draggingId: 'X',
          pointerY: y.toDouble(),
        );
        expect(result.key, 'before_G2',
            reason: 'single event row → drop into following gap (Y=$y)');
      }
    });
  });

  group('Empty-gap-above-event oscillation regression', () {
    test(
        'block dropped from above into an empty gap before an event activates '
        'consistently and stays sticky in its expansion band',
        () {
      // [source A, gap_empty G, event E, ...]. Source A at [0, 40].
      // Empty gap header G at [40, 60] (24px gap header). Event E at [60, 100].
      final slots = <_Slot>[
        _slot(key: 'before_A', y: 0, prev: null, next: 'A'),
        _slot(key: 'before_G', y: 40, prev: 'A', next: 'G'),
        _slot(
          key: 'before_E',
          y: 60,
          prev: 'G',
          next: 'E',
          nextIsEvent: true,
        ),
        _slot(key: 'after_E', y: 100, prev: 'E', next: null),
      ];

      // Cursor in G [40, 60] → K_after_G = before_E.
      var result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 50,
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_E');

      // Active before_E with expansion 40. Sticky band [60, 100].
      // Cursor in this band keeps before_E active.
      result = computeBlockDragActivation(
        slots: slots,
        draggingId: 'A',
        pointerY: 80,
        activeSlotKey: 'before_E',
        activeSlotExpansion: 40,
      );
      expect(result.key, 'before_E',
          reason: 'sticky preview band keeps before_E active even though E is '
              'a deadzone in the live layout');
    });
  });
}
