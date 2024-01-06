import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/date_time.dart';
import 'activity.dart';

final supabase = Supabase.instance.client;

class TimeBlock extends Equatable {
  static TimeBlock? _current;

  static Future<bool> load() async {
    try {
      final block = await supabase
          .from('time')
          .select()
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

  static Future<TimeBlock> add(Activity activity, Interval at) async {
    final result = await supabase
        .from('time')
        .insert({
          'user_id': supabase.auth.currentUser?.id,
          'activity_id': activity.id,
          'at': at.toDb(),
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
        at = IntervalUtil.parseDb(json['at'] as String);

  final int id;
  final Activity activity;
  final Interval at;

  @override
  List<Object> get props => [id, activity.id];

  Map<String, dynamic> toJson() => {
        'id': id,
        'activity_id': activity.id,
        'at': at.toDb(),
      };
}
