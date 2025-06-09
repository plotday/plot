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
  TextColumn get response =>
      textEnum<EventResponse>().withDefault(
        Constant(EventResponse.accepted.toString()),
      )();
  TextColumn get status =>
      textEnum<EventStatus>().withDefault(
        Constant(EventStatus.confirmed.toString()),
      )();
  TextColumn get visibility =>
      textEnum<EventVisibility>().withDefault(
        Constant(EventVisibility.normal.toString()),
      )();
  TextColumn get availability =>
      textEnum<EventAvailability>().withDefault(
        Constant(EventAvailability.free.toString()),
      )();
  BoolColumn get inviteesHidden =>
      boolean().withDefault(const Constant(false))();
  BlobColumn get priorityId =>
      blob()
          .nullable()
          .map(const UuidConverter())
          .references(Priorities, #id)();
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
  }) {
    pullRange(range);
    final order =
        range.start <= range.end ? OrderingMode.asc : OrderingMode.desc;

    final query =
        Store.get.select(table)
          ..where((t) => t.start.isBiggerOrEqualValue(range.start.toStart()))
          ..where((t) => t.start.isSmallerThanValue(range.end.toEnd()));
    if (deleted != null) {
      query.where(
        (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull(),
      );
    }

    if (withPriority) {
      final joinedQuery = query.join([
        leftOuterJoin(
          Store.get.priorities,
          Store.get.priorities.id.equalsExp(Store.get.events.priorityId),
        ),
      ]);

      return Rx.combineLatest2(
        (joinedQuery..orderBy([
              OrderingTerm(expression: Store.get.events.start, mode: order),
              OrderingTerm(expression: Store.get.events.end, mode: order),
            ]))
            .watch(),
        Priority.watchDefault(),
        (events, defaultPriority) =>
            events
                .map(
                  (row) => Event.fromStore(
                    row.readTable(Store.get.events),
                    priority: Priority.fromStore(
                      row.readTableOrNull(Store.get.priorities) ??
                          defaultPriority,
                    ),
                  ),
                )
                .toList(),
      );
    }

    return (query..orderBy([
          (t) => OrderingTerm(expression: t.start, mode: order),
          (t) => OrderingTerm(expression: t.end, mode: order),
        ]))
        .watch()
        .map((rows) => rows.map((row) => Event.fromStore(row)).toList());
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
    EventResponse? response,
    EventStatus? status,
    EventVisibility? visibility,
    EventAvailability? availability,
    bool? inviteesHidden,
    Value<String?> series = const Value.absent(),
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

  BalanceType get balanceType {
    switch (response) {
      case EventResponse.accepted:
        return BalanceType.accepted;
      case EventResponse.declined:
        return BalanceType.declined;
      case EventResponse.tentative:
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
