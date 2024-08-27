import 'dart:math';
import 'package:drift/drift.dart';

import 'model.dart';
import 'package:plot/util/order.dart';

export 'package:plot/util/order.dart';

class Contexts extends Table {
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get modifiedAt => dateTime()();

  TextColumn get userId => text()();
  TextColumn get body => text()();
  RealColumn get order => real()();
  BoolColumn get root => boolean()();
  BoolColumn get private => boolean()();

  IntColumn get contextId => integer().nullable().references(Contexts, #id)();
  IntColumn get topicId => integer()();
}

typedef ContextID = UUID;

class Context extends LocalModel implements Comparable<Context> {
  static final store = Store<ContextID, Context>(
    load: () async {
      final contexts = (await base
              .from('context_x')
              .select()
              .eq("user_id", base.auth.currentUser!.id))
          .map(Context.fromJson);
      for (var context in contexts) {
        _pathToId[context.path] = context.id;
      }
      return contexts.map((m) => MapEntry(m.id, m));
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

  static final Map<String, ContextID> _pathToId = {};

  Context({
    required this.name,
    Order? order,
    Context? parent,
    this.pomodoro = const Duration(minutes: 25),
  })  : path = _makePath(parent),
        order = order ?? Order();

  const Context._({
    required UUID id,
    required this.name,
    required this.path,
    required this.order,
    required this.pomodoro,
  }) : super.withId(id);

  @override
  Context.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        path = json['path'] as String,
        pomodoro = Duration(minutes: json['pomodoro'] as int),
        order = Order.fromNumber(json['order']),
        super.fromJson(json);

  @override
  int compareTo(Context other) {
    return order.compareTo(other.order);
  }

  final String name;
  final String path;
  final Duration pomodoro;
  final Order order;

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

  bool isParent(Context other) =>
      other == this || other.path.startsWith("$path.");
  bool isChild(Context? other) =>
      other == null || path.startsWith("${other.path}.");

  Context copyWith({
    String? name,
    Duration? pomodoro,
    Order? order,
  }) {
    return Context._(
      id: id,
      name: name ?? this.name,
      path: path,
      pomodoro: pomodoro ?? this.pomodoro,
      order: order ?? this.order,
    );
  }

  @override
  Future<Context> save() async {
    try {
      store.put(id, this);
      _pathToId[path] = id;
      await base.from("context").upsert({
        'id': id.toString(),
        'name': name,
        'path': path,
      });
      await base.from("context_settings").upsert({
        'context_id': id.toString(),
        'user_id': base.auth.currentUser!.id,
        'pomodoro': pomodoro.inMinutes,
        'order': order.toDouble(),
      }, onConflict: 'user_id,context_id');
      return this;
    } catch (e) {
      print("Error saving ${toJson()}");
      print(e);
      rethrow;
    }
  }

  @override
  List<Object?> get props => super.props + [name, path, pomodoro, order];

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'name': name,
        'path': path,
        'pomodoro': pomodoro.inMinutes,
        'order': order.toDouble(),
      };
}
