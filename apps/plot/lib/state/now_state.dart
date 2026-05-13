part of 'now.dart';

sealed class NowState extends Equatable {
  const NowState();
}

/// Active state of the pomodoro timer for the current `context` priority.
/// Derived from the active session's [Session.pomodoro] and
/// [Session.pomodoroAt] fields plus wall-clock time — no separate storage.
enum PomodoroState {
  /// No active session for the context priority. Pill shows planned
  /// duration with a play prefix; nothing is being recorded.
  inactive,
  /// Session is running and within its planned pomodoro window.
  active,
  /// Pomodoro window elapsed, but the session keeps recording for an
  /// additional 5-minute grace period. Pill pulses "0m" during this time.
  grace,
}

/// How long the user has after pomodoro expiry before the session
/// auto-stops. Shared between the NowBloc tick driver and the pill's
/// pulse state so both agree on when grace ends.
const Duration kPomodoroGrace = Duration(minutes: 5);

/// Default pomodoro duration when the focused priority has no
/// `priority_block.duration` set. Long enough to be useful, short
/// enough that the user notices when it's wrong.
const Duration kDefaultPomodoro = Duration(minutes: 15);

/// Default pomodoro duration when the user switches to a different
/// priority while a session is already active — short on purpose so
/// distractions either get explicitly extended or get a quick reminder.
const Duration kDistractionPomodoro = Duration(minutes: 5);

/// Snap granularity used by [AddTime] / [RemoveTime]. `+` jumps the
/// remaining time UP to the next multiple; `−` shaves exactly this much
/// off (with a floor at [kMinPomodoro]).
const Duration kPomodoroStep = Duration(minutes: 15);

/// Minimum remaining time the `−` button leaves on the timer when the
/// caller has less than [kPomodoroStep] left to remove.
const Duration kMinPomodoro = Duration(minutes: 5);

final class NowLoading extends NowState {
  const NowLoading();

  @override
  List<Object?> get props => [];
}

final class NowLoaded extends NowState {
  NowLoaded({
    required this.defaultPriority,
    required ScheduledDay day,
    this.priorities = const [],
    this.priorityBlocksByPriority = const {},
    this.session,
    this.context,
    this.currentEvent,
    this.trackingPausedAt,
    this.previewPomodoro,
  }) : now = Time.now(),
       _day = day;

  final DateTime now;
  final Session? session;
  final ScheduledDay _day;
  final Priority defaultPriority;
  final Priority? context;

  /// User's global tracking-pause state from `user_settings`. When
  /// non-null and not the epoch sentinel, the [NowBloc] driver leaves the
  /// active session alone and the UI's pause toggle reads as "paused"
  /// with this timestamp. Use [trackingPaused] for the boolean answer —
  /// resume writes [DateTime.fromMillisecondsSinceEpoch(0)] as an
  /// explicit-clear marker for the server, which the local DB stores
  /// verbatim until the next pull replaces it with null.
  final DateTime? trackingPausedAt;

  /// True when global time tracking is paused, ignoring the epoch
  /// sentinel that `ResumeTracking` writes as an explicit-clear marker
  /// (see [trackingPausedAt]).
  bool get trackingPaused =>
      trackingPausedAt != null &&
      trackingPausedAt!.millisecondsSinceEpoch != 0;

  /// The event thread the user has tapped in the agenda. Sticky for the
  /// lifetime of the current priority view: cleared when [context]
  /// changes to a priority that doesn't own the event. Drives the
  /// PriorityPage "Event Agenda" section, the unified-header title, and
  /// the right-side agenda filter.
  final Thread? currentEvent;

  /// Every non-archived priority. Used to rank "current priority" by
  /// [effectivePriorityOrderAt] when neither an active session nor a
  /// currently-running scheduled event applies.
  final List<Priority> priorities;

  /// Priority-block timeline rows grouped by priority id. Same shape the
  /// agenda's [AgendaBuilder] consumes — keeps `NowLoaded.priority` in
  /// sync with what the agenda renders as its lead block.
  final Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority;

  /// The duration the inactive-state pill should display for the
  /// [context] priority after the user nudged `+`/`-`. Cleared whenever
  /// [context] changes (`NowBloc.setContext` is responsible). Not
  /// persisted — purely a UI staging value before [StartTimer] writes
  /// `pomodoro`/`pomodoroAt` to the session row.
  final Duration? previewPomodoro;

  List<Thread> get scheduled =>
      _day.scheduled.where((event) => event.at!.includes(now)).toList();

