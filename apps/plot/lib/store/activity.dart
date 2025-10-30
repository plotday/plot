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

enum LinkType { external, auth, hidden, callback }

abstract class Link extends Equatable {
  const Link({required this.type});

  final LinkType type;

  factory Link.fromJson(Map<String, dynamic> json) {
    final type = LinkType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => LinkType.external,
    );

    switch (type) {
      case LinkType.external:
        return ExternalLink.fromJson(json);
      case LinkType.auth:
        return AuthLink.fromJson(json);
      case LinkType.hidden:
        return HiddenLink.fromJson(json);
      case LinkType.callback:
        return CallbackLink.fromJson(json);
    }
  }

  Map<String, dynamic> toJson();
}

class ExternalLink extends Link {
  const ExternalLink({required this.title, required this.url})
    : super(type: LinkType.external);

  final String title;
  final String url;

  factory ExternalLink.fromJson(Map<String, dynamic> json) {
    return ExternalLink(
      title: json['title'] as String,
      url: json['url'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': type.name, 'title': title, 'url': url};
  }

  @override
  List<Object?> get props => [type, title, url];
}

class AuthLink extends Link {
  const AuthLink({
    required this.title,
    required this.provider,
    required this.level,
    required this.scopes,
    required this.callback,
  }) : super(type: LinkType.auth);

  final String title;
  final AuthProvider provider;
  final String level;
  final List<String> scopes;
  final String callback;

  factory AuthLink.fromJson(Map<String, dynamic> json) {
    return AuthLink(
      title: json['title'] as String,
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      level: json['level'] as String,
      scopes: (json['scopes'] as List).cast<String>(),
      callback: json['callback'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'title': title,
      'provider': provider.name,
      'level': level,
      'scopes': scopes,
      'callback': callback,
    };
  }

  @override
  List<Object?> get props => [type, title, provider, level, scopes, callback];
}

class HiddenLink extends Link {
  const HiddenLink({this.metadata = const {}}) : super(type: LinkType.hidden);

  final Map<String, dynamic> metadata;

  String get title => '';
  Map<String, dynamic> get extras => metadata;

  factory HiddenLink.fromJson(Map<String, dynamic> json) {
    final metadata = Map<String, dynamic>.from(json);
    metadata.remove('type');
    return HiddenLink(metadata: metadata);
  }

  @override
  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(metadata);
    json['type'] = type.name;
    return json;
  }

  @override
  List<Object?> get props => [type, metadata];
}

class CallbackLink extends Link {
  const CallbackLink({required this.title, required this.token})
    : super(type: LinkType.callback);

  final String title;
  final String token;

  factory CallbackLink.fromJson(Map<String, dynamic> json) {
    return CallbackLink(
      title: json['title'] as String,
      token: json['token'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': type.name, 'title': title, 'token': token};
  }

  @override
  List<Object?> get props => [type, title, token];
}

class LinksConverter extends TypeConverter<List<Link>?, String?>
    with JsonTypeConverter2<List<Link>?, String?, List<dynamic>?> {
  const LinksConverter();

  @override
  List<Link>? fromSql(String? fromDb) {
    if (fromDb == null || fromDb.isEmpty) {
      return null;
    }
    try {
      final dynamic jsonData = jsonDecode(fromDb);
      if (jsonData is List) {
        return jsonData
            .map((json) => Link.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  @override
  String? toSql(List<Link>? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return jsonEncode(value.map((link) => link.toJson()).toList());
  }

  @override
  List<Link>? fromJson(List<dynamic>? json) {
    if (json == null) {
      return null;
    }
    try {
      return json
          .map((item) => Link.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  @override
  List<dynamic>? toJson(List<Link>? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return value.map((link) => link.toJson()).toList();
  }
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase()
    : super(
        table: 'user_activity',
        writeTable: 'activity',
        name: "activities",
        ascending:
            false, // Get latest items first for reverse chronological sync
      );

  @override
  PostgrestFilterBuilder<T2> filterRange<T2>(
    PostgrestFilterBuilder<T2> query,
    String? from,
    String? to,
  ) {
    final range = CustomDateRange(
      from != null ? Date.fromString(from) : null,
      to != null ? Date.fromString(to) : null,
    );
    query = query.or(
      'range_at.ov."${range.toDb()}",range_on.ov."${range.toDb()}"',
    );
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
  /// Parse @mentions from note and return list of agent UUIDs
  static List<Uuid> parseMentionsFromNote(String? note, List<PriorityAgent> agents) {
    if (note == null || note.isEmpty || agents.isEmpty) {
      return [];
    }

    // Extract @mentions using regex (case-insensitive)
    final mentionPattern = RegExp(r'@([\w_]+)', caseSensitive: false);
    final matches = mentionPattern.allMatches(note);

    if (matches.isEmpty) {
      return [];
    }

    // Collect mentioned names (normalized to lowercase)
    final mentionedNames = matches
        .map((match) => match.group(1)?.toLowerCase())
        .where((name) => name != null)
        .cast<String>()
        .toSet();

    // Match against agent names (normalized)
    final mentionedAgentIds = <Uuid>[];
    for (final agent in agents) {
      // Normalize agent name: lowercase and replace spaces with underscores
      final normalizedAgentName = agent.name.toLowerCase().replaceAll(' ', '_');

      if (mentionedNames.contains(normalizedAgentName)) {
        mentionedAgentIds.add(Uuid.fromString(agent.id));
      }
    }

    // Return unique agent IDs
    return mentionedAgentIds.toSet().toList();
  }

  static Future<bool> pull() async {
    return await Store.get.pull(
          PullType.updates,
          Store.get.activities,
          ActivitiesBase(),
        ) &&
        await Store.get.pull(
          PullType.updates,
          Store.get.activityExceptions,
          ActivityExceptionsBase(),
        ) &&
        await Store.get.pull(
          PullType.updates,
          Store.get.activityTags,
          ActivityTagsBase(),
        );
  }

  static Future<bool> pullRange(DateRange range) async {
    return (await Store.get.pull(
          PullType.more,
          Store.get.activities,
          ActivitiesBase(),
          range: (range.start?.toString(), range.end?.toString()),
        )) &&
        (await Store.get.pull(
          PullType.more,
          Store.get.activityExceptions,
          ActivityExceptionsBase(),
          range: (range.start?.toString(), range.end?.toString()),
        )) &&
        (await Store.get.pull(
          PullType.more,
          Store.get.activityTags,
          ActivityTagsBase(),
          range: (range.start?.toString(), range.end?.toString()),
        ));
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
      Activity.pullRange(range);
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

    if (doNow) {
      final now = DateTime.now();
      query.where(
        a.type.equalsValue(ActivityType.task) &
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
        a.type.equalsValue(ActivityType.task) &
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
                (tags.occurrence.isNull() & exceptions.occurrence.isNull())),
      ),
    ]);

    return query;
  }

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
      final baseActivity = Activity._fromStore(
        activity: activityRow,
        priority: priority,
        tags: activityRow.recurrenceRule == null
            ? group.first.readTableOrNull(tags)
            : null,
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
         pending: ActivityPendingSync.full.value,
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
  DateTime? get deletedAt => _activity.deletedAt;
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
  String? get noteText => (_exception?.note ?? _activity.note)
      ?.removeMarkdown()
      .replaceAll('\n', ' ')
      .trim();
  String get displayTitle =>
      title ??
      note?.split("\n").first.removeMarkdown().trim().truncate(50) ??
      (draft ? '🤷' : 'Untitled');

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
  bool get todo => type == ActivityType.task && !done;
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
    Value<DateTime?> deletedAt = const Value.absent(),

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
                deletedAt.present))) {
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
        if (deletedAt.present) rootDeletedAt = deletedAt;
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
        updatedAt: now,
        pending: Value(ActivityPendingSync.full.value),
        startAt: rootStartAt,
        endAt: rootEndAt,
        startOn: rootStartOn,
        endOn: rootEndOn,
        doneAt: rootDoneAt,
        deletedAt: rootDeletedAt,
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
            deletedAt.present)) {
      exception = exception!.copyWith(
        startAt: at.present ? Value(at.value?.start) : const Value.absent(),
        endAt: at.present ? Value(at.value?.end) : const Value.absent(),
        startOn: on.present ? Value(on.value?.start) : const Value.absent(),
        endOn: on.present ? Value(on.value?.end) : const Value.absent(),
        doneAt: doneAt,
        title: title,
        note: note,
        duration: duration,
        // Note: exceptions don't have deletedAt, so we ignore that field
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
          deletedAt: Value(deletedAt == null ? DateTime.now() : null),
        );
      case Tag.now:
        if (doNow) {
          // Removing doNow - clear scheduling
          return copyWith(
            on: const Value(null),
            at: const Value(null),
            doneAt: const Value(null),
          );
        } else {
          // Adding doNow - preserve existing scheduling type or default to date-based
          final hasDateTime = at != null;
          return copyWith(
            type: ActivityType.task,
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
          type: ActivityType.task,
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
      "Toggling tag ${tag.name} (${tag.type}) to $isAdding ($currentTags)",
    );

    return Activity._fromStore(
      activity: _activity,
      exception: _exception,
      tags:
          _tags?.copyWith(
            updatedAt: DateTime.now(),
            tags: Value(currentTags.isEmpty ? null : currentTags),
            tagsUpdated: Value(currentTagUpdates),
          ) ??
          ActivityTagsRow(
            id: id,
            updatedAt: DateTime.now(),
            tags: currentTags.isEmpty ? null : currentTags,
            tagsUpdated: currentTagUpdates.isEmpty ? null : currentTagUpdates,
          ),
      priority: priority,
      parent: parent,
    );
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

  Future<void> delete() => copyWith(deletedAt: Value(DateTime.now())).save();

  bool hasTag(Tag tag) {
    switch (tag) {
      case Tag.archived:
        return deletedAt != null;
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

    // Generate instances within the range using the rrule package
    final start = (at?.start ?? on?.start?.toDateTime())!;
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

    // Generate instances within the range using the rrule package
    final instances = recurrenceRule!.getInstances(
      start: (at?.start ?? on?.start?.toDateTime())!.copyWith(isUtc: true),
      after: dateTimeRange.start,
      includeAfter: true,
      before: dateTimeRange.end,
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

    // Otherwise, compare doneAt ?? createdAt
    final thisTime = doneAt ?? createdAt;
    final otherTime = other.doneAt ?? other.createdAt;
    return thisTime.compareTo(otherTime);
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

    if (deletedAt != null) {
      buffer.write('deleted: $deletedAt, ');
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
