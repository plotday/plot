part of 'store.dart';

typedef ActivityId = Uuid;

@DataClassName('ActivityRow')
class Activities extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  BlobColumn get priorityId => blob().map(const UuidConverter())();
  BlobColumn get authorId => blob().map(const ActorIdConverter())();
  BlobColumn get assigneeId =>
      blob().nullable().map(const ActorIdConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  TextColumn get type => text().map(const EnumConverter<ActivityType>())();
  TextColumn get kind =>
      text().nullable().map(const EnumConverter<ActivityKind>())();

  TextColumn get title => text().nullable()();
  TextColumn get preview => text().nullable()();

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
  DateTimeColumn get lastNoteCreatedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get lastNoteSourceCreatedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get sourceCreatedAt =>
      dateTime().map(const LocalDateTimeConverter())();

  TextColumn get recurrenceRule =>
      text().nullable().map(const RecurrenceRuleConverter())();
  TextColumn get recurrenceExdates =>
      text().nullable().map(const DateTimeListConverter())();
  TextColumn get mentions => text().nullable().map(const UuidListConverter())();
  TextColumn get links => text().nullable().map(const LinksConverter())();
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
  ActivitiesBase({this.priorityPath, this.initial = false})
    : super(
        table: 'user_activity',
        syncEndpoint: 'activities',
        name: "activities",
        filterName: priorityPath,
        ascending:
            false, // Get latest items first for reverse chronological sync
        limit: initial
            ? null
            : 200, // No limit for initial pull (active OR unread)
      );

  final String? priorityPath;
  final bool initial;

  @override
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = super.buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      initial: initial,
      archived: archived,
    );
    if (priorityPath != null) {
      params['priority_path'] = priorityPath!;
    }
    return params;
  }

  @override
  Map<String, String> buildRangeParams(DateTimeRange range) {
    // Calendar overlap filtering via range_start/range_end
    final params = <String, String>{};
    if (range.start != null) {
      params['range_start'] = range.start!.toIso8601String();
    }
    if (range.end != null) {
      params['range_end'] = range.end!.toIso8601String();
    }
    return params;
  }

  @override
  Insertable<ActivityRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove(
      'user_id',
    ); // Remove user_id from activity_in_range function result

    // Handle the 'at' field from activity_in_range function
    final at = json['at'] != null && json['at'] != 'empty'
        ? DateTimeRange.fromString(json['at'] as String)
        : null;
    json['start_at'] = at?.start?.toDb();
    json['end_at'] = at?.end?.toDb();
    json.remove('at');

    // Handle the 'on' field from activity_in_range function
    final on = json['on'] != null && json['on'] != 'empty'
        ? DateRange.fromString(json['on'] as String)
        : null;
    json['start_on'] = on?.start?.toString();
    json['end_on'] = on?.end?.toString();
    json.remove('on');

    return ActivityRow.fromJson(json);
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final activityRow = row as ActivityRow;
      // Check if local has a pending unread change
      final local = await (store.select(
        store.activities,
      )..where((t) => t.id.equals(activityRow.id.toBytes()))).getSingleOrNull();
      if (local != null && local.unreadUpdated == true) {
        if (activityRow.unread == local.unread) {
          // Server confirms our local unread state - clear the pending flag
          result.add(activityRow.copyWith(unreadUpdated: const Value(null)));
        } else {
          // Server still has stale data - preserve local unread state
          result.add(
            activityRow.copyWith(
              unread: local.unread,
              unreadUpdated: const Value(true),
            ),
          );
        }
      } else {
        result.add(row);
      }
    }
    return result;
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

    // Convert author_id from ActorId bytes to UUID string for the API
    // The client sets this correctly to Base.actorId (contact ID)
    // Do NOT remove - the sync API needs it to set the correct author

    // Remove unread fields - they are managed separately
    json.remove('unread');
    json.remove('unread_updated');

    // Remove mentions - it's a calculated field from notes
    json.remove('mentions');

    // Remove last_note_created_at and last_note_source_created_at - they are calculated fields from notes
    json.remove('last_note_created_at');
    json.remove('last_note_source_created_at');

    return json;
  }
}

enum ActivityOrder { sorted, reverse }

class Activity extends Equatable implements Comparable<Activity> {
  static Future<void> pullInitial() async {
    // Pull active OR unread activities (no limit)
    // We do this to ensure we can reflect which priorities have unread activities.
    // We were going to do something similar for priorities with actions, but haven't yet.
    // This fetches all items that are either:
    // - Active: type=action, not done, not archived, scheduled for now/past or unscheduled
    // - Unread: unread=true, not archived, not draft
    await Store.get.pull(
      Store.get.activities,
      ActivitiesBase(initial: true),
      initial: true,
    );

    // We don't pull exceptions or tags mostly because we don't have a good way of pulling the related
    // ones, but also because those should come with pullTo.
  }

  static Future<void> pull() async {
    await Store.get.pull(Store.get.activities, ActivitiesBase());
    await Store.get.pull(
      Store.get.activityExceptions,
      ActivityExceptionsBase(),
    );
    await Store.get.pull(Store.get.activityTags, ActivityTagsBase());
  }

