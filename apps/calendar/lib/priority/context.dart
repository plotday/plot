import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class Context extends Equatable {
  static Map<int, Context> _cache = {};

  static String nameToPath(String name) {
    return name
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), " ")
        .trim()
        .replaceAll(RegExp(r' +'), "_")
        .toLowerCase();
  }

  static Future<void> load() async {
    final contexts = await supabase
        .from('context')
        .select()
        .eq("user_id", supabase.auth.currentUser!.id);
    _cache = {
      for (var context in contexts.map((context) => Context.fromJson(context)))
        context.id!: context
    };
  }

  static Context get(int id) {
    if (!_cache.containsKey(id)) {
      throw ArgumentError('Context $id not found');
    }
    return _cache[id]!;
  }

  static List<Context> list() {
    return _cache.values.toList();
  }

  Context({
    this.id,
    required this.name,
    String? path,
  }) : path = path ?? nameToPath(name);

  Context.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name'] as String,
        path = json['path'] as String;

  final int? id;
  final String name;
  final String path;

  Context copyWith({String? name}) {
    var path = this.path;
    if (name != null) {
      path = (this.path.split('.') + [(Context.nameToPath(name))]).join('.');
    }
    return Context(
      id: id,
      name: name ?? this.name,
      path: path,
    );
  }

  Context newChild(String name) {
    String path = '${this.path}.${nameToPath(name)}';
    return Context(
      id: id,
      name: name,
      path: path,
    );
  }

  Future<Context> save() async {
    Map<String, dynamic>? result;
    if (id == null) {
      result = await supabase
          .from('context')
          .insert({
            ...toJson(),
            'user_id': supabase.auth.currentUser?.id,
          })
          .select()
          .single();
    } else {
      result = await supabase
          .from('context')
          .update(toJson())
          .eq('id', id!)
          .select()
          .single();
    }
    final context = Context.fromJson(result);
    _cache[context.id!] = context;
    return context;
  }

  @override
  List<Object> get props => [id ?? 0, name, path];

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
      };
}
