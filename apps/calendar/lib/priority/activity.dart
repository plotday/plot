import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/map.dart';

final supabase = Supabase.instance.client;

class Activity extends Equatable {
  static Map<int, Activity> _cache = {};

  static String nameToPath(String name) {
    return name
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), "_")
        .replaceAll(RegExp(r'_+'), "_")
        .toLowerCase();
  }

  static Future<void> load() async {
    final activities = await supabase.from('activity').select();
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

  static Future<Activity> add(String name, Activity? parent) async {
    String path = nameToPath(name);
    if (parent != null) {
      path = '${parent.path}.$path';
    }
    final response = await supabase
        .from('activity')
        .insert({
          'user_id': supabase.auth.currentUser!.id,
          'name': name,
          'path': path
        })
        .select()
        .single();
    final activity = Activity.fromJson(response);
    _cache[activity.id!] = activity;
    return activity;
  }

  const Activity(
      {this.id,
      required this.name,
      required this.path,
      this.pomodoro = const Duration(minutes: 25)});

  Activity.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name'] as String,
        path = json['path'] as String,
        pomodoro = Duration(minutes: json['pomodoro'] as int);

  final int? id;
  final String name;
  final String path;
  final Duration pomodoro;

  Activity copyWith({String? name, Duration? pomodoro}) {
    var path = this.path;
    if (name != null) {
      path = (this.path.split('.') + [(Activity.nameToPath(name))]).join('.');
    }
    return Activity(
      id: id,
      name: name ?? this.name,
      path: path,
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
          .update(toJson().filterKeys({'name', 'path', 'pomodoro'}))
          .eq('id', id!)
          .select()
          .single();
    }
    return Activity.fromJson(result);
  }

  @override
  List<Object> get props => [id ?? 0, name, path, pomodoro];

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'path': path,
        'pomodoro': pomodoro.inMinutes,
      };
}
