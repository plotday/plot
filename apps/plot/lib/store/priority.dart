part of 'store.dart';

typedef PriorityId = Uuid;

@DataClassName('PriorityRow')
class Priorities extends UuidStoreTable with DraftTable, DeletableTable {
  TextColumn get name => text()();
  TextColumn get path => text().map(const PathConverter())();
  RealColumn get order =>
      real()
          .clientDefault(() => Order.last().value)
          .map(const OrderConverter())();
  IntColumn get pomodoro =>
      integer()
          .withDefault(const Constant(25 * 60))
          .map(const DurationConverter())();
  IntColumn get color =>
      integer()
          .withDefault(const Constant(0))
          .map(const ThemeColorConverter())();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
}

class PrioritiesBase extends BaseTable {
  PrioritiesBase()
    : super(table: 'priority_x', name: "priorities", upsertAsUpdate: true);

  @override
  Insertable<PriorityRow> fromBase(Map<String, dynamic> json) =>
      PriorityRow.fromJson(json);
}

class Priority extends PriorityRow implements Comparable<Priority> {
  static $PrioritiesTable get table => Store.get.priorities;

  static Future<void> push() => Store.get.push(table, PrioritiesBase());
  static Future<bool> pull() =>
      Store.get.pull(PullType.all, table, PrioritiesBase());

  static Future<Priority> get(PriorityId id) async {
    return await (Store.get.select(table)..where(
      (t) => t.id.equals(id.toBytes()),
    )).getSingle().then(Priority.fromStore);
  }

