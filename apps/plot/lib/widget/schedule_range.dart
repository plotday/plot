import 'package:forui/forui.dart';

import 'package:plot/util/time.dart';

/// Pure helpers that recompute a [DateTimeRange] when one facet (date, start,
/// end, duration) changes, plus a [clampScheduleRange] that enforces a minimum
/// duration and (optionally) keeps the range out of the past. Extracted so both
/// the scheduler UI and unit tests share one implementation.

const Duration _minDuration = Duration(minutes: 15);
const Duration _fallbackDuration = Duration(minutes: 30);

DateTime _at(DateTime date, FTime time) =>
    DateTime(date.year, date.month, date.day, time.hour, time.minute);

/// Move the range to [date], preserving time-of-day and duration.
DateTimeRange withDate(DateTimeRange range, DateTime date) {
  final start = range.start;
  if (start == null) return range;
  final duration = range.duration ?? _fallbackDuration;
  final newStart = DateTime(
    date.year,
    date.month,
    date.day,
    start.hour,
    start.minute,
  );
  return DateTimeRange(newStart, newStart.add(duration));
}

/// Set the start time-of-day, preserving duration.
DateTimeRange withStart(DateTimeRange range, FTime start) {
  final anchor = range.start ?? Time.now();
  final duration = range.duration ?? _fallbackDuration;
  final newStart = _at(anchor, start);
  return DateTimeRange(newStart, newStart.add(duration));
}

/// Set the end time-of-day, recomputing duration. If the new end is at or
/// before start, it rolls to the next day.
DateTimeRange withEnd(DateTimeRange range, FTime end) {
  final start = range.start ?? Time.now();
  var newEnd = _at(start, end);
  if (!newEnd.isAfter(start)) {
    newEnd = newEnd.add(const Duration(days: 1));
  }
  return DateTimeRange(start, newEnd);
}

/// Set the duration, moving end relative to start.
DateTimeRange withDuration(DateTimeRange range, Duration duration) {
  final start = range.start ?? Time.now();
  return DateTimeRange(start, start.add(duration));
}

/// Shift both ends by [delta], preserving duration.
DateTimeRange shiftedBy(DateTimeRange range, Duration delta) {
  final start = range.start;
  final end = range.end;
  if (start == null || end == null) return range;
  return DateTimeRange(start.add(delta), end.add(delta));
}

/// Enforce a 15-minute minimum duration and, unless [allowPast], keep the range
/// from starting before [now] (sliding it forward and preserving duration).
DateTimeRange clampScheduleRange(
  DateTimeRange range, {
  required bool allowPast,
  required DateTime now,
}) {
  var start = range.start;
  var end = range.end;
  if (start == null || end == null) return range;

  if (!allowPast && start.isBefore(now)) {
    final shift = now.difference(start);
    start = now;
    end = end.add(shift);
  }

  if (end.isBefore(start) || end.difference(start) < _minDuration) {
    end = start.add(_minDuration);
  }

  return DateTimeRange(start, end);
}
