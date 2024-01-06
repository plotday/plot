import 'package:dart_date/dart_date.dart';
export 'package:dart_date/dart_date.dart';

class IntervalUtil {
  static Interval parseDb(String db) {
    String stripped = db.replaceAll(RegExp(r'[\[\]()"]'), '');
    List<String> dateTimeStrings = stripped.split(',');
    List<DateTime> dateTimes = dateTimeStrings
        .map((timestamp) => DateTime.parse(timestamp.trim()))
        .toList();
    return Interval(dateTimes[0], dateTimes[1]);
  }

  static Interval day(DateTime value) => Interval(
        value.startOfDay,
        value.nextDay,
      );

  static Interval week(DateTime value) => Interval(
        value.startOfWeek,
        value.nextWeek,
      );

  static Interval month(DateTime value) => Interval(
        value.startOfMonth,
        value.nextMonth,
      );

  static Interval year(DateTime value) => Interval(
        value.startOfYear,
        value.nextYear,
      );

  static Interval today() => IntervalUtil.day(DateTime.now());
}

extension PostgresDateTime on DateTime {
  String toDb() {
    return toUtc().toIso8601String();
  }
}

extension PostgresDateTimeRange on Interval {
  String toDb() {
    return "[${start.toUtc().toIso8601String()}, ${end.toUtc().toIso8601String()})";
  }
}
