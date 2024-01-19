import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/time.dart';
import '../priority/activity.dart';

final supabase = Supabase.instance.client;

class ScheduledEvent extends Equatable {
  static final Map<Interval, List<ScheduledEvent>> _cache = {};

  static Future<List<ScheduledEvent>> _load(Interval day) async {
    final events = await supabase
        .from('event_x')
        .select()
        .eq('user_id', supabase.auth.currentUser!.id)
        .eq('day', day.toDayString())
        .order('at', ascending: true);
    _cache[day] =
        events.map((event) => ScheduledEvent.fromJson(event)).toList();
    return _cache[day]!;
  }

  static Future<List<ScheduledEvent>> list(Interval day) {
    return _cache[day] != null ? Future.value(_cache[day]) : _load(day);
  }

  static Future<List<ScheduledEvent>> today() async {
    return list(Time.today());
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

  ScheduledEvent.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name'] as String,
        at = Time.interval(json['at'] as String),
        _activityId = json['activity_id'] as int?;

  final int? id;
  final String name;
  final Interval at;
  get activity => _activityId == null ? null : Activity.get(_activityId);

  final int? _activityId;

  @override
  List<Object> get props => [id ?? 0, name, at, _activityId ?? 0];
}
