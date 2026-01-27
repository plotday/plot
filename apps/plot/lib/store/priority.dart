part of 'store.dart';

typedef PriorityId = Uuid;

@DataClassName('PriorityRow')
class Priorities extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  TextColumn get title => text()();
  TextColumn get path => text().map(const PathConverter())();
  BlobColumn get createdBy => blob().map(const UuidConverter())();
  RealColumn get topOrder => real().nullable().map(const OrderConverter())();
  RealColumn get order => real()
      .map(const OrderConverter())
      .clientDefault(() => DateTime.now().millisecondsSinceEpoch.toDouble())();
  IntColumn get pomodoro => integer()
      .nullable()
      .withDefault(const Constant(25 * 60))
      .map(const DurationConverter())();
  IntColumn get color =>
      integer().nullable().map(const ThemeColorConverter())();
  TextColumn get key => text().nullable()();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get unread => boolean().withDefault(const Constant(false))();
}

class PrioritiesBase extends BaseTable {
  PrioritiesBase()
    : super(
        table: 'user_priority',
        name: "priorities",
        order: 'created_at',
        upsertAsUpdate: true,
      );

  @override
  Insertable<PriorityRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    return PriorityRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('unread');
    return json;
  }
}

enum PriorityOrder { sorted, nested, recent }

class PriorityAncestor {
  static List<PriorityAncestor> fromStore(PriorityAncestryData row) {
    // Parse raw arrays from JSON
    final rawTitles = jsonDecode(row.titles) as List;
    final rawIds = jsonDecode(row.ancestors) as List;
    final rawColors = jsonDecode(row.colors) as List;

    // Filter out NULL entries (from LEFT JOIN when ancestor doesn't exist)
    final ids = <Uuid>[];
    final titles = <String>[];
    final colors = <int?>[];

    for (int i = 0; i < rawTitles.length; i++) {
      if (rawTitles[i] != null) {
        titles.add(rawTitles[i] as String);
        ids.add(Uuid.fromString(rawIds[i] as String));
        colors.add(rawColors[i] as int?);
      }
    }

    // Compute display colors with inheritance
    int currentColorIndex = ThemeColor.defaultColor().index;
    final displayColors = <int>[];
    for (int i = 0; i < colors.length; i++) {
      if (colors[i] != null) {
        currentColorIndex = colors[i]!;
      }
      displayColors.add(currentColorIndex);
    }

    return List.generate(
      ids.length,
      (index) => PriorityAncestor(
        id: ids[index],
        title: titles[index],
        color: displayColors[index],
      ),
    );
  }

  const PriorityAncestor({
    required this.id,
    required this.title,
    required this.color,
  });

  final PriorityId id;
  final String title;

  /// The computed display color index (with inheritance applied).
  /// Root priorities default to 7 (Resolution) when no color is explicitly set.
  final int color;
}

class Priority extends PriorityRow implements Comparable<Priority> {
  static $PrioritiesTable get table => Store.get.priorities;

  static Future<bool> push() => Store.get.push(table, PrioritiesBase());
  static Future<void> pull() async {
    // First pull: fetch all priorities if not already initialized
    await Store.get.pull(table, PrioritiesBase(), initial: true);
    // Subsequent pulls: fetch changes since last pull
    await Store.get.pull(table, PrioritiesBase());
  }

