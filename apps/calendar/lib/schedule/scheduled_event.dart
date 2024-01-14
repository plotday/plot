import 'package:equatable/equatable.dart';

import '../util/time.dart';
import '../priority/activity.dart';

class ScheduledEvent extends Equatable {
  static final Map<Interval, List<ScheduledEvent>> _cache = {
    Time.day(DateTime(2023, 12, 27)): [
      ScheduledEvent(
          "Dev Standup",
          Interval(
            DateTime(2023, 12, 27, 14, 30),
            DateTime(2023, 12, 27, 15, 00),
          ),
          1),
    ],
  };

  static Future<List<ScheduledEvent>> list(Interval day) {
    return Future.value(_cache[day] ?? []);
  }

  static Future<List<ScheduledEvent>> today() async {
    return list(Time.day(DateTime.now()));
  }

  static Future<List<ScheduledEvent>> current() async {
    final all = await today();
    final current = all.where((ScheduledEvent event) {
      return event.at.includes(DateTime.now());
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
  final Interval at;
  get activity => Activity.get(_activityId);

  final int _activityId;

  @override
  List<Object> get props => [name, at, _activityId];
}
