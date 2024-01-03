import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'activity.dart';

final supabase = Supabase.instance.client;

class TimeBlock extends Equatable {
  static TimeBlock? _current;

  static Future<bool> load() async {
    // TODO final blocks = await supabase.from('time').select();
    return true;
  }

  static TimeBlock? get current {
    return _current;
  }

  static Future<TimeBlock> start(
      Activity activity, DateTime start, DateTime end) async {
    final newBlock = await supabase
        .from('time')
        .insert({
          'user_id': supabase.auth.currentUser?.id,
          'activity_id': activity.id,
          'at': "[${start.toIso8601String()}, ${end.toIso8601String()})",
          'status': "started",
        })
        .select()
        .single();
    return TimeBlock.fromJson(newBlock);
  }

  const TimeBlock(this.id, this.activity);

  TimeBlock.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        activity = Activity.get(json['activity_id'] as int);

  final int id;
  final Activity activity;

  @override
  List<Object> get props => [id, activity.id];

  Map<String, dynamic> toJson() => {
        'id': id,
        'activity_id': activity.id,
      };
}
