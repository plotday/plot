import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import './context.dart';

final supabase = Supabase.instance.client;

class Activity extends Equatable {
  static Map<int, Activity> _cache = {};

  static Future<void> load() async {
    final activities = await supabase
        .from('activity')
        .select()
        .eq("user_id", supabase.auth.currentUser!.id);
    _cache = {
      for (var activity
          in activities.map((activity) => Activity.fromJson(activity)))
        activity.id!: activity
    };
  }

  static Activity get(int id) {
    if (!_cache.containsKey(id)) {
      throw ArgumentError('Activity $id not found');
    }
    return _cache[id]!;
  }

  static List<Activity> list() {
    return _cache.values.toList();
  }

  Activity({
    this.id,
    required this.name,
    required Context context,
    this.pomodoro = const Duration(minutes: 25),
  }) : _contextId = context.id!;

  Activity.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        _contextId = json['context_id'] as int,
        name = json['name'] as String,
        pomodoro = Duration(minutes: json['pomodoro'] as int);

  final int? id;
  final int _contextId;
  final String name;
  final Duration pomodoro;

  get context => Context.get(_contextId);

  Activity copyWith({
    String? name,
    Duration? pomodoro,
    int? budget,
    String? order,
  }) {
    return Activity(
      id: id,
      name: name ?? this.name,
      context: context,
      pomodoro: pomodoro ?? this.pomodoro,
    );
  }

  Future<Activity> save() async {
    Map<String, dynamic>? result;
    if (id == null) {
      result = await supabase
          .from('activity')
          .insert({
            ...toJson(),
            'user_id': supabase.auth.currentUser?.id,
          })
          .select()
          .single();
    } else {
      result = await supabase
          .from('activity')
          .update(toJson())
          .eq('id', id!)
          .select()
          .single();
    }
    final activity = Activity.fromJson(result);
    _cache[activity.id!] = activity;
    return activity;
  }

  @override
  List<Object> get props => [id ?? 0, _contextId, name, pomodoro];

  Map<String, dynamic> toJson() => {
        'name': name,
        'context_id': context.id,
        'pomodoro': pomodoro.inMinutes,
      };
}
