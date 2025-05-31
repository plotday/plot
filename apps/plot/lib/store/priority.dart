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
  TextColumn get doAt => text().nullable().map(const DateConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();
  TextColumn get eventSeries => text().nullable()();

  @override
  List<String> get customConstraints => [
    'CHECK (draft = 1 OR title IS NOT NULL)',
  ];
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

enum PriorityOrder { sorted, nested, recent }

class PriorityAncestor {
  static List<PriorityAncestor> fromStore(PriorityAncestryData row) {
    final ids =
        (jsonDecode(row.ancestors) as List)
            .map((e) => Uuid.fromString(e as String))
            .toList();
    final titles =
        (jsonDecode(row.titles) as List).map((e) => e as String).toList();
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
    bool? pinned,
    bool? active,
    bool? deleted = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) async {
    return _get(
      id: id,
      path: path,
      depth: depth,
      pinned: pinned,
      active: active,
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
    bool? pinned,
    bool? active,
    bool? deleted = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) {
    return _get(
      id: id,
      path: path,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      order: order,
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
      order: PriorityOrder.nested,
    ).get().then((priorities) => _asNested(priorities, id: id).first);
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
      order: PriorityOrder.nested,
    ).watch().map((priorities) => _asNested(priorities, id: id).first);
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
    order: PriorityOrder.nested,
  ).then((priorities) => _asNested(priorities));

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
    order: PriorityOrder.nested,
  ).map((priorities) => _asNested(priorities));

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

    if (active == true) {
      query.where(p.doAt.isNotNull() & p.doneAt.isNull());
    } else if (active == false) {
      query.where(p.doAt.isNull() | p.doneAt.isNotNull());
    }
    if (pinned != null) {
      query.where(p.pinned.equals(pinned));
    }
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
        query.orderBy([
          // Pinned
          OrderingTerm(expression: p.pinned, mode: OrderingMode.desc),
          // Active
          OrderingTerm.desc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  p.doAt.isSmallerOrEqual(Constant(Date.today().toString())) &
                      p.doneAt.isNull(),
                  then: p.doAt,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.asc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  p.pinned |
                      (p.doAt.isSmallerOrEqual(
                            Constant(Date.today().toString()),
                          ) &
                          p.doneAt.isNull()),
                  then: p.order,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.desc(p.order),
        ]);
        break;
      case PriorityOrder.nested:
        // order by path so parents always precede children
        query.orderBy([OrderingTerm(expression: p.path)]);
        break;
      case PriorityOrder.recent:
        query = query.join([
          leftOuterJoin(
            Store.get.sessions,
            Store.get.sessions.priorityId.equalsExp(p.id),
          ),
        ]);
        query.orderBy([
          OrderingTerm(
            expression: Store.get.sessions.end,
            mode: OrderingMode.desc,
          ),
        ]);
        break;
    }

    final pne = Store.get.alias(Store.get.priorityNextEvent, 'pne');
    query = query.join([leftOuterJoin(pne, pne.priorityId.equalsExp(p.id))]);

    if (ancestry) {
      final pa = Store.get.alias(Store.get.priorityAncestry, 'pa');
      return query
          .join([leftOuterJoin(pa, pa.priorityId.equalsExp(p.id))])
          .map(
            (row) => Priority.fromStore(
              row.readTable(p),
              ancestry: row.readTableOrNull(pa),
              nextEventStart: row.readTableOrNull(pne)?.start,
            ),
          );
    }

    return query.map(
      (row) => Priority.fromStore(
        row.readTable(p),
        nextEventStart: row.readTableOrNull(pne)?.start,
      ),
    );
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

  /// Transform a flat list in PriorityOrder.nested order to a list of the top-level items with descendants.
  static List<Priority> _asNested(
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
    super.eventSeries,
  }) : children = [],
       _ancestors =
           parent == null
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
    DateTime? nextEventStart,
  }) : children = children ?? [],
       _ancestors =
           ancestry == null
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
         createdBy: row.createdBy,
         doAt: nextEventStart != null ? nextEventStart.toDate() : row.doAt,
         doneAt: row.doneAt,
         eventSeries: row.eventSeries,
       ) {
    parent?._addChild(this);
  }

  /// Title is always set when draft = false
  @override
  String get title => super.title ?? 'Untitled';

  bool get hasTitle => super.title != null;

  static String noteToTitle(String markdown) {
    final firstLine = markdown.split("\n").first.removeMarkdown().trim();
    if (firstLine.length > 40) {
      return "${firstLine.substring(0, 40)}…";
    }
    return firstLine;
  }

  static const separator = ' › ';

  List<PriorityAncestor> ancestors({Priority? context}) {
    if (_ancestors.length < 2) {
      return const [];
    } else if (context != null) {
      int startIndex = _ancestors.indexWhere((a) => a.id == context.id);
      if (startIndex != -1) {
        return _ancestors.sublist(startIndex + 1);
      }
    }
    // Skip "Everything" root priority
    return _ancestors.sublist(1);
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

  Priority merge(Priority other) {
    return copyWith(
      title:
          !hasTitle
              ? other.hasTitle
                  ? Value(other.title)
                  : Value.absent()
              : Value(title),
      doAt: Value(doAt ?? other.doAt),
      doneAt: Value(doneAt ?? other.doneAt),
      pinned: pinned || other.pinned,
      private: private || other.private,
      eventSeries: Value(eventSeries ?? other.eventSeries),
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
    Value<Duration?> pomodoro = const Value.absent(),
    Value<ThemeColor?> color = const Value.absent(),
    bool? root,
    bool? pinned,
    bool? private,
    Value<Date?> doAt = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Priority? parent,
    Balance? balance,
    Value<String?> eventSeries = const Value.absent(),
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
    if (publish &&
        note.present &&
        note.value != null &&
        !title.present &&
        !hasTitle) {
      title = Value(noteToTitle(note.value!));
      if (note.value!.length < 40 && !note.value!.contains(RegExp(r'[\n]'))) {
        note = Value.absent();
      }
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
        pomodoro: pomodoro,
        color: color,
        root: root,
        pinned: pinned,
        private: private,
        doAt: doAt,
        doneAt: doneAt,
        note: note,
        eventSeries: eventSeries,
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

  // For the user, doAt can never be in the past
  @override
  Date? get doAt =>
      _doAt != null && _doAt! < Date.today() ? Date.today() : _doAt;

  Date? get _doAt => super.doAt;

  bool get doNow {
    return !done && _doAt != null && _doAt! <= Date.today();
  }

  bool get doLater {
    return _doAt != null && _doAt! > Date.today();
  }

  bool get scheduled {
    return _doAt != null;
  }

  bool get done => doneAt != null;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), PrioritiesBase());

  @override
  int compareTo(Priority other) {
    if (pinned && other.pinned) {
      return -order.compareTo(other.order);
    }
    if (pinned || other.pinned) {
      return pinned ? -1 : 1;
    }
    if (doNow && other.doNow) {
      final doAtComp = _doAt!.compareTo(other._doAt!);
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
