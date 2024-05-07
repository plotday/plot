import 'package:dart_date/dart_date.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:equatable/equatable.dart';

export 'package:dart_date/dart_date.dart' hide Interval;
export 'package:flutter/material.dart' show TimeOfDay;

enum TimeDirection {
  descending,
  ascending,
}

class Date extends Equatable {
  static Date today() => DateTime.now().toLocal().toDate();

  const Date(this.year, this.month, this.day);

  Date.fromString(String date)
      : year = int.parse(date.substring(0, 4)),
        month = int.parse(date.substring(5, 7)),
        day = int.parse(date.substring(8, 10));

  final int year;
  final int month;
  final int day;

  @override
  List<Object> get props => [year, month, day];

  bool operator <(Date other) =>
      year < other.year ||
      (year == other.year && month < other.month) ||
      (year == other.year && month == other.month && day < other.day);
  bool operator <=(Date other) => this == other || this < other;
  bool operator >(Date other) =>
      year > other.year ||
      (year == other.year && month > other.month) ||
      (year == other.year && month == other.month && day > other.day);
  bool operator >=(Date other) => this == other || this > other;

  Duration difference(Date other) =>
      Duration(days: toDateTime().difference(other.toDateTime()).inDays);

  Date operator +(Duration duration) => toDateTime().add(duration).toDate();
  Date operator -(Duration duration) => toDateTime().sub(duration).toDate();
  Date addDays(int days, {TimeDirection direction = TimeDirection.ascending}) =>
      toDateTime()
          .addDays(days * (direction == TimeDirection.ascending ? 1 : -1))
          .toDate();
  Date subDays(int days) => toDateTime().subDays(days).toDate();
  Date next({TimeDirection direction = TimeDirection.ascending}) =>
      addDays(direction == TimeDirection.ascending ? 1 : -1);

  int get weekday => toDateTime().weekday;

  DateTime toDateTime({TimeOfDay time = const TimeOfDay(hour: 0, minute: 0)}) =>
      DateTime(year, month, day, time.hour, time.minute);
  Day toDateRange() => Day(this);
  DateTimeRange toDateTimeRange() => toDateRange().toDateTimeRange();

  Date copyWith({int? year, int? month, int? day}) =>
      Date(year ?? this.year, month ?? this.month, day ?? this.day);
  Date get startOfMonth => Date(year, month, 1);

  @override
  String toString() =>
      "$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}";

  String format() {
    return toDateTime().format('EEEE, MMM d');
  }
}

abstract class DateRange extends Equatable {
  static DateRange fromString(String db) {
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateStrings = stripped.split(',');
    List<Date> dates = dateStrings
        .map((timestamp) => Date.fromString(timestamp.trim()))
        .toList();
    switch (dates[1].difference(dates[0]).inDays) {
      case 1:
        return Day(dates[0]);
      case 7:
        return Week(dates[0]);
      case 28:
      case 30:
      case 31:
        return Month(dates[0]);
      default:
        throw RangeError("Invalid DateRange: $db");
    }
  }

  const DateRange();

  Date get start;
  Date get end;
  DateRange previous();
  DateRange next();

  Duration get duration => end.difference(start);

  bool includes(Date date) => date >= start && date < end;
  bool contains(DateRange interval) =>
      includes(interval.start) && includes(interval.end);
  bool overlaps(DateRange other) =>
      includes(other.start) || other.includes(start);
  bool cross(DateRange other) =>
      overlaps(other) || start == other.end || end == other.start;

  bool operator <(DateRange other) =>
      start < other.start || start == other.start && end < other.end;
  bool operator <=(DateRange other) => this < other || this == other;
  bool operator >(DateRange other) =>
      start > other.start || (start == other.start && end > other.end);
  bool operator >=(DateRange other) => this > other || this == other;

  @override
  String toString() => "[$start, $end)";

  DateTimeRange toDateTimeRange() =>
      DateTimeRange(start.toDateTime(), end.toDateTime());

  bool isNow() {
    return includes(Date.today());
  }

