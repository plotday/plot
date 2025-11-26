part of 'store.dart';

typedef ActivityId = Uuid;

@DataClassName('ActivityRow')
class Activities extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  BlobColumn get priorityId => blob().map(const UuidConverter())();
  TextColumn get path => text().map(const PathConverter())();
  BlobColumn get authorId => blob().map(const UuidConverter())();
  BlobColumn get assigneeId => blob().nullable().map(const UuidConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  TextColumn get type => text().map(const EnumConverter<ActivityType>())();

  TextColumn get title => text().nullable()();
  TextColumn get note => text().nullable()();

  DateTimeColumn get startAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get endAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get startOn =>
      text().nullable().nullable().map(const DateConverter())();
  TextColumn get endOn =>
      text().nullable().nullable().map(const DateConverter())();
  IntColumn get duration =>
      integer().nullable().map(const IntervalConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();

  TextColumn get recurrenceRule =>
      text().nullable().map(const RecurrenceRuleConverter())();
  TextColumn get recurrenceExdates =>
      text().nullable().map(const DateTimeListConverter())();
  TextColumn get recurrenceDates =>
      text().nullable().map(const DateTimeListConverter())();
  TextColumn get links => text().nullable().map(const LinksConverter())();
  TextColumn get mentions => text().nullable().map(const UuidListConverter())();
  BoolColumn get unread => boolean().withDefault(const Constant(false))();
  BoolColumn get unreadUpdated => boolean().nullable()();
}

class RecurrenceRuleConverter extends TypeConverter<RecurrenceRule?, String?>
    with JsonTypeConverter2<RecurrenceRule?, String?, String?> {
  const RecurrenceRuleConverter();

  @override
  RecurrenceRule? fromSql(String? fromDb) {
    if (fromDb == null || fromDb.isEmpty) {
      return null;
    }
    try {
      return RecurrenceRule.fromString(fromDb);
    } catch (e) {
      // Return null for invalid RRULE strings
      return null;
    }
  }

  @override
  String? toSql(RecurrenceRule? value) => value?.toString();

  @override
  RecurrenceRule? fromJson(String? json) {
    if (json == null || json.isEmpty) {
      return null;
    }
    try {
      // If the JSON doesn't start with "RRULE:", add it
      final ruleString = json.startsWith('RRULE:') ? json : 'RRULE:$json';
      return RecurrenceRule.fromString(ruleString);
    } catch (e) {
      // Return null for invalid RRULE strings
      return null;
    }
  }

  @override
  String? toJson(RecurrenceRule? value) {
    if (value == null) return null;
    final ruleString = value.toString();
    // Remove "RRULE:" prefix for JSON serialization if present
    return ruleString.startsWith('RRULE:')
        ? ruleString.substring(6)
        : ruleString;
  }
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase({this.priorityPath})
    : super(
        table: 'user_activity',
        writeTable: 'activity',
        name: "activities",
        filterName: priorityPath,
        ascending:
            false, // Get latest items first for reverse chronological sync
        limit: 200,
      );

  final String? priorityPath;

  @override
  PostgrestFilterBuilder<T2> filterRange<T2>(
    PostgrestFilterBuilder<T2> query,
    DateTimeRange? range,
  ) {
    if (range == null) return query;
    final dateRange = range.toDateRange();
    query = query.or(
      'range_at.ov."${dateRange.toDb()}",range_on.ov."${dateRange.toDb()}"',
    );
    return query;
  }

  @override
  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    query = super.filter(query); // Apply user_id filter

    // Add priority path filtering if priorityPath is provided
    // Use ltree 'cd' operator (contained in / descendant of)
    if (priorityPath != null) {
      query = query.filter('priority_path', 'cd', priorityPath);
    }

    return query;
  }

  @override
  Insertable<ActivityRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove(
      'user_id',
    ); // Remove user_id from activity_in_range function result

    // Handle the 'at' field from activity_in_range function
    final at = json['at'] != null
        ? DateTimeRange.fromString(json['at'] as String)
        : null;
    json['start_at'] = at?.start?.toDb();
    json['end_at'] = at?.end?.toDb();
    json.remove('at');

    // Handle the 'on' field from activity_in_range function
    final on = json['on'] != null
        ? DateRange.fromString(json['on'] as String)
        : null;
    json['start_on'] = on?.start?.toString();
    json['end_on'] = on?.end?.toString();
    json.remove('on');

    return ActivityRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Convert start_at/end_at to 'at' field for upsert_activity
    final at = json['start_at'] != null || json['end_at'] != null
        ? DateTimeRange(
            json['start_at'] != null
                ? DateTime.parse(json['start_at'] as String)
                : null,
            json['end_at'] != null
                ? DateTime.parse(json['end_at'] as String)
                : null,
          )
        : null;
    json['at'] = at?.toDb();
    json.remove('start_at');
    json.remove('end_at');

    // Convert start_on/end_on to 'on' field for upsert_activity
    final on = json['start_on'] != null || json['end_on'] != null
        ? CustomDateRange(
            json['start_on'] != null
                ? Date.fromString(json['start_on'] as String)
                : null,
            json['end_on'] != null
                ? Date.fromString(json['end_on'] as String)
                : null,
          )
        : null;
    json['on'] = on?.toDb();
    json.remove('start_on');
    json.remove('end_on');

    // Remove author_id - it's set by the database trigger
    json.remove('author_id');

    // Remove unread fields - they are managed separately
    json.remove('unread');
    json.remove('unread_updated');

    return json;
  }
}

enum ActivityOrder { sorted, nested, reverse }

class Activity extends Equatable implements Comparable<Activity> {
  /// Parse mentions from note and return list of twist UUIDs
  /// Mentions are stored in the format [Name](#@{UUID}) in markdown
  static List<Uuid> parseMentionsFromNote(
    String? note,
    List<PriorityTwist> twists,
  ) {
    if (note == null || note.isEmpty) {
      return [];
    }

    final mentionedTwistIds = <Uuid>{};

    // Match mentions in format [Name](#@{UUID})
    // UUID format: 8-4-4-4-12 hexadecimal characters
    final mentionPattern = RegExp(
      r'\[([^\]]+)\]\(#@([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)',
    );

    final matches = mentionPattern.allMatches(note);
    for (final match in matches) {
      final uuidString = match.group(
        2,
      ); // UUID is in group 2, name is in group 1
      if (uuidString != null) {
        try {
          mentionedTwistIds.add(Uuid.fromString(uuidString));
        } catch (e) {
          // Skip invalid UUIDs
          continue;
        }
      }
    }

    return mentionedTwistIds.toList();
  }

