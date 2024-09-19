import 'dart:math';

import 'model.dart';
import 'package:plot/util/order.dart';
import 'package:plot/store/store.dart' as store;

export 'package:plot/util/order.dart';

typedef ContextID = Uuid;

class Context extends LocalModel
    with store.ContextStorable, store.ContextSaveable
    implements Comparable<Context> {
  static Future<Context> getPath(String path) =>
      store.ContextStorable.getPathMap(path, (row) => Context.fromStore(row));

  final String name;
  final String path;
  final Duration pomodoro;
  final Order order;

  Context({
    required this.name,
    Order? order,
    Context? parent,
    this.pomodoro = const Duration(minutes: 25),
  })  : path = _makePath(parent),
        order = order ?? Order(),
        super.create();

  Context copyWith({
    String? name,
    Duration? pomodoro,
    Order? order,
  }) {
    return Context._(
      id: id,
      createdAt: createdAt,
      modifiedAt: DateTime.now(),
      name: name ?? this.name,
      path: path,
      pomodoro: pomodoro ?? this.pomodoro,
      order: order ?? this.order,
    );
  }

  Future<Context?> get parent async {
    final parentPath = this.parentPath;
    if (parentPath == null) return null;
    return await getPath(parentPath);
  }

  String? get parentPath {
    var segments = path.split('.');
    if (segments.length == 1) {
      return null;
    }
    return segments.sublist(0, segments.length - 1).join('.');
  }

  bool isParent(Context other) =>
      other == this || other.path.startsWith("$path.");
  bool isChild(Context? other) =>
      other == null || path.startsWith("${other.path}.");

  /* Internal */

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

  const Context._({
    required super.id,
    required super.createdAt,
    required super.modifiedAt,
    required this.name,
    required this.path,
    required this.order,
    required this.pomodoro,
  });

  factory Context.fromStore(store.Context row) => Context._(
        id: row.id,
        createdAt: row.createdAt,
        modifiedAt: row.modifiedAt,
        name: row.name,
        path: row.path,
        order: row.order,
        pomodoro: row.pomodoro,
      );

  @override
  int compareTo(Context other) {
    return order.compareTo(other.order);
  }

  @override
  List<Object?> get props => super.props + [name, path, pomodoro, order];

  @override
  store.Insertable<store.Context> toStore() => store.ContextsCompanion.custom(
        id: store.Constant(id.toBytes()),
        modifiedAt: store.currentDateAndTime,
        name: store.Constant(name),
        path: store.Constant(path),
        order: store.Constant(order.toDouble()),
        pomodoro: store.Constant(pomodoro.inMinutes),
      );
}