  String format() => '${start.format()} - ${end.format()}';
}

class Day extends DateRange {
  const Day(this.start);
  Day.today() : start = Date.today();

  @override
  final Date start;

  @override
  Date get end => start + const Duration(days: 1);

  @override
  Day previous() => Day(start - const Duration(days: 1));

  @override
  Day next() => Day(start + const Duration(days: 1));

  @override
  List<Object> get props => [start];

  @override
  String format() {
    final day = start.format();
    if (isNow()) {
      return "Today ($day)";
    } else if (next().isNow()) {
      return "Yesterday ($day)";
    } else if (previous().isNow()) {
      return "Tomorrow ($day)";
    } else {
      return day;
    }
  }
}

class Week extends DateRange {
  static int startOfWeek = DateTime.monday;

  final Date _monday;

  static Date _getMonday(Date date) {
    if (date.weekday >= startOfWeek) {
      return date.addDays(8 - date.weekday);
    } else {
      return date.subDays(date.weekday - 1);
    }
  }

  Week(Date date) : _monday = _getMonday(date);
  Week.current() : _monday = _getMonday(Date.today());

  @override
  Date get start => _monday.subDays((8 - startOfWeek) % 7);

  @override
  Date get end => start + const Duration(days: 7);

  @override
  Week previous() => Week(_monday - const Duration(days: 7));

  @override
  Week next() => Week(end);

  @override
  List<Object> get props => [_monday];

  @override
  String format() {
    final week =
        "${start.toDateTime().format('MMM d')} - ${end.month == start.month ? '' : "${end.toDateTime().format('MMM')} "}${end.toDateTime().format('d')}";
    if (isNow()) {
      return "This week ($week)";
    } else if (next().isNow()) {
      return "Last week ($week)";
    } else if (previous().isNow()) {
      return "Next week ($week)";
    } else {
      return week;
    }
  }
}

class Month extends DateRange {
  @override
  final Date start;

  Month(Date start) : start = start.startOfMonth;
  Month.current() : start = Date.today().startOfMonth;

  @override
  Date get end => start.toDateTime().nextMonth.toDate();

  @override
  Month previous() => Month(start.toDateTime().previousMonth.toDate());

  @override
  Month next() => Month(end);

  @override
  List<Object> get props => [start];

  @override
  String format() {
    if (start.year == Date.today().year) {
      return start.toDateTime().format('MMMM');
    } else {
      return start.toDateTime().format('MMMM yyyy');
    }
  }
}

class DateTimeRange extends Equatable {
  static DateTimeRange fromString(String db) {
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateTimeStrings = stripped.split(',');
    List<DateTime> dateTimes = dateTimeStrings
        .map((timestamp) => DateTime.parse(timestamp.trim()).toLocal())
        .toList();
    return DateTimeRange(dateTimes[0], dateTimes[1]);
  }

  DateTimeRange(this.start, this.end) {
    if (start.isAfter(end)) {
      throw RangeError('Invalid Range');
    }
  }

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

    final intersectionStart = DateTimeExtension.max(start, other.start);
    final intersectionEnd = DateTimeExtension.min(end, other.end);

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
  String toDb() => toString();

  bool isNow() {
    return includes(DateTime.now());
  }
}

extension DateTimeExtension2 on DateTime {
  String toDb() {
    return toUtc().toIso8601String();
  }

  Date toDate() => Date(year, month, day);
  TimeOfDay toTimeOfDay() => TimeOfDay(hour: hour, minute: minute);
  DateTime at(TimeOfDay time) =>
      DateTime(year, month, day, time.hour, time.minute);
}

Duration durationFromString(String durationString) {
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

  String format() {
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
  bool operator <(TimeOfDay other) {
    return hour < other.hour || (hour == other.hour && minute < other.minute);
  }

  bool operator >(TimeOfDay other) {
    return hour > other.hour || (hour == other.hour && minute > other.minute);
  }

  bool operator <=(TimeOfDay other) {
    return this == other || this < other;
  }

  bool operator >=(TimeOfDay other) {
    return this == other || this > other;
  }
}
