import 'package:equatable/equatable.dart';

class Activity extends Equatable {
  static final Map<int, Activity> _cache = {
    1: const Activity(1, "Development", "plot.development"),
    2: const Activity(2, "Customer discovery", "plot.customer-discovery"),
    3: const Activity(3, "Team meetings", "plot.team-meetings"),
  };

  static Activity? get(int id) {
    if (!_cache.containsKey(id)) {
      return null;
    }
    return _cache[id];
  }

  static Future<List<Activity>> list() {
    return Future.value(_cache.values.toList());
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