  static Future<List<Priority>> get({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? archived = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) async {
    // Trigger archived sync if needed
    if (archived == true) {
      await Store.get.pullArchived(table, PrioritiesBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      await Store.get.pullArchived(table, PrioritiesBase());
    }

    final priorities = await _get(
      id: id,
      path: path,
      depth: depth,
      archived: archived,
      order: order,
      search: search,
      self: self,
    ).get();

    // Compute active/unread status for all priorities
    return _enrichWithStatus(priorities);
  }

  static Stream<List<Priority>> watch({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? archived = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) {
    // Defensive check: Return empty stream if Store is not available (user signing out)
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value([]);
    }

    // Trigger archived sync if needed
    if (archived == true) {
      Store.get.pullArchived(table, PrioritiesBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      Store.get.pullArchived(table, PrioritiesBase());
    }

    // Watch priorities table
    final prioritiesStream = _get(
      id: id,
      path: path,
      depth: depth,
      archived: archived,
      order: order,
      search: search,
      self: self,
    ).watch();

    // Watch active and unread priority IDs
    final activePriorityIdsStream = _watchActivePriorityIds();
    final unreadPriorityIdsStream = _watchUnreadPriorityIds();

    // Combine all three streams
    return Rx.combineLatest3(
          prioritiesStream,
          activePriorityIdsStream,
          unreadPriorityIdsStream,
          (priorities, activeIds, unreadIds) =>
              (priorities, activeIds, unreadIds),
        )
        .map((tuple) {
          final priorities = tuple.$1;
          final activeIds = tuple.$2;
          final unreadIds = tuple.$3;

          // Map priorities with computed status
          return priorities.map((p) {
            return Priority.fromStore(
              p,
              parent: p.parent,
              children: p.children,
              draft: p.draft,
              ancestors: p._ancestors,
              minAncestorTopOrder: p.minAncestorTopOrder,
              active: activeIds.contains(p.id),
              unreadComputed: unreadIds.contains(p.id),
            );
          }).toList();
        })
        .debounceTime(const Duration(milliseconds: 100))
        .distinct()
        .transform(
          ExpiringStreamTransformer((priorities) {
            // Re-evaluate every minute on the minute for time-based active status
            final now = DateTime.now();
            final expiry = now.add(
              Duration(
                seconds: 60 - now.second,
                milliseconds: -now.millisecond,
              ),
            );
            return ExpiringResult(value: priorities, expiry: expiry);
          }),
        );
  }

  static Future<Priority> getOne(
    PriorityId id, {
    int? depth = 0,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      archived: null,
      ancestors: ancestors,
      order: PriorityOrder.nested,
    ).get().then((priorities) {
      final nested = asNested(priorities, id: id);
      if (nested.isEmpty) {
        throw StateError('Priority not found: $id');
      }
      return nested.first;
    });
  }

  static Stream<Priority> watchOne(
    PriorityId id, {
    int? depth = 0,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      archived: null,
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

  static Future<List<Priority>> getRoot({int? depth, bool? archived = false}) =>
      get(
        depth: depth,
        archived: archived,
        order: PriorityOrder.nested,
      ).then((priorities) => asNested(priorities));

  static Stream<List<Priority>> watchRoot({
    int? depth,
    bool? archived = false,
  }) => watch(
    depth: depth,
    archived: archived,
    order: PriorityOrder.nested,
  ).map((priorities) => asNested(priorities));

  /// Enriches a list of priorities with computed active/unread status.
  static Future<List<Priority>> _enrichWithStatus(
    List<Priority> priorities,
  ) async {
    if (priorities.isEmpty) return priorities;

    // Get all priority IDs
    final priorityIds = priorities.map((p) => p.id).toList();

    // Compute which priorities have active/unread activities
    final activeIds = await _getActivePriorityIds(priorityIds);
    final unreadIds = await _getUnreadPriorityIds(priorityIds);

    // Create new Priority objects with computed status
    return priorities.map((p) {
      return Priority.fromStore(
        p,
        parent: p.parent,
        children: p.children,
        draft: p.draft,
        ancestors: p._ancestors,
        minAncestorTopOrder: p.minAncestorTopOrder,
        active: activeIds.contains(p.id),
        unreadComputed: unreadIds.contains(p.id),
      );
    }).toList();
  }

  /// Efficiently gets which priority IDs from the given list have active activities.
  static Future<Set<PriorityId>> _getActivePriorityIds(
    List<PriorityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    final now = DateTime.now();
    final today = Date.today().toString();

    // Get all user contact IDs from Actor cache
    final userActorIds = Actor._cache.values
        .where((actor) => actor.self)
        .map((actor) => actor.id.toBytes())
        .toList();

    // Fallback to primary contact if cache is empty
    if (userActorIds.isEmpty) {
      userActorIds.add(Base.actorId.toBytes());
    }

    final a = Store.get.activities;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    // Convert PriorityId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.priorityId.isIn(idBytes) &
          a.type.equalsValue(ActivityType.action) &
          a.assigneeId.isIn(userActorIds) &
          a.doneAt.isNull() &
          a.archivedAt.isNull() &
          (
          // DateTime scheduled
          (a.startAt.isSmallerOrEqualValue(now) & a.startOn.isNull()) |
              // Date scheduled
              (a.startOn.isSmallerOrEqualValue(today) & a.startAt.isNull()) |
              // Unscheduled
              (a.startAt.isNull() & a.startOn.isNull())),
    );

    final results = await query.get();
    return results
        .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
        .toSet();
  }

  /// Efficiently gets which priority IDs from the given list have unread activities.
  static Future<Set<PriorityId>> _getUnreadPriorityIds(
    List<PriorityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    final a = Store.get.activities;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    // Convert PriorityId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.priorityId.isIn(idBytes) &
          a.unread.equals(true) &
          (a.unreadUpdated.isNull() | a.unreadUpdated.equals(false)) &
          a.archivedAt.isNull() &
          a.draft.equals(false),
    );

    final results = await query.get();
    return results
        .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
        .toSet();
  }

  /// Watches which priorities have unread activities.
  /// Returns a stream of priority IDs that have unread items.
  static Stream<Set<PriorityId>> _watchUnreadPriorityIds() {
    final a = Store.get.activities;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    query.where(
      a.unread.equals(true) &
          (a.unreadUpdated.isNull() | a.unreadUpdated.equals(false)) &
          a.archivedAt.isNull() &
          a.draft.equals(false),
    );

    return query
        .watch()
        .map(
          (results) => results
              .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
              .toSet(),
        )
        .distinct();
  }

  /// Watches which priorities have active activities.
  /// Returns a stream of priority IDs that have active tasks.
  /// Time-based filtering is done in-memory to allow reactive updates.
  static Stream<Set<PriorityId>> _watchActivePriorityIds() {
    // Get all user contact IDs from Actor cache
    final userActorIds = Actor._cache.values
        .where((actor) => actor.self)
        .map((actor) => actor.id.toBytes())
        .toList();

    // Fallback to primary contact if cache is empty
    if (userActorIds.isEmpty) {
      userActorIds.add(Base.actorId.toBytes());
    }

    final a = Store.get.activities;

    // Query for activities that could be active (without time filtering)
    // We'll filter by time in the map to allow reactive updates
    final query = Store.get.selectOnly(a)
      ..addColumns([a.priorityId, a.startAt, a.startOn]);

    query.where(
      a.type.equalsValue(ActivityType.action) &
          a.assigneeId.isIn(userActorIds) &
          a.doneAt.isNull() &
          a.archivedAt.isNull(),
    );

    return query.watch().map((results) {
      final now = DateTime.now();
      final today = Date.today().toString();

      return results
          .where((row) {
            final startAt = row.read(a.startAt);
            final startOn = row.read(a.startOn);

            // DateTime scheduled and active
            if (startAt != null && startOn == null) {
              return startAt.isBefore(now) || startAt.isAtSameMomentAs(now);
            }
            // Date scheduled and active
            if (startOn != null && startAt == null) {
              return startOn.compareTo(today) <= 0;
            }
            // Unscheduled (always active)
            if (startAt == null && startOn == null) {
              return true;
            }
            return false;
          })
          .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
          .toSet();
    }).distinct();
  }

  static MultiSelectable<Priority> _get({
    /* Selectors */
    PriorityId? id,
    Path? path,

    /* Filters */
    int? depth,
    bool ancestors = false,
    bool self = true,
    bool? archived = false,
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

    if (archived != null) {
      query.where(archived ? p.archivedAt.isNotNull() : p.archivedAt.isNull());
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
        query.orderBy([OrderingTerm.asc(p.path)]);
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
          OrderingTerm.asc(p.path),
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
          ..where((t) => t.archivedAt.isNull())
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

    matches.sort((a, b) => a.path.value.compareTo(b.path.value));
    return matches;
  }

  Priority({
    required this.parent,
    required super.title,
    super.topOrder,
    super.pomodoro = const Duration(minutes: 25),
    super.color,
    this.draft = false,
  }) : children = [],
       _ancestors =
           parent!._ancestors +
           [
             PriorityAncestor(
               id: parent.id,
               title: parent.title,
               color: parent.displayColor.index,
             ),
           ],
       minAncestorTopOrder = null,
       displayColor = color ?? parent.displayColor,
       _originalPath = null,
       _activeComputed = null,
       _unreadComputed = null,
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         path: Path.generate(parent: parent.path),
         order: Order(DateTime.now().millisecondsSinceEpoch.toDouble()),
         root: false,
         unread: false,
       ) {
    if (!draft) {
      parent!._addChild(this);
    }
  }

  Priority.fromStore(
    PriorityRow row, {
    this.parent,
    List<Priority>? children,
    PriorityAncestryData? ancestry,
    List<PriorityAncestor>? ancestors,
    Order? minAncestorTopOrder,
    this.draft = false,
    Path? originalPath,
    bool? active,
    bool? unreadComputed,
    ThemeColor? displayColor,
  }) : children = children ?? [],
       _ancestors =
           ancestors ??
           (ancestry == null
               ? parent == null
                     ? const []
                     : parent._ancestors +
                           [
                             PriorityAncestor(
                               id: parent.id,
                               title: parent.title,
                               color: parent.displayColor.index,
                             ),
                           ]
               : PriorityAncestor.fromStore(ancestry)),
       minAncestorTopOrder =
           minAncestorTopOrder ?? ancestry?.minAncestorTopOrder,
       _originalPath = originalPath ?? row.path,
       displayColor =
           displayColor ??
           row.color ??
           _computeDisplayColor(
             ancestry: ancestry,
             parent: parent,
             isRoot: row.root,
           ),
       _activeComputed = active,
       _unreadComputed = unreadComputed,
       super(
         id: row.id,
         createdAt: row.createdAt,
         updatedAt: row.updatedAt,
         pending: row.pending,
         archivedAt: row.archivedAt,
         title: row.title,
         topOrder: row.topOrder,
         order: row.order,
         pomodoro: row.pomodoro,
         color: row.color,
         key: row.key,
         root: row.root,
         path: row.path,
         createdBy: row.createdBy,
         unread: row.unread,
       ) {
    if (!draft) {
      parent?._addChild(this);
    }
  }

  static ThemeColor _computeDisplayColor({
    PriorityAncestryData? ancestry,
    Priority? parent,
    required bool isRoot,
  }) {
    // If we have ancestry data, walk from last (parent) to first (root)
    if (ancestry != null) {
      final colors = (jsonDecode(ancestry.colors) as List)
          .map((e) => e as int?)
          .toList();
      // Walk from parent (last) to root (first)
      for (int i = colors.length - 1; i >= 0; i--) {
        if (colors[i] != null) {
          return ThemeColor(colors[i]!);
        }
      }
    } else if (parent != null) {
      // Use parent's displayColor
      return parent.displayColor;
    }
    return const ThemeColor.defaultColor();
  }

  static const separator = ' › ';

  List<PriorityAncestor> ancestors({
    Priority? context,
    bool includeSelf = false,
  }) {
    final ancestors = [
      ..._ancestors,
      if (includeSelf)
        PriorityAncestor(id: id, title: title, color: displayColor.index),
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

  String? ancestorsLabel({Priority? context}) {
    final ancestors = this.ancestors(context: context);
    if (ancestors.isEmpty) {
      return null;
    }
    return (ancestors
            .map((a) => a.title)
            .toList()
            .expand((p) => [p, separator])
            .toList()
          ..removeLast())
        .join();
  }

  /// Get the effective topOrder for sorting, considering both this priority's
  /// topOrder and the minimum topOrder from its ancestry.
  /// Returns the minimum (earliest) value, as lower Order values sort first.
  Order? get effectiveTopOrder {
    // If both exist, return the minimum (earliest)
    if (topOrder != null && minAncestorTopOrder != null) {
      return topOrder!.value < minAncestorTopOrder!.value
          ? topOrder
          : minAncestorTopOrder;
    }
    // Return whichever one exists, or null if neither exists
    return topOrder ?? minAncestorTopOrder;
  }

  final Priority? parent;
  PriorityId? get parentId => parent?.id ?? _ancestors.lastOrNull?.id;
  List<Priority> children;
  final List<PriorityAncestor> _ancestors;
  final Order? minAncestorTopOrder;
  final ThemeColor displayColor;

  /// The original path from the database, used to detect parent changes.
  /// Null for newly created priorities that haven't been saved yet.
  final Path? _originalPath;

  /// Whether this priority is a draft (not added to parent's children list).
  /// This is an in-memory property only, not persisted to the database.
  final bool draft;

  /// Computed active status from query (true if priority has active activities).
  /// Falls back to false if not computed.
  final bool? _activeComputed;

  /// Computed unread status from query (considers local overrides).
  /// Falls back to row's unread value if not computed.
  final bool? _unreadComputed;

  /// Returns true if this priority has active activities.
  bool get active => _activeComputed ?? false;

  /// Returns true if this priority has unread activities (considering local overrides).
  /// Falls back to the row's unread value if not computed.
  @override
  bool get unread => _unreadComputed ?? super.unread;

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

  Future<void> delete() async {
    await copyWith(archivedAt: Value(DateTime.now())).save();
  }

  @override
  Priority copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    String? title,
    Path? path,
    Uuid? createdBy,
    Value<Order?> topOrder = const Value.absent(),
    Order? order,
    Value<Duration?> pomodoro = const Value.absent(),
    Value<ThemeColor?> color = const Value.absent(),
    Value<String?> key = const Value.absent(),
    bool? root,
    Priority? parent,
    Value<int?> pending = const Value.absent(),
    bool? unread,
    bool? draft,
  }) {
    final newDraft = draft ?? this.draft;
    final currentParent = parent ?? this.parent;

    // Handle draft transitions
    if (draft != null && draft != this.draft && currentParent != null) {
      if (draft == true && !this.draft) {
        // Transitioning from non-draft to draft: remove from parent's children
        _removeFromParent(currentParent);
      }
      // Transitioning from draft to non-draft is handled by fromStore constructor
    }

    return Priority.fromStore(
      super.copyWith(
        id: id,
        createdBy: createdBy,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: DateTime.now(),
        pending: pending,
        archivedAt: archivedAt,
        title: title ?? this.title,
        path: path ?? this.path,
        topOrder: topOrder,
        order: order,
        pomodoro: pomodoro,
        color: color,
        key: key,
      ),
      parent: currentParent,
      children: children,
      draft: newDraft,
      ancestors: _ancestors,
      minAncestorTopOrder: minAncestorTopOrder,
      originalPath: _originalPath,
    );
  }

  void _removeFromParent(Priority parent) {
    parent.children = parent.children.where((child) => child.id != id).toList();
  }

  void _addChild(Priority child) {
    children = List<Priority>.from(
      children,
    ).replaceSorted(child, (a, b) => a.id == b.id);
  }

  bool isParent(Priority other) => path.isParent(other.path);
  List<Priority> get peers => parent?.children ?? [];

  /// Compute what the path should be based on the current parent.
  /// Preserves the priority's own label (last segment of path).
  Path _computePathFromParent() {
    // Extract this priority's label (last segment of path)
    final segments = path.value.split('.');
    final label = segments.last;

    // Compute new path based on parent
    if (parent == null) {
      // Moving to root is never allowed. If parent is null, it means the
      // in-memory parent field isn't populated, so keep the original path.
      return _originalPath ?? path;
    } else {
      // Moving to a parent - combine parent path + label
      return Path('${parent!.path.value}.$label');
    }
  }

  /// Check if the parent has changed since the priority was loaded from the database.
  bool _hasParentChanged() {
    // New priorities don't have an original path yet
    if (_originalPath == null) return false;

    // Compare original path with what the path should be based on current parent
    final computedPath = _computePathFromParent();
    return _originalPath!.value != computedPath.value;
  }

  /// Validate that moving to the new parent won't create a circular reference.
  /// Throws an exception if the new parent is a descendant of this priority.
  void _validateNoCircularReference(Path newPath) {
    if (_originalPath == null) {
      return; // New priorities can't have circular refs
    }

    // Check if the new path would make this priority its own descendant
    // This happens if the new parent path starts with the original path
    if (parent != null && _originalPath!.isParent(parent!.path)) {
      throw ArgumentError(
        'Cannot move priority to be its own descendant. '
        'Original path: ${_originalPath!.value}, '
        'New parent path: ${parent!.path.value}',
      );
    }
  }

  /// Find all descendants of a priority with the given path.
  /// Returns all priorities whose path starts with the given path (excluding the priority itself).
  Future<List<Priority>> _findDescendants(Path ancestorPath) async {
    final query = Store.get.select(table)
      ..where((t) => t.path.like('${ancestorPath.value}.%'));
    return query.map(Priority.fromStore).get();
  }

  /// Update paths when a priority is moved to a new parent.
  /// This handles updating both this priority and all its descendants.
  Future<void> _updatePathsForMove() async {
    final oldPath = _originalPath!;
    final newPath = _computePathFromParent();

    // Validate that non-root priorities cannot be moved to root level
    if (!root && newPath.isRoot) {
      throw ArgumentError(
        'Cannot move priority to root level. '
        'Only the priority created with root=true can have a root-level path. '
        'Attempted to change path from "${oldPath.value}" to "${newPath.value}".',
      );
    }

    // Validate no circular reference
    _validateNoCircularReference(newPath);

    // Find all descendants
    final descendants = await _findDescendants(oldPath);

    // Update all descendant paths
    for (final descendant in descendants) {
      final updatedPath = descendant.path.replacePrefix(oldPath, newPath);
      final updatedDescendant = descendant.copyWith(path: updatedPath);
      await Store.get.save(
        table,
        updatedDescendant.toCompanion(false),
        PrioritiesBase(),
      );
    }

    // Update this priority's path
    final updatedPriority = copyWith(path: newPath);
    await Store.get.save(
      table,
      updatedPriority.toCompanion(false),
      PrioritiesBase(),
    );
  }

  Future<Priority> save() async {
    if (draft) {
      // If this is a draft, create a non-draft copy and save it
      final nonDraft = copyWith(draft: false);
      await Store.get.save(
        table,
        nonDraft.toCompanion(false),
        PrioritiesBase(),
      );
      return nonDraft;
    } else {
      // Check if parent has changed and update paths if needed
      if (_hasParentChanged()) {
        await _updatePathsForMove();
        // Return updated priority with new path
        return copyWith(path: _computePathFromParent());
      } else {
        // No parent change, save normally
        await Store.get.save(table, toCompanion(false), PrioritiesBase());
        return this;
      }
    }
  }

  @override
  int compareTo(Priority other) {
    // Get effective topOrder (considering ancestry) for both priorities
    final thisEffectiveOrder = effectiveTopOrder;
    final otherEffectiveOrder = other.effectiveTopOrder;

    // Sort by effective topOrder if both have it
    if (thisEffectiveOrder != null && otherEffectiveOrder != null) {
      final orderCompare = thisEffectiveOrder.value.compareTo(
        otherEffectiveOrder.value,
      );
      if (orderCompare != 0) return orderCompare;
    }

    // If only one has effective topOrder, that one comes first
    if (thisEffectiveOrder != null && otherEffectiveOrder == null) return -1;
    if (thisEffectiveOrder == null && otherEffectiveOrder != null) return 1;

    // For peers (same parent), sort by order
    if (parent?.id == other.parent?.id) {
      final orderCompare = order.value.compareTo(other.order.value);
      if (orderCompare != 0) return orderCompare;
    }

    // Fall back to createdAt
    return createdAt.compareTo(other.createdAt);
  }
}

enum PriorityPendingSync {
  /// Full priority data changed
  full(2);

  const PriorityPendingSync(this.value);
  final int value;
}
