import 'package:flutter/widgets.dart';
import 'package:dart_date/dart_date.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:equatable/equatable.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:drift/drift.dart';

import 'time_service.dart' show Time;

export 'package:dart_date/dart_date.dart' hide Interval;
export 'package:flutter/material.dart' show TimeOfDay;
export 'time_service.dart' show Time;

enum TimeDirection { descending, ascending }

class Date extends Equatable implements Comparable<Date> {
  static Date today() => Time.now().toLocal().toDate();

  static Stream<Date> current() async* {
    while (true) {
      DateTime now = Time.now().toLocal();
      yield now.toDate();

      // Wait until the start of the next day
      DateTime tomorrow = now.nextDay.startOfDay;
      Duration untilMidnight = tomorrow.difference(now);
      await Future<void>.delayed(untilMidnight);
    }
  }

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
      Duration(days: toUtc().difference(other.toUtc()).inDays);

  Date operator +(Duration duration) => addDays(duration.inDays);
  Date operator -(Duration duration) => addDays(-duration.inDays);
  Date addDays(int days, {TimeDirection direction = TimeDirection.ascending}) {
    final m = direction == TimeDirection.ascending ? 1 : -1;
    return (toUtc() + Duration(days: days * m)).toDate();
  }

  Date subDays(int days) => addDays(-1 * days);
  Date next({TimeDirection direction = TimeDirection.ascending}) =>
      addDays(direction == TimeDirection.ascending ? 1 : -1);

  int get weekday => toDateTime().weekday;

  DateTime toDateTime({TimeOfDay time = const TimeOfDay(hour: 0, minute: 0)}) =>
      DateTime(year, month, day, time.hour, time.minute);
  DateTime toUtc() => DateTime.utc(year, month, day);
  Day toDateRange() => Day(this);
  DateTimeRange toDateTimeRange() => toDateRange().toDateTimeRange();
  DateTime toStart() => toDateTimeRange().start!;
  DateTime toEnd() => toDateTimeRange().end!;
  bool isPast() => this < today();

  Date copyWith({int? year, int? month, int? day}) =>
      Date(year ?? this.year, month ?? this.month, day ?? this.day);
  Date get startOfMonth => Date(year, month, 1);

  @override
  String toString() =>
      "$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}";

  String format({String format = 'EEEE, MMM d'}) {
    return toDateTime().format(format);
  }

  @override
  int compareTo(Date other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  bool isBefore(Date other) {
    return this < other;
  }

  bool isAfter(Date other) {
    return this > other;
  }
}

abstract class DateRange extends Equatable {
  static DateRange fromString(String db) {
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateStrings = stripped.split(',');
    List<Date?> dates = dateStrings
        .map(
          (timestamp) =>
              timestamp.trim() == '' ||
                  timestamp.trim() == '-∞' ||
                  timestamp.trim() == '+∞'
              ? null
              : Date.fromString(timestamp.trim()),
        )
        .toList();

    // Handle unbounded ranges
    if (dates[0] == null || dates[1] == null) {
      return CustomDateRange(dates[0], dates[1]);
    }

    switch (dates[1]!.difference(dates[0]!).inDays) {
      case 1:
        return Day(dates[0]!);
      case 7:
        return Week(dates[0]!);
      case 28:
      case 30:
      case 31:
        return Month(dates[0]!);
      default:
        return CustomBoundedDateRange(dates[0]!, dates[1]!);
    }
  }

  const DateRange();

  bool get bounded => start != null && end != null;
  Date? get start;
  Date? get end;
  Date? get first => start;
  Date? get last => end?.subDays(1);
  DateRange previous();
  DateRange next();

  Duration? get duration =>
      start != null && end != null ? end!.difference(start!) : null;
  (Date?, Date?) get bounds => (start, end);

  bool includes(Date date) =>
      (start == null || date >= start!) && (end == null || date < end!);
  bool contains(DateRange interval) =>
      (interval.start == null || includes(interval.start!)) &&
      (interval.end == null || (end == null || interval.end! <= end!));

  bool overlaps(DateRange other) =>
      (other.start != null && includes(other.start!)) ||
      (start != null && other.includes(start!));

  bool cross(DateRange other) =>
      overlaps(other) || start == other.end || end == other.start;

  bool operator <(DateRange other) {
    if (start == other.start) {
      if (end == other.end) return false;
      if (end == null) return false;
      if (other.end == null) return true;
      return end!.isBefore(other.end!);
    }
    if (start == null) return true;
    if (other.start == null) return false;
    return start!.isBefore(other.start!);
  }

