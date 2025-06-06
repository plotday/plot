part of 'store.dart';

@DataClassName('CalendarRow')
class Calendars extends Table
    with SyncableTable, IdTable, CreatedTable, DeletableTable {
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

  static Stream<List<Calendar>> watch({bool? deleted = false}) =>
      (Store.get.select(table)..where(
            (t) => deleted == null
                ? const Constant(true)
                : deleted
                ? t.deletedAt.isNotNull()
                : t.deletedAt.isNull(),
          ))
          .watch()
          .map((rows) => rows.map((row) => Calendar.fromStore(row)).toList());

  Calendar.fromStore(CalendarRow row)
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        name: row.name,
        enabled: row.enabled,
        accountId: row.accountId,
      );

  @override
  Calendar copyWith({
    int? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? name,
    bool? enabled,
    int? accountId,
  }) => Calendar.fromStore(
    super.copyWith(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      deletedAt: deletedAt,
      name: name,
      enabled: enabled,
      accountId: accountId,
    ),
  );

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), CalendarsBase());

  Future<void> sync() async {
    await api.post("/sync", body: {'calendarId': id});
  }
}
