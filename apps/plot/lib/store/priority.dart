part of 'store.dart';

typedef PriorityId = Uuid;

@DataClassName('PriorityRow')
class Priorities extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  TextColumn get title => text()();
  TextColumn get path => text().map(const PathConverter())();
  BlobColumn get createdBy => blob().map(const UuidConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  IntColumn get pomodoro => integer()
      .nullable()
      .withDefault(const Constant(25 * 60))
      .map(const DurationConverter())();
  IntColumn get color => integer()
      .nullable()
      .withDefault(const Constant(0))
      .map(const ThemeColorConverter())();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
}

class PrioritiesBase extends BaseTable {
  PrioritiesBase()
    : super(
        table: 'priority_x',
        name: "priorities",
        order: 'order',
        upsertAsUpdate: true,
      );

  @override
  Insertable<PriorityRow> fromBase(Map<String, dynamic> json) =>
      PriorityRow.fromJson(json);
}

enum PriorityOrder { sorted, nested, recent }

class PriorityAncestor {
  static List<PriorityAncestor> fromStore(PriorityAncestryData row) {
    final ids = (jsonDecode(row.ancestors) as List)
        .map((e) => Uuid.fromString(e as String))
        .toList();
    final titles = (jsonDecode(row.titles) as List)
        .map((e) => e as String)
        .toList();
    return List.generate(
      ids.length,
      (index) => PriorityAncestor(id: ids[index], title: titles[index]),
    );
  }

  const PriorityAncestor({required this.id, required this.title});

  final PriorityId id;
  final String title;
}

class Priority extends PriorityRow implements Comparable<Priority> {
  static $PrioritiesTable get table => Store.get.priorities;

  static Future<void> push() => Store.get.push(table, PrioritiesBase());
  static Future<bool> pull() async {
    return await Store.get.pull(PullType.all, table, PrioritiesBase());
  }

