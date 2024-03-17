import 'package:dart_date/dart_date.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:equatable/equatable.dart';

export 'package:dart_date/dart_date.dart' show Date, DurationExtension;
export 'package:flutter/material.dart' show TimeOfDay;

enum TimeHorizon {
  day,
  week,
  month,
  year;

  DateTime add(DateTime dateTime) {
    return switch (this) {
      TimeHorizon.day => dateTime.addDays(1, true),
      TimeHorizon.week => dateTime.addDays(7, true),
      TimeHorizon.month => dateTime.nextMonth,
      TimeHorizon.year => dateTime.nextYear,
    };
  }

  DateTime sub(DateTime dateTime) {
    return switch (this) {
      TimeHorizon.day => dateTime.addDays(-1, true),
      TimeHorizon.week => dateTime.addDays(-7, true),
      TimeHorizon.month => dateTime.previousMonth,
      TimeHorizon.year => dateTime.previousYear,
    };
  }
}

enum TimeDirection {
  descending,
  ascending,
}

class DateTimeRange extends Equatable {
  static DateTimeRange fromString(String db) {
    if (db == 'empty') {
      final now = DateTime.now().toLocal();
      return DateTimeRange(now, now);
    }
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateTimeStrings = stripped.split(',');
    List<DateTime> dateTimes = dateTimeStrings
        .map((timestamp) => DateTime.parse(timestamp.trim()).toLocal())
        .toList();
    if (db.endsWith(')')) {
      return DateTimeRange(dateTimes[0], dateTimes[1]);
    } else {
      return DateTimeRange(dateTimes[0], dateTimes[1]);
    }
  }

  DateTimeRange(this.start, this.end) {
    if (start.isAfter(end)) {
      throw RangeError('Invalid Range');
    }
  }

  DateTimeRange.day(DateTime value)
      : this(
          value.startOfDay,
          TimeHorizon.day.add(value),
        );

  DateTimeRange.week(DateTime value)
      : this(
          value.startOfWeek,
          TimeHorizon.week.add(value),
        );

  DateTimeRange.month(DateTime value)
      : this(
          value.startOfMonth,
          TimeHorizon.month.add(value),
        );

  DateTimeRange.year(DateTime value)
      : this(
          value.startOfYear,
          TimeHorizon.year.add(value),
        );

  DateTimeRange.today() : this.day(DateTime.now().toLocal());

  final DateTime start;
  final DateTime end;

  @override
  List<Object> get props => [start, end];

  Duration get duration => end.difference(start);

  bool includes(DateTime date) =>
      (date.isAfter(start) || date.isAtSameMomentAs(start)) &&
      (date.isBefore(end));

  bool contains(DateTimeRange interval) =>
      includes(interval.start) && includes(interval.end);

  bool overlaps(DateTimeRange other) =>
      includes(other.start) || other.includes(start);

  bool cross(DateTimeRange other) =>
      overlaps(other) || start == other.end || end == other.start;

  DateTimeRange union(DateTimeRange other) {
    if (cross(other)) {
      if (end.isAfter(other.start) || end.isAtSameMomentAs(other.start)) {
        return DateTimeRange(start, other.end);
      } else if (other.end.isAfter(start) ||
          other.end.isAtSameMomentAs(start)) {
        return DateTimeRange(other.start, end);
      } else {
        throw RangeError('Error this: $this; other: $other');
      }
    } else {
      throw RangeError('DateTimeRanges don\'t cross');
    }
  }

  DateTimeRange intersection(DateTimeRange other) {
    if (!cross(other)) {
      if (other.contains(this)) {
        return this;
      }

      throw RangeError('DateTimeRanges don\'t cross');
    }

    final intersectionStart = Date.max(start, other.start);
    final intersectionEnd = Date.min(end, other.end);

    return DateTimeRange(intersectionStart, intersectionEnd);
  }

  DateTimeRange? difference(DateTimeRange other) {
    if (other == this) {
      return null;
    } else if (this <= other) {
      // | this | | other |
      if (end.isBefore(other.start)) {
        return this;
      } else {
        return DateTimeRange(start, other.start);
      }
    } else if (this >= other) {
      // | other | | this |
      if (other.end.isBefore(start)) {
        return this;
      } else {
        return DateTimeRange(other.end, end);
      }
    } else {
      throw RangeError('Error this: $this; other: $other');
    }
  }

