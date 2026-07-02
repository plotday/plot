import 'package:flutter_test/flutter_test.dart';

import 'package:plot/command/schedule_send.dart';

void main() {
  // Wed 2026-07-01, 10:00.
  final now = DateTime(2026, 7, 1, 10, 0);

  group('rememberedDefault', () {
    test('nothing remembered → tomorrow 9 AM', () {
      expect(rememberedDefault(null, now), DateTime(2026, 7, 2, 9, 0));
    });

    test('remembered same-day slot still ahead → applied from today', () {
      const remembered = SendScheduleDefault(dayOffset: 0, time: '14:00');
      expect(rememberedDefault(remembered, now), DateTime(2026, 7, 1, 14, 0));
    });

    test('remembered same-day slot already passed → tomorrow 9 AM', () {
      const remembered = SendScheduleDefault(dayOffset: 0, time: '08:00');
      expect(rememberedDefault(remembered, now), DateTime(2026, 7, 2, 9, 0));
    });

    test('remembered day offset applies from today', () {
      const remembered = SendScheduleDefault(dayOffset: 2, time: '08:00');
      expect(rememberedDefault(remembered, now), DateTime(2026, 7, 3, 8, 0));
    });
  });

  group('pickerInitial', () {
    test('an existing future schedule wins', () {
      final current = DateTime(2026, 7, 4, 12, 0);
      expect(pickerInitial(current, null, now), current);
    });

    test('a stale (past) schedule falls back to the remembered default', () {
      final past = DateTime(2026, 6, 30, 12, 0);
      expect(pickerInitial(past, null, now), DateTime(2026, 7, 2, 9, 0));
    });

    test('no schedule → remembered default', () {
      const remembered = SendScheduleDefault(dayOffset: 1, time: '15:30');
      expect(
        pickerInitial(null, remembered, now),
        DateTime(2026, 7, 2, 15, 30),
      );
    });
  });

  group('rememberSchedule', () {
    test('captures calendar-day offset and time', () {
      final chosen = DateTime(2026, 7, 3, 14, 5);
      final r = rememberSchedule(chosen, now);
      expect(r.dayOffset, 2);
      expect(r.time, '14:05');
    });

    test('round-trips through encode/decode', () {
      final r = rememberSchedule(DateTime(2026, 7, 2, 9, 0), now);
      final decoded = SendScheduleDefault.decode(r.encode());
      expect(decoded!.dayOffset, r.dayOffset);
      expect(decoded.time, r.time);
    });

    test('decode rejects malformed input', () {
      expect(SendScheduleDefault.decode(null), isNull);
      expect(SendScheduleDefault.decode(''), isNull);
      expect(SendScheduleDefault.decode('not json'), isNull);
      expect(SendScheduleDefault.decode('{"dayOffset":"x","time":5}'), isNull);
    });
  });
}
