import 'dart:math';

import 'model.dart';
import 'package:plot/util/order.dart';
import 'package:plot/store/store.dart' as store;

export 'package:plot/util/order.dart';

typedef ContextID = UUID;

class Context extends LocalModel implements Comparable<Context> {
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

  Context.fromStore(store.Context row)
      : name = row.name,
        path = row.path,
        pomodoro = Duration(minutes: row.pomodoro),
        order = Order.fromNumber(row.order),
        super.fromJson(json);

  @override
  int compareTo(Context other) {
    return order.compareTo(other.order);
  }

  final String name;
  final String path;
  final Duration pomodoro;
  final Order order;

  Future<Context?> get parent async {
    var segments = path.split('.');
    if (segments.length == 1) {
      return null;
    }
    final parentPath = segments.sublist(0, segments.length - 1).join('.');
    return await (store.Store.get.select(store.Store.get.contexts)
          ..where((t) => t.path.equals(parentPath)))
        .map((row) => Context.fromJson(row.toJson()))
        .getSingle();
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
      await (store.Store.get
          .into(store.Store.get.contexts)
          .insertOnConflictUpdate(toStore()));
      // await base.from("context").upsert({
      //   'id': id.toString(),
      //   'name': name,
      //   'path': path,
      // });
      // await base.from("context_settings").upsert({
      //   'context_id': id.toString(),
      //   'user_id': base.auth.currentUser!.id,
      //   'pomodoro': pomodoro.inMinutes,
      //   'order': order.toDouble(),
      // }, onConflict: 'user_id,context_id');
      return this;
    } catch (e) {
      print("Error saving ${toJson()}");
      print(e);
      rethrow;
    }
  }

  @override
  List<Object?> get props => super.props + [name, path, pomodoro, order];

  store.Context toStore() => store.Context(
        id: id.toBytes(),
        name: name,
        path: path,
        order: order.toDouble(),
        pomodoro: pomodoro.inMinutes,
        modifiedAt: DateTime.now(),
      );
}
