part of 'now.dart';

sealed class NowState extends Equatable {
  const NowState();
}

final class NowLoadingState extends NowState {
  const NowLoadingState();

  @override
  List<Object?> get props => [];
}

final class NowLoadedState extends NowState {
  NowLoadedState({
    required this.defaultPriority,
    required ScheduledDay day,
    this.session,
  }) : now = DateTime.now(),
       _day = day;

  final DateTime now;
  final Session? session;
  final ScheduledDay _day;
  final Priority defaultPriority;

  List<Event> get scheduled =>
      _day.events.where((event) => event.at.includes(now)).toList();

  List<Event> get next {
    final events = _day.events;
    int first = -1;
    int last = events.length;
    for (int i = 0; i < events.length; i++) {
      if (events[i].start.isAfter(now)) {
        if (first == -1) {
          first = i;
        } else if (!events[i].start.isAtSameMomentAs(events[first].start)) {
          last = i;
          break;
        }
      }
    }
    if (first == -1) {
      return [];
    }
    return events.sublist(first, last);
  }

  List<Event> get previous {
    final events = _day.events;
    int first = 0;
    int last = events.length;
    for (int i = events.length - 1; i >= 0; i--) {
      if (events[i].start.isBefore(now)) {
        if (!events[i].start.isAtSameMomentAs(events[first].start)) {
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
  Event get current =>
      scheduled.firstOrNull ??
      Event(
        at: DateTimeRange(
          previous.firstOrNull?.at.end ?? now.round(),
          next.firstOrNull?.at.start ?? now.round(down: false),
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

  // TODO change to range
  DateTime? get start =>
      pomodoro?.start ??
      session?.at.start ?? // TODO: follow back
      scheduled.firstOrNull?.at.start ??
      previous.firstOrNull?.at.end;
  DateTime? get end =>
      pomodoro?.end ??
      (scheduled.firstOrNull?.priority == priority
          ? scheduled.firstOrNull?.at.end
          : null) ??
      next.firstOrNull?.at.start;

  DateTime? endFor(Priority? priority) {
    if (priority == this.priority && end != null) {
      return end;
    }
    return next.firstOrNull?.at.start;
  }

  Duration? get elapsed => start != null ? now.difference(start!) : null;
  Duration? get remaining =>
      end != null && end!.isBefore(now) ? end!.difference(now) : null;

  bool get finite => start != null && end != null;
  Duration? get duration => finite ? end!.difference(start!) : null;
  double? get progress => finite
      ? now.isBefore(end!)
            ? elapsed!.inSeconds / duration!.inSeconds
            : 1
      : null;

  NowState copyWith({
    Session? session,
    ScheduledDay? day,
    Priority? defaultPriority,
  }) {
    return NowLoadedState(
      session: session ?? this.session,
      day: day ?? _day,
      defaultPriority: defaultPriority ?? this.defaultPriority,
    );
  }
}