  bool operator <=(DateRange other) => this < other || this == other;
  bool operator >(DateRange other) {
    return this != other && !(this < other);
  }

  bool operator >=(DateRange other) => this > other || this == other;

  CustomBoundedDateRange toBounded() => CustomBoundedDateRange(start!, end!);

  @override
  String toString() => "[${start ?? ''},${end ?? ''})";

  String toDb() => toString();

  bool isNow() {
    return includes(Date.today());
  }

  String format() => '${start?.format() ?? '-∞'} - ${end?.format() ?? '+∞'}';

  DateTimeRange toDateTimeRange() =>
      DateTimeRange(start?.toDateTime(), end?.toDateTime());
}

abstract class BoundedDateRange extends DateRange {
  const BoundedDateRange();

  @override
  Date get start;
  @override
  Date get end;
  @override
  Date get first => start;
  @override
  Date get last => end.subDays(1);

  @override
  Duration get duration => end.difference(start);

  @override
  (Date, Date) get bounds => (start, end);

  @override
  String toString() => "[$start, $end)";

  @override
  BoundedDateTimeRange toDateTimeRange() =>
      BoundedDateTimeRange(start.toDateTime(), end.toDateTime());
}

class Day extends BoundedDateRange {
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
  String format({String? format}) {
    final day = start.format();
    if (format != null) {
      return start.format(format: format);
    } else if (isNow()) {
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

class Week extends BoundedDateRange {
  static int startOfWeek = DateTime.monday;

  final Date _monday;

  static Date _getMonday(Date date) {
    return date.subDays(date.toDateTime().weekday - startOfWeek);
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
        "${first.toDateTime().format('MMM d')} – ${last.month == first.month ? '' : "${last.toDateTime().format('MMM')} "}${last.toDateTime().format('d')}";
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

class Month extends BoundedDateRange {
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

class CustomDateRange extends DateRange {
  CustomDateRange(this.start, this.end) {
    if (start != null &&
        end != null &&
        (start!.isAfter(end!) || start == end)) {
      throw RangeError('Invalid CustomDateRange: $start - $end');
    }
  }

  @override
  final Date? start;
  @override
  final Date? end;

  @override
  CustomDateRange previous() {
    if (start != null && end != null) {
      final duration = end!.difference(start!);
      return CustomDateRange(start! - duration, start);
    } else {
      return CustomDateRange(null, start);
    }
  }

  @override
  CustomDateRange next() {
    if (start != null && end != null) {
      final duration = end!.difference(start!);
      return CustomDateRange(end, end! + duration);
    } else {
      return CustomDateRange(end, null);
    }
  }

  @override
  List<Object?> get props => [start, end];
}

class CustomBoundedDateRange extends BoundedDateRange {
  CustomBoundedDateRange(Date start, Date end) : _start = start, _end = end {
    if (start.isAfter(end) || start == end) {
      throw RangeError('Invalid CustomBoundedDateRange: $start - $end');
    }
  }

  final Date _start;
  final Date _end;

  @override
  Date get start => _start;

  @override
  Date get end => _end;

  @override
  CustomBoundedDateRange previous() =>
      CustomBoundedDateRange(_start - end.difference(_start), _start);

  @override
  CustomBoundedDateRange next() =>
      CustomBoundedDateRange(end, end + end.difference(_start));

  @override
  List<Object> get props => [_start, _end];

  @override
  String format() => '${start.format()} - ${end.format()}';

  /// Creates a bounded date range from nullable dates
  /// Returns null if either date is null
  static CustomBoundedDateRange? fromNullable(Date? start, Date? end) {
    if (start != null && end != null) {
      return CustomBoundedDateRange(start, end);
    }
    return null;
  }

  /// Creates a bounded date range with validation
  /// Throws ArgumentError if dates are invalid
  static CustomBoundedDateRange validated(Date start, Date end) {
    if (start.isAfter(end)) {
      throw ArgumentError('Start date $start cannot be after end date $end');
    }
    if (start == end) {
      throw ArgumentError('Start and end dates cannot be equal: $start');
    }
    return CustomBoundedDateRange(start, end);
  }
}

class DateTimeRange extends Equatable {
  factory DateTimeRange.fromString(String db) {
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateTimeStrings = stripped.split(',');
    List<DateTime?> dateTimes = dateTimeStrings
        .map(
          (timestamp) => timestamp.trim() == ''
              ? null
              : DateTime.parse(timestamp.trim()).toLocal(),
        )
        .toList();
    return DateTimeRange(dateTimes[0], dateTimes[1]);
  }

  DateTimeRange(this.start, this.end) {
    if (start != null && end != null && start!.isAfter(end!)) {
      throw RangeError('Invalid DateTimeRange: $start - $end');
    }
  }

  DateTimeRange copyWith({DateTime? start, DateTime? end, Duration? duration}) {
    if (start != null && end == null && duration != null) {
      end = start.add(duration);
    } else if (start == null && end != null && duration != null) {
      start = end.subtract(duration);
    }
    return DateTimeRange(start ?? this.start, end ?? this.end);
  }

  DateTimeRange min(DateTime start) => DateTimeRange(
    this.start == null
        ? start
        : (this.start!.isBefore(start) ? start : this.start),
    end == null ? start : (end!.isBefore(start) ? start : end),
  );

  DateTimeRange max(DateTime end) => DateTimeRange(
    start == null ? end : (start!.isAfter(end) ? end : start),
    this.end == null ? end : (this.end!.isAfter(end) ? end : this.end),
  );

  final DateTime? start;
  final DateTime? end;

  (DateTime?, DateTime?) get bounds => (start, end);

  @override
  List<Object?> get props => [start, end];

  Duration? get duration =>
      start != null && end != null ? end!.difference(start!) : null;

  bool includes(DateTime date) =>
      (start == null ||
          date.isAfter(start!) ||
          date.isAtSameMomentAs(start!)) &&
      (end == null || date.isBefore(end!));

  bool contains(DateTimeRange interval) =>
      (interval.start == null || includes(interval.start!)) &&
      (interval.end == null || includes(interval.end!));

  bool overlaps(DateTimeRange other) =>
      (other.start != null && includes(other.start!)) ||
      (start != null && other.includes(start!));

  bool cross(DateTimeRange other) =>
      overlaps(other) ||
      (start != null && start == other.end) ||
      (end != null && end == other.start);

  DateTimeRange union(DateTimeRange other) {
    if (cross(other)) {
      // Handle unbounded ranges - null means infinity
      final DateTime? unionStart = start == null || other.start == null
          ? null
          : (start!.isBefore(other.start!) ? start : other.start);
      final DateTime? unionEnd = end == null || other.end == null
          ? null
          : (end!.isAfter(other.end!) ? end : other.end);
      return DateTimeRange(unionStart, unionEnd);
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

    // For intersection, we take the later start and earlier end
    final DateTime? intersectionStart = start == null
        ? other.start
        : (other.start == null
              ? start
              : (start!.isAfter(other.start!) ? start : other.start));
    final DateTime? intersectionEnd = end == null
        ? other.end
        : (other.end == null
              ? end
              : (end!.isBefore(other.end!) ? end : other.end));

    return DateTimeRange(intersectionStart, intersectionEnd);
  }

  DateTimeRange? difference(DateTimeRange other) {
    if (other == this) {
      return null;
    } else if (this <= other) {
      // | this | | other |
      if (end != null && other.start != null && end!.isBefore(other.start!)) {
        return this;
      } else {
        return DateTimeRange(start, other.start);
      }
    } else if (this >= other) {
      // | other | | this |
      if (other.end != null && start != null && other.end!.isBefore(start!)) {
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

  bool operator <(DateTimeRange other) {
    if (start == other.start) {
      if (end == other.end) return false;
      if (end == null) return false;
      if (other.end == null) return true;
      return end!.isBefore(other.end!);
    }
    if (start == null) return true;
    if (other.start == null) return false;
    return start!.isBefore(other.start!);
  }

  bool operator <=(DateTimeRange other) => this < other || this == other;

  bool operator >(DateTimeRange other) {
    return this != other && !(this < other);
  }

  bool operator >=(DateTimeRange other) => this > other || this == other;

  bool isBefore(DateTimeRange other) =>
      end != null && other.start != null && end!.isSameOrBefore(other.start!);
  bool isAfter(DateTimeRange other) =>
      start != null && other.end != null && start!.isSameOrAfter(other.end!);

  @override
  String toString() =>
      "[${start?.toUtc().toIso8601String() ?? '-∞'}, ${end?.toUtc().toIso8601String() ?? '+∞'})";
  String toDb() =>
      "[${start?.toUtc().toIso8601String() ?? ''},${end?.toUtc().toIso8601String() ?? ''})";

  bool isNow() {
    return includes(Time.now());
  }

  CustomDateRange toDateRange() {
    Date? startDate = start?.toDate();
    Date? endDate;
    if (end != null) {
      final endAsDate = end!.toDate();
      // Round up: if end has any time component, move to next day
      if (end != endAsDate.toDateTime()) {
        endDate = endAsDate.addDays(1);
      } else {
        endDate = endAsDate;
      }
    }
    return CustomDateRange(startDate, endDate);
  }
}

class BoundedDateTimeRange extends DateTimeRange {
  BoundedDateTimeRange(DateTime start, DateTime end) : super(start, end) {
    if (start.isAfter(end)) {
      throw RangeError('Invalid BoundedDateTimeRange: $start - $end');
    }
  }

  factory BoundedDateTimeRange.fromString(String db) {
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateTimeStrings = stripped.split(',');
    List<DateTime> dateTimes = dateTimeStrings
        .map((timestamp) => DateTime.parse(timestamp.trim()).toLocal())
        .toList();
    return BoundedDateTimeRange(dateTimes[0], dateTimes[1]);
  }

  @override
  DateTime get start => super.start!;

  @override
  DateTime get end => super.end!;

  @override
  Duration get duration => end.difference(start);

  @override
  (DateTime, DateTime) get bounds => (start, end);

  @override
  BoundedDateTimeRange copyWith({
    DateTime? start,
    DateTime? end,
    Duration? duration,
  }) {
    if (start != null && end == null && duration != null) {
      end = start.add(duration);
    } else if (start == null && end != null && duration != null) {
      start = end.subtract(duration);
    }
    return BoundedDateTimeRange(start ?? this.start, end ?? this.end);
  }

  @override
  BoundedDateTimeRange min(DateTime start) => BoundedDateTimeRange(
    this.start.isBefore(start) ? start : this.start,
    end.isBefore(start) ? start : end,
  );

  @override
  BoundedDateTimeRange max(DateTime end) => BoundedDateTimeRange(
    start.isAfter(end) ? end : start,
    this.end.isAfter(end) ? end : this.end,
  );
}

extension PlotDateTimeExtension on DateTime {
  String toDb() {
    return toUtc().toIso8601String();
  }

  Date toDate() => Date(year, month, day);
  TimeOfDay toTimeOfDay() => TimeOfDay(hour: hour, minute: minute);
  DateTime at(TimeOfDay time) =>
      DateTime(year, month, day, time.hour, time.minute);
  DateTime min(DateTime other) => isBefore(other) ? other : this;
  DateTime max(DateTime other) => isAfter(other) ? other : this;

  DateTime round({int minutes = 30, bool down = true}) => sub(
    Duration(minutes: down ? minute % minutes : (minute % minutes) - minutes),
  );

  DateTime previousMidnight() => toDate().subDays(1).toDateTime();
  DateTime nextMidnight() => toDate().addDays(1).toDateTime();

  String toTimeAgo() => timeago.format(this, clock: Time.now());
}

Duration durationFromString(String durationString) {
  final RegExp postgresDateTimeRangeRegExp = RegExp(
    r'^(([0-9]+) days? )?([0-9]{2,3}):([0-9]{2}):([0-9]+(\.[0-9]+)?)?$',
  );
  final RegExp iso8601RegExp = RegExp(
    r'^P(([0-9]+)D)?(T(([0-9]+)H)?(([0-9]+)M)?(([0-9]+(\.[0-9]+)?)S)?)?$',
  );

  final Match? postgresDateTimeRangeMatch = postgresDateTimeRangeRegExp
      .matchAsPrefix(durationString);
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
    final int hours = inHours;
    final int minutes = inMinutes.remainder(60);

    if (hours == 0 && minutes == 0) {
      return '—';
    }

    final buffer = StringBuffer();
    if (hours > 0) {
      buffer.write('$hours');
      buffer.write('h');
    }
    if (hours > 0 && minutes > 0) {
      buffer.write(' ');
    }
    if (minutes > 0) {
      buffer.write('$minutes');
      buffer.write('m');
    }
    return buffer.toString();
  }

  bool get hasHours => inHours > 0;

  String get hoursString => inHours.toString();

  bool get hasMinutes => inMinutes.remainder(60) > 0;

  String get minutesString => inMinutes.remainder(60).toString();

  bool get isNonZero => inSeconds > 0;
}

/// Formats a [dateTime] into a compact relative label for schedule display.
///
/// Timed events include the time portion (e.g. "Today, 2 PM").
/// All-day events (midnight start) omit the time (e.g. "Today").
String formatRelativeSchedule(DateTime dateTime, BuildContext context) {
  final today = Date.today();
  final date = dateTime.toDate();
  final time = dateTime.toTimeOfDay();
  final isAllDay = time.isMidnight;
  final timeStr = isAllDay ? '' : ', ${time.formatShort(context)}';

  final diff = date.difference(today).inDays;

  if (date == today) {
    return 'Today$timeStr';
  } else if (diff == -1) {
    return 'Yesterday$timeStr';
  } else if (diff == 1) {
    return 'Tomorrow$timeStr';
  } else if (diff >= 2 && diff <= 6) {
    return '${dateTime.format('EEEE')}$timeStr';
  } else if (diff >= -6 && diff <= -2) {
    return 'Last ${dateTime.format('EEEE')}$timeStr';
  } else {
    return '${dateTime.format('MMM d')}$timeStr';
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

  bool get isMidnight => hour == 0 && minute == 0;

  String formatShort(BuildContext context) {
    return format(context)
        .replaceAll(':00', '')
        .replaceAllMapped(
          RegExp(r'\s?([AP]M)$'),
          (m) => ' ${m[1]!.toLowerCase()}',
        );
  }
}

TimeOfDay parseTimeOfDay(String str) {
  final pm = str.contains(RegExp(r'[pP]'));
  str = str.toLowerCase().replaceAll(RegExp(r'[ apm]'), '');
  final parts = str.trim().replaceAll(RegExp(r'[:.\s]'), ':').split(':');
  return TimeOfDay(
    hour: int.parse(parts[0]) + (pm ? 12 : 0),
    minute: parts.length == 1 ? 0 : int.parse(parts[1]),
  );
}

class DateConverter extends TypeConverter<Date, String>
    with JsonTypeConverter2<Date, String, String> {
  const DateConverter();

  @override
  Date fromSql(String fromDb) {
    return Date.fromString(fromDb);
  }

  @override
  String toSql(Date value) {
    return value.toString();
  }

  @override
  Date fromJson(String json) {
    return Date.fromString(json);
  }

  @override
  String toJson(Date value) {
    return value.toString();
  }
}

class DateRangeConverter extends TypeConverter<DateRange, String> {
  const DateRangeConverter();

  @override
  DateRange fromSql(String fromDb) {
    return DateRange.fromString(fromDb);
  }

  @override
  String toSql(DateRange value) {
    return value.toDb();
  }
}

class DateTimeRangeConverter extends TypeConverter<DateTimeRange, String> {
  const DateTimeRangeConverter();

  @override
  DateTimeRange fromSql(String fromDb) {
    return DateTimeRange.fromString(fromDb);
  }

  @override
  String toSql(DateTimeRange value) {
    return value.toDb();
  }
}

class DurationConverter extends TypeConverter<Duration, int>
    with JsonTypeConverter2<Duration, int, int> {
  const DurationConverter();

  @override
  Duration fromSql(int fromDb) {
    return Duration(seconds: fromDb);
  }

  @override
  int toSql(Duration value) {
    return value.inSeconds;
  }

  @override
  Duration fromJson(int json) {
    return Duration(seconds: json);
  }

  @override
  int toJson(Duration value) {
    return value.inSeconds;
  }
}

class IntervalConverter extends TypeConverter<Duration, int>
    with JsonTypeConverter2<Duration, int, Object> {
  const IntervalConverter();

  @override
  Duration fromSql(int fromDb) {
    return Duration(seconds: fromDb);
  }

  @override
  int toSql(Duration value) {
    return value.inSeconds;
  }

  @override
  Duration fromJson(Object json) {
    if (json is String) {
      return durationFromString(json);
    }
    if (json is Map) {
      return Duration(
        days: (json['days'] as num?)?.toInt() ?? 0,
        hours: (json['hours'] as num?)?.toInt() ?? 0,
        minutes: (json['minutes'] as num?)?.toInt() ?? 0,
        seconds: (json['seconds'] as num?)?.toInt() ?? 0,
        milliseconds: (json['milliseconds'] as num?)?.toInt() ?? 0,
      );
    }
    throw FormatException('Invalid interval format: $json');
  }

  @override
  Object toJson(Duration value) {
    return value.toDb();
  }
}

class DateTimeListConverter extends TypeConverter<List<DateTime>, String>
    with JsonTypeConverter2<List<DateTime>, String, List<dynamic>> {
  const DateTimeListConverter();

  @override
  List<DateTime> fromSql(String fromDb) {
    if (fromDb.isEmpty) return [];
    return fromDb
        .split(',')
        .map((dateStr) => DateTime.parse(dateStr.trim()))
        .toList();
  }

  @override
  String toSql(List<DateTime> value) {
    return value.map((date) => date.toUtc().toIso8601String()).join(',');
  }

  @override
  List<DateTime> fromJson(List<dynamic> json) {
    return json
        .where((item) => item != null)
        .map((item) => DateTime.parse(item as String))
        .toList();
  }

  @override
  List<dynamic> toJson(List<DateTime> value) {
    return value.map((date) => date.toUtc().toIso8601String()).toList();
  }
}
