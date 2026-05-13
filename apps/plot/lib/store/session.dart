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

  /// Provenance of this session: 'active' (foreground tracker via
  /// [Session.resume]), 'event' (server-finalized scheduled event chunk),
  /// or 'manual' (±15m adjustment from the time-tracking modal). Defaults
  /// to 'active' so existing call sites keep their semantics.
  TextColumn get source =>
      text().withDefault(const Constant('active'))();

  /// For 'event' sessions: the scheduled event this session was finalized
  /// from. NULL for 'active'/'manual' sessions.
  BlobColumn get scheduleId =>
      blob().nullable().map(const UuidConverter())();

  /// For 'event' sessions on a recurring schedule: the occurrence start.
  /// Combined with [scheduleId] this is the idempotency key the server's
  /// event finalizer cron uses; the client treats it as opaque.
  DateTimeColumn get occurrenceAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();

  /// True when the user started this pomodoro themselves (pressed
  /// Start, or adjusted a running auto-start via Add time). False when
  /// the client started it implicitly as a 5-minute distraction handoff
  /// after the user switched priorities mid-session. Only `explicit`
  /// paused sessions are revived by the resume path — auto-starts are
  /// one-shot reminders.
  BoolColumn get explicit => boolean().withDefault(const Constant(true))();
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

  /// Sum the durations of non-archived sessions whose `priority_id` is in
  /// [priorityIds]. Pure helper — no DB access. Used by the priority tile
  /// chip, the unified header, and the time-tracking modal to aggregate
  /// weekly/daily totals. Sessions with `priority_id` set to null (rare —
  /// the user's priority was deleted after the session) are ignored.
  ///
  /// When [until] is provided, each session's effective end is clamped to
  /// it. An active session has `end` set in the future (the periodic
  /// bloc tick re-bumps it to `Time.now()` each minute, but the initial
  /// `setFocus` writes `end = now + 3m`). Without clamping, the displayed
  /// total would include unaccrued future minutes and dip when the next
  /// tick rewrites `end` back to the real `now`.
  static Duration sumDuration(
    Iterable<Session> sessions,
    Set<PriorityId> priorityIds, {
    DateTime? until,
  }) {
    var total = Duration.zero;
    for (final s in sessions) {
      if (s.archivedAt != null) continue;
      // 'skip' rows mark time the user opted out of crediting for a
      // scheduled event; they exist solely as blockers for the
      // server-side event finalizer and must not contribute to totals.
      if (s.source == 'skip') continue;
      final pid = s.priorityId;
      if (pid == null || !priorityIds.contains(pid)) continue;
      final end = until != null && s.end.isAfter(until) ? until : s.end;
      final span = end.difference(s.start);
      if (span > Duration.zero) total += span;
    }
    return total;
  }

  /// Write a 'skip' session covering `[from, to]` against the given
  /// (schedule, occurrence). Used when the user stops the auto-displayed
  /// in-progress event timer: the row acts as a blocker for the server
  /// event finalizer so the resulting 'event' row is clamped to the
  /// time before the stop. Idempotent on `(scheduleId, occurrenceAt)`
  /// — a re-press replaces the existing skip range.
  static Future<void> writeSkip({
    required Priority priority,
    required Uuid scheduleId,
    DateTime? occurrenceAt,
    required DateTime from,
    required DateTime to,
  }) async {
    if (!Store.isAvailable) return;
    if (!to.isAfter(from)) return;
    final existing = await (Store.get.select(table)
          ..where(
            (t) =>
                t.scheduleId.equals(scheduleId.toBytes()) &
                (occurrenceAt == null
                    ? t.occurrenceAt.isNull()
                    : t.occurrenceAt.equals(occurrenceAt)) &
                t.source.equals('skip') &
                t.archivedAt.isNull(),
          )
          ..limit(1))
        .getSingleOrNull();
    final Session row;
    if (existing != null) {
      row = Session.fromStore(
        existing.copyWith(start: from, end: to),
        priority: priority,
      );
    } else {
      final base = Session(
        priority: priority,
        end: to,
        source: 'skip',
        scheduleId: scheduleId,
        occurrenceAt: occurrenceAt,
        explicit: false,
      );
      row = Session.fromStore(
        base.copyWith(start: from),
        priority: priority,
      );
    }
    await row.save();
  }

  /// Stream the most-recent non-archived 'skip' session for the given
  /// (schedule, occurrence). Drives the auto-event timer's hide-after-stop
  /// behavior so a Pause/Stop press takes effect immediately and persists
  /// across reloads. Emits null when no marker exists.
  static Stream<Session?> watchSkipFor(
    Uuid scheduleId, {
    DateTime? occurrenceAt,
  }) {
    if (!Store.isAvailable) return Stream.value(null);
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.scheduleId.equals(scheduleId.toBytes()) &
            (occurrenceAt == null
                ? t.occurrenceAt.isNull()
                : t.occurrenceAt.equals(occurrenceAt)) &
            t.source.equals('skip') &
            t.archivedAt.isNull(),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc),
      ])
      ..limit(1);
    return query.watch().map(
      (rows) => rows.isEmpty ? null : Session.fromStore(rows.first),
    );
  }

  /// Stream the set of priority ids covered by [priority] and every one
  /// of its descendants. Resolved by `path` prefix against the priorities
  /// table — the canonical source — because [Priority.descendants] walks
  /// the in-memory `children` tree, which isn't fully hydrated on every
  /// instance (the PrioritiesBloc only links direct children for the
  /// rows it's currently rendering, while the unified header's context
  /// priority carries the full tree). Routing through `path` keeps every
  /// time-tracking surface in agreement.
  ///
  /// The stream emits a fresh set whenever the priority tree changes
  /// (add / archive / move). Combine with [watch] in a `Rx.combineLatest2`
  /// to keep totals reactive.
  ///
  /// Filtering happens in Dart: drift's [Column.equals] / [Column.like]
  /// against a typed [Path] column have inconsistent type behavior with
  /// a raw [String], and producing the right SQL via `equalsValue` +
  /// `likeExp` is fiddly to keep right. The priorities table is small
  /// (dozens of rows for a real user), so walking all non-archived rows
  /// in Dart is cheap and unambiguous.
  static Stream<Set<PriorityId>> watchSelfAndDescendantIds(Priority priority) {
    final basePath = priority.path.value;
    final basePathPrefix = '$basePath.';
    return (Store.get.select(Store.get.priorities)
          ..where((t) => t.archivedAt.isNull()))
        .watch()
        .map((rows) {
      final result = <PriorityId>{};
      for (final r in rows) {
        final p = r.path.value;
        if (p == basePath || p.startsWith(basePathPrefix)) {
          result.add(r.id);
        }
      }
      return result;
    });
  }

  /// Resume or create a session for [priority].
  ///
  /// When [pomodoro] / [pomodoroAt] are supplied AND a new row is being
  /// created (no in-progress session to extend), they are written through.
  /// When an existing in-progress session for the same priority is being
  /// extended, the pomodoro fields are intentionally NOT overwritten —
  /// the running pomodoro keeps its original start and target.
  ///
  /// [explicit] controls the new row's `explicit` flag. Defaults to true
  /// (user pressed Start, or the caller is reviving a paused explicit
  /// session); pass false from the distraction-handoff path so the
  /// 5-minute auto-start is not later resumed as if the user had asked
  /// for it.
  static Future<Session> resume(
    Priority? priority, {
    required DateTime end,
    Duration? pomodoro,
    DateTime? pomodoroAt,
    bool explicit = true,
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
          session = Session(
            priority: priority,
            end: end,
            pomodoro: pomodoro,
            pomodoroAt: pomodoroAt,
            explicit: explicit,
          );
        }
      }
      await session.save();
      return session;
    });
  }

  /// Most recent paused explicit pomodoro session for [priorityId], or
  /// null if none qualifies. A session is "paused" when:
  ///   - `source` is `'active'` and the row is not archived,
  ///   - `explicit` is true (auto-started 5m distractions never resume),
  ///   - `pomodoroAt` and `pomodoro` are both set,
  ///   - its `end` is strictly before `pomodoroAt + pomodoro` — i.e. it
  ///     was closed before the planned window naturally elapsed.
  /// Used by [NowBloc.startSession] to restore the progress ring's
  /// fill level when the user resumes after pausing.
  static Future<Session?> latestPausedFor(PriorityId priorityId) async {
    if (!Store.isAvailable) return null;
    final row = await (Store.get.select(table)
          ..where(
            (t) =>
                t.priorityId.equals(priorityId.toBytes()) &
                t.archivedAt.isNull() &
                t.source.equals('active') &
                t.explicit.equals(true) &
                t.pomodoroAt.isNotNull() &
                t.pomodoro.isNotNull(),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    final session = Session.fromStore(row);
    if (session.at.isNow()) return null; // Still running.
    final originalEnd = session.pomodoroAt!.add(session.pomodoro!);
    if (!session.end.isBefore(originalEnd)) return null; // Ran to natural end.
    return session;
  }

  /// Like [latestPausedFor] but returns a reactive stream. Used by
  /// `watchPendingDuration` so the agenda's per-priority display flips to
  /// "remaining at pause" the moment the user pauses, and back to the
  /// configured priority_block duration after Stop/Resume cycles.
  static Stream<Session?> watchLatestPausedFor(PriorityId priorityId) {
    if (!Store.isAvailable) return Stream.value(null);
    final query = (Store.get.select(table)
          ..where(
            (t) =>
                t.priorityId.equals(priorityId.toBytes()) &
                t.archivedAt.isNull() &
                t.source.equals('active') &
                t.explicit.equals(true) &
                t.pomodoroAt.isNotNull() &
                t.pomodoro.isNotNull(),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc),
          ])
          ..limit(1));
    return query.watch().map((rows) {
      final row = rows.firstOrNull;
      if (row == null) return null;
      final session = Session.fromStore(row);
      if (session.at.isNow()) return null;
      final originalEnd = session.pomodoroAt!.add(session.pomodoro!);
      if (!session.end.isBefore(originalEnd)) return null;
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

  /// Add or subtract recorded time on a specific day for a priority,
  /// used by the time-tracking modal's per-day +/− buttons. Backed by
  /// `source='manual'` Session rows anchored at noon on [day] (the
  /// anchor is arbitrary — only `at.end - at.start` matters when totals
  /// are summed by day from the local `start` field).
  ///
  /// On +15m, extends the latest `source='manual'` row for the day, or
  /// inserts a new one. On −15m, shrinks the latest `source='manual'`
  /// row, archives it when it falls to zero. If the day has no manual
  /// rows but does have other rows (active/event), the user is implicitly
  /// trimming the most recent of those by inserting a negative manual
  /// row of equal duration? No — to keep totals semantically clean,
  /// negative deltas with no manual headroom are floored at zero so the
  /// display can't go negative.
  static Future<void> adjustDailyTime({
    required PriorityId priorityId,
    required Date day,
    required Duration delta,
  }) async {
    if (!Store.isAvailable) return;
    if (delta == Duration.zero) return;

    // Find the most recent manual session for this priority + day.
    final dayStart = day.toStart();
    final dayEnd = day.toEnd();
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.priorityId.equals(priorityId.toBytes()) &
            t.archivedAt.isNull() &
            t.source.equals('manual') &
            t.start.isBiggerOrEqualValue(dayStart) &
            t.start.isSmallerOrEqualValue(dayEnd),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.start, mode: OrderingMode.desc),
      ])
      ..limit(1);
    final existing = await query.getSingleOrNull();

    if (existing == null) {
      if (delta.isNegative) {
        // Nothing to trim — clamp at zero per the doc above.
        return;
      }
      // Anchor at noon so the row lives inside the day regardless of TZ
      // edge cases when the user later changes locale.
      final anchor = DateTime(day.year, day.month, day.day, 12);
      final row = Session(end: anchor.add(delta));
      // Override the auto-set source/start so this becomes a manual row
      // pinned to the chosen day rather than 'active' at Time.now().
      await Session.fromStore(row.copyWith(
        start: anchor,
        end: anchor.add(delta),
        source: 'manual',
      )).save();
      return;
    }

    final newDuration = existing.end.difference(existing.start) + delta;
    if (newDuration <= Duration.zero) {
      final archived = Session.fromStore(
        existing.copyWith(archivedAt: Value(DateTime.now())),
      );
      await archived.save();
      return;
    }
    final updated = Session.fromStore(
      existing.copyWith(end: existing.start.add(newDuration)),
    );
    await updated.save();
  }

  static Stream<Session?> watchCurrent() =>
      watch(withPriority: true, limit: 1, expiring: true).map((sessions) {
        final session = sessions.firstOrNull;
        return session?.at.isNow() == true ? session : null;
      });

  Session({
    this.priority,
    required super.end,
    super.source = 'active',
    super.scheduleId,
    super.occurrenceAt,
    super.pomodoro,
    super.pomodoroAt,
    super.explicit = true,
  }) : super(
         id: Uuid.generate(),
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         priorityId: priority?.id,
         start: Time.now(),
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
        source: row.source,
        scheduleId: row.scheduleId,
        occurrenceAt: row.occurrenceAt,
        explicit: row.explicit,
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
    String? source,
    Value<Uuid?> scheduleId = const Value.absent(),
    Value<DateTime?> occurrenceAt = const Value.absent(),
    bool? explicit,
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
      source: source,
      scheduleId: scheduleId,
      occurrenceAt: occurrenceAt,
      explicit: explicit,
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
