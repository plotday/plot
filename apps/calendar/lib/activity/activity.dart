import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class Activity extends Equatable {
  static Map<int, Activity> _cache = {};

  static String nameToPath(String name) {
    return name
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), "_")
        .replaceAll(RegExp(r'_+'), "_")
        .toLowerCase();
  }

  static Future<bool> load() async {
    final activities = await supabase.from('activity').select();
    _cache = {
      for (var activity in activities)
        activity['id']: Activity.fromJson(activity)
    };
    return true;
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
    final newActivity = await supabase
        .from('activity')
        .insert({
          'user_id': supabase.auth.currentUser?.id,
          'name': name,
          'path': path
        })
        .select()
        .single();
    return Activity.fromJson(newActivity);
  }

  const Activity(this.id, this.name, this.path);

  Activity.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name'] as String,
        path = json['path'] as String;

  final int id;
  final String name;
  final String path;

  @override
  List<Object> get props => [id, name, path];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
      };
}
