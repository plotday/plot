import 'package:equatable/equatable.dart';

import '../util/date_time.dart';
import 'activity.dart';

class Budget extends Equatable {
  static final Map<Interval, List<Budget>> _cache = {
    IntervalUtil.week(DateTime(2024, 01, 01)): [
      const Budget(1, Duration(hours: 30), "A"),
      const Budget(1, Duration(hours: 3), "B"),
      const Budget(2, Duration(hours: 3), "C"),
    ],
  };

  static Future<Budget> get(Interval week, int activityId) {
    return list(week).then((List<Budget> list) {
      return list
          .firstWhere((Budget budget) => budget._activityId == activityId);
    });
  }

  static Future<List<Budget>> list(Interval week) {
    return Future.value(_cache[week] ?? []);
  }

  const Budget(this._activityId, this.duration, this._order);

  Budget.fromJson(Map<String, dynamic> json)
      : _activityId = json['activity_id'] as int,
        duration = Duration(minutes: json['budget'] as int),
        _order = json['order'] as String;

  final int _activityId;
  final Duration duration;

  get activity => Activity.get(_activityId);

  final String _order;

  @override
  List<Object> get props => [_activityId, duration, _order];

  Map<String, dynamic> toJson() => {
        'activity_id': _activityId,
        'budget': duration.inMinutes,
        'order': _order,
      };
}
