part of 'store.dart';

enum EventResponse { accepted, declined, tentative }

@DataClassName('EventRow')
class Events extends UuidStoreTable {
  TextColumn get name => text()();
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

  Event.fromStore(EventRow row)
      : super(
          id: row.id,
          modifiedAt: row.createdAt,
          createdAt: row.createdAt,
          name: row.name,
          start: row.start,
          end: row.end,
          series: row.series,
          response: row.response,
          contextId: row.contextId,
        );

  Future<void> save() => Store.get.save(table, this);

  DateTimeRange get at => DateTimeRange(start, end);
}
