part of 'store.dart';

typedef ActivityId = Uuid;

@DataClassName('ActivityRow')
class Activities extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  BlobColumn get priorityId => blob().map(const UuidConverter())();
  TextColumn get path => text().map(const PathConverter())();
  BlobColumn get createdBy => blob().map(const UuidConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  TextColumn get doAt => text().nullable().map(const DateConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();
  TextColumn get eventSeries => text().nullable()();
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase()
    : super(
        table: 'activity_x',
        name: "activities",
        order: 'order_x',
        upsertAsUpdate: true,
      );

  @override
  Insertable<ActivityRow> fromBase(Map<String, dynamic> json) =>
      ActivityRow.fromJson(json);
}

enum ActivityOrder { sorted, nested, recent }

class Activity extends ActivityRow implements Comparable<Activity> {
  static $ActivitiesTable get table => Store.get.activities;

  static Future<void> push() => Store.get.push(table, ActivitiesBase());
  static Future<bool> pull() async {
    return await Store.get.pull(PullType.all, table, ActivitiesBase());
  }

  static Future<List<Activity>> get({
    DateRange? range,
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    Path? path,
    int? depth,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    String? search,
    bool self = true,
    ActivityOrder order = ActivityOrder.sorted,
  }) async {
    return _get(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
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

  static Stream<List<Activity>> watch({
    DateRange? range,
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    Path? path,
    int? depth,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    String? search,
    bool self = true,
    ActivityOrder order = ActivityOrder.sorted,
  }) {
    return _get(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
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

  static Future<Activity> getOne(
    ActivityId id, {
    int? depth = 0,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    bool getParent = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      getParent: getParent,
      order: ActivityOrder.nested,
    ).get().then((activities) => _asNested(activities, id: id).first);
  }

  static Stream<Activity> watchOne(
    ActivityId id, {
    int? depth = 0,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    bool getParent = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      pinned: pinned,
      active: active,
      deleted: deleted,
      getParent: getParent,
      order: ActivityOrder.nested,
    ).watch().map((activities) => _asNested(activities, id: id).first);
  }

  static Stream<(Date?, Date?)?> watchRange({
    Priority? context,
    bool? deleted = false,
  }) {
    // Use the existing _get method to leverage its filtering logic
    final activities = _get(
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.sorted,
    ).watch();

    return activities.map((activityList) {
      if (activityList.isEmpty) {
        return null;
      }

      Date? earliest;
      Date? latest;
      final today = Date.today();

      for (final activity in activityList) {
        // Determine the effective date for this activity
        Date effectiveDate;
        if (activity.doneAt != null) {
          effectiveDate = activity.doneAt!.toDate();
        } else if (activity.doAt != null) {
          final doAtDate = activity.doAt!;
          // Treat past doAt dates as today
          effectiveDate = doAtDate.isBefore(today) ? today : doAtDate;
        } else {
          effectiveDate = activity.createdAt.toDate();
        }

        // Update earliest and latest
        if (earliest == null || effectiveDate.isBefore(earliest)) {
          earliest = effectiveDate;
        }
        if (latest == null || effectiveDate.isAfter(latest)) {
          latest = effectiveDate;
        }
      }

      return (earliest, latest);
    });
  }

  static MultiSelectable<Activity> _get({
    DateRange? range,

    /* Selectors */
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    Path? path,

    /* Filters */
    int? depth,
    bool self = true,
    bool? pinned,
    bool? active,
    bool? deleted = false,
    String? search,

    /* Sorting */
    ActivityOrder order = ActivityOrder.sorted,

    /* Augmentation */
    bool getParent = true,
  }) {
    final base = Store.get.alias(Store.get.activities, 'base');
    final startingQuery = Store.get.select(base);
    if (id != null) {
      startingQuery.where((t) => t.id.equalsValue(id));
    }
    if (priorityId != null) {
      startingQuery.where((t) => t.priorityId.equalsValue(priorityId));
    }
    if (path != null) {
      startingQuery.where((t) => t.path.equalsValue(path));
    }

    final a = Store.get.alias(Store.get.activities, 'a');
    var query = startingQuery.join([
      innerJoin(
        a,
        id == null && path == null && priorityId == null
            ? base.id.equalsExp(a.id)
            : (priorityId != null
                      ? a.priorityId.equalsValue(priorityId)
                      : Constant(true)) &
                  (path != null
                      ? a.path.likeExp(base.path + Constant('%')) &
                            ((getParent
                                    // This gets all parents and could be optimized to get just the direct parent.
                                    ? base.path.likeExp(a.path + Constant('%'))
                                    : Constant(true)) |
                                (a.path.likeExp(base.path + Constant('%')))) &
                            (depth == null
                                ? Constant(true)
                                : CustomExpression<int>("""
    LENGTH(a.path) - LENGTH(REPLACE(a.path, '.', '')) -
    (CASE WHEN base.path IS NULL THEN 0 ELSE LENGTH(base.path) - LENGTH(REPLACE(base.path, '.', '')) END)
    """).isSmallerOrEqualValue(depth))
                      : Constant(true)),
      ),
    ]);

    // Add priority path filtering if priorityPath is provided
    if (priorityPath != null) {
      final p = Store.get.alias(Store.get.priorities, 'p');
      query = query.join([
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) &
              (p.path.equalsValue(priorityPath) |
                  p.path.likeExp(Constant('$priorityPath%'))),
        ),
      ]);
    }

    final nextEvent = Store.get.alias(Store.get.activityNextEvent, 'nextEvent');
    query = query.join([
      leftOuterJoin(nextEvent, nextEvent.activityId.equalsExp(a.id)),
    ]);

    if (active == true) {
      query.where(a.doAt.isNotNull() & a.doneAt.isNull());
    } else if (active == false) {
      query.where(a.doAt.isNull() | a.doneAt.isNotNull());
    }
    if (pinned != null) {
      query.where(a.pinned.equals(pinned));
    }
    if (deleted != null) {
      query.where(deleted ? a.deletedAt.isNotNull() : a.deletedAt.isNull());
    }
    if (search?.isNotEmpty == true) {
      query.where(a.note.like('%$search%'));
    }
    if (self == false) {
      if (id != null) {
        query.where(a.id.equalsValue(id).not());
      }
      if (path != null) {
        query.where(a.path.equalsValue(path).not());
      }
    }

    // Add range filtering based on createdAt, doAt, and doneAt fields
    if (range != null) {
      // Filter activities that fall within the date range based on:
      // 1. createdAt - when the activity was created
      // 2. doAt - when the activity is scheduled (if scheduled)
      //    - Past doAt dates are treated as current date
      // 3. doneAt - when the activity was completed (if completed)
      final rangeStart = range.start.toDateTime();
      final rangeEnd = range.end.toDateTime();
      final today = Date.today().toString();

      query.where(
        // Activity was created within the range
        (a.createdAt.isBiggerOrEqualValue(rangeStart) &
                a.createdAt.isSmallerThanValue(rangeEnd)) |
            // Activity is scheduled within the range (future dates)
            (a.doAt.isNotNull() &
                a.doAt.isBiggerOrEqualValue(today) &
                a.doAt.isBiggerOrEqualValue(range.start.toString()) &
                a.doAt.isSmallerThanValue(range.end.toString())) |
            // Activity is scheduled in the past (treat as current date)
            (a.doAt.isNotNull() &
                a.doAt.isSmallerThanValue(today) &
                Constant(today).isBiggerOrEqualValue(range.start.toString()) &
                Constant(today).isSmallerThanValue(range.end.toString())) |
            // Activity was completed within the range
            (a.doneAt.isNotNull() &
                a.doneAt.isBiggerOrEqualValue(rangeStart) &
                a.doneAt.isSmallerThanValue(rangeEnd)),
      );
    }

    switch (order) {
      case ActivityOrder.sorted:
        query.orderBy([
          // Pinned
          OrderingTerm(expression: a.pinned, mode: OrderingMode.desc),
          // Active
          OrderingTerm.desc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  a.doAt.isSmallerOrEqual(Constant(Date.today().toString())) &
                      a.doneAt.isNull(),
                  then: a.doAt,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.asc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  a.pinned |
                      (a.doAt.isSmallerOrEqual(
                            Constant(Date.today().toString()),
                          ) &
                          a.doneAt.isNull()),
                  then: a.order,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.desc(a.order),
        ]);
        break;
      case ActivityOrder.nested:
        // order by path so parents always precede children
        query.orderBy([OrderingTerm(expression: a.path)]);
        break;
      case ActivityOrder.recent:
        query = query.join([
          leftOuterJoin(
            Store.get.sessions,
            Store.get.sessions.priorityId.equalsExp(a.priorityId),
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

    return query.map((row) => Activity.fromStore(row.readTable(a)));
  }

  /// Transform a flat list in ActivityOrder.nested order to a list of the top-level items with descendants.
  static List<Activity> _asNested(
    List<Activity> activities, {
    ActivityId? id,
    Path? path,
    bool flat = false,
  }) {
    List<Activity> matches = [];
    List<Activity> stack = [];

    for (var activity in activities) {
      if (stack.isNotEmpty && !stack.last.path.isParent(activity.path)) {
        stack.removeWhere((c) => !c.path.isParent(activity.path));
      }

      if (stack.isNotEmpty) {
        activity = activity.copyWith(parent: stack.last);
      }

      if ((id == null && path == null && activity.path.isRoot) ||
          activity.path == path ||
          activity.id == id) {
        matches.add(activity);
        stack.clear();
      } else if (flat) {
        matches.add(activity);
      }

      stack.add(activity);
    }

    matches.sort();
    return matches;
  }

  Future<String> generateTitle() async {
    final response = await api.post("/summary", body: {'body': note});
    return response['title'] as String;
  }

  Activity({
    Order? order,
    this.parent,
    required super.priorityId,
    super.note,
    super.draft = false,
    super.private = false,
    super.pinned = false,
    super.eventSeries,
  }) : children = [],
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         order: order ?? Order.first(),
         path: Path.generate(parent: parent?.path),
       ) {
    parent?._addChild(this);
  }

  Activity.fromStore(ActivityRow row, {this.parent, List<Activity>? children})
    : children = children ?? [],
      super(
        id: row.id,
        priorityId: row.priorityId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        draft: row.draft,
        note: row.note,
        order: row.order,
        path: row.path,
        private: row.private,
        pinned: row.pinned,
        createdBy: row.createdBy,
        doAt: row.doAt,
        doneAt: row.doneAt,
        eventSeries: row.eventSeries,
      ) {
    parent?._addChild(this);
  }

  String get title =>
      note?.split("\n").first.removeMarkdown().trim() ?? 'Untitled';

  static String noteToTitle(String markdown) {
    final firstLine = markdown.split("\n").first.removeMarkdown().trim();
    if (firstLine.length > 40) {
      return "${firstLine.substring(0, 40)}…";
    }
    return firstLine;
  }

  static const separator = ' › ';

  final Activity? parent;
  List<Activity> children;

  List<Activity> descendants() {
    List<Activity> result = [];

    void collectDescendants(Activity activity) {
      for (var child in activity.children) {
        result.add(child);
        collectDescendants(child);
      }
    }

    collectDescendants(this);
    result.sort();
    return result;
  }

  Future<void> delete() => copyWith(deletedAt: Value(DateTime.now())).save();

  Activity merge(Activity other) {
    return copyWith(
      doAt: Value(doAt ?? other.doAt),
      doneAt: Value(doneAt ?? other.doneAt),
      pinned: pinned || other.pinned,
      private: private || other.private,
      eventSeries: Value(eventSeries ?? other.eventSeries),
    );
  }

  @override
  Activity copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    bool? draft,
    Value<DateTime?> deletedAt = const Value.absent(),
    PriorityId? priorityId,
    Path? path,
    Uuid? createdBy,
    Order? order,
    bool? private,
    bool? pinned,
    Value<Date?> doAt = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Activity? parent,
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
    if (publish ||
        (doAt.present && doAt.value != this.doAt) ||
        (doneAt.present && doneAt.value != null) ||
        (pinned != null && pinned != this.pinned)) {
      order ??= Order.first();
    }
    return Activity.fromStore(
      super.copyWith(
        id: id,
        priorityId: priorityId,
        createdBy: createdBy,
        createdAt: publish ? DateTime.now() : this.createdAt,
        updatedAt: DateTime.now(),
        deletedAt: deletedAt,
        draft: draft,
        path: path,
        order: order,
        private: private,
        pinned: pinned,
        doAt: doAt,
        doneAt: doneAt,
        note: note,
        eventSeries: eventSeries,
      ),
      parent: parent ?? this.parent,
      children: children,
    );
  }

  void _addChild(Activity child) {
    children = List<Activity>.from(
      children,
    ).replaceSorted(child, (a, b) => a.id == b.id);
  }

  bool isParent(Activity other) => path.isParent(other.path);
  List<Activity> get peers => parent?.children ?? [];

  DateTime get at => doneAt ?? createdAt;

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
      Store.get.save(table, toCompanion(false), ActivitiesBase());

  @override
  int compareTo(Activity other) {
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
    T Function(T previousValue, Activity activity, int depth) combine,
  ) {
    T foldRecursively(Activity activity, T acc, int depth) {
      acc = combine(acc, activity, depth);

      for (var child in activity.children) {
        acc = foldRecursively(child, acc, depth + 1);
      }

      return acc;
    }

    return foldRecursively(this, initialValue, 0);
  }

  @override
  bool operator ==(Object other) {
    return super == other && children == (other as Activity).children;
  }

  @override
  int get hashCode {
    return Object.hash(super.hashCode, children.hashCode);
  }
}
