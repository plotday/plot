part of 'now.dart';

sealed class NowState extends Equatable {
  const NowState();
}

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
  }) : now = Time.now(),
       _day = day;

  final DateTime now;
  final Session? session;
  final ScheduledDay _day;
  final Priority defaultPriority;
  final Priority? context;

  /// Every non-archived priority. Used to rank "current priority" by
  /// [effectivePriorityOrderAt] when neither an active session nor a
  /// currently-running scheduled event applies.
  final List<Priority> priorities;

  /// Priority-block timeline rows grouped by priority id. Same shape the
  /// agenda's [AgendaBuilder] consumes — keeps `NowLoaded.priority` in
  /// sync with what the agenda renders as its lead block.
  final Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority;

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
  }) {
    return NowLoaded(
      session: session ?? this.session,
      day: day ?? _day,
      defaultPriority: defaultPriority ?? this.defaultPriority,
      context: context ?? this.context,
      priorities: priorities ?? this.priorities,
      priorityBlocksByPriority:
          priorityBlocksByPriority ?? this.priorityBlocksByPriority,
    );
  }
}
