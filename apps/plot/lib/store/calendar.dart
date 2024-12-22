part of 'store.dart';

@DataClassName('CalendarRow')
class Calendars extends IdStoreTable {
  TextColumn get name => text()();
  BoolColumn get enabled => boolean()();
  IntColumn get accountId => integer().references(Accounts, #id)();
}

class CalendarsBase extends BaseTable {
  CalendarsBase() : super(table: 'calendar');

  @override
  Insertable<CalendarRow> fromBase(Map<String, dynamic> json) =>
      CalendarRow.fromJson(json);
}

class Calendar extends CalendarRow {
  static TableInfo<Calendars, CalendarRow> get table => Store.get.calendars;

  static Future<void> push() => Store.get.push(table, CalendarsBase());
  static Future<bool> pull() =>
      Store.get.pull(PullType.all, table, BalanceBase());

  static Stream<List<Calendar>> watch() => Store.get
      .select(table)
      .watch()
      .map((rows) => rows.map((row) => Calendar.fromStore(row)).toList());

  Calendar.fromStore(CalendarRow row)
      : super(
          id: row.id,
          updatedAt: row.updatedAt,
          name: row.name,
          enabled: row.enabled,
          accountId: row.accountId,
        );

  @override
  Calendar copyWith({
    int? id,
    DateTime? updatedAt,
    String? name,
    bool? enabled,
    int? accountId,
  }) =>
      Calendar.fromStore(super.copyWith(
        id: id,
        updatedAt: DateTime.now(),
        name: name,
        enabled: enabled,
        accountId: accountId,
      ));

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), CalendarsBase());

  Future<void> sync() async {
    await api.post(
      "/sync",
      body: {
        'calendarId': id,
      },
    );
  }
}