  List<DateTimeRange?> symetricDiffetence(DateTimeRange other) {
    final list = <DateTimeRange?>[null, null];
    try {
      list[0] = difference(other);
    } catch (e) {
      list[0] = null;
    }
    try {
      list[1] = other.difference(this);
    } catch (e) {
      list[1] = null;
    }
    return list;
  }

  bool operator <(DateTimeRange other) =>
      start.isBefore(other.start) ||
      (start.isAtSameMomentAs(other.start) && end.isBefore(other.end));

  bool operator <=(DateTimeRange other) => this < other || this == other;

  bool operator >(DateTimeRange other) =>
      start.isAfter(other.start) ||
      (start.isAtSameMomentAs(other.start) && end.isAfter(other.end));

  bool operator >=(DateTimeRange other) => this > other || this == other;

  bool isBefore(DateTimeRange other) => end.isSameOrBefore(other.start);
  bool isAfter(DateTimeRange other) => start.isSameOrAfter(other.end);

  @override
  String toString() =>
      "[${start.toUtc().toIso8601String()}, ${end.toUtc().toIso8601String()})";

  TimeHorizon? get horizon {
    if (start == start.startOfDay && start.nextDay.startOfDay == end) {
      return TimeHorizon.day;
    } else if (start == start.startOfWeek &&
        start.nextWeek.startOfWeek == end) {
      return TimeHorizon.week;
    }
    return null;
  }

  DateTimeRange previous() {
    return DateTimeRange(
        start -
            (duration +
                (start - duration).timeZoneOffset -
                start.timeZoneOffset -
                start.timeZoneOffset +
                end.timeZoneOffset),
        start);
  }

  DateTimeRange next() {
    return DateTimeRange(
        end,
        end +
            (duration +
                end.timeZoneOffset -
                (end + duration).timeZoneOffset -
                start.timeZoneOffset +
                end.timeZoneOffset));
  }

  DateTime at(TimeOfDay time) {
    return DateTime(
      start.year,
      start.month,
      start.day,
      time.hour,
      time.minute,
    );
  }

  bool isNow() {
    return includes(DateTime.now());
  }

  String toFriendlyString() {
    final now = DateTime.now();
    // We shrink the interval to account for DST and exclusive endings
    final start = this.start.add(const Duration(hours: 1));
    final end = this.end.sub(const Duration(hours: 1, seconds: 1));
    if (horizon == TimeHorizon.day) {
      return start.format('EEEE, MMM d');
    } else if (horizon == TimeHorizon.week &&
        start.isAtSameMomentAs(now.startOfWeek)) {
      return "This week";
    } else if (horizon == TimeHorizon.week &&
        start == now.startOfWeek.previousWeek) {
      return "Last week";
    } else if (horizon == TimeHorizon.week &&
        start == now.startOfWeek.nextWeek) {
      return "Next week";
    } else if (start.isSameMonth(end)) {
      return '${start.format('MMM d')} - ${end.format('d')}';
    } else {
      return '${start.format('MMM d')} - ${end.format('MMM d')}';
    }
  }
}

class Time {
  static Duration duration(String durationString) {
    final RegExp postgresDateTimeRangeRegExp = RegExp(
        r'^(([0-9]+) days? )?([0-9]{2-3}):([0-9]{2}):([0-9]+(\.[0-9]+)?)?$');
    final RegExp iso8601RegExp = RegExp(
        r'^P(([0-9]+)D)?(T(([0-9]+)H)?(([0-9]+)M)?(([0-9]+(\.[0-9]+)?)S)?)?$');

    final Match? postgresDateTimeRangeMatch =
        postgresDateTimeRangeRegExp.matchAsPrefix(durationString);
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
    } else if (postgresDateTimeRangeMatch != null) {
      String? days = postgresDateTimeRangeMatch.group(2);
      hours = postgresDateTimeRangeMatch.group(3);
      minutes = postgresDateTimeRangeMatch.group(4);
      seconds = postgresDateTimeRangeMatch.group(5);
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

  String toFriendlyString() {
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
