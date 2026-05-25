import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/notifications/notification_window.dart';
import 'package:plot/store/attention.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SharedPreferences> prefsWithWindows(
    List<AttentionWindow> windows,
  ) async {
    SharedPreferences.setMockInitialValues({
      notifyWindowsPrefsKey: AttentionWindow.toJsonString(windows) ?? '',
    });
    return SharedPreferences.getInstance();
  }

  Future<SharedPreferences> prefsWithNoKey() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  group('computeWindowOpenTime', () {
    test('inside an 09:00–17:00 weekday window → returns null (fire now)',
        () async {
      final prefs = await prefsWithWindows(const [
        AttentionWindow(days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00'),
      ]);
      // Monday 2026-05-25 13:00 — squarely inside the window.
      final now = DateTime(2026, 5, 25, 13);
      expect(computeWindowOpenTime(prefs, now: now), isNull);
    });

    test(
        'outside the window after close → returns next-day open',
        () async {
      final prefs = await prefsWithWindows(const [
        AttentionWindow(days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00'),
      ]);
      // Monday 19:00 — past close; next opening is Tuesday 09:00.
      final now = DateTime(2026, 5, 25, 19);
      expect(
        computeWindowOpenTime(prefs, now: now),
        DateTime(2026, 5, 26, 9),
      );
    });

    test('weekday window on Saturday → returns Monday 09:00', () async {
      final prefs = await prefsWithWindows(const [
        AttentionWindow(days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00'),
      ]);
      // Saturday 2026-05-30 10:00 — closed; spill to next Monday.
      final now = DateTime(2026, 5, 30, 10);
      expect(
        computeWindowOpenTime(prefs, now: now),
        DateTime(2026, 6, 1, 9),
      );
    });

    test('midnight-crossing 21:00–07:00 window, 02:00 → inside → null',
        () async {
      final prefs = await prefsWithWindows(const [
        AttentionWindow(
          days: [1, 2, 3, 4, 5, 6, 7],
          start: '21:00',
          end: '07:00',
        ),
      ]);
      // Mon 02:00 — inside the early-morning tail of the previous day's window.
      final now = DateTime(2026, 5, 25, 2);
      expect(computeWindowOpenTime(prefs, now: now), isNull);
    });

    test('midnight-crossing 21:00–07:00, 08:00 → next 21:00 today', () async {
      final prefs = await prefsWithWindows(const [
        AttentionWindow(
          days: [1, 2, 3, 4, 5, 6, 7],
          start: '21:00',
          end: '07:00',
        ),
      ]);
      // Mon 08:00 — outside window; next opening is Mon 21:00.
      final now = DateTime(2026, 5, 25, 8);
      expect(
        computeWindowOpenTime(prefs, now: now),
        DateTime(2026, 5, 25, 21),
      );
    });

    test('empty notify_windows → returns null (always open)', () async {
      final prefs = await prefsWithWindows(const []);
      final now = DateTime(2026, 5, 25, 23);
      expect(computeWindowOpenTime(prefs, now: now), isNull);
    });

    test(
        'no notify_windows key → falls back to a 24/7 always-open window → null',
        () async {
      final prefs = await prefsWithNoKey();
      final now = DateTime(2026, 5, 25, 23);
      expect(computeWindowOpenTime(prefs, now: now), isNull);
    });

    test('before today\'s opening → returns same-day open time', () async {
      final prefs = await prefsWithWindows(const [
        AttentionWindow(
          days: [1, 2, 3, 4, 5],
          start: '09:00',
          end: '17:00',
        ),
      ]);
      // Mon 07:00 — before today's open.
      final now = DateTime(2026, 5, 25, 7);
      expect(
        computeWindowOpenTime(prefs, now: now),
        DateTime(2026, 5, 25, 9),
      );
    });
  });
}
