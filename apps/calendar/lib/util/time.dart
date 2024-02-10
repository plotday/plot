import 'package:dart_date/dart_date.dart';
import 'package:flutter/material.dart' show TimeOfDay;

export 'package:dart_date/dart_date.dart';
export 'package:flutter/material.dart' show TimeOfDay;

enum TimeHorizon {
  day,
  week;

  get duration {
    switch (this) {
      case TimeHorizon.day:
        return const Duration(days: 1);
      case TimeHorizon.week:
        return const Duration(days: 7);
    }
  }
}

enum TimeDirection {
  descending,
  ascending,
}

class Time {
  static Interval interval(String db) {
    if (db == 'empty') {
      final now = DateTime.now();
      return Interval(now, now);
    }
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateTimeStrings = stripped.split(',');
    List<DateTime> dateTimes = dateTimeStrings
        .map((timestamp) => DateTime.parse(timestamp.trim()).toLocal())
        .toList();
    return Interval(dateTimes[0], dateTimes[1]);
  }

  static Interval day(DateTime value) => Interval(
        value.startOfDay,
        value.startOfDay.nextDay,
      );

  static Interval week(DateTime value) => Interval(
        value.startOfWeek,
        value.startOfWeek.nextWeek,
      );

  static Interval month(DateTime value) => Interval(
        value.startOfMonth,
        value.startOfMonth.nextMonth,
      );

  static Interval year(DateTime value) => Interval(
        value.startOfYear,
        value.startOfYear.nextYear,
      );

  static Interval today() => Time.day(DateTime.now());

  static Duration duration(String durationString) {
    final RegExp postgresIntervalRegExp = RegExp(
        r'^(([0-9]+) days? )?([0-9]{2-3}):([0-9]{2}):([0-9]+(\.[0-9]+)?)?$');
    final RegExp iso8601RegExp = RegExp(
        r'^P(([0-9]+)D)?(T(([0-9]+)H)?(([0-9]+)M)?(([0-9]+(\.[0-9]+)?)S)?)?$');

    final Match? postgresIntervalMatch =
        postgresIntervalRegExp.matchAsPrefix(durationString);
    final Match? iso8601Match = iso8601RegExp.matchAsPrefix(durationString);

    String? hours;
    String? minutes;
    String? seconds;
    if (iso8601Match != null) {
      String? days = iso8601Match.group(2);
      hours = iso8601Match.group(4);
      minutes = iso8601Match.group(6);
      seconds = iso8601Match.group(8);
      return Duration(
        days: days != null ? int.parse(days) : 0,
        hours: hours != null ? int.parse(hours) : 0,
        minutes: minutes != null ? int.parse(minutes) : 0,
        seconds: seconds != null ? double.parse(seconds).round() : 0,
      );
    } else if (postgresIntervalMatch != null) {
      String? days = postgresIntervalMatch.group(2);
      hours = postgresIntervalMatch.group(3);
      minutes = postgresIntervalMatch.group(4);
      seconds = postgresIntervalMatch.group(5);
      return Duration(
        days: days != null ? int.parse(days) : 0,
        hours: hours != null ? int.parse(hours) : 0,
        minutes: minutes != null ? int.parse(minutes) : 0,
        seconds: seconds != null ? double.parse(seconds).round() : 0,
      );
    } else {
      throw FormatException("Invalid duration format: $durationString");
    }
  }
}

extension PostgresDateTime on DateTime {
  String toDb() {
    return toUtc().toIso8601String();
  }

  String toDayString() {
    return startOfDay.format('yyyy-MM-dd');
  }

  String toTimeString() {
    return format('h:mm a');
  }

  String get clockString {
    return format('h:mm');
  }

  String get meridiem {
    return format('a');
  }

  TimeOfDay get timeOfDay {
    return TimeOfDay(hour: hour, minute: minute);
  }
}

extension IntervalExtension on Interval {
  Interval get previous => Interval(start.subtract(duration), start);
  Interval get next => Interval(end, end.add(duration));

  DateTime at(TimeOfDay time) {
    return DateTime(
      start.year,
      start.month,
      start.day,
      time.hour,
      time.minute,
    );
  }

  String get friendly {
    final now = DateTime.now();
    final displayEnd = end.subtract(const Duration(seconds: 1));
    if (start.isSameDay(displayEnd)) {
      return start.format('EEEE, MMM d');
    } else if (start == now.startOfWeek && end == now.startOfWeek.nextWeek) {
      return "This week";
    } else if (start == now.startOfWeek.previousWeek &&
        end == now.startOfWeek) {
      return "Last week";
    } else if (start == now.startOfWeek.nextWeek &&
        end == now.startOfWeek.nextWeek.nextWeek) {
      return "Next week";
    } else if (start.isSameMonth(end)) {
      return '${start.format('MMM d')} - ${displayEnd.format('d')}';
    } else {
      return '${start.format('MMM d')} - ${displayEnd.format('MMM d')}';
    }
  }

  String toRangeString() {
    return "[${start.toUtc().toIso8601String()}, ${end.toUtc().toIso8601String()})";
  }

  String toDayString() {
    return start.toDayString();
  }

  bool isNow() {
    return includes(DateTime.now());
  }
}

extension DurationExtension on Duration {
  String toDb() {
    String format(int n, {int digits = 2}) {
      return n.toString().padLeft(digits, '0');
    }

    var seconds = format(inSeconds.remainder(60));
    final microseconds = inMicroseconds.remainder(1000000);
    if (microseconds > 0) {
      seconds = "$seconds.${format(microseconds, digits: 6)}";
    }
    return 'P${inDays}DT${format(inHours)}H${format(inMinutes)}M${seconds}S';
  }

  String get friendly {
    return '${inHours > 0 ? inHours : ''}:${inMinutes.remainder(60).toString().padLeft(2, '0')}';
  }

  bool get hasHours {
    return inHours > 0;
  }

  String get hoursString {
    return inHours.toString();
  }

  bool get hasMinutes {
    return inMinutes.remainder(60) > 0;
  }

  String get minutesString {
    return inMinutes.remainder(60).toString();
  }
}

extension TimeOfDayExtension on TimeOfDay {
  bool sameTime(DateTime other) {
    return hour == other.hour && minute == other.minute;
  }

  bool operator <(DateTime other) {
    return hour < other.hour || (hour == other.hour && minute < other.minute);
  }

  bool operator >(DateTime other) {
    return hour > other.hour || (hour == other.hour && minute > other.minute);
  }

  bool operator <=(DateTime other) {
    return sameTime(other) || this < other;
  }

  bool operator >=(DateTime other) {
    return sameTime(other) || this > other;
  }

  String get friendly {
    return "${hour == 0 ? 12 : hour <= 12 ? hour : hour - 12}:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}";
  }
}
