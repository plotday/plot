part of 'store.dart';

class Calendars extends IdStoreTable {
  static TableInfo<Calendars, Calendar> get table => Store.get.calendars;

  static Future<void> push() => Store.get.push(table, CalendarsBase());
  static Future<bool> pull() =>
      Store.get.pull(table, CalendarsBase(), Calendar.fromJson);
  static Future<M> getMap<M>(int id, M Function(Calendar) toModel) =>
      (Store.get.select(table)..where((t) => t.id.equals(id)))
          .map(toModel)
          .getSingle();
  static Stream<List<Calendar>> watch() => Store.get.select(table).watch();

  TextColumn get name => text()();
  BoolColumn get enabled => boolean()();
  IntColumn get accountId => integer().references(Accounts, #id)();
}

class CalendarsBase extends BaseTable {
  CalendarsBase() : super(table: 'calendar');
}

extension CalendarFunctions on Calendar {
  TableInfo<Calendars, Calendar> get table => Store.get.calendars;

  Future<void> save() => Store.get.save(table, this);

  Future<void> sync() async {
    await api.post(
      "/sync",
      body: {
        'calendarId': id,
      },
    );
  }
}
