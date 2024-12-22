part of 'store.dart';

enum EventResponse { accepted, declined, tentative }

enum EventStatus { confirmed, cancelled, tentative }

enum EventVisibility { normal, private, confidential, public, personal }

enum EventAvailability { busy, away, focus, free, location }

typedef EventId = Uuid;

@DataClassName('EventRow')
class Events extends UuidStoreTable with DraftTable {
  TextColumn get name => text().nullable()();
  DateTimeColumn get start => dateTime().map(const LocalDateTimeConverter())();
  DateTimeColumn get end => dateTime().map(const LocalDateTimeConverter())();
  TextColumn get series => text().nullable()();
  TextColumn get response => textEnum<EventResponse>()
      .withDefault(Constant(EventResponse.accepted.toString()))();
  TextColumn get status => textEnum<EventStatus>()
      .withDefault(Constant(EventStatus.confirmed.toString()))();
  TextColumn get visibility => textEnum<EventVisibility>()
      .withDefault(Constant(EventVisibility.normal.toString()))();
  TextColumn get availability => textEnum<EventAvailability>()
      .withDefault(Constant(EventAvailability.free.toString()))();
  BoolColumn get inviteesHidden =>
      boolean().withDefault(const Constant(false))();
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
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
    final range = DateTimeRange(DateTime.parse(json['start'] as String),
        DateTime.parse(json['end'] as String));
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
  static Future<bool> pullRange(DateRange range) =>
      Store.get.pull(PullType.more, table, EventsBase(),
          range: (range.start.toString(), range.end.toString()));

  static Stream<List<Event>> watch(
    DateRange range, {
    bool withActivity = false,
  }) {
    pullRange(range);
    final order =
        range.start <= range.end ? OrderingMode.asc : OrderingMode.desc;
    final eventStream = (Store.get.select(table)
          ..where((t) => t.start.isBiggerOrEqualValue(range.start.toStart()))
          ..where((t) => t.start.isSmallerThanValue(range.end.toEnd()))
          ..orderBy([
            (t) => OrderingTerm(expression: t.start, mode: order),
            (t) => OrderingTerm(expression: t.end, mode: order)
          ]))
        .watch()
        .map((rows) => rows.map((row) => Event.fromStore(row)).toList());
    if (withActivity) {
      return Rx.combineLatest2(eventStream, Activity.watch(),
          (List<Event> events, Map<Uuid, Activity> activities) {
        final ret = events
            .map((event) => Event.fromStore(event,
                activity: event.activityId == null
                    ? null
                    : activities[event.activityId]))
            .toList();
        return ret;
      });
    }
    return eventStream;
  }

  static Stream<Event> watchOne(EventId id) {
    // TODO if not found, pull
    final query = Store.get.select(table)
      ..where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().map((row) => Event.fromStore(row));
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
    this.activity,
  }) : super(
          id: Uuid.generate(),
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          activityId: activity?.id,
          start: at.start,
          end: at.end,
        );

  Event.fromStore(EventRow row, {this.activity})
      : super(
          id: row.id,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
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
          activityId: activity?.id ?? row.activityId,
        );

  @override
  Event copyWith({
    Uuid? id,
    DateTime? modifiedAt,
    DateTime? createdAt,
    bool? draft,
    Value<Uuid?> activityId = const Value.absent(),
    Value<Activity?> activity = const Value.absent(),
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
    start ??= at?.start;
    end ??= at?.end;
    if (start != null && end != null && start.isAfter(end)) {
      throw ArgumentError('Start must be before end');
    }
    if (start != null && end == null) {
      end =
          this.end.add(start.difference(this.start)).max(start.nextMidnight());
    } else if (start == null && end != null) {
      start = this
          .start
          .subtract(end.difference(this.end))
          .min(end.previousMidnight());
    }
    final publish = this.draft && draft == false;
    return Event.fromStore(
      super.copyWith(
        id: id,
        activityId: activityId,
        createdAt: publish ? DateTime.now() : this.createdAt,
        modifiedAt: DateTime.now(),
        draft: draft,
        start: start,
        end: end,
        name: name,
        response: response,
        status: status,
        visibility: visibility,
        inviteesHidden: inviteesHidden,
        series: series,
      ),
      activity: activity.present ? activity.value : null,
    );
  }

  final Activity? activity;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), EventsBase());

  DateTimeRange get at => DateTimeRange(start, end);

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
}

class ScheduledDay extends Equatable {
  static Stream<Map<Date, ScheduledDay>> watch(DateRange range) {
    return Event.watch(range, withActivity: true).map((events) {
      var (start, end) = range.bounds;

      final direction =
          start < end ? TimeDirection.ascending : TimeDirection.descending;
      Map<Date, ScheduledDay> days = {};
      Iterator<Event> eventIterator = events.iterator;
      bool hasMore = eventIterator.moveNext();

      while (start != end) {
        List<Event> dayEvents = [];
        while (hasMore && eventIterator.current.start.toDate() == start) {
          dayEvents.add(eventIterator.current);
          hasMore = eventIterator.moveNext();
        }
        days[start] = ScheduledDay(start, dayEvents);
        start = start.next(direction: direction);
      }
      return days;
    });
  }

  ScheduledDay(this.date, List<Event> events)
      : events = _addGaps(
            date,
            events
                .where((e) => e.at.duration < const Duration(hours: 22))
                .toList()),
        allDayEvents = events
            .where((e) => e.at.duration >= const Duration(hours: 22))
            .toList();

  final Date date;
  final List<Event> events;
  final List<Event> allDayEvents;

  ScheduledDay copyWith(Event event) {
    final list = events.where((e) => e.id != event.id).toList();
    var index = list.indexWhere((i) => i.at < event.at);
    if (index == -1) {
      index = list.length;
    }
    list.insert(index, event);
    return ScheduledDay(date, list);
  }

  Event getAt(DateTime time) {
    return events.firstWhere((e) => e.at.includes(time));
  }

  @override
  List<Object> get props => [date, events];

  /* Private */

  static List<Event> _addGaps(Date date, List<Event> events) {
    List<Event> expanded = [];
    final start = date.toDateTime();
    final end = start.nextDay;
    if (events.isEmpty ||
        events.first.at.start.difference(start).inMinutes > 0) {
      expanded.add(Event(
        at: DateTimeRange(
            start,
            events.isEmpty
                ? end
                : start.at(events.first.at.start.toTimeOfDay())),
        draft: true,
      ));
    }
    for (var i = 0; i < events.length; i++) {
      expanded.add(events[i]);
      if (i + 1 == events.length || events[i].at.end < events[i + 1].at.start) {
        expanded.add(Event(
          at: DateTimeRange(
            events[i].at.end,
            i + 1 == events.length ? end : events[i + 1].at.start,
          ),
          draft: true,
        ));
      }
    }
    return expanded;
  }
}