  static Future<void> pullInitial() async {
    // Pull activities first (with limit of 200)
    final activitiesRange = await Store.get.pull(
      PullType.initial,
      Store.get.activities,
      ActivitiesBase(),
    );

    if (activitiesRange == null) return;

    // Use the returned range for exceptions and tags
    await Store.get.pull(
      PullType.initial,
      Store.get.activityExceptions,
      ActivityExceptionsBase(),
      range: activitiesRange,
    );
    await Store.get.pull(
      PullType.initial,
      Store.get.activityTags,
      ActivityTagsBase(),
      range: activitiesRange,
    );
  }

  static Future<void> pull() async {
    await Store.get.pull(
      PullType.updates,
      Store.get.activities,
      ActivitiesBase(),
    );
    await Store.get.pull(
      PullType.updates,
      Store.get.activityExceptions,
      ActivityExceptionsBase(),
    );
    await Store.get.pull(
      PullType.updates,
      Store.get.activityTags,
      ActivityTagsBase(),
    );
  }

  static Future<void> pullRange(DateRange range, Path? priorityPath) async {
    // Pull activities first (with limit of 200)
    final activitiesRange = await Store.get.pull(
      PullType.more,
      Store.get.activities,
      ActivitiesBase(priorityPath: priorityPath?.value ?? ''),
      range: (range.start?.toDateTime(), range.end?.toDateTime()),
    );

    if (activitiesRange == null) return;

    // Use the returned range for exceptions and tags
    await Store.get.pull(
      PullType.more,
      Store.get.activityExceptions,
      ActivityExceptionsBase(priorityPath: priorityPath?.value ?? ''),
      range: activitiesRange,
    );
    await Store.get.pull(
      PullType.more,
      Store.get.activityTags,
      ActivityTagsBase(priorityPath: priorityPath?.value ?? ''),
      range: activitiesRange,
    );
  }

  static Future<bool> push() async {
    final success =
        await Store.get.push(Store.get.activities, ActivitiesBase()) &&
        await Store.get.push(
          Store.get.activityExceptions,
          ActivityExceptionsBase(),
        ) &&
        await Store.get.push(Store.get.activityTags, ActivityTagsBase());

    // Batch push unread changes
    final unreadActivities = await (Store.get.select(
      Store.get.activities,
    )..where((t) => t.unreadUpdated.equals(true))).get();

    for (final activity in unreadActivities) {
      // Get root activity path (first level only)
      final pathParts = activity.path.value.split('.');
      final rootPath = pathParts.first;

      if (activity.unread) {
        // Mark as unread - delete from activity_read table
        await Base.client
            .from('activity_read')
            .delete()
            .eq('user_id', Base.userId.toString())
            .eq('activity_path', rootPath);
      } else {
        // Mark as read - upsert to activity_read table
        await Base.client.from('activity_read').upsert({
          'user_id': Base.userId.toString(),
          'activity_path': rootPath,
          'read_at': DateTime.now().toIso8601String(),
        });
      }

      // Clear unreadUpdated flag in local database
      await Store.get
          .update(Store.get.activities)
          .replace(
            ActivitiesCompanion(
              id: Value(activity.id),
              unreadUpdated: const Value(null),
              updatedAt: Value(DateTime.now()),
            ),
          );
    }

    return success;
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
    return await _get(
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
    );
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
    return _getQuery(
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
    ).watch().asyncMap(
      (results) =>
          _mapResultsToActivities(results, deleted: deleted, range: range),
    );
  }

  static Future<Activity> getOne(
    ActivityId id, {
    int? depth = 0,
    bool getParent = true,
  }) async {
    final activities = await _get(
      id: id,
      depth: depth,
      deleted: null,
      getParent: getParent,
      order: ActivityOrder.nested,
    );
    if (activities.isEmpty) {
      log.warning("Activity not found: $id");
      throw Exception('Activity not found');
    }
    return _asNested(activities, id: id).first;
  }

  static Stream<Activity> watchOne(
    ActivityId id, {
    int? depth = 0,
    bool getParent = true,
  }) {
    return _getQuery(
      id: id,
      depth: depth,
      deleted: null,
      getParent: getParent,
      order: ActivityOrder.nested,
    ).watch().asyncMap((results) async {
      final activities = await _mapResultsToActivities(results, range: null);
      return _asNested(activities, id: id).first;
    });
  }

  //   /// Transform a flat list in ActivityOrder.nested order to a list of the top-level items with descendants.
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

  static Future<Activity?> next(
    Date? fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) async {
    if (fromDate == null) {
      return null;
    }
    final activities = await _get(
      range: CustomDateRange(fromDate, null),
      strictRange: true,
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.sorted,
      limit: 1,
      offset: offset,
    );
    if (activities.isEmpty) {
      return null;
    }
    return activities.first;
  }

  static Future<Activity?> previous(
    Date? fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) async {
    if (fromDate == null) {
      return null;
    }
    final endDate = fromDate;
    final range = CustomDateRange(null, endDate) as DateRange;

    final activities = await _get(
      range: range,
      strictRange: true,
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.reverse,
      limit: 1,
      offset: offset,
    );
    if (activities.isEmpty) {
      return null;
    }
    return activities.first;
  }

  static Stream<Activity?> watchNext(
    Date? fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) {
    if (fromDate == null) {
      return Stream.value(null);
    }
    final startDate = fromDate.addDays(1);
    final range = CustomDateRange(startDate, null) as DateRange;

    return _getQuery(
      range: range,
      strictRange: true,
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.sorted,
      limit: 1,
      offset: offset,
    ).watch().asyncMap((results) async {
      final activities = await _mapResultsToActivities(
        results,
        deleted: deleted,
        range: range,
      );
      return activities.isEmpty ? null : activities.first;
    });
  }

