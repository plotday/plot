import 'dart:math';

import 'model.dart';

class ContextOrder {
  const ContextOrder(this.after, this.before);

  final Context? after;
  final Context? before;
}

class Context extends Model {
  static final store = Store<int, Context>(
    load: () async {
      final contexts = (await base
              .from('context')
              .select()
              .eq("user_id", base.auth.currentUser!.id))
          .map(Context.fromJson);
      for (var context in contexts) {
        _pathToId[context.path] = context.id!;
      }
      return contexts.map((m) => MapEntry(m.id!, m));
    },
  );

  static String _makePath(Context? parent) {
    const characters =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    Random random = Random();
    String prefix = "";
    if (parent != null) {
      prefix = "${parent.path}.";
    }
    return prefix +
        String.fromCharCodes(Iterable.generate(
          4,
          (_) => characters.codeUnitAt(random.nextInt(characters.length)),
        ));
  }

  static String _between(String? str1, String? str2) {
    if (str1 == null) {
      if (str2 == null) return "O";
      str1 = String.fromCharCode(max(32, str2.codeUnitAt(0) - 1));
    } else {
      str2 ??= String.fromCharCode(min(126, str1.codeUnitAt(0) + 1));
    }

    String newStr = "";
    for (int i = 0; true; i++) {
      final c1 = i < str1.length ? str1.codeUnitAt(i) : 32;
      final c2 = i < str2.length ? str2.codeUnitAt(i) : 126;
      final cn = ((c1 + c2) / 2).floor();

      if (c1 == cn || c2 == cn) {
        newStr += str1[i];
        continue;
      }

      newStr += String.fromCharCode(cn);
      break;
    }
    return newStr;
  }

  static final Map<String, int> _pathToId = {};

  static const unchanged = Context._(
      id: -1,
      name: "",
      path: "",
      order: "",
      pomodoro: Duration(),
      pinned: false);

  Context({
    super.id,
    required this.name,
    ContextOrder? order,
    Context? parent,
    this.pomodoro = const Duration(minutes: 25),
    this.pinned = false,
  })  : path = _makePath(parent),
        _order = _between(order?.after?._order, order?.before?._order);

  const Context._({
    super.id,
    required this.name,
    required this.path,
    required String order,
    required this.pomodoro,
    required this.pinned,
  }) : _order = order;

  @override
  Context.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        path = json['path'] as String,
        pomodoro = Duration(minutes: json['pomodoro'] as int),
        _order = json['order'] as String? ?? 'Z0000',
        pinned = json['pinned'] as bool? ?? false,
        super(id: json['id'] as int);

  final String name;
  final String path;
  final Duration pomodoro;
  final String _order;
  final bool pinned;

  Context? get parent {
    var segments = path.split('.');
    if (segments.length == 1) {
      return null;
    }
    final parentPath = segments.sublist(0, segments.length - 1).join('.');
    final parentId = _pathToId[parentPath];
    if (parentId == null) {
      return null;
    }
    return store.get(parentId);
  }

  Context copyWith({
    String? name,
    Duration? pomodoro,
    ContextOrder? order,
    bool? pinned,
  }) {
    String newOrder = _order;
    if (order != null) {
      newOrder = _between(order.after?._order, order.before?._order);
    }
    return Context._(
      id: id,
      name: name ?? this.name,
      path: path,
      pomodoro: pomodoro ?? this.pomodoro,
      order: newOrder,
      pinned: pinned ?? this.pinned,
    );
  }

  @override
  Future<Context> save() async {
    final model = await saveToBase("context", Context.fromJson);
    store.put(model.id!, model);
    _pathToId[model.path] = model.id!;
    return model;
  }

  @override
  List<Object?> get props =>
      super.props + [name, path, pomodoro, _order, pinned];

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'pomodoro': pomodoro.inMinutes,
        'order': _order,
      };
}