  static Future<List<Priority>> getAll() async {
    return await (Store.get.select(table)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm(expression: t.path)]))
        .get()
        .then((rows) => _buildHierarchy(rows, flat: true).toList());
  }

  static SimpleSelectStatement<$PrioritiesTable, PriorityRow> _selectDefault() {
    return Store.get.select(table)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.isDefault, mode: OrderingMode.desc),
        // If no priority is marked default, fall back to the first one created
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
      ])
      ..limit(1);
  }

  static Future<Priority?> getDefault() async {
    return await _selectDefault().getSingleOrNull().then(
      (p) => p == null ? null : Priority.fromStore(p),
    );
  }

  static Stream<Priority?> watchDefault({int depth = 0}) {
    return _selectDefault().watchSingleOrNull().asyncExpand((row) {
      if (row == null) {
        return Stream.value(null);
      }
      return watchPath(
        row.path,
        depth: depth,
      ).map((priorities) => priorities.first);
    });
  }

  static Stream<Map<Uuid, Priority>> watch({bool deleted = false}) {
    return watchAll(deleted: deleted).map((rows) {
      final priorities = <Uuid, Priority>{};
      void add(Priority priority) {
        priorities[priority.id] = priority;
        for (var child in priority.children) {
          add(child);
        }
      }

      for (var row in rows) {
        add(row);
      }
      return priorities;
    });
  }

  static Stream<Priority> watchOne(PriorityId id, {int? depth = 0}) {
    final query = Store.get.select(table);
    query.where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().asyncExpand((row) {
      return watchPath(
        row.path,
        depth: depth,
      ).map((priorities) => priorities.firstOrNull ?? Priority.fromStore(row));
    });
  }

  static Stream<List<Priority>> watchAll({bool? deleted = false}) =>
      watchPath(null, depth: null, deleted: deleted);

  static Stream<List<Priority>> watchRoot({
    int? depth,
    bool? deleted = false,
  }) => watchPath(null, depth: depth);

  static Stream<List<Priority>> watchPath(
    Path? path, {
    int? depth = 1,
    bool? deleted = false,
  }) {
    final query = Store.get.select(table);
    if (path != null) {
      query.where(
        (t) =>
            Variable<String>(
              path.toString(),
            ).likeExp(t.path + const Constant('%')) |
            t.path.like("$path.%"),
      );
    }
    if (depth != null) {
      query.where(
        (t) => CustomExpression<int>(
          "LENGTH(path) - LENGTH(REPLACE(path, '.', ''))",
        ).isSmallerOrEqual(Variable<int>(((path?.depth ?? 0) + depth))),
      );
    }
    if (deleted != null) {
      query.where(
        (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull(),
      );
    }
    // order by path so parents always precede children
    query.orderBy([(t) => OrderingTerm(expression: t.path)]);

    return query.watch().map((rows) {
      return _buildHierarchy(rows, path: path);
    });
  }

  static List<Priority> _buildHierarchy(
    List<PriorityRow> rows, {
    Path? path,
    bool flat = false,
  }) {
    List<Priority> matches = [];
    List<Priority> stack = [];

    for (var row in rows) {
      var priority = Priority.fromStore(row);

      if (stack.isNotEmpty && !stack.last.path.isParent(priority.path)) {
        stack.removeWhere((c) => !c.path.isParent(priority.path));
      }

      if (stack.isNotEmpty) {
        priority = priority.copyWith(parent: stack.last);
      }

      if ((path == null && priority.path.isRoot) || priority.path == path) {
        matches.add(priority);
        stack.clear();
      } else if (flat) {
        matches.add(priority);
      }

      stack.add(priority);
    }

    matches.sort();
    return matches;
  }

  Priority({
    required super.name,
    required super.order,
    this.parent,
    super.isDefault = false,
    super.pomodoro = const Duration(minutes: 25),
    super.color = const ThemeColor.defaultColor(),
  }) : children = [],
       super(
         id: Uuid.generate(),
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         draft: false,
         path: Path.generate(parent: parent?.path),
       ) {
    parent?._addChild(this);
  }

  Priority.fromStore(PriorityRow row, {this.parent, List<Priority>? children})
    : children = children ?? [],
      super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        draft: row.draft,
        name: row.name,
        pomodoro: row.pomodoro,
        color: row.color,
        isDefault: row.isDefault,
        order: row.order,
        path: row.path,
      ) {
    parent?._addChild(this);
  }

  final Priority? parent;
  List<Priority> children;

  Future<void> delete() => copyWith(deletedAt: Value(DateTime.now())).save();

  @override
  Priority copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    bool? draft,
    String? name,
    Path? path,
    Order? order,
    Duration? pomodoro,
    ThemeColor? color,
    bool? isDefault,
    Priority? parent,
  }) => Priority.fromStore(
    super.copyWith(
      id: id,
      createdAt: this.draft && draft == false ? DateTime.now() : this.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: deletedAt,
      draft: draft,
      name: name,
      path: path,
      order: order,
      pomodoro: pomodoro,
      color: color,
      isDefault: isDefault,
    ),
    parent: parent ?? this.parent,
    children: children,
  );

  void _addChild(Priority child) {
    children = List<Priority>.from(
      children,
    ).replaceSorted(child, (a, b) => a.id == b.id);
  }

  bool isParent(Priority other) => path.isParent(other.path);
  List<Priority> get ancestors =>
      parent == null ? [] : parent!.ancestors + [parent!];
  List<Priority> get peers => parent?.children ?? [];
  Priority get root => parent?.root ?? this;

  String get pathLabel {
    return (([this] + ancestors)
            .map((a) => a.name)
            .toList()
            .expand((p) => [p, ' › '])
            .toList()
          ..removeLast())
        .join();
  }

  Future<void> save() => Store.get.save(table, this, PrioritiesBase());

  @override
  int compareTo(Priority other) {
    return order.compareTo(other.order);
  }

  T fold<T>(
    T initialValue,
    T Function(T previousValue, Priority priority, int depth) combine,
  ) {
    // Define a recursive function that applies the fold operation to this priority and its children
    T foldRecursively(Priority priority, T acc, int depth) {
      // Apply the combine function to the current priority
      acc = combine(acc, priority, depth);

      // Apply the fold function recursively to each child, incrementing the depth
      for (var child in priority.children) {
        acc = foldRecursively(child, acc, depth + 1);
      }

      return acc;
    }

    // Start the recursive fold process with the initial value and starting from depth 0
    return foldRecursively(this, initialValue, 0);
  }

  @override
  bool operator ==(Object other) {
    return super == other && children == (other as Priority).children;
  }

  @override
  int get hashCode {
    return Object.hash(super.hashCode, children.hashCode);
  }
}
