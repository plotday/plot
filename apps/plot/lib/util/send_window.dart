import 'package:plot/store/attention.dart';

/// Pure send-window resolution for scheduled sending (client-side).
///
/// A focus's `sendWindow` (a `List<AttentionWindow>`, role-cascaded) defines
/// recurring windows during which messages may go out. A message drafted
/// OUTSIDE every window is auto-scheduled to the next window opening; inside a
/// window (or with no windows configured) it sends immediately.
///
/// Windows are same-day (`start < end`, no cross-midnight — matching the
/// notify_window / AttentionWindow assumption) and interpreted in the device's
/// local timezone. The produced instant is absolute, so DST/travel are fixed
/// at draft time.

/// Whether [now] falls inside any of [windows] (start inclusive, end
/// exclusive) on today's ISO weekday.
bool insideAnyWindow(List<AttentionWindow> windows, DateTime now) {
  final weekday = now.weekday; // ISO 1=Mon..7=Sun
  final minutes = now.hour * 60 + now.minute;
  for (final w in windows) {
    if (!w.days.contains(weekday)) continue;
    if (minutes >= _minutes(w.start) && minutes < _minutes(w.end)) return true;
  }
  return false;
}

/// The earliest window opening strictly after [now], scanning forward up to
/// 7 days. Null when [windows] never opens (e.g. a window with no days).
DateTime? nextWindowOpening(List<AttentionWindow> windows, DateTime now) {
  DateTime? earliest;
  for (var d = 0; d <= 7; d++) {
    final day = DateTime(now.year, now.month, now.day + d);
    for (final w in windows) {
      if (!w.days.contains(day.weekday)) continue;
      final opening = DateTime(
        day.year,
        day.month,
        day.day,
        _hour(w.start),
        _minute(w.start),
      );
      if (!opening.isAfter(now)) continue;
      if (earliest == null || opening.isBefore(earliest)) earliest = opening;
    }
    // Openings only get later on subsequent days; stop at the first hit.
    if (earliest != null) return earliest;
  }
  return earliest;
}

/// The auto-schedule decision for an outward draft: returns the instant to
/// set as the draft's sendAt, or null for "leave the draft unchanged".
///
/// No change when:
/// - the note is not outward (private/unshared — [isOutward] false);
/// - the focus has no send windows;
/// - now is inside a window (immediate send);
/// - the draft already has a schedule ([currentSendAt] non-null — a manual
///   choice or a prior auto-schedule must not be overridden);
/// - the user manually scheduled OR cleared via the modal
///   ([userTouchedSchedule] — sticky for the draft's lifetime, since a null
///   sendAt alone can't distinguish "never scheduled" from "user cleared").
DateTime? maybeAutoSchedule({
  required List<AttentionWindow>? windows,
  required DateTime? currentSendAt,
  required bool userTouchedSchedule,
  required bool isOutward,
  required DateTime now,
}) {
  if (!isOutward) return null;
  if (windows == null || windows.isEmpty) return null;
  if (insideAnyWindow(windows, now)) return null;
  if (currentSendAt != null) return null;
  if (userTouchedSchedule) return null;
  return nextWindowOpening(windows, now);
}

int _hour(String hhmm) => int.parse(hhmm.split(':')[0]);
int _minute(String hhmm) => int.parse(hhmm.split(':')[1]);
int _minutes(String hhmm) => _hour(hhmm) * 60 + _minute(hhmm);
