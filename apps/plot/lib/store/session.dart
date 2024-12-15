part of 'store.dart';

enum SessionPriority implements Comparable<SessionPriority> {
  user(100);

  const SessionPriority(this.value);

  final int value;

  @override
  int compareTo(SessionPriority other) => value - other.value;
}

@DataClassName('SessionRow')
class Sessions extends UuidStoreTable {
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();

  DateTimeColumn get start => dateTime().map(const LocalDateTimeConverter())();
  DateTimeColumn get end => dateTime().map(const LocalDateTimeConverter())();
  IntColumn get priority =>
      integer().withDefault(Constant(SessionPriority.user.value))();

  IntColumn get pomodoro =>
      integer().nullable().map(const DurationConverter())();
  DateTimeColumn get pomodoroAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

class SessionsBase extends BaseTable {
  SessionsBase() : super(table: 'session');

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
  static Future<bool> pull() =>
      Store.get.pull(PullType.updates, table, SessionsBase());

  static Future<Session> resume(Activity? activity,
      {required DateTime end}) async {
    var session = await _latest();
    Session? previous;
    if (session != null) {
      if (session.at.isNow()) {
        if (session.activity == activity) {
          session = Session.fromStore(session.copyWith(end: end));
        } else {
          session = Session.fromStore(session.copyWith(end: DateTime.now()));
          await session.save();
          session = null;
        }
      } else {
        if (session.activity == activity) {
          previous = session;
        }
        session = null;
      }
    }
    if (session == null) {
      previous ??= await _latest(context: activity);
      session = Session(activity: activity, end: end);
    }
    await session.save();
    return session;
  }

  static Future<Session?> _latest({Activity? context}) async {
    final query = Store.get.select(table);
    if (context != null) {
      query.where((t) => t.activityId.equals(context.id.toBytes()));
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

  static Stream<List<Session>> watch({
    DateRange? range,
    int? limit,
    bool withContext = false,
  }) {
    final query = Store.get.select(table);
    if (range != null) {
      query.where((t) => t.start.isBiggerOrEqualValue(range.start.toStart()));
      query.where((t) => t.end.isSmallerThanValue(range.end.toEnd()));
    }
    if (limit != null) {
      query.orderBy(
          [(t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc)]);
      query.limit(limit);
    }
    final sessionStream = query.watch().map(
          (rows) => rows.map((row) => Session.fromStore(row)).toList(),
        );

    if (withContext) {
      return Rx.combineLatest2(
          sessionStream,
          Activity.watch(),
          (List<Session> sessions, Map<Uuid, Activity> contexts) => sessions
              .map((session) => Session.fromStore(session,
                  activity: session.activityId == null
                      ? null
                      : contexts[session.activityId]))
              .toList());
    }
    return sessionStream;
  }

  static Stream<Session?> watchCurrent() =>
      watch(withContext: true, limit: 10).map((sessions) {
        final session = sessions.firstOrNull;
        return session?.at.isNow() == true ? session : null;
      });

  Session({this.activity, required super.end})
      : super(
          id: Uuid.generate(),
          modifiedAt: DateTime.now(),
          activityId: activity?.id,
          start: DateTime.now(),
          pomodoro: null,
          pomodoroAt: null,
          priority: 0,
        );

  Session.fromStore(SessionRow row, {this.activity})
      : super(
          id: row.id,
          modifiedAt: row.modifiedAt,
          activityId: row.activityId,
          start: row.start,
          end: row.end,
          pomodoro: row.pomodoro,
          pomodoroAt: row.pomodoroAt,
          priority: row.priority,
        );

  @override
  Session copyWith(
          {Uuid? id,
          DateTime? modifiedAt,
          Value<Uuid?> activityId = const Value.absent(),
          DateTime? start,
          DateTime? end,
          int? priority,
          Value<Duration?> pomodoro = const Value.absent(),
          Value<DateTime?> pomodoroAt = const Value.absent()}) =>
      Session.fromStore(super.copyWith(
        id: id,
        modifiedAt: DateTime.now(),
        activityId: activityId,
        start: start,
        end: end,
        priority: priority,
        pomodoro: pomodoro,
        pomodoroAt: pomodoroAt,
      ));

  final Activity? activity;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), SessionsBase());

  DateTimeRange get at => DateTimeRange(start, end);
}
