part of 'store.dart';

enum SessionPriority implements Comparable<SessionPriority> {
  user(100);

  const SessionPriority(this.value);

  final int value;

  @override
  int compareTo(SessionPriority other) => value - other.value;
}

@DataClassName('SessionRow')
class Sessions extends Table
    with SyncableTable, CreatedTable, UuidTable, DeletableTable {
  BlobColumn get priorityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Priorities, #id)();

  DateTimeColumn get start => dateTime().map(const LocalDateTimeConverter())();
  DateTimeColumn get end => dateTime().map(const LocalDateTimeConverter())();
  IntColumn get precedence =>
      integer().withDefault(Constant(SessionPriority.user.value))();

  IntColumn get pomodoro =>
      integer().nullable().map(const DurationConverter())();
  DateTimeColumn get pomodoroAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

class SessionsBase extends BaseTable {
  SessionsBase() : super(table: 'session', syncEndpoint: 'sessions');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    var start = DateTime.parse(json['start'] as String);
    var end = DateTime.parse(json['end'] as String);

    // Handle time travel edge cases where start might be after end
    // This can happen when frozen time is in the past but session dates
    // use real time from DateTime.now()
    if (!start.isBefore(end)) {
      // Use a minimal valid range to prevent sync errors during time travel
      // or when start == end (which PostgreSQL normalizes to 'empty' range)
      end = start.add(const Duration(seconds: 1));
    }

    final range = DateTimeRange(start, end);
    json['at'] = range.toDb();
    json['user_id'] = Base.userId.toString();
    json.remove('start');
    json.remove('end');
    return json;
  }

  @override
  SessionRow fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    final range = DateTimeRange.fromString(json['at'] as String);
    // 'empty' ranges (start == end with exclusive upper bound) have null start/end.
    // Use created_at as a fallback since start/end are non-nullable locally.
    final fallback = json['created_at'] as String;
    json['start'] = range.start?.toDb() ?? fallback;
    json['end'] = range.end?.toDb() ?? fallback;
    return SessionRow.fromJson(json);
  }
}

class Session extends SessionRow {
  static TableInfo<Sessions, SessionRow> get table => Store.get.sessions;

  static Future<bool> push() => Store.get.push(table, SessionsBase());
  static Future<void> pull() async =>
      await Store.get.pull(table, SessionsBase());

  static final _resumeLock = Lock();

  static Future<Session> resume(
    Priority? priority, {
    required DateTime end,
  }) async {
    return await _resumeLock.synchronized(() async {
      var session = await _latest();
      Session? previous;
      if (session != null) {
        if (session.at.isNow()) {
          if (session.priority == priority) {
            session = Session.fromStore(session.copyWith(end: end));
          } else {
            session = Session.fromStore(session.copyWith(end: Time.now()));
            await session.save();
            session = null;
          }
        } else {
          if (session.priority == priority) {
            previous = session;
          }
          session = null;
        }
      }
      if (session == null) {
        previous ??= await _latest(context: priority);
        // Double-check if a session was just created for this priority
        // to catch race conditions that slipped through
        final latestForPriority = await _latest(context: priority);
        if (latestForPriority != null && latestForPriority.at.isNow()) {
          session = Session.fromStore(latestForPriority.copyWith(end: end));
        } else {
          session = Session(priority: priority, end: end);
        }
      }
      await session.save();
      return session;
    });
  }

