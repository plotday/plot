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
  TextColumn get doOn => text().nullable().map(const DateConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();
  TextColumn get eventSeries => text().nullable()();
  TextColumn get title => text().nullable()();
  TextColumn get tags => text().nullable().map(const ActivityTagsConverter())();
  TextColumn get tagsUpdated =>
      text().nullable().map(const TagUpdatesConverter())();
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase()
    : super(
        table: 'activity_x',
        name: "activities",
        order: 'day',
        upsertAsUpdate: true,
      );

  @override
  Insertable<ActivityRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    return ActivityRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    // The upsert trigger (handle_activity_x_upsert) handles our tags_updated format
    if (json['tags_updated'] != null) {
      json['tags'] = json['tags_updated'];
    } else {
      json.remove('tags');
    }
    json.remove('tags_updated');
    return json;
  }
}

enum ActivityOrder { sorted, nested, recent, reverse }

class Activity extends ActivityRow implements Comparable<Activity> {
  static $ActivitiesTable get table => Store.get.activities;

  static Future<bool> push() async {
    // Record timestamp before starting push to avoid race conditions
    final pushStartTime = DateTime.now();

    // Perform the actual push
    final success = await Store.get.push(table, ActivitiesBase());

    // If push was successful, clear tagsUpdated for all activities that were pushed
    if (success) {
      await _clearTagsUpdatedAfterPush(pushStartTime);
    }

    return success;
  }

  static Future<void> _clearTagsUpdatedAfterPush(DateTime pushStartTime) async {
    // Clear tagsUpdated for all activities that were part of the successful push
    // Only clear for activities with non-null tagsUpdated and updatedAt <= pushStartTime
    await (Store.get.update(table)..where(
          (t) =>
              t.tagsUpdated.isNotNull() &
              t.updatedAt.isSmallerOrEqualValue(pushStartTime),
        ))
        .write(const ActivitiesCompanion(tagsUpdated: Value(null)));
  }

  static Future<bool> pull() async {
    return await Store.get.pull(PullType.all, table, ActivitiesBase());
  }

  static Map<Priority, List<Activity>> prioritize(List<Activity> activities) {
    final Map<Priority, List<Activity>> activitiesByPriority = {};
    for (final activity in activities) {
      activitiesByPriority
          .putIfAbsent(activity.priority, () => [])
          .add(activity);
    }

    // Create list of priority groups ordered by priority order property
    final Map<Priority, List<Activity>> sortedActivitiesByPriority = {};
    final priorities = activitiesByPriority.keys.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final priority in priorities) {
      final priorityActivities = activitiesByPriority[priority]!;
      // Sort activities within each priority group (by order property)
      priorityActivities.sort();
      sortedActivitiesByPriority[priority] = priorityActivities;
    }

