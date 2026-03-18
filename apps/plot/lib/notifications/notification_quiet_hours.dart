import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/store/attention.dart';

/// Returns the [DateTime] at which notifications should be shown if quiet
/// hours are currently in effect, or null if notifications should show now.
///
/// [prefs] is used to look up the `attention_windows` key. If the key is
/// absent, [AttentionWindow.defaultQuietHours] is used.
/// [now] overrides the current time, useful for testing.
DateTime? computeNotifyTime(SharedPreferences prefs, {DateTime? now}) {
  try {
    final windowsJson = prefs.getString('attention_windows');
    final List<AttentionWindow> windows;
    if (windowsJson != null) {
      windows = AttentionWindow.fromJsonString(windowsJson) ?? [];
    } else {
      windows = AttentionWindow.defaultQuietHours;
    }

    if (windows.isEmpty) return null;

    final now0 = now ?? DateTime.now();
    final dayOfWeek = now0.weekday; // 1=Mon..7=Sun
    final currentMinutes = now0.hour * 60 + now0.minute;

    for (final w in windows) {
      if (!w.days.contains(dayOfWeek)) continue;
      final startParts = w.start.split(':');
      final endParts = w.end.split(':');
      final startMinutes =
          int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
      final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

      final inWindow = startMinutes < endMinutes
          ? currentMinutes >= startMinutes && currentMinutes < endMinutes
          : currentMinutes >= startMinutes || currentMinutes < endMinutes;

      if (inWindow) {
        // We're in a quiet window — compute when it ends
        if (startMinutes < endMinutes) {
          // Same-day window: end is today
          return DateTime(
            now0.year,
            now0.month,
            now0.day,
            endMinutes ~/ 60,
            endMinutes % 60,
          );
        } else {
          // Window crosses midnight.
          // If currentMinutes < endMinutes, we're in the early-morning portion
          // of the window — the end is still today.
          // If currentMinutes >= startMinutes, we're in the late-night portion
          // of the window — the end is tomorrow.
          if (currentMinutes < endMinutes) {
            return DateTime(
              now0.year,
              now0.month,
              now0.day,
              endMinutes ~/ 60,
              endMinutes % 60,
            );
          } else {
            final tomorrow = now0.add(const Duration(days: 1));
            return DateTime(
              tomorrow.year,
              tomorrow.month,
              tomorrow.day,
              endMinutes ~/ 60,
              endMinutes % 60,
            );
          }
        }
      }
    }
    return null; // Not in quiet hours, notify immediately
  } catch (_) {
    return null;
  }
}
