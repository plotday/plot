part of 'store.dart';

typedef ContextId = Uuid;
typedef TopicId = Uuid;

@DataClassName('ContextRow')
class Contexts extends UuidStoreTable {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  TextColumn get name => text()();
  TextColumn get path => text().map(const PathConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.last().value)
      .map(const OrderConverter())();
  IntColumn get pomodoro => integer()
      .withDefault(const Constant(25 * 60))
      .map(const DurationConverter())();
}

class ContextsBase extends BaseTable {
  ContextsBase() : super(table: 'context_x', name: "contexts");

  @override
  Insertable<ContextRow> fromBase(Map<String, dynamic> json) =>
      ContextRow.fromJson(json);

  @override
  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    // Upsert isn't supported on views because they don't have uniqueness
    // constraints. Insert is overridden to upsert.
    await base.from(table).insert(rows.toList());
  }
}

class Context extends ContextRow implements Comparable<Context> {
  static $ContextsTable get table => Store.get.contexts;
  static CustomExpression<
      bool> pathDepth(Path? path, int depth) => CustomExpression<
          bool>(
      "LENGTH(path) - LENGTH(REPLACE(path, '.', '')) <= ${path == null ? depth - 1 : path.depth + depth}");

  static Future<void> push() => Store.get.push(table, ContextsBase());
  static Future<bool> pull() => Store.get.pull(table, ContextsBase());

  static Stream<Map<Uuid, Context>> watch() {
    final query = Store.get.select(table);
    return query.watch().map((rows) {
      final contexts = <Uuid, Context>{};
      for (var row in rows) {
        final context = Context.fromStore(row);
        contexts[context.id] = context;
      }
      return contexts;
    });
  }

  static Stream<Context> watchOne(ContextId id, {int depth = 0}) {
    final query = Store.get.select(table);
    query.where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().asyncExpand((row) {
      return watchPath(row.path, depth: depth)
          .map((contexts) => contexts.first);
    });
  }

  static Stream<List<Context>> watchRoot() => watchPath(null);
  static Stream<List<Context>> watchPath(Path? path, {int? depth = 1}) {
    final query = Store.get.select(table);
    if (path != null) {
      query.where((t) =>
          Variable<String>(path.toString())
              .likeExp(t.path + const Constant('%')) |
          t.path.like("$path.%"));
    }
    if (depth != null) {
      query.where((t) => pathDepth(path, (path?.depth ?? 0) + depth));
    }
    // order by path so parents always precede children
    query.orderBy([(t) => OrderingTerm(expression: t.path)]);

    return query.watch().map((rows) {
      List<Context> matches = [];
      List<Context> stack = [];

      for (var row in rows) {
        var context =
            Context.fromStore(row, parent: stack.isEmpty ? null : stack.last);

        if ((path == null && context.path.isRoot) || context.path == path) {
          matches.add(context);
        } else if (stack.isNotEmpty &&
            !stack.last.path.isParent(context.path)) {
          stack.removeWhere((c) => !c.path.isParent(context.path));
        }

        if (stack.isNotEmpty) {
          context = context.copyWith(parent: stack.last);
        }
        stack.add(context);
      }

      matches.sort();
      return matches;
    });
  }

  Context({
    required super.name,
    required super.order,
    this.parent,
    super.pomodoro = const Duration(minutes: 25),
  })  : children = [],
        super(
          id: Uuid.generate(),
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          path: Path.generate(parent: parent?.path),
        ) {
    parent?._addChild(this);
  }

  Context.fromStore(ContextRow row, {this.parent, List<Context>? children})
      : children = children ?? [],
        super(
          id: row.id,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
          name: row.name,
          pomodoro: row.pomodoro,
          order: row.order,
          path: row.path,
        ) {
    parent?._addChild(this);
  }

  final Context? parent;
  final List<Context> children;

  @override
  Context copyWith({
    Uuid? id,
    DateTime? modifiedAt,
    DateTime? createdAt,
    String? name,
    Path? path,
    Order? order,
    Duration? pomodoro,
    Context? parent,
  }) =>
      Context.fromStore(
        super.copyWith(
          id: id,
          modifiedAt: modifiedAt,
          createdAt: createdAt,
          name: name,
          path: path,
          order: order,
          pomodoro: pomodoro,
        ),
        parent: parent ?? this.parent,
        children: children,
      );

  void _addChild(Context child) {
    children.replaceSorted(child, (a, b) => a.id == b.id);
  }

  Future<void> save() {
    return Store.get.save(table, copyWith(modifiedAt: DateTime.now()));
  }

  @override
  int compareTo(Context other) {
    return order.compareTo(other.order);
  }
}
