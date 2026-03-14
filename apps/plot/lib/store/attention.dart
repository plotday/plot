import 'dart:convert';

import 'package:plot/util/time.dart';

class AttentionWindow {
  final List<int> days; // ISO 1=Mon..7=Sun
  final String start; // "HH:MM"
  final String end; // "HH:MM"

  static const dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  const AttentionWindow({
    required this.days,
    required this.start,
    required this.end,
  });

  factory AttentionWindow.fromJson(Map<String, dynamic> json) {
    return AttentionWindow(
      days: (json['days'] as List).cast<int>(),
      start: json['start'] as String,
      end: json['end'] as String,
    );
  }

  Map<String, dynamic> toJson() => {'days': days, 'start': start, 'end': end};

  AttentionWindow copyWith({List<int>? days, String? start, String? end}) {
    return AttentionWindow(
      days: days ?? this.days,
      start: start ?? this.start,
      end: end ?? this.end,
    );
  }

  String get summary => '$displayDays, $displayTime';

  String get displayDays {
    final sorted = List<int>.from(days)..sort();
    if (sorted.length == 7) return 'Every day';
    if (sorted.length == 5 && sorted[0] == 1 && sorted[4] == 5) {
      return 'Weekdays';
    }
    if (sorted.length == 2 && sorted[0] == 6 && sorted[1] == 7) {
      return 'Weekends';
    }

    // Check if consecutive
    bool consecutive = true;
    for (int i = 1; i < sorted.length; i++) {
      if (sorted[i] != sorted[i - 1] + 1) {
        consecutive = false;
        break;
      }
    }

    if (consecutive && sorted.length > 1) {
      return '${dayLabels[sorted.first - 1]}\u2013${dayLabels[sorted.last - 1]}';
    }
    return sorted.map((d) => dayLabels[d - 1]).join(', ');
  }

  String get displayTime => '${formatTime(start)} \u2013 ${formatTime(end)}';

  static String formatTime(String hhmm) {
    final parts = hhmm.split(':');
    final hour = int.parse(parts[0]);
    final minute = parts[1];
    if (hour == 0) return '12:$minute AM';
    if (hour < 12) return '$hour:$minute AM';
    if (hour == 12) return '12:$minute PM';
    return '${hour - 12}:$minute PM';
  }

  static List<AttentionWindow>? fromJsonString(String? jsonString) {
    if (jsonString == null) return null;
    final list = jsonDecode(jsonString) as List;
    return list
        .map((e) => AttentionWindow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String? toJsonString(List<AttentionWindow>? windows) {
    if (windows == null) return null;
    return jsonEncode(windows.map((w) => w.toJson()).toList());
  }

  /// Default quiet hours: every day, 9pm-7am
  static List<AttentionWindow> get defaultQuietHours => [
    const AttentionWindow(
      days: [1, 2, 3, 4, 5, 6, 7],
      start: '21:00',
      end: '07:00',
    ),
  ];

  /// Computes the start of the last attention window before the "see within"
  /// deadline, used for smart scheduling of agenda items.
  static DateTimeRange computeSmartScheduleAt(
    DateTime now,
    List<AttentionWindow> windows,
    SeeWithinTime seeWithin,
  ) {
    // 1. Compute deadline
    final deadline = _computeDeadline(now, windows, seeWithin);

    // 2. Scan backwards from deadline to now to find last matching window
    for (
      var day = deadline;
      !day.isBefore(now);
      day = day.subtract(const Duration(days: 1))
    ) {
      final isoWeekday =
          day.weekday; // 1=Mon..7=Sun (matches ISO used in windows)
      for (final window in windows) {
        if (window.days.contains(isoWeekday)) {
          final startParts = window.start.split(':');
          final endParts = window.end.split(':');
          final candidate = DateTime(
            day.year,
            day.month,
            day.day,
            int.parse(startParts[0]),
            int.parse(startParts[1]),
          );
          final candidateEnd = DateTime(
            day.year,
            day.month,
            day.day,
            int.parse(endParts[0]),
            int.parse(endParts[1]),
          );
          if (!candidate.isBefore(now) && !candidate.isAfter(deadline)) {
            return DateTimeRange(candidate, candidateEnd);
          }
        }
      }
    }

    // 3. Fallback: find next attention window after now (scan up to 14 days)
    for (var i = 0; i < 14; i++) {
      final day = now.add(Duration(days: i));
      final isoWeekday = day.weekday;
      for (final window in windows) {
        if (window.days.contains(isoWeekday)) {
          final startParts = window.start.split(':');
          final endParts = window.end.split(':');
          final candidate = DateTime(
            day.year,
            day.month,
            day.day,
            int.parse(startParts[0]),
            int.parse(startParts[1]),
          );
          final candidateEnd = DateTime(
            day.year,
            day.month,
            day.day,
            int.parse(endParts[0]),
            int.parse(endParts[1]),
          );
          if (!candidate.isBefore(now)) {
            return DateTimeRange(candidate, candidateEnd);
          }
        }
      }
    }

    // Ultimate fallback: now + 1 hour
    return DateTimeRange(now, now.add(const Duration(hours: 1)));
  }

  static DateTime _computeDeadline(
    DateTime now,
    List<AttentionWindow> windows,
    SeeWithinTime seeWithin,
  ) {
    switch (seeWithin.unit) {
      case SeeWithinUnit.minutes:
        return now.add(Duration(minutes: seeWithin.value));
      case SeeWithinUnit.hours:
        return now.add(Duration(hours: seeWithin.value));
      case SeeWithinUnit.days:
        return now.add(Duration(days: seeWithin.value));
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttentionWindow &&
          _listEquals(days, other.days) &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(Object.hashAll(days), start, end);

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

enum SeeWithinUnit {
  minutes,
  hours,
  days;

  String get label {
    switch (this) {
      case SeeWithinUnit.minutes:
        return 'minutes';
      case SeeWithinUnit.hours:
        return 'hours';
      case SeeWithinUnit.days:
        return 'days';
    }
  }
}

class SeeWithinTime {
  final int value;
  final SeeWithinUnit unit;

  const SeeWithinTime({required this.value, required this.unit});

  factory SeeWithinTime.fromJson(Map<String, dynamic> json) {
    return SeeWithinTime(
      value: json['value'] as int,
      unit: SeeWithinUnit.values.firstWhere((u) => u.name == json['unit']),
    );
  }

  Map<String, dynamic> toJson() => {'value': value, 'unit': unit.name};

  static SeeWithinTime? fromJsonString(String? jsonString) {
    if (jsonString == null) return null;
    return SeeWithinTime.fromJson(
      jsonDecode(jsonString) as Map<String, dynamic>,
    );
  }

  static String? toJsonString(SeeWithinTime? seeWithin) {
    if (seeWithin == null) return null;
    return jsonEncode(seeWithin.toJson());
  }

  String get displayLabel {
    return '$value ${unit.label}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeeWithinTime && value == other.value && unit == other.unit;

  @override
  int get hashCode => Object.hash(value, unit);
}
