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

  Context? get context => session?.context ?? scheduled.firstOrNull?.context;
  ScheduledEvent get current =>
      scheduled.firstOrNull ??
      ScheduledEvent(
        at: DateTimeRange(previous.firstOrNull?.at.end ?? now.round(),
            next.firstOrNull?.at.start ?? now.round(down: false)),
      );

  bool get pomodoroActive =>
      session?.pomodoroStart != null &&
      session?.pomodoroLength != null &&
      now.isBefore(pomodoroStart!
          .add(session!.pomodoroLength!)
          .add(const Duration(minutes: 1)));
  DateTime? get pomodoroStart => pomodoroActive ? session?.pomodoroStart : null;
  DateTime? get pomodoroEnd =>
      pomodoroActive ? pomodoroStart?.add(session!.pomodoroLength!) : null;

  DateTime? get start =>
      pomodoroStart ??
      session?.at.start ??
      scheduled.firstOrNull?.at.start ??
      previous.firstOrNull?.at.end;
  DateTime? get end =>
      pomodoroEnd ??
      (session != null &&
              session!.at.end.add(const Duration(minutes: 1)).isBefore(now)
          ? session!.at.end
          : null) ??
      (scheduled.firstOrNull?.context == context
          ? scheduled.firstOrNull?.at.end
          : null) ??
      next.firstOrNull?.at.start;

  DateTime? endFor(Context? context) {
    if (context == session?.context) {
      return end;
    }
    return (scheduled.firstOrNull?.context == context
            ? scheduled.firstOrNull?.at.end
            : null) ??
        next.firstOrNull?.at.start;
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
