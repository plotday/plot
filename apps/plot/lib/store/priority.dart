part of 'store.dart';

typedef PriorityId = Uuid;

@DataClassName('PriorityRow')
class Priorities extends Table
    with SyncableTable, UuidTable, DraftTable, DeletableTable {
  TextColumn get title => text().nullable()();
  TextColumn get path => text().map(const PathConverter())();
  BlobColumn get createdBy => blob().map(const UuidConverter())();
  RealColumn get order =>
      real()
          .clientDefault(() => Order.first().value)
          .map(const OrderConverter())();
  DateTimeColumn get orderedAt =>
      dateTime()
          .withDefault(currentDateAndTime)
          .map(const LocalDateTimeConverter())();
  IntColumn get pomodoro =>
      integer()
          .nullable()
          .withDefault(const Constant(25 * 60))
          .map(const DurationConverter())();
  IntColumn get color =>
      integer()
          .nullable()
          .withDefault(const Constant(0))
          .map(const ThemeColorConverter())();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  DateTimeColumn get doAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();
}

class PrioritiesBase extends BaseTable {
  PrioritiesBase()
    : super(
        table: 'priority_x',
        name: "priorities",
        order: 'order_x',
        upsertAsUpdate: true,
      );

  @override
  Insertable<PriorityRow> fromBase(Map<String, dynamic> json) =>
      PriorityRow.fromJson(json);
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
    bool? pinned,
    bool? active,
    bool? deleted = false,
    bool recent = false,
    String? search,
    bool self = true,
  }) async {
    return _get(
      id: id,
      path: path,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      recent: recent,
      search: search,
      self: self,
    ).get();
  }

  static Stream<List<Priority>> watch({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    bool recent = false,
    String? search,
    bool self = true,
  }) {
    return _get(
      id: id,
      path: path,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      recent: recent,
      search: search,
      self: self,
    ).watch();
  }

  static Future<Priority> getOne(
    PriorityId id, {
    int? depth = 0,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      ancestors: ancestors,
    ).get().then((priorities) => asNested(priorities, id: id).first);
  }

  static Stream<Priority> watchOne(
    PriorityId id, {
    int? depth = 0,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      ancestors: ancestors,
    ).watch().map((priorities) => asNested(priorities, id: id).first);
  }

  static Future<Priority> getDefault() {
    return _default().getSingle();
  }

  static Stream<Priority> watchDefault() {
    return _default().watchSingle();
  }

  static Future<List<Priority>> getRoot({
    int? depth,
    bool? pinned,
    bool? active,
    bool? deleted = false,
  }) => get(
    depth: depth,
    pinned: pinned,
    active: active,
    deleted: deleted,
  ).then((priorities) => asNested(priorities));

  static Stream<List<Priority>> watchRoot({
    int? depth,
    bool? pinned,
    bool? active,
    bool? deleted = false,
  }) => watch(
    depth: depth,
    pinned: pinned,
    active: active,
    deleted: deleted,
  ).map((priorities) => asNested(priorities));

  static MultiSelectable<Priority> _get({
    /* Selectors */
    PriorityId? id,
    Path? path,

    /* Filters */
    int? depth,
    bool ancestors = false,
    bool self = true,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    String? search,

    /* Sorting */
    bool recent = false,
  }) {
    // pullPriorityPath(priorityPath);
    final p = Store.get.alias(Store.get.priorities, 'p');
    final query = Store.get.select(p);
    if (id != null) {
      query.where((t) => t.id.equalsValue(id));
    }
    if (path != null) {
      query.where((t) => t.path.equalsValue(path));
    }

    final p2 = Store.get.alias(Store.get.priorities, 'p2');
    final join = query.join([
      innerJoin(
        p2,
        id == null && path == null
            ? p.id.equalsExp(p2.id)
            : p2.path.likeExp(p.path + Constant('%')) &
                ((ancestors
                        ? p.path.likeExp(p2.path + Constant('%'))
                        : Constant(true)) |
                    (p2.path.likeExp(p.path + Constant('%')))) &
                (depth == null
                    ? Constant(true)
                    : CustomExpression<int>("""
  LENGTH(p2.path) - LENGTH(REPLACE(p2.path, '.', '')) -
  (CASE WHEN p.path IS NULL THEN 0 ELSE LENGTH(p.path) - LENGTH(REPLACE(p.path, '.', '')) END)
  """).isSmallerOrEqualValue(depth)),
      ),
    ]);

    if (active == true) {
      join.where(p2.doAt.isNotNull() & p2.doneAt.isNull());
    } else if (active == false) {
      join.where(p2.doAt.isNull() | p2.doneAt.isNotNull());
    }
    if (pinned != null) {
      join.where(p2.pinned.equals(pinned));
    }
    if (deleted != null) {
      join.where(deleted ? p2.deletedAt.isNotNull() : p2.deletedAt.isNull());
    }
    if (search != null) {
      join.where(p2.title.like('%$search%'));
    }
    if (self == false) {
      if (id != null) {
        join.where(p2.id.equalsValue(id).not());
      }
      if (path != null) {
        join.where(p2.path.equalsValue(path).not());
      }
    }

    if (recent) {
      final join2 = join.join([
        leftOuterJoin(
          Store.get.sessions,
          Store.get.sessions.priorityId.equalsExp(p2.id),
        ),
      ]);
      join2.orderBy([
        OrderingTerm(
          expression: Store.get.sessions.end,
          mode: OrderingMode.desc,
        ),
      ]);
      return join2.map((row) => Priority.fromStore(row.readTable(p2)));
    }

    // order by path so parents always precede children
    join.orderBy([OrderingTerm(expression: p2.path)]);

    return join.map((row) => Priority.fromStore(row.readTable(p2)));
  }

  static SingleSelectable<Priority> _default() {
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

  static Map<Uuid, Priority> asNestedMap(List<Priority> list) {
    return asMap(asNested(list, flat: true));
  }

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

  Future<String> generateTitle() async {
    final response = await api.post("/summary", body: {'body': note});
    return response['title'] as String;
  }

  Priority({
    Order? order,
    this.parent,
    this.balance,
    super.title,
    super.note,
    super.pomodoro = const Duration(minutes: 25),
    super.color = const ThemeColor.defaultColor(),
    super.draft = false,
    super.private = false,
    super.pinned = false,
  }) : children = [],
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         order: order ?? Order.first(),
         orderedAt: DateTime.now(),
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
  }) : children = children ?? [],
       super(
         id: row.id,
         createdAt: row.createdAt,
         updatedAt: row.updatedAt,
         deletedAt: row.deletedAt,
         draft: row.draft,
         title: row.title,
         note: row.note,
         pomodoro: row.pomodoro,
         color: row.color,
         root: row.root,
         order: row.order,
         path: row.path,
         private: row.private,
         pinned: row.pinned,
         orderedAt: row.orderedAt,
         createdBy: row.createdBy,
         doAt: row.doAt,
         doneAt: row.doneAt,
       ) {
    parent?._addChild(this);
  }

  String get label {
    return title ?? note?.removeMarkdown().trim() ?? 'Untitled';
  }

  String get pathLabel {
    return (([this] + ancestors)
            .map((a) => a.title)
            .toList()
            .expand((p) => [p, ' › '])
            .toList()
          ..removeLast())
        .join();
  }

  final Priority? parent;
  List<Priority> children;
  final Balance? balance;

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

  Priority merge(Priority other) {
    return copyWith(
      title: title?.isEmpty == true ? Value(other.title) : Value.absent(),
      doAt: Value(doAt ?? other.doAt),
      doneAt: Value(doneAt ?? other.doneAt),
      pinned: pinned || other.pinned,
      private: private || other.private,
    );
  }

  @override
  Priority copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    bool? draft,
    Value<DateTime?> deletedAt = const Value.absent(),
    Value<String?> title = const Value.absent(),
    Path? path,
    Uuid? createdBy,
    Order? order,
    DateTime? orderedAt,
    Value<Duration?> pomodoro = const Value.absent(),
    Value<ThemeColor?> color = const Value.absent(),
    bool? root,
    bool? pinned,
    bool? private,
    Value<DateTime?> doAt = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Priority? parent,
    Balance? balance,
  }) {
    final publish = this.draft && draft == false;
    if (doAt.present && doAt.value != null) {
      doneAt = const Value(null);
      pinned = false;
    } else if (pinned == true) {
      doAt = const Value(null);
      doneAt = const Value(null);
    } else if (doneAt.present) {
      doAt = const Value(null);
      pinned = false;
    }
    if (publish ||
        (doAt.present && doAt.value != this.doAt) ||
        (doneAt.present && doneAt.value != null) ||
        (pinned != null && pinned != this.pinned)) {
      order ??= Order.first();
    }
    return Priority.fromStore(
      super.copyWith(
        id: id,
        createdBy: createdBy,
        createdAt: publish ? DateTime.now() : this.createdAt,
        updatedAt: DateTime.now(),
        deletedAt: deletedAt,
        draft: draft,
        title: title,
        path: path,
        order: order,
        orderedAt:
            orderedAt ?? (order != null ? DateTime.now() : this.orderedAt),
        pomodoro: pomodoro,
        color: color,
        root: root,
        pinned: pinned,
        private: private,
        doAt: doAt,
        doneAt: doneAt,
        note: note,
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
  List<Priority> get ancestors =>
      parent == null ? [] : parent!.ancestors + [parent!];
  List<Priority> get peers => parent?.children ?? [];

  bool get doNow {
    return !done && doAt?.isSameOrBefore(DateTime.now()) == true;
  }

  bool get scheduled {
    return doAt?.isAfter(DateTime.now()) == true;
  }

  bool get done => doneAt != null;

  Future<void> save() => Store.get.save(table, this, PrioritiesBase());

  @override
  int compareTo(Priority other) {
    if (pinned && other.pinned) {
      return -order.compareTo(other.order);
    }
    if (pinned || other.pinned) {
      return pinned ? -1 : 1;
    }
    if (doNow && other.doNow) {
      final doAtComp = doAt!.compareTo(other.doAt!);
      if (doAtComp != 0) {
        return doAtComp;
      }
      return -order.compareTo(other.order);
    }
    if (doNow || other.doNow) {
      return doNow ? -1 : 1;
    }
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
