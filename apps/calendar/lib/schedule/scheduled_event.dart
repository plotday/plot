import 'package:equatable/equatable.dart';
import 'package:in_date_range/in_date_range.dart';

import '../activity/activity.dart';

class ScheduledEvent extends Equatable {
  static final Map<DateRange, List<ScheduledEvent>> _cache = {
    DateRange.day(DateTime(2023, 12, 27)): [
      ScheduledEvent(
          "Dev Standup",
          DateRange(
            DateTime(2023, 12, 27, 11, 15),
            DateTime(2023, 12, 27, 11, 30),
          ),
          1),
    ],
  };

  static Future<List<ScheduledEvent>> list(DateRange day) {
    return Future.value(_cache[day] ?? []);
  }

  static Future<List<ScheduledEvent>> today() async {
    return list(DateRange.day(DateTime.now()));
  }

  static Future<List<ScheduledEvent>> current() async {
    final all = await today();
    final current = all.where((ScheduledEvent event) {
      return event.at.contains(DateTime.now());
    }).toList();
    return Future.value(current);
  }

  static Future<List<ScheduledEvent>> next() async {
    final all = await today();
    final now = DateTime.now();
    var next = all.where((ScheduledEvent event) {
      return event.at.start.isAfter(now);
    }).toList();
    if (next.isNotEmpty) {
      next = all.where((ScheduledEvent event) {
        return event.at.start == next.first.at.start;
      }).toList();
    }
    return Future.value(next);
  }

  const ScheduledEvent(this.name, this.at, this._activityId);

  final String name;
  final DateRange at;
  get activity => Activity.get(_activityId);

  final int _activityId;

  @override
  List<Object> get props => [name, at, _activityId];
}
