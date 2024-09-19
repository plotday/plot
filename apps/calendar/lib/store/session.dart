part of 'store.dart';

@DataClassName('SessionRow')
class Sessions extends IdStoreTable {
  BlobColumn get contextId =>
      blob().nullable().map(const UuidConverter()).references(Contexts, #id)();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime()();

  // final Duration paused;
  // final DateTime? pomodoroStart;
  // final Duration? pomodoroLength;
}

class SessionsBase extends BaseTable {
  SessionsBase() : super(table: 'session');

  @override
  Insertable<SessionRow> fromBase(Map<String, dynamic> json) =>
      SessionRow.fromJson(json);
}

class Session extends SessionRow {
  static TableInfo<Sessions, SessionRow> get table => Store.get.sessions;

  static Future<void> push() => Store.get.push(table, SessionsBase());
  static Future<bool> pull() => Store.get.pull(table, SessionsBase());

  static Stream<List<Session>> watch() => Store.get.select(table).watch().map(
        (rows) => rows.map((row) => Session.fromStore(row)).toList(),
      );

  Session.fromStore(SessionRow row)
      : super(
          id: row.id,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
          contextId: row.contextId,
          start: row.start,
          end: row.end,
        );

  Future<void> save() => Store.get.save(table, this);

  DateTimeRange get at => DateTimeRange(start, end);
}
