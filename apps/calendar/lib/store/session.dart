part of 'store.dart';

@DataClassName('SessionRow')
class Sessions extends IdStoreTable {
  BlobColumn get contextId =>
      blob().nullable().map(const UuidConverter()).references(Contexts, #id)();

  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime()();
  IntColumn get priority => integer().withDefault(const Constant(0))();

  IntColumn get pomodoro =>
      integer().nullable().map(const DurationConverter())();
  IntColumn get pomodoroRemaining =>
      integer().nullable().map(const DurationConverter())();
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

  static Stream<List<Session>> watch() => (Store.get.select(table)
        ..orderBy(
            [(t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc)])
        ..limit(10))
      .watch()
      .map(
        (rows) => rows.map((row) => Session.fromStore(row)).toList(),
      );
  static Stream<List<Session>> watchWithContext() => Rx.combineLatest2(
      Session.watch(),
      Context.watch(),
      (List<Session> sessions, Map<Uuid, Context> contexts) => sessions
          .map((session) => Session.fromStore(session,
              context: session.contextId == null
                  ? null
                  : contexts[session.contextId]))
          .toList());
  static Stream<Session?> watchCurrent() => watchWithContext().map((sessions) {
        final session = sessions.firstOrNull;
        return session?.at.isNow() == true ? session : null;
      });

  Session.fromStore(SessionRow row, {this.context})
      : super(
          id: row.id,
          modifiedAt: row.modifiedAt,
          contextId: row.contextId,
          start: row.start,
          end: row.end,
          pomodoro: row.pomodoro,
          pomodoroRemaining: row.pomodoroRemaining,
          priority: row.priority,
        );

  final Context? context;

  Future<void> save() => Store.get.save(table, this);

  DateTimeRange get at => DateTimeRange(start, end);
}