  List<Thread> get next {
    final events = _day.scheduled;
    int first = -1;
    int last = events.length;
    for (int i = 0; i < events.length; i++) {
      if (events[i].at?.start?.isAfter(now) == true) {
        if (first == -1) {
          first = i;
        } else {
          final currentStart = events[i].at?.start;
          final firstStart = events[first].at?.start;
          if (currentStart != null &&
              firstStart != null &&
              !currentStart.isAtSameMomentAs(firstStart)) {
            last = i;
            break;
          }
        }
      }
    }
    if (first == -1) {
      return [];
    }
    return events.sublist(first, last);
  }

  List<Thread> get previous {
    final events = _day.scheduled;
    int last = -1;
    int first = -1;

    // Iterate backwards to find the most recent group of previous events
    for (int i = events.length - 1; i >= 0; i--) {
      if (events[i].at?.start?.isBefore(now) == true) {
        if (last == -1) {
          // Found the most recent previous event
          last = i + 1;
          first = i;
        } else {
          // Check if this event is at the same moment
          final currentStart = events[i].at?.start;
          final lastStart = events[last - 1].at?.start;
          if (currentStart != null &&
              lastStart != null &&
              currentStart.isAtSameMomentAs(lastStart)) {
            // Part of the same group
            first = i;
          } else {
            // Different moment, stop
            break;
          }
        }
      } else {
        // Not a previous event, stop if we've found any
        if (last != -1) {
          break;
        }
      }
    }

    if (last == -1) {
      return [];
    }
    return events.sublist(first, last);
  }

  @override
  List<Object?> get props => [
    session,
    scheduled,
    next,
    previous,
    context?.id,
    defaultPriority,
    // Derived value standing in for `priorities` /
    // `priorityBlocksByPriority`: only rebuild when the picked current
    // priority actually changes, not on every block-row tweak.
    priority.id,
    currentEvent?.id,
    currentEvent?.occurrence,
    // Reduced to a boolean so the epoch sentinel `ResumeTracking` writes
    // locally doesn't show up as a distinct paused state — only a real
    // flip of [trackingPaused] should re-emit.
    trackingPaused,
    previewPomodoro,
  ];

  /// The "current priority" — what the user should be working on right
  /// now. Used by the `/` route redirect, focus commands, and other
  /// callers that need a single canonical answer. Ordering, in priority:
  ///   1. [context] — explicit programmatic override (the priority the
  ///      user is currently viewing).
  ///   2. [session] — the active focus session's priority.
  ///   3. The first event currently in progress on today's schedule
  ///      (matches an [EventBlock] with `isCurrent: true` in the agenda).
  ///   4. The priority with the lowest [effectivePriorityOrderAt] at
  ///      [now] — same ranking the agenda uses to choose each region's
  ///      lead block.
  ///   5. [defaultPriority] — last-resort fallback.
  Priority get priority =>
      context ??
      session?.priority ??
      scheduled.firstOrNull?.priority ??
      _topByEffectiveOrder() ??
      defaultPriority;

  Priority? _topByEffectiveOrder() {
    if (priorities.isEmpty) return null;
    final ranked = priorities.toList()
      ..sort((a, b) {
        final aOrd = effectivePriorityOrderAt(
          moment: now,
          blocksForPriority: priorityBlocksByPriority[a.id] ?? const [],
          fallback: a.order.value,
        );
        final bOrd = effectivePriorityOrderAt(
          moment: now,
          blocksForPriority: priorityBlocksByPriority[b.id] ?? const [],
          fallback: b.order.value,
        );
        return aOrd.compareTo(bOrd);
      });
    return ranked.first;
  }
  Thread get current =>
      scheduled.firstOrNull ??
      Thread(
        at: DateTimeRange(
          previous.firstOrNull?.at?.end ?? now.round(),
          next.firstOrNull?.at?.start ?? now.round(down: false),
        ),
        priority: priority,
      );

  DateTimeRange? get pomodoro {
    if (session?.pomodoro == null || session?.pomodoroAt == null) return null;
    return DateTimeRange(
      session!.pomodoroAt!,
      session!.pomodoroAt!.add(session!.pomodoro!),
    );
  }

  /// True iff [session] is an active, non-archived `source='active'`
  /// session for the [context] priority. `source='event'` rows from the
  /// scheduled-event finalizer are deliberately excluded — they show in
  /// the agenda, not the pill.
  bool get _hasActiveContextSession {
    final s = session;
    final ctx = context;
    if (s == null || ctx == null) return false;
    if (s.archivedAt != null) return false;
    if (s.source != 'active') return false;
    if (s.priority?.id != ctx.id) return false;
    if (!s.at.isNow()) return false;
    return s.pomodoroAt != null && s.pomodoro != null;
  }