  static Future<List<Priority>> get({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? deleted = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) async {
    return _get(
      id: id,
      path: path,
      depth: depth,
      deleted: deleted,
      order: order,
      search: search,
      self: self,
    ).get();
  }

  static Stream<List<Priority>> watch({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? deleted = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) {
    return _get(
      id: id,
      path: path,
      depth: depth,
      deleted: deleted,
      order: order,
      search: search,
      self: self,
    ).watch();
  }

  static Future<Priority> getOne(
    PriorityId id, {
    int? depth = 0,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      deleted: null,
      ancestors: ancestors,
      order: PriorityOrder.nested,
    ).get().then((priorities) => asNested(priorities, id: id).first);
  }

  static Stream<Priority> watchOne(
    PriorityId id, {
    int? depth = 0,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      deleted: null,
      ancestors: ancestors,
      order: PriorityOrder.nested,
    ).watch().map((priorities) => asNested(priorities, id: id).first);
  }

  static Future<bool> hasDefault() async {
    return (await _default().getSingleOrNull()) != null;
  }

  static Future<Priority> getDefault() async {
    return (await _default().getSingleOrNull())!;
  }

  static Stream<Priority> watchDefault() {
    return _default().watchSingleOrNull().map((p) => p!);
  }

  static Future<List<Priority>> getRoot({int? depth, bool? deleted = false}) =>
      get(
        depth: depth,
        deleted: deleted,
        order: PriorityOrder.nested,
      ).then((priorities) => asNested(priorities));

  static Stream<List<Priority>> watchRoot({
    int? depth,
    bool? deleted = false,
  }) => watch(
    depth: depth,
    deleted: deleted,
    order: PriorityOrder.nested,
  ).map((priorities) => asNested(priorities));

  static MultiSelectable<Priority> _get({
    /* Selectors */
    PriorityId? id,
    Path? path,

    /* Filters */
    int? depth,
    bool ancestors = false,
    bool self = true,
    bool? deleted = false,
    String? search,

    /* Sorting */
    PriorityOrder order = PriorityOrder.sorted,

    /* Augmentation */
    bool ancestry = true,
  }) {
    // pullPriorityPath(priorityPath);
    final base = Store.get.alias(Store.get.priorities, 'base');
    final startingQuery = Store.get.select(base);
    if (id != null) {
      startingQuery.where((t) => t.id.equalsValue(id));
    }
    if (path != null) {
      startingQuery.where((t) => t.path.equalsValue(path));
    }

    final p = Store.get.alias(Store.get.priorities, 'p');
    var query = startingQuery.join([
      innerJoin(
        p,
        id == null && path == null
            ? base.id.equalsExp(p.id)
            : p.path.likeExp(base.path + Constant('%')) &
                  ((ancestors
                          ? base.path.likeExp(p.path + Constant('%'))
                          : Constant(true)) |
                      (p.path.likeExp(base.path + Constant('%')))) &
                  (depth == null
                      ? Constant(true)
                      : CustomExpression<int>("""
  LENGTH(p.path) - LENGTH(REPLACE(p.path, '.', '')) -
  (CASE WHEN base.path IS NULL THEN 0 ELSE LENGTH(base.path) - LENGTH(REPLACE(base.path, '.', '')) END)
  """).isSmallerOrEqualValue(depth)),
      ),
    ]);

    if (deleted != null) {
      query.where(deleted ? p.deletedAt.isNotNull() : p.deletedAt.isNull());
    }
    if (search?.isNotEmpty == true) {
      query.where(p.title.like('%$search%'));
    }
    if (self == false) {
      if (id != null) {
        query.where(p.id.equalsValue(id).not());
      }
      if (path != null) {
        query.where(p.path.equalsValue(path).not());
      }
    }

    switch (order) {
      case PriorityOrder.sorted:
        query.orderBy([OrderingTerm.asc(p.order)]);
        break;
      case PriorityOrder.nested:
        // order by path so parents always precede children
        query.orderBy([OrderingTerm(expression: p.path)]);
        break;
      case PriorityOrder.recent:
        query = query.join([
          leftOuterJoin(
            Store.get.latestPriorities,
            Store.get.latestPriorities.priorityId.equalsExp(p.id),
          ),
        ]);
        query.orderBy([
          OrderingTerm(
            expression: Store.get.latestPriorities.at,
            mode: OrderingMode.desc,
          ),
          OrderingTerm.asc(p.order),
        ]);
        break;
    }

    if (ancestry) {
      final pa = Store.get.alias(Store.get.priorityAncestry, 'pa');
      return query
          .join([leftOuterJoin(pa, pa.priorityId.equalsExp(p.id))])
          .map(
            (row) => Priority.fromStore(
              row.readTable(p),
              ancestry: row.readTableOrNull(pa),
            ),
          );
    }

    return query.map((row) => Priority.fromStore(row.readTable(p)));
  }

  static SingleOrNullSelectable<Priority> _default() {
    return (Store.get.select(table)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.root, mode: OrderingMode.desc),
            // If no priority is marked default, fall back to the first one created
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
          ])
          ..limit(1))
        .map(Priority.fromStore);
  }

  static Map<Uuid, Priority> asMap(List<Priority> list) {
    final priorities = <Uuid, Priority>{};
    void add(Priority priority) {
      priorities[priority.id] = priority;
      for (var child in priority.children) {
        add(child);
      }
    }

    for (var p in list) {
      add(p);
    }
    return priorities;
  }

  /// Transform a flat list in PriorityOrder.nested order to a list of the top-level items with descendants.
  static List<Priority> asNested(
    List<Priority> priorities, {
    PriorityId? id,
    Path? path,
    bool flat = false,
  }) {
    List<Priority> matches = [];
    List<Priority> stack = [];

    for (var priority in priorities) {
      if (stack.isNotEmpty && !stack.last.path.isParent(priority.path)) {
        stack.removeWhere((c) => !c.path.isParent(priority.path));
      }

      if (stack.isNotEmpty) {
        priority = priority.copyWith(parent: stack.last);
      }

      if ((id == null && path == null && priority.path.isRoot) ||
          priority.path == path ||
          priority.id == id) {
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
    Order? order,
    this.parent,
    this.balance,
    required super.title,
    super.pomodoro = const Duration(minutes: 25),
    super.color = const ThemeColor.defaultColor(),
  }) : children = [],
       _ancestors = parent == null
           ? const []
           : parent._ancestors +
                 [PriorityAncestor(id: parent.id, title: parent.title)],
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         order: order ?? Order.first(),
         path: Path.generate(parent: parent?.path),
         root: false,
       ) {
    parent?._addChild(this);
  }

  Priority.fromStore(
    PriorityRow row, {
    this.parent,
    List<Priority>? children,
    this.balance,
    PriorityAncestryData? ancestry,
  }) : children = children ?? [],
       _ancestors = ancestry == null
           ? parent == null
                 ? const []
                 : parent._ancestors +
                       [PriorityAncestor(id: parent.id, title: parent.title)]
           : PriorityAncestor.fromStore(ancestry),
       super(
         id: row.id,
         createdAt: row.createdAt,
         updatedAt: row.updatedAt,
         deletedAt: row.deletedAt,
         title: row.title,
         pomodoro: row.pomodoro,
         color: row.color,
         root: row.root,
         order: row.order,
         path: row.path,
         createdBy: row.createdBy,
       ) {
    parent?._addChild(this);
  }

  static const separator = ' › ';

  List<PriorityAncestor> ancestors({
    Priority? context,
    bool includeSelf = false,
  }) {
    final ancestors = [
      ..._ancestors,
      if (includeSelf) PriorityAncestor(id: id, title: title),
    ];
    if (context != null) {
      int startIndex = ancestors.indexWhere((a) => a.id == context.id);
      if (startIndex != -1) {
        return ancestors.sublist(startIndex + 1);
      }
    }
    if (ancestors.length > (includeSelf ? 1 : 0)) {
      // Skip "Everything" root priority
      return ancestors.sublist(1);
    }
    return ancestors;
  }

  String ancestorsLabel({Priority? context}) {
    final ancestors = this.ancestors(context: context);
    if (ancestors.isEmpty) {
      return '';
    }
    return (ancestors
            .map((a) => a.title)
            .toList()
            .expand((p) => [p, separator])
            .toList()
          ..removeLast())
        .join();
  }

  final Priority? parent;
  PriorityId? get parentId => parent?.id ?? _ancestors.lastOrNull?.id;
  List<Priority> children;
  final Balance? balance;
  final List<PriorityAncestor> _ancestors;

  List<Priority> descendants() {
    List<Priority> result = [];

    // Recursive helper to collect descendants
    void collectDescendants(Priority priority) {
      for (var child in priority.children) {
        result.add(child);
        collectDescendants(child);
      }
    }

    collectDescendants(this);
    result.sort();
    return result;
  }

  Future<void> delete() => copyWith(deletedAt: Value(DateTime.now())).save();

  @override
  Priority copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? title,
    Path? path,
    Uuid? createdBy,
    Order? order,
    Value<Duration?> pomodoro = const Value.absent(),
    Value<ThemeColor?> color = const Value.absent(),
    bool? root,
    Priority? parent,
    Balance? balance,
  }) {
    return Priority.fromStore(
      super.copyWith(
        id: id,
        createdBy: createdBy,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: DateTime.now(),
        deletedAt: deletedAt,
        title: title ?? this.title,
        path: path ?? this.path,
        order: order ?? this.order,
        pomodoro: pomodoro,
        color: color,
        root: root ?? this.root,
      ),
      parent: parent ?? this.parent,
      children: children,
      balance: balance ?? this.balance,
    );
  }

  void _addChild(Priority child) {
    children = List<Priority>.from(
      children,
    ).replaceSorted(child, (a, b) => a.id == b.id);
  }

  bool isParent(Priority other) => path.isParent(other.path);
  List<Priority> get peers => parent?.children ?? [];

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), PrioritiesBase());

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
}
