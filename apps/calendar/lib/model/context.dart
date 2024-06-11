import 'model.dart';

class Context extends Model {
  static final store = Store<int, Context>(
    load: () async {
      return (await base
              .from('context')
              .select()
              .eq("user_id", base.auth.currentUser!.id))
          .map(Context.fromJson)
          .map((m) => MapEntry(m.id!, m));
    },
  );

  static String nameToPath(String name) {
    return name
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), " ")
        .trim()
        .replaceAll(RegExp(r' +'), "-")
        .toLowerCase();
  }

  Context({
    super.id,
    required this.name,
    String? path,
    this.pomodoro = const Duration(minutes: 25),
  }) : path = path ?? nameToPath(name);

  @override
  Context.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        path = json['path'] as String,
        pomodoro = Duration(minutes: json['pomodoro'] as int),
        super(id: json['id'] as int);

  final String name;
  final String path;
  final Duration pomodoro;

  Context copyWith({
    String? name,
    Duration? pomodoro,
  }) {
    var path = this.path;
    if (name != null) {
      var segments = this.path.split('.');
      if (segments.isNotEmpty) {
        segments = segments.sublist(0, segments.length - 1);
      }
      path = (segments + [(Context.nameToPath(name))]).join('.');
    }
    return Context(
      id: id,
      name: name ?? this.name,
      path: path,
      pomodoro: pomodoro ?? this.pomodoro,
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

  @override
  Future<Context> save() async {
    final model = await saveToBase("context", Context.fromJson);
    store.put(model.id!, model);
    return model;
  }

  @override
  List<Object?> get props => super.props + [name, path, pomodoro];

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'pomodoro': pomodoro.inMinutes,
      };
}
