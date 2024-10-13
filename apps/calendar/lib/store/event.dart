part of 'store.dart';

enum EventResponse { accepted, declined, tentative }

typedef EventId = Uuid;

@DataClassName('EventRow')
class Events extends UuidStoreTable {
  TextColumn get name => text().nullable()();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime()();
  TextColumn get series => text().nullable()();
  TextColumn get response => textEnum<EventResponse>()();
  BlobColumn get contextId =>
      blob().nullable().map(const UuidConverter()).references(Contexts, #id)();
}

class EventsBase extends BaseTable {
  EventsBase() : super(table: 'event_x', name: 'events');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    final range = DateTimeRange(DateTime.parse(json['start'] as String),
        DateTime.parse(json['end'] as String));
    json['at'] = range.toDb();
    return json;
  }

  @override
  EventRow fromBase(Map<String, dynamic> json) {
    final range = DateTimeRange.fromString(json['at'] as String);
    json['start'] = range.start.toDb();
    json['end'] = range.end.toDb();
    return EventRow.fromJson(json);
  }
}

class Event extends EventRow {
  static TableInfo<Events, EventRow> get table => Store.get.events;

  static Future<void> push() => Store.get.push(table, EventsBase());
  static Future<bool> pull() async => Store.get.pull(table, EventsBase());
  // TODO: fetch more

  static Stream<List<Event>> watch(DateRange range,
      {bool withContext = false}) {
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
    if (withContext) {
      return Rx.combineLatest2(
          eventStream,
          Context.watch(),
          (List<Event> events, Map<Uuid, Context> contexts) => events
              .map((event) => Event.fromStore(event,
                  context: event.contextId == null
                      ? null
                      : contexts[event.contextId]))
              .toList());
    }
    return eventStream;
  }

  static Stream<Event> watchOne(EventId id) {
    final query = Store.get.select(table)
      ..where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().map((row) => Event.fromStore(row));
  }

  Event(
      {required DateTimeRange at,
      super.name,
      super.response = EventResponse.accepted,
      this.context})
      : super(
          id: Uuid.generate(),
          modifiedAt: DateTime.now(),
          contextId: context?.id,
          start: at.start,
          end: at.end,
        );

  Event.fromStore(EventRow row, {this.context})
      : super(
          id: row.id,
          modifiedAt: row.modifiedAt,
          name: row.name,
          start: row.start,
          end: row.end,
          series: row.series,
          response: row.response,
          contextId: context?.id ?? row.contextId,
        );

  @override
  Event copyWith({
    Uuid? id,
    DateTime? modifiedAt,
    Value<Uuid?> contextId = const Value.absent(),
    Value<Context?> context = const Value.absent(),
    DateTime? start,
    DateTime? end,
    Value<String?> name = const Value.absent(),
    EventResponse? response,
    Value<String?> series = const Value.absent(),
  }) {
    return Event.fromStore(
      super.copyWith(
        id: id,
        contextId: contextId,
        start: start,
        end: end,
        name: name,
        response: response,
        series: series,
      ),
      context: context.present ? context.value : null,
    );
  }

  final Context? context;

  Future<void> save() => Store.get.save(table, this);

  DateTimeRange get at => DateTimeRange(start, end);
}

class ScheduledDay extends Equatable {
  static Stream<Map<Date, ScheduledDay>> watch(DateRange range) {
    var (start, end) = range.bounds;
    final direction =
        start < end ? TimeDirection.ascending : TimeDirection.descending;
    return Event.watch(range, withContext: true).map((events) {
      Map<Date, ScheduledDay> days = {};
      List<Event> dayEvents = [];
      Iterator<Event> eventIterator = events.iterator;

      while (start != end) {
        while (eventIterator.moveNext() &&
            eventIterator.current.start.toDate() == start) {
          dayEvents.add(eventIterator.current);
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
    final end = start.endOfDay;
    if (events.isEmpty ||
        events.first.at.start.difference(start).inMinutes > 0) {
      expanded.add(Event(
        at: DateTimeRange(
            start,
            events.isEmpty
                ? end
                : start.at(events.first.at.start.toTimeOfDay())),
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
        ));
      }
    }
    return expanded;
  }
}