    return sortedActivitiesByPriority;
  }

  static Future<List<Activity>> get({
    DateRange? range,
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    Path? path,
    int? depth,
    bool? deleted = false,
    String? search,
    bool self = true,
    ActivityOrder order = ActivityOrder.sorted,
    List<Tag>? filter,
  }) async {
    final activities = await _get(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      path: path,
      depth: depth,
      deleted: deleted,
      order: order,
      search: search,
      self: self,
      filter: filter,
    ).get();

    return _mapAll(activities, deleted: deleted);
  }

  static Stream<List<Activity>> watch({
    DateRange? range,
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    Path? path,
    int? depth,
    bool? deleted = false,
    String? search,
    bool self = true,
    ActivityOrder order = ActivityOrder.sorted,
    List<Tag>? filter,
  }) {
    return _get(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      path: path,
      depth: depth,
      deleted: deleted,
      order: order,
      search: search,
      self: self,
      filter: filter,
    ).watch().asyncMap(_mapAll);
  }

  static Future<List<Activity>> _mapAll(
    List<ActivityRow> activities, {
    bool? deleted = false,
  }) async {
    final priorities = await Priority.get(
      // If we're getting deleted activities, the priorities might be deleted, too
      deleted: deleted == false ? false : null,
    );
    final priorityMap = Priority.asMap(priorities);

    return activities
        .map((activity) => (activity, priorityMap[activity.priorityId]))
        .where((values) => values.$2 != null)
        .map((values) => Activity.fromStore(values.$1, priority: values.$2!))
        .toList();
  }

  static Future<Activity> _mapOne(
    List<ActivityRow> activityRows, {
    Uuid? id,
  }) async {
    final priority = await Priority.getOne(activityRows.first.priorityId);
    final activities = activityRows
        .map((row) => Activity.fromStore(row, priority: priority))
        .toList();
    if (activities.length == 1 && id == null) {
      return activities.first;
    }
    return _asNested(activities, id: id).first;
  }

  static Future<Activity> getOne(
    ActivityId id, {
    int? depth = 0,
    bool getParent = true,
  }) async {
    final activityRows = await _get(
      id: id,
      depth: depth,
      deleted: null,
      getParent: getParent,
      order: ActivityOrder.nested,
    ).get();
    return await _mapOne(activityRows, id: id);
  }

  static Stream<Activity> watchOne(
    ActivityId id, {
    int? depth = 0,
    bool getParent = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      deleted: null,
      getParent: getParent,
      order: ActivityOrder.nested,
    ).watch().asyncMap(_mapOne);
  }

  static Stream<(Date?, Date?)?> watchRange({
    Priority? context,
    bool? deleted = false,
  }) {
    return Stream.fromFuture(
      _getRange(context: context, deleted: deleted),
    ).asyncExpand((range) async* {
      yield range;

      // Watch for changes by monitoring the underlying tables
      await for (final _ in Store.get.select(table).watch()) {
        yield await _getRange(context: context, deleted: deleted);
      }
    });
  }

  static Future<(Date?, Date?)?> _getRange({
    Priority? context,
    bool? deleted = false,
  }) async {
    // Build base query with filters (same as used in Activity._get)
    final base = Store.get.alias(Store.get.activities, 'base');
    var firstQuery = Store.get.select(base);
    var lastQuery = Store.get.select(base);

    // Apply deleted filter
    if (deleted != null) {
      final deletedFilter = deleted
          ? (Activities t) => t.deletedAt.isNotNull()
          : (Activities t) => t.deletedAt.isNull();
      firstQuery = firstQuery..where(deletedFilter);
      lastQuery = lastQuery..where(deletedFilter);
    }

    // Apply context filter if provided
    if (context != null) {
      final contextJoin = [
        innerJoin(
          Store.get.priorities,
          Store.get.priorities.id.equalsExp(base.priorityId) &
              (Store.get.priorities.path.equalsValue(context.path) |
                  Store.get.priorities.path.likeExp(
                    Constant('${context.path}%'),
                  )),
        ),
      ];

      final firstJoinedQuery = firstQuery.join(contextJoin);
      final lastJoinedQuery = lastQuery.join(contextJoin);

      // Execute parallel queries for earliest and latest activities with context filter
      final results = await Future.wait([
        (firstJoinedQuery
              ..orderBy([
                OrderingTerm(
                  expression: base.createdAt,
                  mode: OrderingMode.asc,
                ),
              ])
              ..limit(1))
            .get(),
        (lastJoinedQuery
              ..orderBy([
                OrderingTerm(
                  expression: base.createdAt,
                  mode: OrderingMode.desc,
                ),
              ])
              ..limit(1))
            .get(),
      ]);

      final firstActivities = results[0];
      final lastActivities = results[1];

      if (firstActivities.isEmpty && lastActivities.isEmpty) {
        return null;
      }

      final earliest = firstActivities.isNotEmpty
          ? firstActivities.first.readTable(base).createdAt.toDate()
          : null;
      final latest = lastActivities.isNotEmpty
          ? lastActivities.first.readTable(base).createdAt.toDate()
          : null;

      return (earliest, latest);
    }

    // Execute parallel queries for earliest and latest activities by createdAt
    final results = await Future.wait([
      (firstQuery
            ..orderBy([
              (t) =>
                  OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
            ])
            ..limit(1))
          .get(),
      (lastQuery
            ..orderBy([
              (t) => OrderingTerm(
                expression: t.createdAt,
                mode: OrderingMode.desc,
              ),
            ])
            ..limit(1))
          .get(),
    ]);

    final firstActivities = results[0];
    final lastActivities = results[1];

    if (firstActivities.isEmpty && lastActivities.isEmpty) {
      return null;
    }

    final earliest = firstActivities.isNotEmpty
        ? firstActivities.first.createdAt.toDate()
        : null;
    final latest = lastActivities.isNotEmpty
        ? lastActivities.first.createdAt.toDate()
        : null;

    return (earliest, latest);
  }

  /// Find the next activity after [fromDate]
  /// [offset] specifies how many activities to skip (0 = first, 1 = second, etc.)
  static Future<Activity?> next(
    Date fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) async {
    if (fromDate == Date.latest) {
      // If fromDate is the latest date, there are no more activities
      return null;
    }
    // Use a range from the day after fromDate to far in the future
    final startDate = fromDate.addDays(1);
    final endDate = Date.latest;
    final range = DateRangeCustom(startDate, endDate);

    // Get activities in this range using the existing _get method
    final rows = await _get(
      range: range,
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.sorted,
      limit: 1,
      offset: offset,
    ).get();
    if (rows.isEmpty) {
      return null;
    }
    return _mapOne(rows);
  }

  /// Find the previous activity before [fromDate]
  /// [offset] specifies how many activities to skip (0 = first, 1 = second, etc.)
  static Future<Activity?> previous(
    Date fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) async {
    if (fromDate == Date.earliest) {
      // If fromDate is the earliest date, there are no previous activities
      return null;
    }
    // Use a range from far in the past to the day before fromDate
    final startDate = Date.earliest;
    final endDate = fromDate;
    final range = DateRangeCustom(startDate, endDate);

    // Get activities in reverse order (latest first) using the existing _get method
    final rows = await _get(
      range: range,
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.reverse,
      limit: 1,
      offset: offset,
    ).get();
    if (rows.isEmpty) {
      return null;
    }
    return _mapOne(rows);
  }

  static MultiSelectable<ActivityRow> _get({
    DateRange? range,

    /* Selectors */
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    Path? path,

    /* Filters */
    int? depth,
    bool self = true,
    bool? deleted = false,
    String? search,
    List<Tag>? filter,

    /* Sorting */
    ActivityOrder order = ActivityOrder.sorted,

    /* Pagination */
    int? limit,
    int? offset,

    /* Augmentation */
    bool getParent = true,
  }) {
    // Create a copy of filter to avoid mutating the original
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;

    if (mutableFilter?.remove(Tag.archived) == true) {
      deleted = true;
    }
    final doNow = mutableFilter?.remove(Tag.doNow) == true;
    final scheduled = mutableFilter?.remove(Tag.doLater) == true;
    final done = mutableFilter?.remove(Tag.done) == true;

    final includeDescendants = path == null && (depth == null || depth > 0);

    final base = Store.get.alias(
      Store.get.activities,
      includeDescendants ? 'base' : 'a',
    );
    final startingQuery = Store.get.select(base);
    if (id != null) {
      startingQuery.where((t) => t.id.equalsValue(id));
    }
    if (priorityId != null) {
      startingQuery.where((t) => t.priorityId.equalsValue(priorityId));
    }
    if (path != null) {
      if (depth == 0) {
        startingQuery.where((t) => t.path.equalsValue(path));
      } else {
        startingQuery.where((t) => t.path.likeExp(Constant('$path%')));
      }
    }
    if (id == null && priorityId == null && path == null && depth == 0) {
      startingQuery.where((t) => t.path.likeExp(Constant('%.%')).not());
    }

    var a = includeDescendants
        ? Store.get.alias(Store.get.activities, 'a')
        : base;
    var query = startingQuery.join([
      if (includeDescendants)
        innerJoin(
          a,
          a.path.likeExp(base.path + Constant('%')) |
              (getParent
                  // This gets all parents and could be optimized to get just the direct parent.
                  ? base.path.likeExp(a.path + Constant('%'))
                  : Constant(false)),
        ),
    ]);
    if (depth != null && depth > 0) {
      query.where(
        CustomExpression<int>("""
            LENGTH(a.path) - LENGTH(REPLACE(a.path, '.', '')) -
            (CASE WHEN a.path IS NULL THEN 0 ELSE LENGTH(a.path) - LENGTH(REPLACE(a.path, '.', '')) END)
          """).isSmallerOrEqualValue(depth),
      );
    }

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

    // Add tag filtering if filter list is provided
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      // For each tag in the filter, we need to check if the tag exists in the JSON tags field
      // Use JSON operators to check if each tag ID exists as a key in the tags JSON object
      for (final tag in mutableFilter) {
        query.where(
          CustomExpression<bool>(
            'JSON_EXTRACT(a.tags, \'\$.${tag.id}\') IS NOT NULL',
          ),
        );
      }
    }

    // Add activity path filtering if path is provided
    if (path != null) {
      query.where(
        a.path.equalsValue(path) | a.path.likeExp(Constant('$path.%')),
      );
    }

    final nextEvent = Store.get.alias(Store.get.activityNextEvent, 'nextEvent');
    query = query.join([
      leftOuterJoin(nextEvent, nextEvent.activityId.equalsExp(a.id)),
    ]);

    if (doNow) {
      query.where(
        a.doOn.isSmallerOrEqualValue(Date.today().toString()) &
            a.doneAt.isNull(),
      );
    }
    if (scheduled) {
      query.where(
        a.doOn.isBiggerThanValue(Date.today().toString()) & a.doneAt.isNull(),
      );
    }
    if (done) {
      query.where(a.doneAt.isNotNull());
    }
    if (deleted != null) {
      query.where(deleted ? a.deletedAt.isNotNull() : a.deletedAt.isNull());
    }
    if (search?.isNotEmpty == true) {
      query.where(a.title.like('%$search%') | a.note.like('%$search%'));
    }
    if (self == false) {
      if (id != null) {
        query.where(a.id.equalsValue(id).not());
      }
      if (path != null) {
        query.where(a.path.equalsValue(path).not());
      }
    }

    // Add range filtering based on createdAt, doOn, and doneAt fields
    if (range != null) {
      // Filter activities that fall within the date range based on:
      // 1. createdAt - when the activity was created
      // 2. doOn - when the activity is scheduled (if scheduled)
      //    - Past doOn dates are treated as current date
      // 3. doneAt - when the activity was completed (if completed)
      final rangeStart = range.start.toDateTime();
      final rangeEnd = range.end.toDateTime();
      final today = Date.today().toString();

      query.where(
        // Activity was created within the range
        (a.createdAt.isBiggerOrEqualValue(rangeStart) &
                a.createdAt.isSmallerThanValue(rangeEnd)) |
            // Activity is scheduled within the range (future dates)
            (a.doOn.isNotNull() &
                a.doOn.isBiggerOrEqualValue(today) &
                a.doOn.isBiggerOrEqualValue(range.start.toString()) &
                a.doOn.isSmallerThanValue(range.end.toString())) |
            // Activity is scheduled in the past (treat as current date)
            (a.doOn.isNotNull() &
                a.doOn.isSmallerThanValue(today) &
                Constant(today).isBiggerOrEqualValue(range.start.toString()) &
                Constant(today).isSmallerThanValue(range.end.toString())) |
            // Activity was completed within the range
            (a.doneAt.isNotNull() &
                a.doneAt.isBiggerOrEqualValue(rangeStart) &
                a.doneAt.isSmallerThanValue(rangeEnd)),
      );
    }

    if (limit != null) {
      query.limit(limit, offset: offset);
    }

    switch (order) {
      case ActivityOrder.sorted:
        query.orderBy([
          // Active
          OrderingTerm.asc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  a.doOn.isSmallerOrEqual(Constant(Date.today().toString())) &
                      a.doneAt.isNull(),
                  then: a.doOn,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.asc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  a.doOn.isSmallerOrEqual(Constant(Date.today().toString())) &
                      a.doneAt.isNull(),
                  then: a.order,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.asc(a.order),
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
      case ActivityOrder.reverse:
        // reverse order of sorted - latest items first
        query.orderBy([
          // Active (reverse order)
          OrderingTerm.asc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  a.doOn.isSmallerOrEqual(Constant(Date.today().toString())) &
                      a.doneAt.isNull(),
                  then: a.doOn,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.desc(
            CaseWhenExpression(
              cases: [
                CaseWhen(
                  a.doOn.isSmallerOrEqual(Constant(Date.today().toString())) &
                      a.doneAt.isNull(),
                  then: a.order,
                ),
              ],
              orElse: const Constant(null),
            ),
          ),
          OrderingTerm.desc(a.order),
        ]);
        break;
    }

    return query.map((row) => row.readTable(a));
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
    this.parentEvent,
    required this.priority,
    super.note,
    super.title,
    super.draft = false,
    super.private = false,
    super.eventSeries,
  }) : children = [],
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         priorityId: priority.id,
         order: order ?? Order.first(),
         path: Path.generate(parent: parent?.path ?? parentEvent?.path),
         tagsUpdated: null,
       ) {
    parent?._addChild(this);
  }

  Activity.fromStore(
    ActivityRow row, {
    this.parent,
    this.parentEvent,
    required this.priority,
    List<Activity>? children,
  }) : children = children ?? [],
       super(
         id: row.id,
         priorityId: row.priorityId,
         createdAt: row.createdAt,
         updatedAt: row.updatedAt,
         deletedAt: row.deletedAt,
         draft: row.draft,
         note: row.note,
         title: row.title,
         order: row.order,
         path: row.path,
         private: row.private,
         createdBy: row.createdBy,
         doOn: row.doOn,
         doneAt: row.doneAt,
         eventSeries: row.eventSeries,
         tags: row.tags,
         tagsUpdated: row.tagsUpdated,
       ) {
    parent?._addChild(this);
  }

  // Update the title getter to use the stored title or fall back to deriving from note
  String get displayTitle =>
      title ?? note?.split("\n").first.removeMarkdown().trim() ?? 'Untitled';

  static String noteToTitle(String markdown) {
    final firstLine = markdown.split("\n").first.removeMarkdown().trim();
    if (firstLine.length > 40) {
      return "${firstLine.substring(0, 40)}…";
    }
    return firstLine;
  }

  static const separator = ' › ';

  final Activity? parent;
  final Event? parentEvent;
  final Priority priority;
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
      doOn: Value(doOn ?? other.doOn),
      doneAt: Value(doneAt ?? other.doneAt),
      private: private || other.private,
      eventSeries: Value(eventSeries ?? other.eventSeries),
      title: Value(title ?? other.title),
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
    Value<Date?> doOn = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Value<String?> title = const Value.absent(),
    Activity? parent,
    Event? parentEvent,
    Priority? priority,
    Value<String?> eventSeries = const Value.absent(),
    Value<Map<Tag, List<Uuid>>?> tags = const Value.absent(),
    Value<Map<int, bool>?> tagsUpdated = const Value.absent(),
  }) {
    final publish = this.draft && draft == false;
    if (doOn.present && doOn.value != null) {
      doneAt = const Value(null);
    } else if (doneAt.present) {
      doOn = const Value(null);
    }
    if (publish ||
        (doOn.present && doOn.value != this.doOn) ||
        (doneAt.present && doneAt.value != null)) {
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
        doOn: doOn,
        doneAt: doneAt,
        note: note,
        title: title,
        eventSeries: eventSeries,
        tags: tags,
        tagsUpdated: tagsUpdated,
      ),
      parent: parent ?? this.parent,
      parentEvent: parentEvent ?? this.parentEvent,
      priority: priority ?? this.priority,
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

  Date get at => doOn ?? doneAt?.toDate() ?? createdAt.toDate();

  // For the user, doOn can never be in the past
  @override
  Date? get doOn =>
      _doOn != null && _doOn! < Date.today() ? Date.today() : _doOn;

  Date? get _doOn => super.doOn;

  bool get doNow {
    return !done && _doOn != null && _doOn! <= Date.today();
  }

  bool get doLater {
    return _doOn != null && _doOn! > Date.today();
  }

  bool get scheduled {
    return _doOn != null && doneAt == null;
  }

  bool get done => doneAt != null;

  bool hasTag(Tag tag) {
    switch (tag) {
      case Tag.archived:
        return deletedAt != null;
      case Tag.doNow:
        return doNow;
      case Tag.done:
        return done;
      case Tag.doLater:
        return doLater;
      default:
        final currentTags = tags ?? {};
        final users = currentTags[tag];
        return users != null && users.isNotEmpty;
    }
  }

  Activity toggleTag(Tag tag) {
    // Handle computed tags
    switch (tag) {
      case Tag.archived:
        return copyWith(
          deletedAt: Value(deletedAt == null ? DateTime.now() : null),
        );
      case Tag.doNow:
        return copyWith(
          doOn: Value(doNow ? null : Date.today()),
          doneAt: const Value(null),
        );
      case Tag.done:
        return copyWith(
          doneAt: Value(done ? null : DateTime.now()),
          doOn: const Value(null),
        );
      case Tag.doLater:
        return copyWith(
          doOn: Value(scheduled ? null : Date.today().addDays(1)),
          doneAt: const Value(null),
        );
      default:
        break;
    }

    final currentTags = Map<Tag, List<Uuid>>.from(tags ?? {});
    final currentUser = Base.userId;

    // Get current users for this tag
    final currentUsers = List<Uuid>.from(currentTags[tag] ?? []);

    bool isAdding = false;

    if (tag.type == TagType.toggle) {
      // Toggle behavior: add if not present, remove if present
      if (currentUsers.isEmpty) {
        // Add user to tag
        currentUsers.add(currentUser);
        currentTags[tag] = currentUsers;
        isAdding = true; // Adding the tag
      } else {
        // Remove tag
        currentTags.remove(tag);
        isAdding = false; // Removing the tag
      }
    } else if (tag.type == TagType.count) {
      // Count behavior: add/remove current user while preserving other users
      if (currentUsers.contains(currentUser)) {
        // Remove current user from tag
        currentUsers.remove(currentUser);
        if (currentUsers.isEmpty) {
          currentTags.remove(tag);
        } else {
          currentTags[tag] = currentUsers;
        }
        isAdding = false; // Removing the user's count
      } else {
        // Add current user to tag (increment count)
        currentUsers.add(currentUser);
        currentTags[tag] = currentUsers;
        isAdding = true; // Adding the user's count
      }
    }

    // Update the tag updates map
    final currentTagUpdates = Map<int, bool>.from(tagsUpdated ?? {});
    currentTagUpdates[tag.id] = isAdding;
    log.info(
      "Toggling tag ${tag.name} (${tag.type}) to $isAdding ($currentTags)",
    );

    return copyWith(
      tags: Value(currentTags.isEmpty ? null : currentTags),
      tagsUpdated: Value(currentTagUpdates),
    );
  }

  Future<void> save() async {
    await Store.get.save(table, toCompanion(false), ActivitiesBase());

    // Generate a title on the first non-draft save
    if (title == null && !draft) {
      try {
        final generatedTitle = await generateTitle();
        log.info("Generated title: $generatedTitle");
        await copyWith(title: Value(generatedTitle)).save();
      } catch (e, st) {
        log.warning("Failed to save generated title", e, st);
      }
    }
  }

  @override
  int compareTo(Activity other) {
    // If scheduled is true, compare order
    if (scheduled) {
      if (other.scheduled) {
        return order.compareTo(other.order);
      } else {
        // Scheduled activities come after
        return 1;
      }
    } else if (other.scheduled) {
      // Other activity is scheduled, this one is not
      return -1;
    }

    // Otherwise, compare doneAt ?? createdAt
    final thisTime = doneAt ?? createdAt;
    final otherTime = other.doneAt ?? other.createdAt;
    return thisTime.compareTo(otherTime);
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
