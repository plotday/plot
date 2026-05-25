import 'package:flutter_test/flutter_test.dart';

import 'package:plot/state/scheduling.dart';
import 'package:plot/store/attention.dart';

// All tests freeze "now" at Monday 2026-05-25 13:00 (Mon at 1pm). The
// default test respondWindow is Mon-Fri 9:00-17:00.

final _now = DateTime(2026, 5, 25, 13, 0);

const _mondayToFriday = AttentionWindow(
  days: [1, 2, 3, 4, 5],
  start: '09:00',
  end: '17:00',
);

const _everyDay = AttentionWindow(
  days: [1, 2, 3, 4, 5, 6, 7],
  start: '00:00',
  end: '23:59',
);

void main() {
  group('computeRespondDeadline', () {
    test('non-urgent: arrivedAt + respondWithin', () {
      final arrived = DateTime(2026, 5, 25, 13, 0);
      final deadline = computeRespondDeadline(
        threads: [
          RespondThreadInput(arrivedAt: arrived, urgent: false),
        ],
        respondWithin:
            const SeeWithinTime(value: 4, unit: SeeWithinUnit.hours),
      );
      expect(deadline, DateTime(2026, 5, 25, 17, 0));
    });

    test('urgent: arrivedAt exactly (no slack)', () {
      final arrived = DateTime(2026, 5, 25, 13, 0);
      final deadline = computeRespondDeadline(
        threads: [
          RespondThreadInput(arrivedAt: arrived, urgent: true),
        ],
        respondWithin:
            const SeeWithinTime(value: 4, unit: SeeWithinUnit.hours),
      );
      expect(deadline, arrived);
    });

    test('multiple threads: earliest deadline wins', () {
      final t1 = DateTime(2026, 5, 25, 13, 0);
      final t2 = DateTime(2026, 5, 25, 11, 0); // earlier
      final deadline = computeRespondDeadline(
        threads: [
          RespondThreadInput(arrivedAt: t1, urgent: false),
          RespondThreadInput(arrivedAt: t2, urgent: false),
        ],
        respondWithin:
            const SeeWithinTime(value: 4, unit: SeeWithinUnit.hours),
      );
      // t2 + 4h = 15:00, earlier than t1 + 4h = 17:00.
      expect(deadline, DateTime(2026, 5, 25, 15, 0));
    });

    test('urgent thread pulls deadline forward', () {
      final t1 = DateTime(2026, 5, 25, 13, 0);
      final t2 = DateTime(2026, 5, 25, 12, 0); // urgent → contributes 12:00
      final deadline = computeRespondDeadline(
        threads: [
          RespondThreadInput(arrivedAt: t1, urgent: false),
          RespondThreadInput(arrivedAt: t2, urgent: true),
        ],
        respondWithin:
            const SeeWithinTime(value: 4, unit: SeeWithinUnit.hours),
      );
      expect(deadline, t2); // 12:00
    });
  });

  group('findRespondBlockSlot', () {
    test('single-priority happy path: latest 15-min slot before deadline',
        () {
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 17, 0),
        respondWindow: const [_mondayToFriday],
        busy: const [],
      );
      expect(slot, isNotNull);
      // Latest 15-min slot ending at 17:00 → starts at 16:45.
      expect(slot!.start, DateTime(2026, 5, 25, 16, 45));
      expect(slot.end, DateTime(2026, 5, 25, 17, 0));
      expect(slot.overflow, isFalse);
    });

    test('calendar event overlap: shifts placement earlier', () {
      final busy = [
        BusyInterval(
          start: DateTime(2026, 5, 25, 16, 30),
          end: DateTime(2026, 5, 25, 17, 0),
        ),
      ];
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 17, 0),
        respondWindow: const [_mondayToFriday],
        busy: busy,
      );
      expect(slot, isNotNull);
      // 16:45-17:00 busy → 16:30-16:45 busy (overlaps event start exactly,
      // half-open: 16:30 inclusive) → next non-busy is 16:15-16:30.
      expect(slot!.start, DateTime(2026, 5, 25, 16, 15));
      expect(slot.overflow, isFalse);
    });

    test('overflow flag when every slot before deadline is busy', () {
      final busy = <BusyInterval>[
        for (var h = 13; h < 17; h++)
          for (var m = 0; m < 60; m += 15)
            BusyInterval(
              start: DateTime(2026, 5, 25, h, m),
              end: DateTime(2026, 5, 25, h, m + 15),
            ),
      ];
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 17, 0),
        respondWindow: const [_mondayToFriday],
        busy: busy,
      );
      expect(slot, isNotNull);
      expect(slot!.overflow, isTrue);
      // Picks the latest slot anyway.
      expect(slot.start, DateTime(2026, 5, 25, 16, 45));
    });

    test('pinned block treated as busy: shifts placement earlier', () {
      // A user-pinned block from 16:00-16:45 sits in the way of the
      // latest-slot pick.
      final busy = [
        BusyInterval(
          start: DateTime(2026, 5, 25, 16, 0),
          end: DateTime(2026, 5, 25, 16, 45),
        ),
      ];
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 17, 0),
        respondWindow: const [_mondayToFriday],
        busy: busy,
      );
      expect(slot, isNotNull);
      // 16:45-17:00 is open; pick it.
      expect(slot!.start, DateTime(2026, 5, 25, 16, 45));
      expect(slot.overflow, isFalse);
    });

    test('deadline that has passed: places at "now"', () {
      // Force the deadline into the past.
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: _now.subtract(const Duration(hours: 1)),
        respondWindow: const [_mondayToFriday],
        busy: const [],
      );
      expect(slot, isNotNull);
      expect(slot!.overflow, isTrue);
      // Snapped to 13:00 (already aligned).
      expect(slot.start, DateTime(2026, 5, 25, 13, 0));
    });

    test('deadline in a closed window: spills to next open window', () {
      // Now = Sat 2026-05-30 10:00 ; window = Mon-Fri 9-5 ; deadline
      // = Sat 12:00 (still Saturday). No slot before deadline because
      // Sat isn't in the window → place at next Mon 09:00.
      final sat10 = DateTime(2026, 5, 30, 10, 0);
      final satDeadline = DateTime(2026, 5, 30, 12, 0);
      final slot = findRespondBlockSlot(
        now: sat10,
        deadline: satDeadline,
        respondWindow: const [_mondayToFriday],
        busy: const [],
      );
      expect(slot, isNotNull);
      expect(slot!.overflow, isTrue);
      // Next Mon = 2026-06-01.
      expect(slot.start, DateTime(2026, 6, 1, 9, 0));
    });

    test('multi-priority backward-pass: earlier deadline placed first', () {
      // Priority A: deadline 17:00, no other priorities yet → 16:45.
      // Priority B: deadline 16:30, A's placement at 16:45 doesn't conflict
      //   → B places at 16:15.
      // The "multi-priority backward-pass" property is encoded as the
      // caller maintaining a running busy list. Verify that effect here.
      final firstSlot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 17, 0),
        respondWindow: const [_mondayToFriday],
        busy: const [],
      );
      expect(firstSlot!.start, DateTime(2026, 5, 25, 16, 45));

      final running = [
        BusyInterval(start: firstSlot.start, end: firstSlot.end),
      ];
      final secondSlot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 16, 30),
        respondWindow: const [_mondayToFriday],
        busy: running,
      );
      // B can pick 16:15 — A's 16:45 doesn't conflict with that.
      expect(secondSlot!.start, DateTime(2026, 5, 25, 16, 15));
      expect(secondSlot.overflow, isFalse);
    });

    test('deadline tomorrow, today fully booked → places tomorrow', () {
      final busy = <BusyInterval>[
        BusyInterval(
          start: DateTime(2026, 5, 25, 9, 0),
          end: DateTime(2026, 5, 25, 23, 59),
        ),
      ];
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 26, 12, 0),
        respondWindow: const [_mondayToFriday],
        busy: busy,
      );
      expect(slot, isNotNull);
      // Tomorrow 11:45-12:00 — latest 15-min slot ≤ tomorrow noon.
      expect(slot!.start, DateTime(2026, 5, 26, 11, 45));
      expect(slot.overflow, isFalse);
    });

    test('returns null when respondWindow is empty', () {
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: DateTime(2026, 5, 25, 17, 0),
        respondWindow: const [],
        busy: const [],
      );
      expect(slot, isNull);
    });

    test('24/7 window with all-busy week still overflows', () {
      // Saturate the next 24h.
      final busy = <BusyInterval>[
        BusyInterval(
          start: _now,
          end: _now.add(const Duration(hours: 24)),
        ),
      ];
      final slot = findRespondBlockSlot(
        now: _now,
        deadline: _now.add(const Duration(hours: 4)),
        respondWindow: const [_everyDay],
        busy: busy,
      );
      expect(slot, isNotNull);
      expect(slot!.overflow, isTrue);
    });
  });

  group('snapForward / snapBackward', () {
    test('aligned moment returns the same minute', () {
      final m = DateTime(2026, 5, 25, 13, 0);
      expect(snapForward(m), m);
      expect(snapBackward(m), m);
    });

    test('off-grid moment rounds correctly', () {
      final m = DateTime(2026, 5, 25, 13, 7);
      expect(snapForward(m), DateTime(2026, 5, 25, 13, 15));
      expect(snapBackward(m), DateTime(2026, 5, 25, 13, 0));
    });

    test('snapForward across hour boundary', () {
      final m = DateTime(2026, 5, 25, 13, 50);
      expect(snapForward(m), DateTime(2026, 5, 25, 14, 0));
    });
  });
}