  static Future<void> pullRange(
    DateRange range,
    Path? priorityPath, {
    bool archived = false,
  }) async {
    // Pull activities first (with limit of 200)
    // For descending order (newest first), pullTo is the older/earlier boundary (range.start)
    final pulledTo = await Store.get.pullTo(
      Store.get.activities,
      ActivitiesBase(priorityPath: priorityPath?.value ?? ''),
      pullTo: range.start?.toDateTime(),
      ascending: false, // Activity pulls newest → oldest
      archived: archived,
    );

    if (pulledTo == null) return;

    // Use the returned range for exceptions and tags
    await Store.get.pullTo(
      Store.get.activityExceptions,
      ActivityExceptionsBase(priorityPath: priorityPath?.value ?? ''),
      pullTo: pulledTo, // Use the oldest boundary from activities
      ascending: false,
      archived: archived,
    );
    await Store.get.pullTo(
      Store.get.activityTags,
      ActivityTagsBase(priorityPath: priorityPath?.value ?? ''),
      pullTo: pulledTo, // Use the oldest boundary from activities
      ascending: false,
      archived: archived,
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

    if (unreadActivities.isEmpty) {
      return success;
    }

    // Get the max pulledAt from activities and notes for read_at timestamp
    final syncStates = await (Store.get.select(
      Store.get.syncStates,
    )..where((row) => row.entity.isIn(['activities', 'notes']))).get();

    final maxPulledAtMicros = syncStates
        .map((s) => s.pulledAt)
        .whereType<int>()
        .fold<int?>(
          null,
          (max, value) => max == null || value > max ? value : max,
        );

    // We use the latest pulledAt since the user hasn't read anything since that point, even if it exists remotely
    final readAt = maxPulledAtMicros != null
        ? DateTime.fromMicrosecondsSinceEpoch(maxPulledAtMicros, isUtc: true)
        : DateTime.now().toUtc();

    // Separate activities into read and unread lists
    final toMarkRead = <ActivityRow>[];
    final toMarkUnread = <ActivityRow>[];

    for (final activity in unreadActivities) {
      if (activity.unread) {
        toMarkUnread.add(activity);
      } else {
        toMarkRead.add(activity);
      }
    }

    try {
      // Batch upsert for marking as read
      if (toMarkRead.isNotEmpty) {
        final readRecords = toMarkRead
            .map(
              (activity) => {
                'user_id': Base.userId.toString(),
                'activity_id': activity.id.toString(),
                'read_at': readAt.toIso8601String(),
              },
            )
            .toList();

        for (final record in readRecords) {
          await api.post<dynamic>('/sync/activity-read', body: record);
        }
      }

      // Batch delete for marking as unread
      if (toMarkUnread.isNotEmpty) {
        for (final activity in toMarkUnread) {
          await api.delete<dynamic>(
            '/sync/activity-read?user_id=${Uri.encodeQueryComponent(Base.userId.toString())}&activity_id=${Uri.encodeQueryComponent(activity.id.toString())}',
          );
        }
      }

      // Don't clear unreadUpdated here - let processPulledRows clear it
      // when the server confirms the unread state matches.
      // Clearing eagerly creates a race: a concurrent pull with stale data
      // (started before the activity_read push) can overwrite unread with
      // the stale server value because unreadUpdated was already null.
    } catch (e) {
      log.severe('Failed to push activity_read changes: $e');
      // unreadUpdated stays true, will be retried on next push
      rethrow;
    }

    return success;
  }

  static Future<List<Activity>> get({
    DateRange? range,
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool? draft = false,
    String? search,
    bool self = true,
    ActivityOrder order = ActivityOrder.sorted,
    List<Tag>? filter,
    bool includeAllFutureEvents = false,
  }) async {
    return await _get(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      order: order,
      search: search,
      self: self,
      filter: filter,
      includeAllFutureEvents: includeAllFutureEvents,
    );
  }

  static Stream<List<Activity>> watch({
    DateRange? range,
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool? draft = false,
    String? search,
    bool self = true,
    ActivityOrder order = ActivityOrder.sorted,
    List<Tag>? filter,
    bool includeAllFutureEvents = false,
  }) {
    return _getQuery(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      order: order,
      search: search,
      self: self,
      filter: filter,
      includeAllFutureEvents: includeAllFutureEvents,
    ).watch().asyncMap(
      (results) =>
          _mapResultsToActivities(results, archived: archived, range: range),
    );
  }

  static Future<Activity> getOne(ActivityId id) async {
    final activities = await _get(
      id: id,
      archived: null,
      draft: null,
      order: ActivityOrder.sorted,
    );
    if (activities.isEmpty) {
      log.warning("Activity not found: $id");
      throw Exception('Activity not found');
    }
    return activities.first;
  }

  static Stream<Activity> watchOne(ActivityId id) {
    return _getQuery(
      id: id,
      archived: null,
      draft: null,
      order: ActivityOrder.sorted,
    ).watch().asyncMap((results) async {
      final activities = await _mapResultsToActivities(results, range: null);
      if (activities.isEmpty) {
        throw Exception('Activity not found');
      }
      return activities.first;
    });
  }

  /// Get the most recent draft activity for a specific priority
  /// Returns the draft with the most recent updatedAt timestamp
  static Future<Activity?> getDraftByPriority(PriorityId priorityId) async {
    final drafts = await _get(
      priorityId: priorityId,
      draft: true,
      archived: null,
      order: ActivityOrder.sorted,
    );
    if (drafts.isEmpty) return null;
    // Sort by updatedAt descending to get the most recent
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return drafts.first;
  }

  // Note: _asNested method removed - path-based nesting is no longer supported.
  // Use Note model for thread structure instead.

  static Future<Activity?> next(
    Date? fromDate, {
    Priority? context,
    bool? archived = false,
    int offset = 0,
  }) async {
    if (fromDate == null) {
      return null;
    }
    final activities = await _get(
      range: CustomDateRange(fromDate, null),
      strictRange: true,
      priorityPath: context?.path,
      archived: archived,
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
    bool? archived = false,
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
      archived: archived,
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
    bool? archived = false,
    int offset = 0,
    List<Tag>? filter,
    String? search,
  }) {
    if (fromDate == null) {
      return Stream.value(null);
    }
    final startDate = fromDate;
    final range = CustomDateRange(startDate, null) as DateRange;

    return _getQuery(
      range: range,
      strictRange: true,
      priorityPath: context?.path,
      archived: archived,
      order: ActivityOrder.sorted,
      limit: 1,
      offset: offset,
      filter: filter,
      search: search,
    ).watch().asyncMap((results) async {
      final activities = await _mapResultsToActivities(
        results,
        archived: archived,
        range: range,
      );
      return activities.isEmpty ? null : activities.first;
    }).distinct();
  }

  static Stream<Activity?> watchPrevious(
    Date? fromDate, {
    Priority? context,
    bool? archived = false,
    int offset = 0,
    List<Tag>? filter,
    String? search,
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
      archived: archived,
      order: ActivityOrder.reverse,
      limit: 1,
      offset: offset,
      filter: filter,
      search: search,
    ).watch().asyncMap((results) async {
      final activities = await _mapResultsToActivities(
        results,
        archived: archived,
        range: range,
      );
      return activities.isEmpty ? null : activities.first;
    }).distinct();
  }

  /// Watch all tags present in activities within a priority and its descendants.
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForPriority(Path priorityPath) {
    final at = Store.get.activityTags;
    final a = Store.get.activities;
    final p = Store.get.priorities;

    final now = DateTime.now();
    final today = Date.today().toString();
    final priorityPathLike = '$priorityPath.%';

    // Query for stored tags from activity_tags table
    final tagsQuery = Store.get.select(at).join([
      innerJoin(a, a.id.equalsExp(at.id)),
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);

    tagsQuery.where(a.archivedAt.isNull());

    // COUNT query for Tag.done
    final doneQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    doneQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);
    doneQuery.where(a.archivedAt.isNull() & a.doneAt.isNotNull());
    final doneCountStream = doneQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for Tag.now
    final nowQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    nowQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);
    nowQuery.where(
      a.archivedAt.isNull() &
          a.type.equalsValue(ActivityType.action) &
          a.doneAt.isNull() &
          (
          // Date-based scheduling: startOn <= today
          (a.startOn.isSmallerOrEqualValue(today) & a.startAt.isNull()) |
              // DateTime-based scheduling: startAt <= now AND endAt >= now
              (a.startAt.isSmallerOrEqualValue(now) &
                  (a.endAt.isNull() | a.endAt.isBiggerOrEqualValue(now)) &
                  a.startOn.isNull())),
    );
    final nowCountStream = nowQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for Tag.later
    final laterQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    laterQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);
    laterQuery.where(
      a.archivedAt.isNull() &
          a.type.equalsValue(ActivityType.action) &
          a.doneAt.isNull() &
          (
          // Date-based scheduling: startOn > today
          (a.startOn.isBiggerThanValue(today) & a.startAt.isNull()) |
              // DateTime-based scheduling: startAt > now
              (a.startAt.isBiggerThanValue(now) & a.startOn.isNull())),
    );
    final laterCountStream = laterQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for Tag.archived
    final archivedQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    archivedQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);
    archivedQuery.where(a.archivedAt.isNotNull());
    final archivedCountStream = archivedQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for Tag.unread
    final unreadQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    unreadQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);
    unreadQuery.where(
      a.archivedAt.isNull() &
          a.draft.equals(false) &
          a.unread.equals(true) &
          (a.unreadUpdated.isNull() | a.unreadUpdated.equals(false)),
    );
    final unreadCountStream = unreadQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    return Rx.combineLatest6(
      tagsQuery.watch(),
      doneCountStream,
      nowCountStream,
      laterCountStream,
      archivedCountStream,
      unreadCountStream,
      (rows, doneCount, nowCount, laterCount, archivedCount, unreadCount) {
        final Map<Tag, int> tagCounts = {};

        // Count stored tags
        final Map<Tag, Set<ActivityId>> storedTagCounts = {};
        for (final row in rows) {
          final activityTagsRow = row.readTable(at);
          final activityId = activityTagsRow.id;
          final tags = activityTagsRow.tags;

          if (tags != null) {
            for (final tag in tags.keys) {
              storedTagCounts.putIfAbsent(tag, () => {}).add(activityId);
            }
          }
        }

        // Add stored tag counts
        for (final entry in storedTagCounts.entries) {
          tagCounts[entry.key] = entry.value.length;
        }

        // Add computed tag counts
        if (doneCount > 0) tagCounts[Tag.done] = doneCount;
        if (nowCount > 0) tagCounts[Tag.now] = nowCount;
        if (laterCount > 0) tagCounts[Tag.later] = laterCount;
        if (archivedCount > 0) tagCounts[Tag.archived] = archivedCount;
        if (unreadCount > 0) tagCounts[Tag.unread] = unreadCount;

        // Convert to list of (Tag, count) and sort by count descending
        final result = tagCounts.entries.map((e) => (e.key, e.value)).toList()
          ..sort((a, b) => b.$2.compareTo(a.$2));

        return result;
      },
    );
  }

  static Future<List<Activity>> _get({
    DateRange? range,
    bool strictRange = false,

    /* Selectors */
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,

    /* Filters */
    bool self = true,
    bool? archived = false,
    bool? draft = false,
    bool includeAllFutureEvents = false,
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
      self: self,
      archived: archived,
      draft: draft,
      includeAllFutureEvents: includeAllFutureEvents,
      search: search,
      filter: filter,
      order: order,
      limit: limit,
      offset: offset,
      getParent: getParent,
    );

    final results = await query.get();
    return _mapResultsToActivities(results, archived: archived, range: range);
  }

  static JoinedSelectStatement<HasResultSet, dynamic> _getQuery({
    DateRange? range,
    // Only include activities that start within the range
    bool strictRange = false,

    /* Selectors */
    ActivityId? id,
    PriorityId? priorityId,
    Path? priorityPath,

    /* Filters */
    bool self = true,
    bool? archived = false,
    bool? draft = false,
    bool includeAllFutureEvents = false,
    String? search,
    List<Tag>? filter,

    /* Sorting */
    ActivityOrder order = ActivityOrder.sorted,

    /* Pagination */
    int? limit,
    int? offset,

    /* Augmentation */
    bool getParent = true, // Deprecated, kept for compatibility
  }) {
    // Create a copy of filter to avoid mutating the original
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;
    if (mutableFilter?.remove(Tag.archived) == true) {
      archived = true;
    }

    if (range != null) {
      // Trigger sync for the date range
      if (archived == null) {
        // Fetch both archived and non-archived
        Activity.pullRange(range, priorityPath, archived: false);
        Activity.pullRange(range, priorityPath, archived: true);
      } else {
        Activity.pullRange(range, priorityPath, archived: archived);
      }
    }
    final doNow = mutableFilter?.remove(Tag.now) == true;
    final doLater = mutableFilter?.remove(Tag.later) == true;
    final done = mutableFilter?.remove(Tag.done) == true;
    final filterUnread = mutableFilter?.remove(Tag.unread) == true;

    final a = Store.get.alias(Store.get.activities, 'a');
    final startingQuery = Store.get.select(a);

    if (id != null) {
      startingQuery.where((t) => t.id.equalsValue(id));
    }
    if (priorityId != null) {
      startingQuery.where((t) => t.priorityId.equalsValue(priorityId));
    }

    var query = startingQuery.join([]);
    final now = DateTime.now();

    // Add priority filtering:
    // 1. Filter by priorityPath if provided
    // 2. Exclude activities with archived priorities when archived == false
    final p = Store.get.alias(Store.get.priorities, 'p');
    if (priorityPath != null) {
      // Join conditions for priority path matching
      Expression<bool> pathCondition =
          p.path.equalsValue(priorityPath) |
          p.path.likeExp(Constant('$priorityPath%'));

      if (includeAllFutureEvents) {
        pathCondition =
            pathCondition |
            (a.type.equalsValue(ActivityType.event) &
                a.endAt.isBiggerOrEqualValue(now));
      }

      // Also filter by priority archived status when looking at non-archived activities
      Expression<bool> joinCondition =
          p.id.equalsExp(a.priorityId) & pathCondition;
      if (archived == false) {
        joinCondition = joinCondition & p.archivedAt.isNull();
      }

      query = query.join([innerJoin(p, joinCondition)]);
    } else if (archived == false) {
      // When no priorityPath filter, still need to exclude activities with archived priorities
      query = query.join([
        innerJoin(p, p.id.equalsExp(a.priorityId) & p.archivedAt.isNull()),
      ]);
    }

    if (doNow) {
      // Get all user contact IDs from Actor cache
      final userActorIds = Actor._cache.values
          .where((actor) => actor.self)
          .map((actor) => actor.id.toBytes())
          .toList();

      // Fallback to primary contact if cache is empty
      if (userActorIds.isEmpty) {
        userActorIds.add(Base.actorId.toBytes());
      }

      query.where(
        a.type.equalsValue(ActivityType.action) &
            a.doneAt.isNull() &
            // Only include if unassigned or assigned to current user
            (a.assigneeId.isNull() | a.assigneeId.isIn(userActorIds)) &
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
      // Get all user contact IDs from Actor cache
      final userActorIds = Actor._cache.values
          .where((actor) => actor.self)
          .map((actor) => actor.id.toBytes())
          .toList();

      // Fallback to primary contact if cache is empty
      if (userActorIds.isEmpty) {
        userActorIds.add(Base.actorId.toBytes());
      }

      query.where(
        a.type.equalsValue(ActivityType.action) &
            a.doneAt.isNull() &
            // Only include if unassigned or assigned to current user
            (a.assigneeId.isNull() | a.assigneeId.isIn(userActorIds)) &
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
    if (filterUnread) {
      query.where(
        a.unread.equals(true) &
            (a.unreadUpdated.isNull() | a.unreadUpdated.equals(false)),
      );
    }
    if (archived != null) {
      query.where(archived ? a.archivedAt.isNotNull() : a.archivedAt.isNull());
    }
    if (draft != null) {
      query.where(a.draft.equals(draft));
    }
    if (search?.isNotEmpty == true) {
      // Use FTS5 for full-text search with prefix matching on activity title and note content
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
        // Search both activity title (activity_fts) and note content (note_fts)
        // Returns activities where either the title OR any note content matches
        query.where(
          CustomExpression<bool>('''
            EXISTS (SELECT 1 FROM activity_fts WHERE activity_id = a.id AND activity_fts MATCH '$words')
            OR
            EXISTS (SELECT 1 FROM note_fts WHERE activity_id = a.id AND note_fts MATCH '$words')
          '''),
        );
      }
    }
    if (self == false) {
      if (id != null) {
        query.where(a.id.equalsValue(id).not());
      }
    }

    // Get all user contact IDs for assignee checks
    // Used for both filtering and sorting
    final actorId = Base.actorId;
    final userActorIds = Actor._cache.values
        .where((actor) => actor.self)
        .map((actor) => actor.id.toBytes())
        .toList();
    if (userActorIds.isEmpty) {
      userActorIds.add(actorId.toBytes());
    }

    if (range != null) {
      final rangeStart = range.start?.toDateTime();
      final rangeEnd = range.end?.toDateTime();
      Expression<bool> condition = Constant(false);

      // Activities assigned to others - ALWAYS treat like notes (use creation times)
      // This matches agendaAt logic (lines 1528-1536) where assigned-to-others
      // return max(sourceCreatedAt, lastNoteSourceCreatedAt)
      Expression<bool> assignedToOthersInRange =
          a.assigneeId.isNotNull() & a.assigneeId.isNotIn(userActorIds);
      if (rangeStart != null) {
        assignedToOthersInRange =
            assignedToOthersInRange &
            (a.sourceCreatedAt.isBiggerOrEqualValue(rangeStart) |
                (a.lastNoteSourceCreatedAt.isNotNull() &
                    a.lastNoteSourceCreatedAt.isBiggerOrEqualValue(
                      rangeStart,
                    )));
      }
      if (rangeEnd != null) {
        assignedToOthersInRange =
            assignedToOthersInRange &
            (a.sourceCreatedAt.isSmallerThanValue(rangeEnd) |
                (a.lastNoteSourceCreatedAt.isNotNull() &
                    a.lastNoteSourceCreatedAt.isSmallerThanValue(rangeEnd)));
      }
      condition = condition | assignedToOthersInRange;

      // Unscheduled activities assigned to self/unassigned - use creation time
      Expression<bool> createdInRange =
          a.startOn.isNull() &
          a.startAt.isNull() &
          a.doneAt.isNull() &
          (a.assigneeId.isNull() | a.assigneeId.isIn(userActorIds));
      if (rangeStart != null) {
        createdInRange =
            createdInRange &
            (a.sourceCreatedAt.isBiggerOrEqualValue(rangeStart) |
                (a.lastNoteSourceCreatedAt.isNotNull() &
                    a.lastNoteSourceCreatedAt.isBiggerOrEqualValue(
                      rangeStart,
                    )));
      }
      if (rangeEnd != null) {
        createdInRange =
            createdInRange &
            (a.sourceCreatedAt.isSmallerThanValue(rangeEnd) |
                (a.lastNoteSourceCreatedAt.isNotNull() &
                    a.lastNoteSourceCreatedAt.isSmallerThanValue(rangeEnd)));
      }
      condition = condition | createdInRange;

      // Activity was completed within the range
      // For assigned-to-others, also check creation times (matching agendaAt line 1531)
      Expression<bool> completedInRange = a.doneAt.isNotNull();
      if (rangeStart != null) {
        // For assigned-to-others, check if created after start OR done after start
        final assignedToOthersCreatedAfterStart =
            (a.assigneeId.isNotNull() & a.assigneeId.isNotIn(userActorIds)) &
            (a.sourceCreatedAt.isBiggerOrEqualValue(rangeStart) |
                (a.lastNoteSourceCreatedAt.isNotNull() &
                    a.lastNoteSourceCreatedAt.isBiggerOrEqualValue(
                      rangeStart,
                    )));
        completedInRange =
            completedInRange &
            (a.doneAt.isBiggerOrEqualValue(rangeStart) |
                assignedToOthersCreatedAfterStart);
      }
      if (rangeEnd != null) {
        // For assigned-to-others, check if created before end OR done before end
        final assignedToOthersCreatedBeforeEnd =
            (a.assigneeId.isNotNull() & a.assigneeId.isNotIn(userActorIds)) &
            (a.sourceCreatedAt.isSmallerThanValue(rangeEnd) |
                (a.lastNoteSourceCreatedAt.isNotNull() &
                    a.lastNoteSourceCreatedAt.isSmallerThanValue(rangeEnd)));
        completedInRange =
            completedInRange &
            (a.doneAt.isSmallerThanValue(rangeEnd) |
                assignedToOthersCreatedBeforeEnd);
      }
      condition = condition | completedInRange;

      // Activity is scheduled before the end of the range (Date-based)
      // Exclude activities assigned to others - they use creation time via assignedToOthersInRange
      if (range.start != null || range.end != null) {
        Expression<bool> dateScheduled =
            a.startOn.isNotNull() &
            a.doneAt.isNull() &
            (a.assigneeId.isNull() | a.assigneeId.isIn(userActorIds));
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
      // Exclude activities assigned to others - they use creation time via assignedToOthersInRange
      Expression<bool> dateTimeScheduled =
          a.startAt.isNotNull() &
          a.doneAt.isNull() &
          (a.assigneeId.isNull() | a.assigneeId.isIn(userActorIds));
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
        // Activities assigned to others sort like notes (use creation time)
        CaseWhen(
          a.assigneeId.isNotNull() &
              a.assigneeId.isNotValue(actorId.toUuid().toBytes()),
          then: coalesce([a.lastNoteSourceCreatedAt, a.sourceCreatedAt]),
        ),
        CaseWhen(a.startAt.isNotNull(), then: a.startAt),
        CaseWhen(a.startOn.isNotNull(), then: a.startOn),
      ],
      // For non-scheduled activities, use GREATEST(sourceCreatedAt, lastNoteSourceCreatedAt)
      orElse: coalesce([a.lastNoteSourceCreatedAt, a.sourceCreatedAt]),
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

  /// Efficiently gets which activity IDs from the given list are active.
  /// An activity is active if it's an action assigned to current user,
  /// not done, not archived, and scheduled for now/past or unscheduled.
  static Future<Set<ActivityId>> _getActiveActivityIds(
    List<ActivityId> ids,
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
    final query = Store.get.selectOnly(a)..addColumns([a.id]);

    // Convert ActivityId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.id.isIn(idBytes) &
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
    return results.map((row) => Uuid.fromBytes(row.read(a.id)!)).toSet();
  }

  /// Efficiently gets which activity IDs from the given list are unread.
  /// An activity is unread if server says unread and we haven't overridden it locally.
  static Future<Set<ActivityId>> _getUnreadActivityIds(
    List<ActivityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    final a = Store.get.activities;
    final query = Store.get.selectOnly(a)..addColumns([a.id]);

    // Convert ActivityId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.id.isIn(idBytes) &
          a.unread.equals(true) &
          (a.unreadUpdated.isNull() | a.unreadUpdated.equals(false)),
    );

    final results = await query.get();
    return results.map((row) => Uuid.fromBytes(row.read(a.id)!)).toSet();
  }

  /// Maps database query results to Activity objects.
  ///
  /// This function handles both regular and recurring activities:
  /// - For non-recurring activities: Returns them directly
  /// - For recurring activities with a range: Generates occurrences within the range
  /// - For recurring activities without a range: Returns the base recurring activity template
  ///
  /// Recurring activities can have exceptions (modified/archived occurrences) stored in
  /// the activity_exceptions table, which override generated occurrences.
  static Future<List<Activity>> _mapResultsToActivities(
    List<TypedResult> results, {
    bool? archived = false,
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
      archived: archived == false ? false : null,
    );
    final priorityMap = Priority.asMap(priorities);

    // Group results by activity ID to handle activity exceptions
    final activityGroups = <Uuid, List<TypedResult>>{};
    for (final result in results) {
      final activityId = result.readTable(a).id;
      activityGroups.putIfAbsent(activityId, () => []).add(result);
    }

    // Compute which activities are active and unread (efficient bulk queries)
    final activityIds = activityGroups.keys.toList();
    final activeIds = await _getActiveActivityIds(activityIds);
    final unreadIds = await _getUnreadActivityIds(activityIds);

    // Separate recurring activities from non-recurring and collect database exceptions
    final activities = <Activity>[];
    for (final group in activityGroups.values) {
      final activityRow = group.first.readTable(a);
      final priority = priorityMap[activityRow.priorityId];
      if (priority == null) {
        // Skip activities with missing priority (e.g., priority was deleted or archived)
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
        active: activeIds.contains(activityRow.id),
        unreadComputed: unreadIds.contains(activityRow.id),
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
              active: activeIds.contains(activityRow.id),
              unreadComputed: unreadIds.contains(activityRow.id),
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

  static Map<Priority, List<Activity>> prioritize(
    List<Activity> activities, {
    Priority? context,
  }) {
    final Map<Priority, List<Activity>> activitiesByPriority = {};
    for (final activity in activities) {
      activitiesByPriority
          .putIfAbsent(activity.priority, () => [])
          .add(activity);
    }

    final Map<Priority, List<Activity>> sortedActivitiesByPriority = {};
    final priorities = activitiesByPriority.keys.toList()
      ..sort((a, b) {
        if (context != null && a == context && b != context) return 1;
        if (context != null && a != context && b == context) return -1;
        return a.compareTo(b);
      });

    for (final priority in priorities) {
      final priorityActivities = activitiesByPriority[priority]!;
      priorityActivities.sort();
      sortedActivitiesByPriority[priority] = priorityActivities;
    }

    return sortedActivitiesByPriority;
  }

  Activity({
    required this.priority,
    ActivityType type = ActivityType.note,
    Order? order,
    String? title,
    String? preview,
    bool draft = false,
    bool private = false,
    DateTimeRange? at,
    DateRange? on,
    ActorId? assigneeId,
    List<Note>? notes,
  }) : _activity = ActivityRow(
         id: Uuid.generate(),
         type: type,
         authorId: Base.actorId,
         assigneeId:
             assigneeId ?? (type == ActivityType.action ? Base.actorId : null),
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         sourceCreatedAt: Time.now(),
         priorityId: priority.id,
         draft: draft,
         private: private,
         order: order ?? Order.first(),
         title: title,
         preview: preview,
         startAt: at?.start,
         endAt: at?.end,
         startOn: on?.start,
         endOn: on?.end,
         unread: false,
         unreadUpdated: null,
       ),
       _exception = null,
       _tags = null,
       _notes = notes,
       _active = null,
       _unreadComputed = null;

  Activity._fromStore({
    required ActivityRow activity,
    required this.priority,
    ActivityExceptionRow? exception,
    ActivityTagsRow? tags,
    List<Note>? notes,
    bool? active,
    bool? unreadComputed,
  }) : _activity = activity,
       _exception = exception,
       _tags = tags,
       _notes = notes,
       _active = active,
       _unreadComputed = unreadComputed {
    assert(
      priority.id == activity.priorityId,
      "Priority does not match activity",
    );
  }

  final ActivityRow _activity;
  final ActivityExceptionRow? _exception;
  final ActivityTagsRow? _tags;
  final List<Note>? _notes;
  final bool? _active;
  final bool? _unreadComputed;

  final Priority priority;

  Uuid get id => _activity.id;
  bool get recurring => _activity.recurrenceRule != null && _exception == null;
  Order get order => _activity.order;
  DateTime get createdAt => _activity.createdAt;
  DateTime get sourceCreatedAt => _activity.sourceCreatedAt;
  DateTime get updatedAt => _activity.updatedAt;
  DateTime? get archivedAt => _activity.archivedAt;
  bool get draft => _activity.draft;
  bool get private => _activity.private;
  ActorId get authorId => _activity.authorId;
  ActorId? get assigneeId => _activity.assigneeId;
  ActivityType get type => _activity.type;
  ActivityKind? get kind => _activity.kind;
  DateTime? get doneAt => _exception?.doneAt ?? _activity.doneAt;
  DateTime? get lastNoteCreatedAt => _activity.lastNoteCreatedAt;
  DateTime? get lastNoteSourceCreatedAt => _activity.lastNoteSourceCreatedAt;
  RecurrenceRule? get recurrenceRule => _activity.recurrenceRule;
  List<DateTime>? get recurrenceExdates => _activity.recurrenceExdates;
  Map<Tag, List<ActorId>> get tags => {
    ...Map.fromEntries(
      [
        Tag.now,
        Tag.later,
        Tag.done,
        Tag.archived,
        Tag.private,
      ].where((tag) => hasTag(tag)).map((tag) => MapEntry(tag, [authorId])),
    ),
    ...(_tags?.tags ?? const {}),
  };

  /// Returns true if this activity is active (computed from query or false if not computed)
  bool get active => _active ?? false;

  /// Returns true if this activity is unread (considering local overrides)
  bool get unread {
    final computed = _unreadComputed;
    final stored = _activity.unread;
    final result = computed ?? stored;

    return result;
  }

  bool? get unreadUpdated => _activity.unreadUpdated;

  String? get title => _exception?.title ?? _activity.title;
  String? get preview => _activity.preview;
  List<Link>? get links => _activity.links;
  List<Note>? get notes => _notes;

  /// Returns the first note if notes are loaded
  Note? get firstNote => notes?.firstOrNull;

  /// Returns true if this activity has any notes
  bool get hasNotes => notes != null && notes!.isNotEmpty;

  String get displayTitle {
    if (title != null) return title!;
    if (preview != null) return preview!;
    return draft ? '🤷' : 'Untitled';
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

  DateTime get agendaAt {
    // For events, return the end time
    if (type == .event && at?.start != null) {
      return at!.start!;
    }

    // For activities assigned to others, use creation time (treat like notes)
    if (assigneeId != null && !assigneeId!.isCurrentUser) {
      final times = [
        sourceCreatedAt,
        ?doneAt,
        ?_activity.lastNoteSourceCreatedAt,
      ];
      times.sort((a, b) => b.compareTo(a)); // Sort descending
      return times.first; // Return the greatest (most recent)
    }

    // For unscheduled activities, use GREATEST(sourceCreatedAt, doneAt, lastNoteSourceCreatedAt)
    if ((on == null && at == null) || doneAt != null) {
      final times = [
        sourceCreatedAt,
        ?doneAt,
        ?_activity.lastNoteSourceCreatedAt,
      ];
      times.sort((a, b) => b.compareTo(a)); // Sort descending
      return times.first; // Return the greatest (most recent)
    }

    return (doNow ? Time.now() : null) ??
        at?.start ??
        on?.start?.toDateTime() ??
        sourceCreatedAt;
  }

  bool get doNow =>
      !assignedToOther && todo && at?.includes(Time.now()) == true;
  bool get otherDoingNow =>
      assignedToOther && todo && at?.includes(Time.now()) == true;
  bool get doLater =>
      !assignedToOther && todo && at?.start?.isAfter(Time.now()) == true;
  bool get doSomeday => todo && (on == null && at == null);
  bool get todo => type == ActivityType.action && !done;
  bool get done => doneAt != null;
  bool get isPast =>
      at?.end?.isBefore(Time.now()) == true ||
      on?.end?.isBefore(Date.today()) == true;
  bool get isFuture =>
      at?.start?.isAfter(Time.now()) == true ||
      on?.start?.isAfter(Date.today()) == true;
  bool get assignedToOther => assigneeId?.isCurrentUser == false;

  String? get occurrence => _exception?.occurrence;

  IconData get icon {
    // For actions, always use state-based icons (done, doNow, doLater, doSomeday)
    if (type == ActivityType.action) {
      if (done) return assignedToOther ? PlotIcon.otherDone : PlotIcon.done;
      if (doNow) return PlotIcon.now;
      if (otherDoingNow) return PlotIcon.other;
      if (doLater) return PlotIcon.later;
      if (doSomeday) return PlotIcon.someday;
    }

    // For events and notes, check for kind-specific icon first
    final kindIcon = _iconForKind(kind);
    if (kindIcon != null) return kindIcon;

    // Fall back to type-based icons
    if (type == ActivityType.event) {
      if (currentUserRsvpSkip) {
        return PlotIcon.calendarXmark;
      } else if (shouldShowRsvpPlus) {
        return PlotIcon.calendarPlus;
      } else {
        return PlotIcon.event;
      }
    }
    return PlotIcon.note;
  }

  IconData? _iconForKind(ActivityKind? kind) {
    if (kind == null) return null;

    switch (kind) {
      case ActivityKind.document:
        return PlotIcon.document;
      case ActivityKind.messages:
        return PlotIcon.messages;
      case ActivityKind.meeting:
        return PlotIcon.meeting;
      case ActivityKind.videoconference:
        return PlotIcon.videoconference;
      case ActivityKind.phone:
        return PlotIcon.phone;
      case ActivityKind.focus:
        return PlotIcon.focus;
      case ActivityKind.meal:
        return PlotIcon.meal;
      case ActivityKind.exercise:
        return PlotIcon.exercise;
      case ActivityKind.family:
        return PlotIcon.family;
      case ActivityKind.travel:
        return PlotIcon.travel;
      case ActivityKind.social:
        return PlotIcon.social;
      case ActivityKind.entertainment:
        return PlotIcon.entertainment;
    }
  }

  static const separator = ' › ';

  Activity copyWith({
    // These fields always update the root activity
    Priority? priority,
    ActivityType? type,
    ActivityKind? kind,
    Order? order,
    bool? draft,
    bool? private,
    ActorId? assigneeId,
    bool? unread,
    Value<List<Uuid>?> mentions = const Value.absent(),
    Value<String?> preview = const Value.absent(),
    Value<List<Note>?> notes = const Value.absent(),

    // These fields update the exception if this is a recurrence, or the root activity otherwise
    Value<DateTimeRange?> at = const Value.absent(),
    Value<DateRange?> on = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
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
    Value<String?> recurrenceTitle = const Value.absent(),
    Value<Duration?> recurrenceDuration = const Value.absent(),
  }) {
    final now = DateTime.now();

    // on and at are mutually exclusive
    if (at.notNull) {
      on = Value(null);
    } else if (on.notNull && this.at != null) {
      at = Value(null);
    }

    // Mark activity as read when marking as done
    if (doneAt.present &&
        doneAt.value != null &&
        unread == null &&
        this.unread) {
      unread = false;
    }

    // Only actions can have done_at — auto-promote type when marking done
    if (doneAt.present && doneAt.value != null) {
      type ??= ActivityType.action;
    }

    // Ensure assigneeId is set when converting to action type
    // If type is being changed to action and no assigneeId is provided, default to current user
    if (type == ActivityType.action &&
        assigneeId == null &&
        _activity.assigneeId == null) {
      assigneeId = Base.actorId;
    }

    // Update root activity if any root-specific fields are changing
    var activity = _activity;
    if (priority != null ||
        type != null ||
        kind != null ||
        order != null ||
        draft != null ||
        private != null ||
        assigneeId != null ||
        unread != null ||
        mentions.present ||
        preview.present ||
        recurrenceAt.present ||
        recurrenceOn.present ||
        recurrenceDoneAt.present ||
        recurrenceDeletedAt.present ||
        recurrenceRule.present ||
        recurrenceExdates.present ||
        recurrenceTitle.present ||
        recurrenceDuration.present ||
        (!recurring &&
            (at.present ||
                on.present ||
                doneAt.present ||
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
        if (title.present) rootTitle = title;
        if (duration.present) rootDuration = duration;
      }

      activity = _activity.copyWith(
        priorityId: priority?.id,
        type: type,
        kind: kind != null ? Value(kind) : const Value.absent(),
        order: order,
        draft: draft,
        private: private,
        assigneeId: assigneeId != null
            ? Value(assigneeId)
            : const Value.absent(),
        mentions: mentions,
        preview: preview,
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
        title: rootTitle,
        duration: rootDuration,
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
        duration: duration,
        // Note: exceptions don't have archivedAt, so we ignore that field
      );
    }

    return Activity._fromStore(
      activity: activity,
      exception: exception,
      tags: _tags,
      priority: priority ?? this.priority,
      notes: notes.present ? notes.value : _notes,
    );
  }

  Activity toggleTag(Tag tag) {
    // Handle computed tags
    switch (tag) {
      case Tag.archived:
        return copyWith(
          archivedAt: Value(archivedAt == null ? DateTime.now() : null),
        );
      case Tag.private:
        return copyWith(private: !private);
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
                      Time.now(),
                      Time.now().add(Duration(hours: 1)),
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
          doneAt: Value(done ? null : Time.now()),
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

    final currentTags = Map<Tag, List<ActorId>>.from(tags);
    // For RSVP tags, select the most appropriate actor
    // For other tags, use the primary actor
    final currentUser = tag.isRsvp ? selectRsvpActorId() : Base.actorId;

    // Get current users for this tag
    final List<ActorId> currentUsers = List<ActorId>.from(
      currentTags[tag] ?? <ActorId>[],
    );

    bool isAdding = false;

    // Initialize tag updates map early since we need it for RSVP exclusivity
    final currentTagUpdates = Map<String, bool>.from(_tags?.tagsUpdated ?? {});

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
        // RSVP tags are mutually exclusive - remove other RSVP tags before adding
        if (tag.isRsvp) {
          for (final rsvpTag in Tag.rsvpTags) {
            if (rsvpTag != tag) {
              final rsvpUsers = currentTags[rsvpTag];
              if (rsvpUsers != null && rsvpUsers.contains(currentUser)) {
                // Remove current user from conflicting RSVP tag
                rsvpUsers.remove(currentUser);
                if (rsvpUsers.isEmpty) {
                  currentTags.remove(rsvpTag);
                } else {
                  currentTags[rsvpTag] = rsvpUsers;
                }
                // Track removal in tagsUpdated
                currentTagUpdates[rsvpTag.id.toString()] = false;
              }
            }
          }
        }

        // Add current user to tag (increment count)
        currentUsers.add(currentUser);
        currentTags[tag] = currentUsers;
        isAdding = true; // Adding the user's count
      }
    }

    // Update the tag updates map
    currentTagUpdates[tag.id.toString()] = isAdding;
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

    // Trigger full push including activity_read changes (fire and forget)
    // This ensures activity_read is synced immediately, not just during sync cycles
    Activity.push();

    // Generate a title on the first non-draft save
    if (title == null && !draft) {
      final generatedTitle = await generateTitle();
      log.info("Generated title: $generatedTitle");
      await copyWith(title: Value(generatedTitle)).save();
    }
  }

  Future<String> generateTitle([String noteContent = '']) async {
    // If no note content provided, return displayTitle as fallback
    if (noteContent.isEmpty) {
      return displayTitle;
    }

    try {
      final response = await api.post<Map<String, dynamic>>(
        '/summary',
        body: {'body': noteContent},
      );
      final generatedTitle = response['title'] as String?;

      if (generatedTitle != null && generatedTitle.isNotEmpty) {
        log.info("Generated title for activity $id: $generatedTitle");
        return generatedTitle;
      } else {
        log.info("API returned empty title for activity $id, using fallback");
        return displayTitle;
      }
    } catch (e, t) {
      log.warning("Error generating title for activity $id: $e\n$t");
      return displayTitle;
    }
  }

  Future<void> delete() => copyWith(archivedAt: Value(DateTime.now())).save();

  bool hasTag(Tag tag) {
    switch (tag) {
      case Tag.now:
        return doNow;
      case Tag.later:
        return doLater;
      case Tag.done:
        return done;
      case Tag.archived:
        return archivedAt != null;
      case Tag.private:
        return private;
      default:
        final currentTags = tags;
        final users = currentTags[tag];
        return users != null && users.isNotEmpty;
    }
  }

  /// Get actor names for a tag, formatted for display in tooltips
  /// Returns a formatted string like "You, Alice, Bob" or "You, Alice, Bob + 2 more"
  Future<String> getTagActorNames(Tag tag) async {
    // Special case: For now/later/done tags, show assignee instead of author
    if (assigneeId != null && [Tag.now, Tag.later, Tag.done].contains(tag)) {
      return Activity._formatActorNames([assigneeId!]);
    }

    // Default behavior for all other tags
    final actorIds = tags[tag];
    if (actorIds == null || actorIds.isEmpty) {
      return '';
    }

    return Activity._formatActorNames(actorIds);
  }

  /// Helper to format a list of actorIds into a display string
  /// - Replaces current user with "You"
  /// - Shows first 3 names + count if more exist
  static Future<String> _formatActorNames(List<ActorId> actorIds) async {
    if (actorIds.isEmpty) return '';

    // Fetch actor names from the database
    final actorRows =
        await (Store.get.select(Store.get.actors)..where(
              (a) => a.id.isIn(actorIds.map((id) => id.toBytes()).toList()),
            ))
            .get();

    // Convert to Actor objects and create a map of actorId to nameOrEmail
    final actors = actorRows.map((row) => Actor.fromStore(row)).toList();
    final actorMap = {for (var actor in actors) actor.id: actor.nameOrEmail};

    // Build the display names list
    final displayNames = <String>[];
    final currentContactId = Base.actorId;

    for (final actorId in actorIds) {
      if (actorId == currentContactId) {
        displayNames.insert(0, 'You'); // Put "You" first
      } else {
        final name = actorMap[actorId] ?? 'Unknown';
        displayNames.add(name);
      }
    }

    // Format the output
    if (displayNames.length <= 3) {
      return displayNames.join(', ');
    } else {
      final first3 = displayNames.take(3).join(', ');
      final remaining = displayNames.length - 3;
      return '$first3 + $remaining more';
    }
  }

  /// Returns true if the current user has RSVP'd attend for this activity
  bool get currentUserRsvpAttend {
    final attendActors = tags[Tag.attend];
    if (attendActors == null) return false;
    return attendActors.any((actorId) => actorId.isCurrentUser);
  }

  /// Returns true if the current user has RSVP'd skip for this activity
  bool get currentUserRsvpSkip {
    final skipActors = tags[Tag.skip];
    if (skipActors == null) return false;
    return skipActors.any((actorId) => actorId.isCurrentUser);
  }

  /// Returns true if the current user has RSVP'd undecided for this activity
  bool get currentUserRsvpUndecided {
    final undecidedActors = tags[Tag.undecided];
    if (undecidedActors == null) return false;
    return undecidedActors.any((actorId) => actorId.isCurrentUser);
  }

  /// Returns true if this event has a different author and user hasn't RSVP'd attend or skip
  bool get shouldShowRsvpPlus {
    if (type != ActivityType.event) return false;
    if (authorId?.isCurrentUser == true) return false;
    return !currentUserRsvpAttend && !currentUserRsvpSkip;
  }

  /// Selects the most appropriate actor ID for RSVP operations.
  ///
  /// Priority:
  /// 1. If any of the user's actors already has an RSVP tag, use that actor
  /// 2. If the event author is one of the user's actors, use the author
  /// 3. Fall back to the primary actor (Base.actorId)
  ActorId selectRsvpActorId() {
    final userActorIds = Actor.getCurrentUserActorIds();

    // Priority 1: Check if any user actor already has an RSVP tag
    for (final rsvpTag in Tag.rsvpTags) {
      final rsvpActors = tags[rsvpTag];
      if (rsvpActors != null) {
        for (final actorId in rsvpActors) {
          if (userActorIds.contains(actorId)) {
            // This user actor already has an RSVP - use it
            return actorId;
          }
        }
      }
    }

    // Priority 2: Check if the author is one of the user's actors
    if (userActorIds.contains(authorId)) {
      return authorId;
    }

    // Priority 3: Fall back to primary actor
    return Base.actorId;
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

    if (instanceSet.isEmpty) {
      return null;
    }

    // Sort instances and return the first or last based on reverse parameter
    final sortedInstances = instanceSet.toList()..sort();
    final targetInstance = reverse
        ? sortedInstances.last
        : sortedInstances.first;

    // Convert to Date and verify it's within the intended range
    // This ensures occurrences at range boundaries are properly excluded
    final targetDate = targetInstance.toDate();
    if (!range.includes(targetDate)) {
      return null;
    }

    return targetDate;
  }

  /// Activity are sorted in this order:
  /// - For ActivityType.note, GREATEST(sourceCreatedAt, doneAt, lastNoteSourceCreatedAt)
  /// - For ActivityType.action, doneAt ?? startAt.toDate()/startOn
  /// - For ActivityType.event, startAt/startOn
  /// Ties are broken using the order property.
  @override
  int compareTo(Activity other) {
    // Get sort time based on type
    final thisTime = _getSortTime();
    final otherTime = other._getSortTime();

    // Compare times
    final timeComparison = thisTime.compareTo(otherTime);
    if (timeComparison != 0) {
      return timeComparison;
    }

    // Break ties with order
    return order.compareTo(other.order);
  }

  DateTime _getSortTime() {
    // Activities assigned to others sort like notes (use creation time)
    if (assigneeId != null && !assigneeId!.isCurrentUser) {
      return [
        sourceCreatedAt,
        ?doneAt,
        ?_activity.lastNoteSourceCreatedAt,
      ].whereType<DateTime>().reduce((a, b) => a.isAfter(b) ? a : b);
    }

    final time = switch (type) {
      ActivityType.action => doneAt ?? at?.start ?? on?.start?.toDateTime(),
      ActivityType.event => at?.start ?? on?.start?.toDateTime(),
      _ => null,
    };
    return time ??
        [sourceCreatedAt, ?doneAt, ?_activity.lastNoteSourceCreatedAt]
            .whereType<DateTime>()
            .reduce((a, b) => a.isAfter(b) ? a : b); // Descending
  }

  @override
  List<Object?> get props => [_activity, _exception, _tags, _notes, priority];

  @override
  String toString() {
    final buffer = StringBuffer('Activity(');

    // ID and type
    buffer.write('id: ${id.toString().substring(0, 8)}..., ');
    buffer.write('type: ${type.name}, ');

    // Title (truncated)
    final titleStr = title;
    if (titleStr != null) {
      final truncatedTitle = titleStr.length > 50
          ? '${titleStr.substring(0, 47)}...'
          : titleStr;
      buffer.write('title: "$truncatedTitle", ');
    }

    // Preview (truncated)
    final previewStr = preview;
    if (previewStr != null && previewStr.isNotEmpty) {
      final truncatedPreview = previewStr.length > 50
          ? '${previewStr.substring(0, 47)}...'
          : previewStr;
      buffer.write('preview: "$truncatedPreview", ');
    }

    // Priority
    buffer.write('priority: ${priority.title}, ');

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
      buffer.write('archived: $archivedAt, ');
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
