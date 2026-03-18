import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/notifications/notification_quiet_hours.dart';
import 'package:plot/store/attention.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('computeNotifyTime', () {
    // Helper: build prefs with given attention windows JSON
    Future<SharedPreferences> prefsWithWindows(
      List<AttentionWindow> windows,
    ) async {
      SharedPreferences.setMockInitialValues({
        'attention_windows': AttentionWindow.toJsonString(windows) ?? '',
      });
      return SharedPreferences.getInstance();
    }

    // Helper: build prefs with no attention_windows key (uses defaultQuietHours)
    Future<SharedPreferences> prefsWithNoKey() async {
      SharedPreferences.setMockInitialValues({});
      return SharedPreferences.getInstance();
    }

    test(
      '21:00–07:00 window, current time 02:00 → returns today 07:00 (not tomorrow)',
      () async {
        final prefs = await prefsWithWindows([
          const AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '21:00', end: '07:00'),
        ]);
        // Monday, 02:00 — inside the midnight-crossing window (early-morning portion)
        final now = DateTime(2025, 1, 6, 2, 0); // Monday

        final result = computeNotifyTime(prefs, now: now);

        expect(result, isNotNull);
        // Should be TODAY (2025-01-06) at 07:00, not tomorrow
        expect(result, equals(DateTime(2025, 1, 6, 7, 0)));
      },
    );

    test(
      '21:00–07:00 window, current time 23:30 → returns tomorrow 07:00',
      () async {
        final prefs = await prefsWithWindows([
          const AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '21:00', end: '07:00'),
        ]);
        // Monday, 23:30 — inside the midnight-crossing window (late-night portion)
        final now = DateTime(2025, 1, 6, 23, 30); // Monday

        final result = computeNotifyTime(prefs, now: now);

        expect(result, isNotNull);
        // Should be TOMORROW (2025-01-07) at 07:00
        expect(result, equals(DateTime(2025, 1, 7, 7, 0)));
      },
    );

    test(
      '12:00–14:00 same-day window, time 13:00 → returns today 14:00',
      () async {
        final prefs = await prefsWithWindows([
          const AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '12:00', end: '14:00'),
        ]);
        final now = DateTime(2025, 1, 6, 13, 0); // Monday 13:00

        final result = computeNotifyTime(prefs, now: now);

        expect(result, equals(DateTime(2025, 1, 6, 14, 0)));
      },
    );

    test(
      'time outside all windows → returns null (notify immediately)',
      () async {
        final prefs = await prefsWithWindows([
          const AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '21:00', end: '07:00'),
        ]);
        // 10:00 AM — not inside the 21:00–07:00 window
        final now = DateTime(2025, 1, 6, 10, 0);

        final result = computeNotifyTime(prefs, now: now);

        expect(result, isNull);
      },
    );

    test(
      'empty windows list → returns null',
      () async {
        final prefs = await prefsWithWindows([]);

        final result = computeNotifyTime(prefs, now: DateTime(2025, 1, 6, 23, 0));

        expect(result, isNull);
      },
    );

    test(
      'no attention_windows key → uses defaultQuietHours (21:00–07:00)',
      () async {
        final prefs = await prefsWithNoKey();
        // 23:00 should be inside defaultQuietHours (21:00–07:00)
        final now = DateTime(2025, 1, 6, 23, 0); // Monday

        final result = computeNotifyTime(prefs, now: now);

        expect(result, isNotNull);
        // Should be tomorrow 07:00 since 23:00 >= 21:00 (late-night portion)
        expect(result, equals(DateTime(2025, 1, 7, 7, 0)));
      },
    );

    test(
      'window does not apply on the current day of week → returns null',
      () async {
        // Weekday-only window (Mon=1..Fri=5), but now is Sunday (7)
        final prefs = await prefsWithWindows([
          const AttentionWindow(days: [1, 2, 3, 4, 5], start: '21:00', end: '07:00'),
        ]);
        final now = DateTime(2025, 1, 5, 23, 0); // Sunday

        final result = computeNotifyTime(prefs, now: now);

        expect(result, isNull);
      },
    );
  });
}
