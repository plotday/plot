part of 'store.dart';

enum EventResponse { accepted, declined, tentative }

enum EventStatus { confirmed, cancelled, tentative }

enum EventVisibility { normal, private, confidential, public, personal }

enum EventAvailability { busy, away, focus, free, location }

typedef EventId = Uuid;

@DataClassName('EventRow')
class Events extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  TextColumn get name => text().nullable()();
  DateTimeColumn get start => dateTime().map(const LocalDateTimeConverter())();
  DateTimeColumn get end => dateTime().map(const LocalDateTimeConverter())();
  TextColumn get series => text().nullable()();
  TextColumn get response => textEnum<EventResponse>().nullable().withDefault(
    Constant(EventResponse.accepted.name),
  )();
  TextColumn get status => textEnum<EventStatus>().withDefault(
    Constant(EventStatus.confirmed.name),
  )();
  TextColumn get visibility => textEnum<EventVisibility>().withDefault(
    Constant(EventVisibility.normal.name),
  )();
  TextColumn get availability => textEnum<EventAvailability>().withDefault(
    Constant(EventAvailability.free.name),
  )();
  BoolColumn get inviteesHidden =>
      boolean().withDefault(const Constant(false))();
  BlobColumn get priorityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Priorities, #id)();
  IntColumn get calendarId => integer().nullable().references(Calendars, #id)();
  TextColumn get conferencingUrl => text().nullable()();
}

class EventsBase extends BaseTable {
  EventsBase({super.filterName, super.ascending, super.limit})
    : super(
        table: 'event_x',
        name: 'events',
        upsertAsUpdate: true,
        order: 'day',
      );

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    final range = DateTimeRange(
      DateTime.parse(json['start'] as String),
      DateTime.parse(json['end'] as String),
    );
    json['at'] = range.toDb();
    json['user_id'] = Base.userId.toString();
    json.remove('start');
    json.remove('end');
    return json;
  }

  @override
  EventRow fromBase(Map<String, dynamic> json) {
    final range = DateTimeRange.fromString(json['at'] as String);
    json['start'] = range.start.toDb();
    json['end'] = range.end.toDb();
    return EventRow.fromJson(json);
  }

  @override
  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    // While we fetch and order by 'day', we want the sort to be more granular
    return query.order('at', ascending: true);
  }
}

class Event extends EventRow {
  static TableInfo<Events, EventRow> get table => Store.get.events;

  static Future<void> push() => Store.get.push(table, EventsBase());
  static Future<bool> pull() =>
      Store.get.pull(PullType.updates, table, EventsBase());
  static Future<bool> pullRange(DateRange range) => Store.get.pull(
    PullType.more,
    table,
    EventsBase(),
    range: (range.start.toString(), range.end.toString()),
  );

  static Stream<List<Event>> watch(
    DateRange range, {
    bool withPriority = false,
    bool? deleted = false,
    Priority? context,
  }) {
    final ascending = range.start <= range.end;

    if (withPriority || context != null) {
      return Rx.combineLatest2(
        _get(
          range: range,
          context: context,
          deleted: deleted,
          withPriority: true,
          ascending: ascending,
        ).watch(),
        Priority.watchDefault(),
        (events, defaultPriority) => events
            .map(
              (event) => event.priority != null
                  ? event
                  : Event.fromStore(event, priority: defaultPriority),
            )
            .toList(),
      );
    }

    return _get(
      range: range,
      context: context,
      deleted: deleted,
      withPriority: false,
      ascending: ascending,
    ).watch();
  }

  static Future<Event> getOne(EventId id, {bool withPriority = false}) async {
    final query = Store.get.select(table)
      ..where((t) => t.id.equals(id.toBytes()));
    final row = await query.getSingle();
    if (withPriority && row.priorityId != null) {
      final priority = await Priority.getOne(row.priorityId!);
      return Event.fromStore(row, priority: priority);
    }
    return Event.fromStore(row);
  }

  static Stream<Event> watchOne(EventId id, {bool withPriority = false}) {
    // TODO if not found, pull
    final query = Store.get.select(table)
      ..where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().asyncExpand((row) async* {
      if (withPriority && row.priorityId != null) {
        final priorityStream = Priority.watchOne(row.priorityId!);
        yield* priorityStream.map(
          (priority) => Event.fromStore(row, priority: priority),
        );
      } else {
        yield Event.fromStore(row);
      }
    });
  }

  static Stream<(Date?, Date?)?> watchRange({
    bool? deleted = false,
    Priority? context,
  }) {
    return Stream.fromFuture(
      _getRange(deleted: deleted, context: context),
    ).asyncExpand((range) async* {
      yield range;

      // Watch for changes by monitoring the underlying tables
      await for (final _ in Store.get.select(table).watch()) {
        yield await _getRange(deleted: deleted, context: context);
      }
    });
  }

