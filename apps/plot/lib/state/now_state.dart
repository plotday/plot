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
    this.session,
  }) : now = DateTime.now(),
       _day = day;

  final DateTime now;
  final Session? session;
  final ScheduledDay _day;
  final Priority defaultPriority;

  List<Activity> get scheduled =>
      _day.events.where((event) => event.at!.includes(now)).toList();

  List<Activity> get next {
    final events = _day.events;
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

  List<Activity> get previous {
    final events = _day.events;
    int first = 0;
    int last = events.length;
    for (int i = events.length - 1; i >= 0; i--) {
      if (events[i].at?.start?.isBefore(now) == true) {
        final currentStart = events[i].at?.start;
        final firstStart = events[first].at?.start;
        if (currentStart != null &&
            firstStart != null &&
            !currentStart.isAtSameMomentAs(firstStart)) {
          first = i;
        }
      } else {
        last = i;
        break;
      }
    }
    return events.sublist(first, last);
  }

  @override
  List<Object?> get props => [session, scheduled, next, previous];

  Priority get priority =>
      session?.priority ?? scheduled.firstOrNull?.priority ?? defaultPriority;
  Activity get current =>
      scheduled.firstOrNull ??
      Activity(
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
  }) {
    return NowLoaded(
      session: session ?? this.session,
      day: day ?? _day,
      defaultPriority: defaultPriority ?? this.defaultPriority,
    );
  }
}
