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
  SessionsBase() : super(table: 'session');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    final range = DateTimeRange(
      DateTime.parse(json['start'] as String),
      DateTime.parse(json['end'] as String),
    );
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
    json['start'] = range.start?.toDb();
    json['end'] = range.end?.toDb();
    return SessionRow.fromJson(json);
  }
}

class Session extends SessionRow {
  static TableInfo<Sessions, SessionRow> get table => Store.get.sessions;

  static Future<bool> push() => Store.get.push(table, SessionsBase());
  static Future<bool> pull() =>
      Store.get.pull(PullType.updates, table, SessionsBase());

  static Future<Session> resume(
    Priority? priority, {
    required DateTime end,
  }) async {
    var session = await _latest();
    Session? previous;
    if (session != null) {
      if (session.at.isNow()) {
        if (session.priority == priority) {
          session = Session.fromStore(session.copyWith(end: end));
        } else {
          session = Session.fromStore(session.copyWith(end: DateTime.now()));
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
      session = Session(priority: priority, end: end);
    }
    await session.save();
    return session;
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
    bool? deleted = false,
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
    if (deleted != null) {
      query.where(
        (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull(),
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
          final now = DateTime.now();
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
        pending: SessionPendingSync.full.value,
        priorityId: priority?.id,
        start: DateTime.now(),
        pomodoro: null,
        pomodoroAt: null,
        precedence: 0,
      );

  Session.fromStore(SessionRow row, {this.priority})
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
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
    Value<DateTime?> deletedAt = const Value.absent(),
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
      pending: pending.present ? pending : Value(SessionPendingSync.full.value),
      deletedAt: deletedAt,
      priorityId: priorityId,
      start: start,
      end: end,
      precedence: precedence,
      pomodoro: pomodoro,
      pomodoroAt: pomodoroAt,
    ),
  );

  final Priority? priority;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), SessionsBase());

  BoundedDateTimeRange get at => BoundedDateTimeRange(start, end);

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
