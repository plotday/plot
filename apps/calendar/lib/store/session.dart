part of 'store.dart';

@DataClassName('SessionRow')
class Sessions extends UuidStoreTable {
  BlobColumn get contextId =>
      blob().nullable().map(const UuidConverter()).references(Contexts, #id)();

  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime()();
  IntColumn get priority => integer().withDefault(const Constant(0))();

  IntColumn get pomodoro =>
      integer().nullable().map(const DurationConverter())();
  DateTimeColumn get pomodoroAt => dateTime().nullable()();
}

class SessionsBase extends BaseTable {
  SessionsBase() : super(table: 'session');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    final range = DateTimeRange(DateTime.parse(json['start'] as String),
        DateTime.parse(json['end'] as String));
    json['at'] = range.toDb();
    return json;
  }

  @override
  SessionRow fromBase(Map<String, dynamic> json) {
    final range = DateTimeRange.fromString(json['at'] as String);
    json['start'] = range.start.toDb();
    json['end'] = range.end.toDb();
    return SessionRow.fromJson(json);
  }
}

class Session extends SessionRow {
  static TableInfo<Sessions, SessionRow> get table => Store.get.sessions;

  static Future<void> push() => Store.get.push(table, SessionsBase());
  static Future<bool> pull() => Store.get.pull(table, SessionsBase());

  static Future<Session> resume(Context? context,
      {required DateTime end}) async {
    var session = await _latest();
    Session? previous;
    if (session != null) {
      if (session.at.isNow()) {
        if (session.context == context) {
          session = Session.fromStore(session.copyWith(end: end));
        } else {
          session = Session.fromStore(session.copyWith(end: DateTime.now()));
          await session.save();
          session = null;
        }
      } else {
        if (session.context == context) {
          previous = session;
        }
        session = null;
      }
    }
    if (session == null) {
      previous ??= await _latest(context: context);
      session = Session(context: context, end: end);
    }
    return session;
  }

  static Future<Session?> _latest({Context? context}) async {
    final query = Store.get.select(table);
    if (context != null) {
      query.where((t) => t.contextId.equals(context.id.toBytes()));
    }
    final row = await (query
          ..orderBy([
            (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return Session.fromStore(row);
  }

  static Stream<List<Session>> watch({bool withContext = false}) {
    final sessionStream = (Store.get.select(table)
          ..orderBy([
            (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc)
          ])
          ..limit(10))
        .watch()
        .map(
          (rows) => rows.map((row) => Session.fromStore(row)).toList(),
        );

    if (withContext) {
      return Rx.combineLatest2(
          sessionStream,
          Context.watch(),
          (List<Session> sessions, Map<Uuid, Context> contexts) => sessions
              .map((session) => Session.fromStore(session,
                  context: session.contextId == null
                      ? null
                      : contexts[session.contextId]))
              .toList());
    }
    return sessionStream;
  }

  static Stream<Session?> watchCurrent() =>
      watch(withContext: true).map((sessions) {
        final session = sessions.firstOrNull;
        return session?.at.isNow() == true ? session : null;
      });

  Session({this.context, required super.end})
      : super(
          id: Uuid.generate(),
          modifiedAt: DateTime.now(),
          contextId: context?.id,
          start: DateTime.now(),
          pomodoro: null,
          pomodoroAt: null,
          priority: 0,
        );

  Session.fromStore(SessionRow row, {this.context})
      : super(
          id: row.id,
          modifiedAt: row.modifiedAt,
          contextId: row.contextId,
          start: row.start,
          end: row.end,
          pomodoro: row.pomodoro,
          pomodoroAt: row.pomodoroAt,
          priority: row.priority,
        );

  final Context? context;

  Future<void> save() => Store.get.save(table, this);

  DateTimeRange get at => DateTimeRange(start, end);
}
