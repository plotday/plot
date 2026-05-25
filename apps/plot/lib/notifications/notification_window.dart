import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/store/attention.dart';

const String notifyWindowsPrefsKey = 'notify_windows';

/// If [now] falls inside one of the configured notify windows, returns null
/// (notifications may fire immediately). If not, returns the [DateTime] at
/// which the next notify window opens, so a caller can clamp a delivery
/// time that lands in a closed period to that next opening.
///
/// [prefs] is consulted for `notify_windows` (a JSON-encoded
/// `List<AttentionWindow>` mirrored from the root priority's
/// `notify_window` setting by [syncNotifyWindowsToPrefs]). When the key is
/// missing, the function falls back to a single 24/7 window — i.e. always
/// open — so users who haven't touched the setting always get
/// notifications.
///
/// Block-start notifications must bypass this function entirely (per the
/// "Schedule time to respond" / "Early notifications" split): a placed
/// block opens the user's attention regardless of `notify_window`.
DateTime? computeWindowOpenTime(SharedPreferences prefs, {DateTime? now}) {
  try {
    final raw = prefs.getString(notifyWindowsPrefsKey);
    final List<AttentionWindow> windows;
    if (raw != null) {
      windows = AttentionWindow.fromJsonString(raw) ?? const [];
    } else {
      windows = const [
        AttentionWindow(
          days: [1, 2, 3, 4, 5, 6, 7],
          start: '00:00',
          end: '23:59',
        ),
      ];
    }

    if (windows.isEmpty) return null;

    final now0 = now ?? DateTime.now();
    if (_isInsideWindow(windows, now0)) return null;

    return _nextOpening(windows, now0);
  } catch (_) {
    return null;
  }
}

bool _isInsideWindow(List<AttentionWindow> windows, DateTime moment) {
  final weekday = moment.weekday; // 1=Mon..7=Sun
  final minutes = moment.hour * 60 + moment.minute;
  for (final w in windows) {
    if (_minutesInsideWindow(w, weekday, minutes)) return true;
  }
  return false;
}

bool _minutesInsideWindow(AttentionWindow w, int weekday, int minutes) {
  final start = _parseHHMM(w.start);
  final end = _parseHHMM(w.end);
  if (start <= end) {
    return w.days.contains(weekday) && minutes >= start && minutes < end;
  }
  // Window crosses midnight (e.g. 22:00→06:00) — split into two halves.
  if (w.days.contains(weekday) && minutes >= start) return true;
  // The early-morning half belongs to the *next* calendar day, so check
  // whether the previous day is one of `w.days`.
  final prev = weekday == 1 ? 7 : weekday - 1;
  if (w.days.contains(prev) && minutes < end) return true;
  return false;
}

DateTime _nextOpening(List<AttentionWindow> windows, DateTime now) {
  DateTime? best;
  final nowMinutes = now.hour * 60 + now.minute;
  for (var i = 0; i < 14; i++) {
    final day = DateTime(now.year, now.month, now.day + i);
    final weekday = day.weekday;
    for (final w in windows) {
      if (!w.days.contains(weekday)) continue;
      final startMinutes = _parseHHMM(w.start);
      if (i == 0 && startMinutes <= nowMinutes) continue;
      final candidate = day.add(Duration(minutes: startMinutes));
      if (best == null || candidate.isBefore(best)) {
        best = candidate;
      }
    }
    if (best != null) return best;
  }
  return now.add(const Duration(hours: 1));
}

int _parseHHMM(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
