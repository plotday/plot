part of 'now.dart';

final class NowState extends Equatable {
  NowState({
    this.session,
    this.scheduled = const [],
    this.next = const [],
    this.previous = const [],
  }) : now = DateTime.now();

  final DateTime now;
  final Session? session;
  final List<ScheduledEvent> scheduled;
  final List<ScheduledEvent> next;
  final List<ScheduledEvent> previous;

  @override
  List<Object?> get props => [session, scheduled, next, previous];

  get context => session?.context ?? scheduled.firstOrNull?.context;

  get pomodoroActive =>
      session?.pomodoroStart != null &&
      session?.pomodoroLength != null &&
      now.isBefore(pomodoroStart
          .add(session!.pomodoroLength)
          .add(const Duration(minutes: 1)));
  get pomodoroStart => pomodoroActive ? session?.pomodoroStart : null;
  get pomodoroEnd =>
      pomodoroActive ? pomodoroStart?.add(session?.pomodoroLength) : null;

  get start =>
      pomodoroStart ??
      session?.at.start ??
      scheduled.firstOrNull?.at.start ??
      previous.firstOrNull?.at.end;
  get end =>
      pomodoroEnd ??
      (session != null &&
              session!.at.end.add(const Duration(minutes: 1)).isBefore(now)
          ? session!.at.end
          : null) ??
      (scheduled.firstOrNull?.context == context
          ? scheduled.firstOrNull?.at.end
          : null) ??
      next.firstOrNull?.at.start;

  endFor(Context? context) {
    if (context == session?.context) {
      return end;
    }
    return (scheduled.firstOrNull?.context == context
            ? scheduled.firstOrNull?.at.end
            : null) ??
        next.firstOrNull?.at.start;
  }

  get elapsed => start != null ? now.difference(start) : null;
  get remaining =>
      end != null && end.isBefore(now) ? end.difference(now) : null;

  get finite => start != null && end != null;
  get duration => finite ? end.difference(start) : null;
  get progress => finite
      ? now.isBefore(end)
          ? elapsed.inSeconds / duration.inSeconds
          : 1
      : null;

  NowState copyWith({
    Session? session,
    List<ScheduledEvent>? scheduled,
    List<ScheduledEvent>? next,
    List<ScheduledEvent>? previous,
  }) {
    return NowState(
      session: session ?? this.session,
      scheduled: scheduled ?? this.scheduled,
      next: next ?? this.next,
      previous: previous ?? this.previous,
    );
  }
}