  static Stream<Activity?> watchPrevious(
    Date? fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) {
    if (fromDate == null) {
      return Stream.value(null);
    }
    final endDate = fromDate;
    final range = CustomDateRange(null, endDate) as DateRange;

    return _getQuery(
      range: range,
      strictRange: true,
      priorityPath: context?.path,
      deleted: deleted,
      order: ActivityOrder.reverse,
      limit: 1,
      offset: offset,
    ).watch().asyncMap((results) async {
      final activities = await _mapResultsToActivities(
        results,
        deleted: deleted,
        range: range,
      );
      return activities.isEmpty ? null : activities.first;
    });
  }

  /// Watch all tags present in activities within a priority and its descendants.
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForPriority(Path priorityPath) {
    final at = Store.get.activityTags;
    final a = Store.get.activities;
    final p = Store.get.priorities;

    final query = Store.get.select(at).join([
      innerJoin(a, a.id.equalsExp(at.id)),
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant('$priorityPath%'))),
      ),
    ]);

    query.where(a.archivedAt.isNull());

    return query.watch().map((rows) {
      final Map<Tag, Set<ActivityId>> tagCounts = {};

      for (final row in rows) {
        final activityTagsRow = row.readTable(at);
        final activityId = activityTagsRow.id;
        final tags = activityTagsRow.tags;

        if (tags != null) {
          for (final tag in tags.keys) {
            tagCounts.putIfAbsent(tag, () => {}).add(activityId);
          }
        }
      }

      // Convert to list of (Tag, count) and sort by count descending
      final result =
          tagCounts.entries.map((e) => (e.key, e.value.length)).toList()
            ..sort((a, b) => b.$2.compareTo(a.$2));

      return result;
    });
  }

  /// Watch all tags present in activities within an activity thread (root + descendants).
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForActivityThread(
    Path activityPath,
  ) {
    final at = Store.get.activityTags;
    final a = Store.get.activities;

    final query = Store.get.select(at).join([
      innerJoin(a, a.id.equalsExp(at.id)),
    ]);

    query.where(
      a.archivedAt.isNull() &
          (a.path.equalsValue(activityPath) |
              a.path.likeExp(Constant('$activityPath.%'))),
    );

    return query.watch().map((rows) {
      final Map<Tag, Set<ActivityId>> tagCounts = {};

      for (final row in rows) {
        final activityTagsRow = row.readTable(at);
        final activityId = activityTagsRow.id;
        final tags = activityTagsRow.tags;

        if (tags != null) {
          for (final tag in tags.keys) {
            tagCounts.putIfAbsent(tag, () => {}).add(activityId);
          }
        }
      }

      // Convert to list of (Tag, count) and sort by count descending
      final result =
          tagCounts.entries.map((e) => (e.key, e.value.length)).toList()
            ..sort((a, b) => b.$2.compareTo(a.$2));

      return result;
    });
  }

  static Future<List<Activity>> _get({
    DateRange? range,
    bool strictRange = false,

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
  }) async {
    final query = _getQuery(
      range: range,
      strictRange: strictRange,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      path: path,
      depth: depth,
      self: self,
      deleted: deleted,
      search: search,
      filter: filter,
      order: order,
      limit: limit,
      offset: offset,
      getParent: getParent,
    );

    final results = await query.get();
    return _mapResultsToActivities(results, deleted: deleted, range: range);
  }

  static JoinedSelectStatement<HasResultSet, dynamic> _getQuery({
    DateRange? range,
    // Only include activities that start within the range
    bool strictRange = false,

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
    if (range != null) {
      Activity.pullRange(range, priorityPath);
    }

    // Create a copy of filter to avoid mutating the original
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;
    if (mutableFilter?.remove(Tag.archived) == true) {
      deleted = true;
    }
    final doNow = mutableFilter?.remove(Tag.now) == true;
    final doLater = mutableFilter?.remove(Tag.later) == true;
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

    // Add activity path filtering if path is provided
    if (path != null) {
      query.where(
        a.path.equalsValue(path) | a.path.likeExp(Constant('$path.%')),
      );
    }

    if (doNow) {
      final now = DateTime.now();
      query.where(
        a.type.equalsValue(ActivityType.action) &
            a.doneAt.isNull() &
            (
            // Date-based scheduling: startOn <= today
            (a.startOn.isSmallerOrEqualValue(Date.today().toString()) &
                    a.startAt.isNull()) |
                // DateTime-based scheduling: startAt <= now AND endAt >= now
                (a.startAt.isSmallerOrEqualValue(now) &
                    (a.endAt.isNull() | a.endAt.isBiggerOrEqualValue(now)) &
                    a.startOn.isNull())),
      );
    }
    if (doLater) {
      final now = DateTime.now();
      query.where(
        a.type.equalsValue(ActivityType.action) &
            a.doneAt.isNull() &
            (
            // Date-based scheduling: startOn > today
            (a.startOn.isBiggerThanValue(Date.today().toString()) &
                    a.startAt.isNull()) |
                // DateTime-based scheduling: startAt > now
                (a.startAt.isBiggerThanValue(now) & a.startOn.isNull())),
      );
    }
    if (done) {
      query.where(a.doneAt.isNotNull());
    }
    if (deleted != null) {
      query.where(deleted ? a.archivedAt.isNotNull() : a.archivedAt.isNull());
    }
    if (search?.isNotEmpty == true) {
      // Use FTS5 for full-text search with prefix matching
      final fts = Store.get.alias(Store.get.activityFts, 'fts');
      // Split search into words, escape special characters, and add prefix matching
      final words = search!
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .map(
            (word) => word
                .replaceAll("'", "''") // Escape single quotes for SQL
                .replaceAll('"', '""') // Escape double quotes for FTS5
                .replaceAll('*', '') // Remove asterisks
                .replaceAll('(', '') // Remove parentheses
                .replaceAll(')', ''),
          )
          .where((word) => word.isNotEmpty)
          .map((word) => '$word*') // Add prefix matching to each word
          .join(' '); // AND multiple words together
      if (words.isNotEmpty) {
        query = query.join([
          innerJoin(
            fts,
            fts.activityId.equalsExp(a.id) &
                CustomExpression<bool>("activity_fts MATCH '$words'"),
          ),
        ]);
      }
    }
    if (self == false) {
      if (id != null) {
        query.where(a.id.equalsValue(id).not());
      }
      if (path != null) {
        query.where(a.path.equalsValue(path).not());
      }
    }

    if (range != null) {
      final rangeStart = range.start?.toDateTime();
      final rangeEnd = range.end?.toDateTime();
      Expression<bool> condition = Constant(false);

      // Activity was created within the range
      Expression<bool> createdInRange =
          a.startOn.isNull() & a.startAt.isNull() & a.doneAt.isNull();
      if (rangeStart != null) {
        createdInRange =
            createdInRange & a.createdAt.isBiggerOrEqualValue(rangeStart);
      }
      if (rangeEnd != null) {
        createdInRange =
            createdInRange & a.createdAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | createdInRange;

      // Activity was completed within the range
      Expression<bool> completedInRange = a.doneAt.isNotNull();
      if (rangeStart != null) {
        completedInRange =
            completedInRange & a.doneAt.isBiggerOrEqualValue(rangeStart);
      }
      if (rangeEnd != null) {
        completedInRange =
            completedInRange & a.doneAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | completedInRange;

      // Activity is scheduled before the end of the range (Date-based)
      if (range.start != null || range.end != null) {
        Expression<bool> dateScheduled =
            a.startOn.isNotNull() & a.doneAt.isNull();
        if (range.start != null) {
          if (strictRange) {
            // For strict range, the activity must start on or after the range start
            dateScheduled =
                dateScheduled &
                a.startOn.isBiggerOrEqualValue(range.start!.toString());
          } else {
            dateScheduled =
                dateScheduled &
                (a.endOn.isNull() |
                    a.endOn.isBiggerOrEqualValue(range.start!.toString()));
          }
        }
        if (range.end != null) {
          dateScheduled =
              dateScheduled &
              a.startOn.isSmallerThanValue(range.end!.toString());
        }
        condition = condition | dateScheduled;
      }

      // Activity is scheduled before the end of the range (DateTime-based)
      Expression<bool> dateTimeScheduled =
          a.startAt.isNotNull() & a.doneAt.isNull();
      if (rangeStart != null) {
        if (strictRange) {
          dateTimeScheduled =
              dateTimeScheduled & a.startAt.isBiggerOrEqualValue(rangeStart);
        } else {
          dateTimeScheduled =
              dateTimeScheduled &
              (a.endAt.isNull() | a.endAt.isBiggerOrEqualValue(rangeStart));
        }
      }
      if (rangeEnd != null) {
        dateTimeScheduled =
            dateTimeScheduled & a.startAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | dateTimeScheduled;

      query.where(condition);
    }

    if (limit != null) {
      query.limit(limit, offset: offset);
    }

    final sortExpression = CaseWhenExpression(
      cases: [
        CaseWhen(a.doneAt.isNotNull(), then: a.doneAt),
        CaseWhen(a.startAt.isNotNull(), then: a.startAt),
        CaseWhen(a.startOn.isNotNull(), then: a.startOn),
      ],
      orElse: a.createdAt,
    );
    switch (order) {
      case ActivityOrder.sorted:
        query.orderBy([
          OrderingTerm.asc(sortExpression),
          OrderingTerm.asc(a.order),
        ]);
        break;
      case ActivityOrder.reverse:
        query.orderBy([
          OrderingTerm.desc(sortExpression),
          OrderingTerm.desc(a.order),
        ]);
        break;
      case ActivityOrder.nested:
        // order by path so parents always precede children
        query.orderBy([OrderingTerm(expression: a.path)]);
        break;
    }

    // Add joins for tags and exceptions
    final exceptions = Store.get.alias(
      Store.get.activityExceptions,
      'exceptions',
    );
    final tags = Store.get.alias(Store.get.activityTags, 'tags');

    query = query.join([
      leftOuterJoin(exceptions, exceptions.activityId.equalsExp(a.id)),
      leftOuterJoin(
        tags,
        (tags.id.equalsExp(a.id) | (tags.id.isNull() & a.id.isNull())) &
            (tags.occurrence.equalsExp(exceptions.occurrence) |
                (tags.occurrence.equals('') & exceptions.occurrence.isNull())),
      ),
    ]);

    // Add tag filtering if filter list is provided
    // This must happen AFTER the tags table is joined
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      for (final tag in mutableFilter) {
        query.where(
          CustomExpression<bool>(
            'JSON_EXTRACT(tags.tags, \'\$.${tag.id}\') IS NOT NULL',
          ),
        );
      }
    }

    return query;
  }

  /// Maps database query results to Activity objects.
  ///
  /// This function handles both regular and recurring activities:
  /// - For non-recurring activities: Returns them directly
  /// - For recurring activities with a range: Generates occurrences within the range
  /// - For recurring activities without a range: Returns the base recurring activity template
  ///
  /// Recurring activities can have exceptions (modified/deleted occurrences) stored in
  /// the activity_exceptions table, which override generated occurrences.
  static Future<List<Activity>> _mapResultsToActivities(
    List<TypedResult> results, {
    bool? deleted = false,
    DateRange? range,
  }) async {
    if (results.isEmpty) return [];

    // Get the table aliases (we need to recreate these for reading)
    final a = Store.get.alias(Store.get.activities, 'a');
    final tags = Store.get.alias(Store.get.activityTags, 'tags');
    final exceptions = Store.get.alias(
      Store.get.activityExceptions,
      'exceptions',
    );

    // Get all priorities needed for the activities
    final priorities = await Priority.get(
      deleted: deleted == false ? false : null,
    );
    final priorityMap = Priority.asMap(priorities);

    // Group results by activity ID to handle activity exceptions
    final activityGroups = <Uuid, List<TypedResult>>{};
    for (final result in results) {
      final activityId = result.readTable(a).id;
      activityGroups.putIfAbsent(activityId, () => []).add(result);
    }

    // Separate recurring activities from non-recurring and collect database exceptions
    final activities = <Activity>[];
    for (final group in activityGroups.values) {
      final activityRow = group.first.readTable(a);
      final priority = priorityMap[activityRow.priorityId];
      if (priority == null) {
        // Skip activities with missing priority
        continue;
      }

      // Create base activity
      final tagsRow = activityRow.recurrenceRule == null
          ? group.first.readTableOrNull(tags)
          : null;
      final baseActivity = Activity._fromStore(
        activity: activityRow,
        priority: priority,
        tags: tagsRow,
      );

      if (!baseActivity.recurring) {
        activities.add(baseActivity);
        continue;
      }

      // Generate occurrences for recurring activities and filter out database overrides
      final occurrences = <String, Activity>{};
      if (range?.bounded == true) {
        try {
          for (final occurrence in baseActivity.generateOccurrences(
            range!.toBounded(),
          )) {
            occurrences[occurrence._exception!.occurrence] = occurrence;
          }
          // Overwrite occurrences with exceptions
          for (final result in group) {
            final exception = result.readTableOrNull(exceptions);
            if (exception == null) continue;
            final activity = Activity._fromStore(
              activity: activityRow,
              priority: priority,
              tags: result.readTableOrNull(tags),
              exception: exception,
            );
            occurrences[exception.occurrence] = activity;
          }
        } catch (e, t) {
          log.warning(
            "Error generating occurrences for activity ${baseActivity.id}: $e\n$t",
          );
        }
        // Add generated occurrences to the activities list
        activities.addAll(occurrences.values);
      } else {
        // No range provided - return the base recurring activity itself
        // This allows viewing/editing the recurrence template
        activities.add(baseActivity);
      }
    }
    return activities;
  }

  static Map<Priority, List<Activity>> prioritize(List<Activity> activities) {
    final Map<Priority, List<Activity>> activitiesByPriority = {};
    for (final activity in activities) {
      activitiesByPriority
          .putIfAbsent(activity.priority, () => [])
          .add(activity);
    }

    // Create list of priority groups ordered by priority path
    final Map<Priority, List<Activity>> sortedActivitiesByPriority = {};
    final priorities = activitiesByPriority.keys.toList()
      ..sort((a, b) => a.compareTo(b));
    for (final priority in priorities) {
      final priorityActivities = activitiesByPriority[priority]!;
      // Sort activities within each priority group (by order property)
      priorityActivities.sort();
      sortedActivitiesByPriority[priority] = priorityActivities;
    }

    return sortedActivitiesByPriority;
  }

  Activity({
    required this.priority,
    this.parent,
    ActivityType type = ActivityType.note,
    Order? order,
    String? note,
    String? title,
    bool draft = false,
    bool private = false,
    DateTimeRange? at,
    DateRange? on,
    Uuid? assigneeId,
  }) : _activity = ActivityRow(
         id: Uuid.generate(),
         type: type,
         authorId: Base.userId,
         assigneeId: assigneeId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         priorityId: priority.id,
         draft: draft,
         private: private,
         order: order ?? Order.first(),
         path: Path.generate(parent: parent?.path),
         title: title,
         note: note,
         startAt: at?.start,
         endAt: at?.end,
         startOn: on?.start,
         endOn: on?.end,
         unread: false,
         unreadUpdated: null,
       ),
       _exception = null,
       _tags = null {
    parent?._addChild(this);
  }

  Activity._fromStore({
    required ActivityRow activity,
    required this.priority,
    this.parent,
    ActivityExceptionRow? exception,
    ActivityTagsRow? tags,
  }) : _activity = activity,
       _exception = exception,
       _tags = tags {
    assert(
      priority.id == activity.priorityId,
      "Priority does not match activity",
    );
    parent?._addChild(this);
  }

  final ActivityRow _activity;
  final ActivityExceptionRow? _exception;
  final ActivityTagsRow? _tags;

  final Activity? parent;
  final Priority priority;

  Uuid get id => _activity.id;
  bool get recurring => _activity.recurrenceRule != null && _exception == null;
  Path get path => _activity.path;
  Order get order => _activity.order;
  DateTime get createdAt => _activity.createdAt;
  DateTime get updatedAt => _activity.updatedAt;
  DateTime? get archivedAt => _activity.archivedAt;
  bool get draft => _activity.draft;
  bool get private => _activity.private;
  Uuid get authorId => _activity.authorId;
  Uuid? get assigneeId => _activity.assigneeId;
  ActivityType? get type => _activity.type;
  DateTime? get doneAt => _exception?.doneAt ?? _activity.doneAt;
  RecurrenceRule? get recurrenceRule => _activity.recurrenceRule;
  List<DateTime>? get recurrenceExdates => _activity.recurrenceExdates;
  List<DateTime>? get recurrenceDates => _activity.recurrenceDates;
  Map<Tag, List<Uuid>> get tags => _tags?.tags ?? const {};
  List<Link> get links => _activity.links ?? const [];
  bool get unread => _activity.unread;
  bool? get unreadUpdated => _activity.unreadUpdated;

  String? get title => _exception?.title ?? _activity.title;
  String? get note => _exception?.note ?? _activity.note;

  /// Helper to replace mentions [Name](#@ID) with just Name for display
  static String _replaceMentionsForDisplay(String text) {
    // Replace [Name](#@UUID) with just Name
    return text.replaceAllMapped(
      RegExp(
        r'\[([^\]]+)\]\(#@[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\)',
      ),
      (match) => match.group(1) ?? '',
    );
  }

  String? get noteText {
    final text = _exception?.note ?? _activity.note;
    if (text == null) return null;
    return _replaceMentionsForDisplay(
      text,
    ).removeMarkdown().replaceAll('\n', ' ').trim();
  }

  String get displayTitle {
    if (title != null) return title!;
    final noteFirstLine = note?.split("\n").first;
    if (noteFirstLine == null) return draft ? '🤷' : 'Untitled';
    return _replaceMentionsForDisplay(noteFirstLine).removeMarkdown().trim();
  }

  DateTimeRange? get at =>
      (_exception?.startAt != null
          ? DateTimeRange(_exception!.startAt!, _exception.endAt)
          : null) ??
      (_activity.startAt != null
          ? DateTimeRange(_activity.startAt!, _activity.endAt)
          : null) ??
      on?.toDateTimeRange();
  DateRange? get on =>
      (_exception?.startOn != null
          ? CustomDateRange(_exception!.startOn!, _exception.endOn)
          : null) ??
      (_activity.startOn != null
          ? CustomDateRange(_activity.startOn!, _activity.endOn)
          : null);
  Duration? get duration =>
      _exception?.duration ??
      _activity.duration ??
      on?.duration ??
      at?.duration;

  DateTime get agendaAt =>
      doneAt ??
      (todo ? DateTime.now() : null) ??
      at?.start ??
      on?.start?.toDateTime() ??
      createdAt;

  bool get doNow => todo && at?.includes(DateTime.now()) == true;
  bool get doLater => todo && at?.start?.isAfter(DateTime.now()) == true;
  bool get todo => type == ActivityType.action && !done;
  bool get scheduled => at != null || on != null;
  bool get done => doneAt != null;

  static const separator = ' › ';

  Activity copyWith({
    // These fields always update the root activity
    Priority? priority,
    ActivityType? type,
    Path? path,
    Order? order,
    bool? draft,
    bool? private,
    Activity? parent,
    Uuid? assigneeId,
    bool? unread,
    Value<List<Uuid>?> mentions = const Value.absent(),

    // These fields update the exception if this is a recurrence, or the root activity otherwise
    Value<DateTimeRange?> at = const Value.absent(),
    Value<DateRange?> on = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Value<String?> title = const Value.absent(),
    Value<Duration?> duration = const Value.absent(),
    Value<DateTime?> archivedAt = const Value.absent(),

    // These fields update the root activity
    Value<DateTimeRange?> recurrenceAt = const Value.absent(),
    Value<DateRange?> recurrenceOn = const Value.absent(),
    Value<DateTime?> recurrenceDoneAt = const Value.absent(),
    Value<DateTime?> recurrenceDeletedAt = const Value.absent(),
    Value<RecurrenceRule?> recurrenceRule = const Value.absent(),
    Value<List<DateTime>?> recurrenceExdates = const Value.absent(),
    Value<List<DateTime>?> recurrenceDates = const Value.absent(),
    Value<String?> recurrenceNote = const Value.absent(),
    Value<String?> recurrenceTitle = const Value.absent(),
    Value<Duration?> recurrenceDuration = const Value.absent(),
    Value<List<Link>?> links = const Value.absent(),
  }) {
    final now = DateTime.now();

    // Update root activity if any root-specific fields are changing
    var activity = _activity;
    if (priority != null ||
        type != null ||
        path != null ||
        order != null ||
        draft != null ||
        private != null ||
        assigneeId != null ||
        unread != null ||
        mentions.present ||
        recurrenceAt.present ||
        recurrenceOn.present ||
        recurrenceDoneAt.present ||
        recurrenceDeletedAt.present ||
        recurrenceRule.present ||
        recurrenceExdates.present ||
        recurrenceDates.present ||
        recurrenceNote.present ||
        recurrenceTitle.present ||
        recurrenceDuration.present ||
        links.present ||
        (!recurring &&
            (at.present ||
                on.present ||
                doneAt.present ||
                note.present ||
                title.present ||
                duration.present ||
                archivedAt.present))) {
      // Determine which fields to update on the root activity
      Value<DateTime?> rootStartAt = const Value.absent();
      Value<DateTime?> rootEndAt = const Value.absent();
      Value<Date?> rootStartOn = const Value.absent();
      Value<Date?> rootEndOn = const Value.absent();
      Value<DateTime?> rootDoneAt = const Value.absent();
      Value<DateTime?> rootDeletedAt = const Value.absent();
      Value<String?> rootNote = const Value.absent();
      Value<String?> rootTitle = const Value.absent();
      Value<Duration?> rootDuration = const Value.absent();

      // Recurrence fields always update root activity
      if (recurrenceAt.present) {
        rootStartAt = Value(recurrenceAt.value?.start);
        rootEndAt = Value(recurrenceAt.value?.end);
      }
      if (recurrenceOn.present) {
        rootStartOn = Value(recurrenceOn.value?.start);
        rootEndOn = Value(recurrenceOn.value?.end);
      }
      if (recurrenceDoneAt.present) rootDoneAt = recurrenceDoneAt;
      if (recurrenceDeletedAt.present) rootDeletedAt = recurrenceDeletedAt;
      if (recurrenceNote.present) rootNote = recurrenceNote;
      if (recurrenceTitle.present) rootTitle = recurrenceTitle;
      if (recurrenceDuration.present) rootDuration = recurrenceDuration;

      // Non-recurrence fields update root activity only if not a recurrence
      if (!recurring) {
        if (at.present) {
          rootStartAt = Value(at.value?.start);
          rootEndAt = Value(at.value?.end);
        }
        if (on.present) {
          rootStartOn = Value(on.value?.start);
          rootEndOn = Value(on.value?.end);
        }
        if (doneAt.present) rootDoneAt = doneAt;
        if (archivedAt.present) rootDeletedAt = archivedAt;
        if (note.present) rootNote = note;
        if (title.present) rootTitle = title;
        if (duration.present) rootDuration = duration;
      }

      activity = _activity.copyWith(
        priorityId: priority?.id,
        type: type,
        path: path,
        order: order,
        draft: draft,
        private: private,
        assigneeId: assigneeId != null
            ? Value(assigneeId)
            : const Value.absent(),
        mentions: mentions,
        createdAt: draft == false && _activity.draft ? now : null,
        updatedAt: now,
        startAt: rootStartAt,
        endAt: rootEndAt,
        startOn: rootStartOn,
        endOn: rootEndOn,
        doneAt: rootDoneAt,
        archivedAt: rootDeletedAt,
        recurrenceRule: recurrenceRule,
        recurrenceExdates: recurrenceExdates,
        recurrenceDates: recurrenceDates,
        note: rootNote,
        title: rootTitle,
        duration: rootDuration,
        links: links,
        unread: unread,
        unreadUpdated: unread != null ? Value(true) : const Value.absent(),
      );
    }

    // Update exception if this is a recurrence and exception fields are changing
    var exception = _exception;
    if (_exception != null &&
        (at.present ||
            on.present ||
            doneAt.present ||
            note.present ||
            title.present ||
            duration.present ||
            archivedAt.present)) {
      exception = exception!.copyWith(
        startAt: at.present ? Value(at.value?.start) : const Value.absent(),
        endAt: at.present ? Value(at.value?.end) : const Value.absent(),
        startOn: on.present ? Value(on.value?.start) : const Value.absent(),
        endOn: on.present ? Value(on.value?.end) : const Value.absent(),
        doneAt: doneAt,
        title: title,
        note: note,
        duration: duration,
        // Note: exceptions don't have archivedAt, so we ignore that field
      );
    }

    return Activity._fromStore(
      activity: activity,
      exception: exception,
      tags: _tags,
      priority: priority ?? this.priority,
      parent: parent ?? this.parent,
    );
  }

  Activity toggleTag(Tag tag) {
    // Handle computed tags
    switch (tag) {
      case Tag.archived:
        return copyWith(
          archivedAt: Value(archivedAt == null ? DateTime.now() : null),
        );
      case Tag.now:
        if (doNow) {
          // Removing doNow - clear scheduling
          return copyWith(
            on: const Value(null),
            at: const Value(null),
            doneAt: const Value(null),
            type: ActivityType.note,
          );
        } else {
          // Adding doNow - preserve existing scheduling type or default to date-based
          final hasDateTime = at != null;
          return copyWith(
            type: ActivityType.action,
            at: hasDateTime
                ? Value(
                    DateTimeRange(
                      DateTime.now(),
                      DateTime.now().add(Duration(hours: 1)),
                    ),
                  )
                : const Value(null),
            on: !hasDateTime
                ? Value(CustomDateRange(Date.today(), null))
                : const Value(null),
            doneAt: const Value(null),
          );
        }
      case Tag.done:
        return copyWith(
          doneAt: Value(done ? null : DateTime.now()),
          on: const Value(null),
          at: const Value(null),
        );
      case Tag.later:
        return copyWith(
          type: ActivityType.action,
          on: Value(
            todo ? null : CustomDateRange(Date.today().addDays(1), null),
          ),
          at: const Value(null), // Clear any existing datetime scheduling
          doneAt: const Value(null),
        );
      default:
        break;
    }

    final currentTags = Map<Tag, List<Uuid>>.from(tags);
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
    final currentTagUpdates = Map<int, bool>.from(_tags?.tagsUpdated ?? {});
    currentTagUpdates[tag.id] = isAdding;
    log.info(
      "Toggling tag ${tag.name} (${tag.type}) to $isAdding ($currentTags, $currentTagUpdates)",
    );

    final newActivity = Activity._fromStore(
      activity: _activity,
      exception: _exception,
      tags:
          _tags?.copyWith(
            updatedAt: DateTime.now(),
            tags: Value(currentTags),
            tagsUpdated: Value(currentTagUpdates),
          ) ??
          ActivityTagsRow(
            id: id,
            occurrence:
                _exception?.occurrence ?? '', // Empty string for base activity
            updatedAt: DateTime.now(),
            tags: currentTags,
            tagsUpdated: currentTagUpdates.isEmpty ? null : currentTagUpdates,
          ),
      priority: priority,
      parent: parent,
    );
    return newActivity;
  }

  Future<void> save() async {
    await Store.get.save(
      Store.get.activities,
      _activity.toCompanion(false),
      ActivitiesBase(),
    );
    if (_exception != null) {
      await Store.get.save(
        Store.get.activityExceptions,
        _exception.toCompanion(false),
        ActivityExceptionsBase(),
      );
    }
    if (_tags != null) {
      await Store.get.save(
        Store.get.activityTags,
        _tags.toCompanion(false),
        ActivityTagsBase(),
      );
    }

    // Generate a title on the first non-draft save
    if (title == null && !draft) {
      final generatedTitle = await generateTitle();
      log.info("Generated title: $generatedTitle");
      await copyWith(title: Value(generatedTitle)).save();
    }
  }

  Future<String> generateTitle() async {
    try {
      final response = await api.post<Map<String, dynamic>>(
        "/summary",
        body: {'body': note},
      );
      return response['title'] as String;
    } catch (e, t) {
      log.warning("Error generating title: $e\n$t");
      // It might be better to leave title null and generate displayTitle,
      // but for some reason, activities without titles are not appearing
      // on PriorityPage.
      return displayTitle;
    }
  }

  Future<void> delete() => copyWith(archivedAt: Value(DateTime.now())).save();

  bool hasTag(Tag tag) {
    switch (tag) {
      case Tag.archived:
        return archivedAt != null;
      case Tag.now:
        return doNow;
      case Tag.done:
        return done;
      case Tag.later:
        return doLater;
      default:
        final currentTags = tags;
        final users = currentTags[tag];
        return users != null && users.isNotEmpty;
    }
  }

  static final Map<Uuid, List<Activity>> _children = {};
  void _addChild(Activity child) {
    _children
        .putIfAbsent(id, () => [])
        .replaceSorted(child, (a, b) => a.id == b.id);
  }

  List<Activity> get children => _children[id] ?? [];
  bool isParent(Activity other) => path.isParent(other.path);
  List<Activity> get peers => parent?.children ?? [];
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

  List<Activity> generateOccurrences(BoundedDateRange range) {
    // For non-recurring activities, return just this activity
    if (!recurring) {
      return [this];
    }

    // For recurring activities, generate occurrences using the RecurrenceRule
    List<Activity> occurrences = [];

    // Convert BoundedDateRange to DateTime range for rrule package
    final dateTimeRange = BoundedDateTimeRange(
      range.start.toDateTime(),
      range.end.toDateTime(),
    );

    // Get the event start time
    final start = (at?.start ?? on?.start?.toDateTime())!;

    // If the range ends before the event starts, there are no occurrences
    if (dateTimeRange.end.isBefore(start)) {
      return [];
    }

    // Generate instances within the range using the rrule package
    final instances = recurrenceRule!.getInstances(
      start: start.copyWith(isUtc: true),
      after: (start.isAfter(dateTimeRange.start) ? start : dateTimeRange.start)
          .copyWith(isUtc: true),
      includeAfter: true,
      before: dateTimeRange.end.copyWith(isUtc: true),
    );

    // Convert instances to a set for efficient exclusion checking
    final instanceSet = Set<DateTime>.from(
      instances.map((dt) => dt.copyWith(isUtc: false)),
    );

    // Apply recurrenceExdates (dates to exclude)
    if (recurrenceExdates?.isNotEmpty == true) {
      instanceSet.removeAll(
        recurrenceExdates!.where((dt) => range.includes(dt.toDate())),
      );
    }

    // Add recurrenceDates (extra dates to include) if they fall within the range
    if (recurrenceDates?.isNotEmpty == true) {
      instanceSet.addAll(
        recurrenceDates!.where((dt) => range.includes(dt.toDate())),
      );
    }

    // Convert back to sorted list
    final finalInstances = instanceSet.toList()..sort();

    for (final instance in finalInstances) {
      // Create a new occurrence for each instance
      final occurrenceAt = at != null
          ? DateTimeRange(instance, instance.add(duration!))
          : null;
      final occurrenceOn = on != null
          ? CustomDateRange(
              instance.toDate(),
              instance.toDate().addDays(duration!.inDays),
            )
          : null;

      // Format occurrence string based on whether this is date or datetime based
      final occurrence = Activity._fromStore(
        activity: _activity,
        exception: ActivityExceptionRow(
          id: Uuid.generate(),
          updatedAt: DateTime.now(),
          activityId: id,
          occurrence: ActivityExceptions.formatOccurrence(
            instance,
            dateOnly: at == null,
          ),
          startAt: occurrenceAt?.start,
          endAt: occurrenceAt?.end,
          startOn: occurrenceOn?.start,
          endOn: occurrenceOn?.end,
        ),
        priority: priority,
        parent: parent,
        tags: _tags,
      );

      occurrences.add(occurrence);
    }

    return occurrences;
  }

  Date? nextOccurrence(BoundedDateRange range, {bool reverse = false}) {
    if (recurrenceRule == null) {
      return null;
    }

    // Convert BoundedDateRange to DateTime range for rrule package
    final dateTimeRange = BoundedDateTimeRange(
      range.start.toDateTime(),
      range.end.toDateTime(),
    );

    // Get the event start time
    final start = (at?.start ?? on?.start?.toDateTime())!;

    // If the range ends before the event starts, there are no occurrences
    if (dateTimeRange.end.isBefore(start)) {
      return null;
    }

    // Generate instances within the range using the rrule package
    final instances = recurrenceRule!.getInstances(
      start: start.copyWith(isUtc: true),
      after: (start.isAfter(dateTimeRange.start) ? start : dateTimeRange.start)
          .copyWith(isUtc: true),
      includeAfter: true,
      before: dateTimeRange.end.copyWith(isUtc: true),
    );

    // Convert instances to check for overlaps
    final instanceSet = Set<DateTime>.from(
      instances.map((dt) => dt.copyWith(isUtc: false)),
    );

    // Apply recurrenceExdates (dates to exclude)
    if (recurrenceExdates?.isNotEmpty == true) {
      instanceSet.removeAll(
        recurrenceExdates!.where((dt) => range.includes(dt.toDate())),
      );
    }

    // Add recurrenceDates (extra dates to include) if they fall within the range
    if (recurrenceDates?.isNotEmpty == true) {
      instanceSet.addAll(
        recurrenceDates!.where((dt) => range.includes(dt.toDate())),
      );
    }

    if (instanceSet.isEmpty) {
      return null;
    }

    // Sort instances and return the first or last based on reverse parameter
    final sortedInstances = instanceSet.toList()..sort();
    final targetInstance = reverse
        ? sortedInstances.last
        : sortedInstances.first;
    return targetInstance.toDate();
  }

  @override
  int compareTo(Activity other) {
    if (todo) {
      if (other.todo) {
        return order.compareTo(other.order);
      } else {
        // todo activities come after
        return 1;
      }
    } else if (other.todo) {
      // other activity is todo, this one is not
      return -1;
    }

    // For non-scheduled activities, sort by order (manual ordering)
    // For scheduled activities, sort by time, then order
    final thisScheduled = scheduled;
    final otherScheduled = other.scheduled;

    if (!thisScheduled && !otherScheduled && !done && !other.done) {
      // Both are non-scheduled, non-done: sort by order for manual reordering
      return order.compareTo(other.order);
    }

    // Otherwise, compare doneAt ?? createdAt, then by order
    final thisTime = doneAt ?? createdAt;
    final otherTime = other.doneAt ?? other.createdAt;
    final timeComparison = thisTime.compareTo(otherTime);
    if (timeComparison != 0) {
      return timeComparison;
    }
    return order.compareTo(other.order);
  }

  @override
  List<Object?> get props => [_activity, _exception, _tags, parent, priority];

  @override
  String toString() {
    final buffer = StringBuffer('Activity(');

    // ID and type
    buffer.write('id: ${id.toString().substring(0, 8)}..., ');
    buffer.write('type: ${type?.name ?? 'null'}, ');

    // Title (truncated)
    final titleStr = title;
    if (titleStr != null) {
      final truncatedTitle = titleStr.length > 50
          ? '${titleStr.substring(0, 47)}...'
          : titleStr;
      buffer.write('title: "$truncatedTitle", ');
    }

    // Note (truncated and sanitized)
    final noteStr = noteText;
    if (noteStr != null && noteStr.isNotEmpty) {
      final truncatedNote = noteStr.length > 50
          ? '${noteStr.substring(0, 47)}...'
          : noteStr;
      buffer.write('note: "$truncatedNote", ');
    }

    // Priority
    buffer.write('priority: ${priority.title}, ');

    // Path (for nested activities)
    if (!path.isRoot) {
      buffer.write('path: $path, ');
    }

    // Scheduling info
    if (at != null) {
      buffer.write('at: ${at!.start}, ');
    } else if (on != null) {
      buffer.write('on: ${on!.start}, ');
    }

    // Status
    if (done) {
      buffer.write('done: $doneAt, ');
    } else if (todo) {
      buffer.write('todo: true, ');
    }

    if (archivedAt != null) {
      buffer.write('deleted: $archivedAt, ');
    }

    if (draft) {
      buffer.write('draft: true, ');
    }

    // Remove trailing comma and space
    final result = buffer.toString();
    if (result.endsWith(', ')) {
      return '${result.substring(0, result.length - 2)})';
    }
    return '$result)';
  }
}

/// Pending sync flags for different entity types.
/// Bit 1 is reserved for sync-in-progress flag.
/// Entity-specific flags start from bit 2 (value 2).
enum ActivityPendingSync {
  /// Full activity data changed
  full(2),

  /// Only tags changed
  tags(4),

  /// Only exceptions changed
  exceptions(8);

  const ActivityPendingSync(this.value);
  final int value;
}
