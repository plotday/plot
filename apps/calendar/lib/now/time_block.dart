import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/time.dart';
import '../util/map.dart';
import '../priority/activity.dart';

final supabase = Supabase.instance.client;

class TimeBlock extends Equatable {
  static TimeBlock? _current;

  static Future<TimeBlock?> load() async {
    try {
      final List<dynamic> results = await Future.wait([
        supabase
            .from('time')
            .select()
            .eq('user_id', supabase.auth.currentUser!.id)
            .order('at', ascending: false)
            .limit(1)
            .maybeSingle(),
        Activity.load(),
      ]);
      final dbBlock = results[0] as Map<String, dynamic>?;

      _current = null;
      if (dbBlock != null) {
        final block = TimeBlock.fromJson(dbBlock);
        if (block.remaining > Duration.zero) {
          _current = block;
        }
      }
      return _current;
    } catch (e) {
      print('Loading time blocks failed');
      print(e);
    }
    return null;
  }

  static TimeBlock? get current {
    return _current;
  }

  static TimeBlock now(Activity activity,
      {Duration? planned, Duration? duration, DateTime? end}) {
    final start = DateTime.now();
    if (end == null) {
      duration ??= activity.pomodoro;
      end = start.add(duration);
    } else {
      duration = end.difference(start);
    }
    planned ??= duration;
    return TimeBlock(
      activity: activity,
      planned: planned,
      at: Interval(start, end),
      remaining: Duration.zero,
    );
  }

  const TimeBlock({
    this.id,
    required this.activity,
    required this.at,
    required this.planned,
    required remaining,
  }) : _remaining = remaining;

  TimeBlock.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        activity = Activity.get(json['activity_id'] as int),
        at = Time.interval(json['at'] as String),
        planned = Time.duration(json['planned'] as String),
        _remaining = Time.duration(json['remaining'] as String);

  final int? id;
  final Activity activity;
  final Interval at;
  final Duration planned;
  final Duration _remaining;

  @override
  List<Object> get props =>
      [id ?? 0, activity.id ?? 0, at, planned, _remaining];

  TimeBlock copyWith({Interval? at, Duration? planned, Duration? remaining}) {
    at ??= this.at;
    if (planned != null) {
      final delta = planned - this.planned;
      if (_remaining == Duration.zero) {
        remaining ??= Duration.zero;
      } else {
        remaining ??= _remaining + delta;
      }
      at = Interval(at.start, at.end.add(delta));
    } else {
      planned = this.planned;
      remaining ??= _remaining;
    }
    return TimeBlock(
      id: id,
      activity: activity,
      planned: planned,
      at: at,
      remaining: remaining,
    );
  }

  TimeBlock copyStopped() {
    return copyWith(
      at: Interval(at.start, DateTime.now()),
      remaining: remaining,
    );
  }

  Future<TimeBlock> save() async {
    Map<String, dynamic>? result;
    if (id == null) {
      result = await supabase
          .from('time')
          .insert({
            ...toJson(),
            'user_id': supabase.auth.currentUser?.id,
          })
          .select()
          .single();
    } else {
      result = await supabase
          .from('time')
          .update(toJson().filterKeys({'at', 'remaining', 'planned'}))
          .eq('id', id!)
          .select()
          .single();
    }
    final newBlock = TimeBlock.fromJson(result);
    _current = newBlock;
    return newBlock;
  }

  bool get isRunning => at.includes(DateTime.now());

  Duration get _duration => _remaining == Duration.zero ? planned : _remaining;

  Duration get elapsed {
    final now = DateTime.now();
    if (at.end.isBefore(now)) {
      return planned - _remaining;
    } else if (at.start.isAfter(now)) {
      return _remaining;
    } else {
      return _duration - at.end.difference(now);
    }
  }

  Duration get remaining {
    return planned - elapsed;
  }

  double get progress =>
      elapsed.inSeconds == 0 ? 0.0 : elapsed.inSeconds / planned.inSeconds;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'activity_id': activity.id,
        'at': at.toRangeString(),
        'planned': planned.toDb(),
        'remaining': _remaining.toDb(),
      };
}