  static Future<(Date?, Date?)?> _getRange({
    bool? deleted = false,
    Priority? context,
  }) async {
    // Build base query with filters
    var firstQuery = Store.get.select(table);
    var lastQuery = Store.get.select(table);

    // Apply deleted filter
    if (deleted != null) {
      final deletedFilter = deleted
          ? (Events t) => t.deletedAt.isNotNull()
          : (Events t) => t.deletedAt.isNull();
      firstQuery = firstQuery..where(deletedFilter);
      lastQuery = lastQuery..where(deletedFilter);
    }

    // Apply context filter if provided
    if (context != null) {
      final contextJoin = [
        leftOuterJoin(
          Store.get.priorities,
          Store.get.priorities.id.equalsExp(Store.get.events.priorityId),
        ),
      ];

      final firstJoinedQuery = firstQuery.join(contextJoin)
        ..where(
          Store.get.priorities.path.equalsValue(context.path) |
              Store.get.priorities.path.likeExp(Constant('${context.path}%')),
        );

      final lastJoinedQuery = lastQuery.join(contextJoin)
        ..where(
          Store.get.priorities.path.equalsValue(context.path) |
              Store.get.priorities.path.likeExp(Constant('${context.path}%')),
        );

      // Execute parallel queries for first and last events with context filter
      final results = await Future.wait([
        (firstJoinedQuery
              ..orderBy([
                OrderingTerm(
                  expression: Store.get.events.start,
                  mode: OrderingMode.asc,
                ),
              ])
              ..limit(1))
            .get(),
        (lastJoinedQuery
              ..orderBy([
                OrderingTerm(
                  expression: Store.get.events.start,
                  mode: OrderingMode.desc,
                ),
              ])
              ..limit(1))
            .get(),
      ]);

      final firstEvents = results[0];
      final lastEvents = results[1];

      if (firstEvents.isEmpty && lastEvents.isEmpty) {
        return null;
      }

      final earliest = firstEvents.isNotEmpty
          ? firstEvents.first.readTable(table).start.toDate()
          : null;
      final latest = lastEvents.isNotEmpty
          ? lastEvents.first.readTable(table).start.toDate()
          : null;

      return (earliest, latest);
    }

    // Execute parallel queries for first and last events
    final results = await Future.wait([
      (firstQuery
            ..orderBy([
              (t) => OrderingTerm(expression: t.start, mode: OrderingMode.asc),
            ])
            ..limit(1))
          .get(),
      (lastQuery
            ..orderBy([
              (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .get(),
    ]);

    final firstEvents = results[0];
    final lastEvents = results[1];

    if (firstEvents.isEmpty && lastEvents.isEmpty) {
      return null;
    }

    final earliest = firstEvents.isNotEmpty
        ? firstEvents.first.start.toDate()
        : null;
    final latest = lastEvents.isNotEmpty
        ? lastEvents.first.start.toDate()
        : null;

    return (earliest, latest);
  }

  /// Find the next event after [fromDate]
  /// [offset] specifies how many events to skip (0 = first, 1 = second, etc.)
  static Future<Event?> next(
    Date fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) async {
    if (fromDate == Date.latest) {
      // If fromDate is the latest date, there are no more events
      return null;
    }
    // Use a range from the day after fromDate to far in the future
    final startDate = fromDate.addDays(1);
    final endDate = Date.latest;
    final range = DateRangeCustom(startDate, endDate);

    // Get events in this range using the existing _get method
    return (await _get(
      range: range,
      context: context,
      deleted: deleted,
      withPriority: context != null,
      ascending: true,
      limit: 1,
      offset: offset,
    ).get()).firstOrNull;
  }

  /// Find the previous event before [fromDate]
  /// [offset] specifies how many events to skip (0 = first, 1 = second, etc.)
  static Future<Event?> previous(
    Date fromDate, {
    Priority? context,
    bool? deleted = false,
    int offset = 0,
  }) async {
    if (fromDate == Date.earliest) {
      // If fromDate is the earliest date, there are no previous events
      return null;
    }
    // Use a range from far in the past to the day before fromDate
    final startDate = Date.earliest;
    final endDate = fromDate;
    final range = DateRangeCustom(startDate, endDate);

    // Get events in reverse order (latest first) using the existing _get method
    return (await _get(
      range: range,
      context: context,
      deleted: deleted,
      withPriority: context != null,
      ascending: false, // descending for "previous"
      limit: 1,
      offset: offset,
    ).get()).firstOrNull;
  }

  /// Internal method for querying events with comprehensive filtering
  static MultiSelectable<Event> _get({
    required DateRange range,
    Priority? context,
    bool? deleted = false,
    bool withPriority = false,
    bool ascending = true,
    int? limit,
    int? offset,
  }) {
    pullRange(range);
    final order = ascending ? OrderingMode.asc : OrderingMode.desc;

    final query = Store.get.select(table)
      ..where((t) => t.start.isBiggerOrEqualValue(range.start.toDateTime()))
      ..where((t) => t.start.isSmallerThanValue(range.end.toDateTime()));

    if (deleted != null) {
      query.where(
        (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull(),
      );
    }

    // Apply pagination before any joins
    if (limit != null) {
      query.limit(limit, offset: offset ?? 0);
    }

    if (withPriority || context != null) {
      final joinedQuery = query.join([
        leftOuterJoin(
          Store.get.priorities,
          Store.get.priorities.id.equalsExp(Store.get.events.priorityId),
        ),
      ]);

      // Add context filter if provided
      if (context != null) {
        joinedQuery.where(
          Store.get.priorities.path.equalsValue(context.path) |
              Store.get.priorities.path.likeExp(Constant('${context.path}%')),
        );
      }

      joinedQuery.orderBy([
        OrderingTerm(expression: Store.get.events.start, mode: order),
        OrderingTerm(expression: Store.get.events.end, mode: order),
      ]);

      return joinedQuery.map(
        (TypedResult row) => Event.fromStore(
          row.readTable(Store.get.events),
          priority: row.readTableOrNull(Store.get.priorities) != null
              ? Priority.fromStore(row.readTableOrNull(Store.get.priorities)!)
              : null,
        ),
      );
    }

    query.orderBy([
      (t) => OrderingTerm(expression: t.start, mode: order),
      (t) => OrderingTerm(expression: t.end, mode: order),
    ]);

    return query.map((EventRow row) => Event.fromStore(row));
  }

  Event({
    required DateTimeRange at,
    super.name,
    super.response = EventResponse.accepted,
    super.status = EventStatus.confirmed,
    super.visibility = EventVisibility.normal,
    super.availability = EventAvailability.free,
    super.inviteesHidden = false,
    super.draft = false,
    this.priority,
  }) : unsaved = true,
       super(
         id: Uuid.generate(),
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         priorityId: priority?.id,
         start: at.start,
         end: at.end,
       );

  Event.fromStore(EventRow row, {this.priority, this.unsaved = false})
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        draft: row.draft,
        name: row.name,
        start: row.start,
        end: row.end,
        series: row.series,
        response: row.response,
        status: row.status,
        visibility: row.visibility,
        availability: row.availability,
        inviteesHidden: row.inviteesHidden,
        priorityId: priority?.id ?? row.priorityId,
      );

  @override
  Event copyWith({
    Uuid? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    bool? draft,
    Value<Uuid?> priorityId = const Value.absent(),
    Value<Priority?> activity = const Value.absent(),
    DateTime? start,
    DateTime? end,
    DateTimeRange? at,
    Value<String?> name = const Value.absent(),
    Value<EventResponse?> response = const Value.absent(),
    EventStatus? status,
    EventVisibility? visibility,
    EventAvailability? availability,
    bool? inviteesHidden,
    Value<String?> series = const Value.absent(),
    Value<int?> calendarId = const Value.absent(),
    Value<String?> conferencingUrl = const Value.absent(),
  }) {
    if (start != null || end != null || at != null) {
      start ??= at?.start ?? this.start;
      end ??= at?.end ?? this.end;
      at = DateTimeRange(
        start,
        end,
      ).min(start.startOfDay).max(start.nextMidnight());
      start = at.start;
      end = at.end;
    }
    final publish = this.draft && draft == false;
    return Event.fromStore(
      super.copyWith(
        id: id,
        priorityId: priorityId,
        createdAt: publish ? DateTime.now() : this.createdAt,
        updatedAt: DateTime.now(),
        deletedAt: deletedAt,
        draft: draft,
        start: start,
        end: end,
        name: name,
        response: response,
        status: status,
        visibility: visibility,
        availability: availability,
        inviteesHidden: inviteesHidden,
        series: series,
        calendarId: calendarId,
        conferencingUrl: conferencingUrl,
      ),
      priority: activity.present ? activity.value : null,
      unsaved: unsaved,
    );
  }

  final Priority? priority;
  final bool unsaved;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), EventsBase());

  DateTimeRange get at => DateTimeRange(start, end);
  Duration get duration => at.duration;
  bool get isAllDay => at.duration >= const Duration(hours: 22);
  Path get path => Path(
    "e_${BaseConversion(from: base10, to: base58)(series.hashCode.toString())}",
  );

  BalanceType get balanceType {
    switch (response) {
      case EventResponse.accepted:
        return BalanceType.accepted;
      case EventResponse.declined:
        return BalanceType.declined;
      case EventResponse.tentative:
      case null:
        return BalanceType.tentative;
    }
  }

  @override
  bool operator ==(Object other) {
    return super == other && priority == (other as Event).priority;
  }

  @override
  int get hashCode {
    return Object.hash(super.hashCode, priority.hashCode);
  }
}