  static Future<Session?> _latest({Priority? context}) async {
    final query = Store.get.select(table);
    if (context != null) {
      query.where((t) => t.priorityId.equals(context.id.toBytes()));
    }
    final row =
        await (query
              ..orderBy([
                (t) =>
                    OrderingTerm(expression: t.start, mode: OrderingMode.desc),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;
    return Session.fromStore(row);
  }

  static Stream<List<Session>> watch({
    DateRange? range,
    int? limit,
    bool withPriority = false,
    bool? archived = false,
    bool expiring = false, // emit every minute
  }) {
    final query = Store.get.select(table);
    if (range != null) {
      if (range.end != null) {
        query.where((t) => t.start.isSmallerThanValue(range.end!.toEnd()));
      }
      if (range.start != null) {
        query.where((t) => t.end.isBiggerThanValue(range.start!.toStart()));
      }
    }
    if (archived != null) {
      query.where(
        (t) => archived ? t.archivedAt.isNotNull() : t.archivedAt.isNull(),
      );
    }
    query.orderBy([
      (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc),
    ]);
    if (limit != null) {
      query.limit(limit);
    }
    Stream<List<Session>> sessionStream;
    if (withPriority) {
      final joinedQuery = query.join([
        innerJoin(
          Store.get.priorities,
          Store.get.priorities.id.equalsExp(Store.get.sessions.priorityId),
        ),
      ]);
      sessionStream = joinedQuery.watch().map(
        (rows) => rows
            .map(
              (row) => Session.fromStore(
                row.readTable(Store.get.sessions),
                priority: Priority.fromStore(
                  row.readTable(Store.get.priorities),
                ),
              ),
            )
            .toList(),
      );
    } else {
      sessionStream = query.watch().map(
        (rows) => rows.map((row) => Session.fromStore(row)).toList(),
      );
    }

    if (expiring) {
      return sessionStream.transform(
        ExpiringStreamTransformer((sessions) {
          final now = Time.now();
          final expiry = sessions.isEmpty || sessions.first.at.end.isBefore(now)
              ? null
              : (now +
                        Duration(
                          seconds:
                              sessions.first.at.start.second +
                              (now.second < sessions.first.at.start.second
                                  ? 0
                                  : 60) -
                              now.second,
                        ))
                    .max(sessions.first.at.end);
          return ExpiringResult(value: sessions, expiry: expiry);
        }),
      );
    }

    return sessionStream;
  }

  static Stream<Session?> watchCurrent() =>
      watch(withPriority: true, limit: 1, expiring: true).map((sessions) {
        final session = sessions.firstOrNull;
        return session?.at.isNow() == true ? session : null;
      });

  Session({this.priority, required super.end})
    : super(
        id: Uuid.generate(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        priorityId: priority?.id,
        start: Time.now(),
        pomodoro: null,
        pomodoroAt: null,
        precedence: 0,
      );

  Session.fromStore(SessionRow row, {this.priority})
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        priorityId: row.priorityId,
        start: row.start,
        end: row.end,
        pomodoro: row.pomodoro,
        pomodoroAt: row.pomodoroAt,
        precedence: row.precedence,
      );

  @override
  Session copyWith({
    Uuid? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    Value<Uuid?> priorityId = const Value.absent(),
    DateTime? start,
    DateTime? end,
    int? precedence,
    Value<Duration?> pomodoro = const Value.absent(),
    Value<DateTime?> pomodoroAt = const Value.absent(),
    Value<int?> pending = const Value.absent(),
  }) => Session.fromStore(
    super.copyWith(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      pending: pending,
      archivedAt: archivedAt,
      priorityId: priorityId,
      start: start,
      end: end,
      precedence: precedence,
      pomodoro: pomodoro,
      pomodoroAt: pomodoroAt,
    ),
  );

  final Priority? priority;

  Future<void> save() async {
    if (!Store.isAvailable) return;
    await Store.get.save(table, toCompanion(false), SessionsBase());
  }

  BoundedDateTimeRange get at {
    // Handle time travel edge cases where start might be after end
    // This can happen when frozen time is in the past but session dates
    // use real time from DateTime.now()
    if (start.isAfter(end)) {
      // Return a minimal valid range to prevent crashes during time travel
      return BoundedDateTimeRange(start, start.add(const Duration(seconds: 1)));
    }
    return BoundedDateTimeRange(start, end);
  }

  @override
  bool operator ==(Object other) {
    return super == other && priority == (other as Session).priority;
  }

  @override
  int get hashCode {
    return Object.hash(super.hashCode, priority.hashCode);
  }
}

enum SessionPendingSync {
  /// Full session data changed
  full(2);

  const SessionPendingSync(this.value);
  final int value;
}
