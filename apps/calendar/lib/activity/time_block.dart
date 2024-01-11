import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/date_time.dart';
import 'activity.dart';

final supabase = Supabase.instance.client;

enum TimeBlockStatus {
  started,
  stopped,
  skipped,
}

class TimeBlock extends Equatable {
  static TimeBlock? _current;

  static Future<bool> load() async {
    try {
      final block = await supabase
          .from('time')
          .select()
          .eq('user_id', supabase.auth.currentUser!.id)
          .inFilter('status', ['started', 'stopped'])
          .order('at', ascending: false)
          .limit(1)
          .maybeSingle();
      await Activity.load();
      if (block == null) {
        _current = null;
      } else {
        _current = TimeBlock.fromJson(block);
      }
    } catch (e) {
      print('Loading time blocks failed');
      print(e);
    }
    return true;
  }

  static TimeBlock? get current {
    return _current;
  }

  static Future<TimeBlock> add(Activity activity,
      {Duration? duration, DateTime? end}) async {
    final start = DateTime.now();
    if (end == null) {
      duration ??= activity.pomodoro;
      end = start.add(duration);
    } else {
      duration = end.difference(start);
    }
    final result = await supabase
        .from('time')
        .insert({
          'user_id': supabase.auth.currentUser?.id,
          'activity_id': activity.id,
          'at': Interval(start, end).toDb(),
          'planned': duration.inSeconds,
          'remaining': duration.inSeconds,
          'status': "started",
        })
        .select()
        .single();
    final newBlock = TimeBlock.fromJson(result);
    _current = newBlock;
    return newBlock;
  }

  TimeBlock.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        activity = Activity.get(json['activity_id'] as int),
        at = IntervalUtil.parseDb(json['at'] as String),
        planned = Duration(seconds: json['planned'] as int),
        _remaining = Duration(seconds: json['remaining'] as int),
        status = TimeBlockStatus.values.byName(json['status'] as String);

  final int id;
  final Activity activity;
  final Interval at;
  final Duration planned;
  final Duration _remaining;
  final TimeBlockStatus status;

  @override
  List<Object> get props => [id, activity.id, at, planned, _remaining, status];

  Future<TimeBlock> update(
      {Interval? at, int? remaining, TimeBlockStatus? status}) async {
    final result = await supabase
        .from('time')
        .update({
          if (at != null) 'at': at.toDb(),
          if (remaining != null) 'remaining': remaining,
          if (status != null) 'status': status.name,
        })
        .eq('id', id)
        .select()
        .single();
    final newBlock = TimeBlock.fromJson(result);
    if (_current == this) {
      _current = newBlock;
    }
    return newBlock;
  }

  Duration get elapsed {
    var elapsed = planned - _remaining;
    if (status == TimeBlockStatus.started) {
      elapsed += DateTime.now().difference(at.start);
    }
    return elapsed;
  }

  Duration get remaining {
    switch (status) {
      case TimeBlockStatus.started:
        if (DateTime.now().isAfter(at.end)) {
          return Duration.zero;
        }
        return _remaining - DateTime.now().difference(at.start);
      case TimeBlockStatus.stopped:
        return _remaining;
      case TimeBlockStatus.skipped:
        return Duration.zero;
    }
  }

  double get progress =>
      elapsed.inSeconds == 0 ? 0.0 : planned.inSeconds / elapsed.inSeconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'activity_id': activity.id,
        'at': at.toDb(),
        'planned': planned.inSeconds,
        'remaining': _remaining.inSeconds,
        'status': status.name,
      };
}
