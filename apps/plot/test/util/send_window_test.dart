import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/attention.dart';
import 'package:plot/util/send_window.dart';

void main() {
  // Mon 2026-07-06 (weekday 1).
  final monday10 = DateTime(2026, 7, 6, 10, 0);
  const weekdays9to17 = AttentionWindow(
    days: [1, 2, 3, 4, 5],
    start: '09:00',
    end: '17:00',
  );

  group('insideAnyWindow', () {
    test('inside on a matching day', () {
      expect(insideAnyWindow([weekdays9to17], monday10), isTrue);
    });

    test('start is inclusive, end exclusive', () {
      expect(
        insideAnyWindow([weekdays9to17], DateTime(2026, 7, 6, 9, 0)),
        isTrue,
      );
      expect(
        insideAnyWindow([weekdays9to17], DateTime(2026, 7, 6, 17, 0)),
        isFalse,
      );
    });

    test('outside on a non-matching day (Sunday)', () {
      expect(
        insideAnyWindow([weekdays9to17], DateTime(2026, 7, 5, 10, 0)),
        isFalse,
      );
    });

    test('any of several windows matches', () {
      const evening = AttentionWindow(days: [1], start: '20:00', end: '21:00');
      expect(
        insideAnyWindow([evening, weekdays9to17], monday10),
        isTrue,
      );
    });
  });

  group('nextWindowOpening', () {
    test('later today when before the window', () {
      final at8 = DateTime(2026, 7, 6, 8, 0);
      expect(
        nextWindowOpening([weekdays9to17], at8),
        DateTime(2026, 7, 6, 9, 0),
      );
    });

    test('tomorrow when past today\'s window', () {
      final at18 = DateTime(2026, 7, 6, 18, 0);
      expect(
        nextWindowOpening([weekdays9to17], at18),
        DateTime(2026, 7, 7, 9, 0),
      );
    });

    test('skips the weekend to Monday', () {
      // Fri 2026-07-10 evening → Mon 2026-07-13 09:00.
      final friday18 = DateTime(2026, 7, 10, 18, 0);
      expect(
        nextWindowOpening([weekdays9to17], friday18),
        DateTime(2026, 7, 13, 9, 0),
      );
    });

    test('strictly after now: inside the window jumps to the next opening',
        () {
      // 10:00 inside Mon window → next opening is Tue 09:00, not today's
      // already-open 09:00.
      expect(
        nextWindowOpening([weekdays9to17], monday10),
        DateTime(2026, 7, 7, 9, 0),
      );
    });

    test('earliest of several windows wins', () {
      const noonWindow =
          AttentionWindow(days: [1], start: '12:00', end: '13:00');
      final at8 = DateTime(2026, 7, 6, 8, 0);
      expect(
        nextWindowOpening([noonWindow, weekdays9to17], at8),
        DateTime(2026, 7, 6, 9, 0),
      );
    });

    test('null when the windows never open', () {
      const dead = AttentionWindow(days: [], start: '09:00', end: '17:00');
      expect(nextWindowOpening([dead], monday10), isNull);
    });
  });

  group('maybeAutoSchedule', () {
    final sunday10 = DateTime(2026, 7, 5, 10, 0); // outside weekday window

    DateTime? run({
      List<AttentionWindow>? windows,
      DateTime? currentSendAt,
      bool userTouchedSchedule = false,
      bool isOutward = true,
      DateTime? now,
    }) => maybeAutoSchedule(
      windows: windows ?? [weekdays9to17],
      currentSendAt: currentSendAt,
      userTouchedSchedule: userTouchedSchedule,
      isOutward: isOutward,
      now: now ?? sunday10,
    );

    test('outside the window → next opening', () {
      expect(run(), DateTime(2026, 7, 6, 9, 0));
    });

    test('inside the window → no change', () {
      expect(run(now: monday10), isNull);
    });

    test('no windows → no change', () {
      expect(run(windows: []), isNull);
      expect(
        maybeAutoSchedule(
          windows: null,
          currentSendAt: null,
          userTouchedSchedule: false,
          isOutward: true,
          now: sunday10,
        ),
        isNull,
      );
    });

    test('private/unshared draft is exempt', () {
      expect(run(isOutward: false), isNull);
    });

    test('an existing schedule is never overridden', () {
      expect(run(currentSendAt: DateTime(2026, 7, 8, 15, 0)), isNull);
    });

    test('a manual clear is sticky', () {
      expect(run(userTouchedSchedule: true), isNull);
    });
  });
}