  /// Pill state machine. See [PomodoroState] for the three positions.
  PomodoroState get pomodoroState {
    if (!_hasActiveContextSession) return PomodoroState.inactive;
    final end = session!.pomodoroAt!.add(session!.pomodoro!);
    if (now.isBefore(end)) return PomodoroState.active;
    if (now.isBefore(end.add(kPomodoroGrace))) return PomodoroState.grace;
    return PomodoroState.inactive;
  }

  /// Time remaining in the current pomodoro window. Negative-clamped to
  /// zero; null when no active context session exists.
  Duration? get pomodoroRemaining {
    if (!_hasActiveContextSession) return null;
    final end = session!.pomodoroAt!.add(session!.pomodoro!);
    final remaining = end.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Fraction of the planned pomodoro that has elapsed (0..1, clamped).
  /// 0 when no active context session.
  double get pomodoroProgress {
    if (!_hasActiveContextSession) return 0;
    final total = session!.pomodoro!.inMilliseconds;
    if (total <= 0) return 1;
    final elapsed = now.difference(session!.pomodoroAt!).inMilliseconds;
    final ratio = elapsed / total;
    if (ratio <= 0) return 0;
    if (ratio >= 1) return 1;
    return ratio;
  }

  /// Pending duration for [p] resolved against the priority_block
  /// timeline at [now]. Returns null when the priority has no row
  /// contributing a duration. Pure read of state — the bloc reads the
  /// same value through `_pendingFor`, this getter just exposes it for
  /// the pill's inactive-state display.
  Duration? pendingFor(Priority p) {
    final rows = priorityBlocksByPriority[p.id] ?? const [];
    return effectivePriorityDurationAt(
      moment: now,
      blocksForPriority: rows,
    );
  }

  DateTimeRange? get at {
    final startTime =
        pomodoro?.start ??
        session?.at.start ??
        scheduled.firstOrNull?.at?.start ??
        previous.firstOrNull?.at?.end;

    final endTime =
        pomodoro?.end ??
        (scheduled.firstOrNull?.priority == priority
            ? scheduled.firstOrNull?.at?.end
            : null) ??
        next.firstOrNull?.at?.start;

    if (startTime == null && endTime == null) return null;
    return DateTimeRange(startTime, endTime);
  }

  DateTime? endFor(Priority? priority) {
    if (priority == this.priority && at?.end != null) {
      return at!.end;
    }
    return next.firstOrNull?.at?.start;
  }

  /// Upper bound for *extending* the active pomodoro. Mirrors [endFor]
  /// but never returns the in-flight pomodoro's own end — using that as
  /// a cap creates a feedback loop where each `+` press clamps the new
  /// duration back down to the existing remaining time.
  DateTime? pomodoroEndCap(Priority? priority) {
    if (priority == this.priority) {
      final scheduledEnd = scheduled.firstOrNull?.priority == priority
          ? scheduled.firstOrNull?.at?.end
          : null;
      if (scheduledEnd != null) return scheduledEnd;
    }
    return next.firstOrNull?.at?.start;
  }

  Duration? get elapsed =>
      at?.start != null ? now.difference(at!.start!) : null;
  Duration? get remaining => at?.end != null && at!.end!.isBefore(now)
      ? at!.end!.difference(now)
      : null;

  bool get finite => at?.start != null && at?.end != null;
  Duration? get duration => at?.duration;
  double? get progress => finite
      ? now.isBefore(at!.end!)
            ? elapsed!.inSeconds / duration!.inSeconds
            : 1
      : null;

  NowState copyWith({
    Session? session,
    ScheduledDay? day,
    Priority? defaultPriority,
    Priority? context,
    List<Priority>? priorities,
    Map<PriorityId, List<PriorityBlockRow>>? priorityBlocksByPriority,
    Object? currentEvent = _sentinel,
    Object? trackingPausedAt = _sentinel,
    Object? previewPomodoro = _sentinel,
  }) {
    return NowLoaded(
      session: session ?? this.session,
      day: day ?? _day,
      defaultPriority: defaultPriority ?? this.defaultPriority,
      context: context ?? this.context,
      priorities: priorities ?? this.priorities,
      priorityBlocksByPriority:
          priorityBlocksByPriority ?? this.priorityBlocksByPriority,
      currentEvent: identical(currentEvent, _sentinel)
          ? this.currentEvent
          : currentEvent as Thread?,
      trackingPausedAt: identical(trackingPausedAt, _sentinel)
          ? this.trackingPausedAt
          : trackingPausedAt as DateTime?,
      previewPomodoro: identical(previewPomodoro, _sentinel)
          ? this.previewPomodoro
          : previewPomodoro as Duration?,
    );
  }
}

const Object _sentinel = Object();
