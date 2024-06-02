part of 'now.dart';

sealed class NowState extends Equatable {
  NowState({
    this.session,
    this.scheduled = const [],
    this.next = const [],
    this.previous = const [],
  }) : now = DateTime.now();

  NowState.copy(NowState state)
      : now = state.now,
        session = state.session,
        scheduled = state.scheduled,
        next = state.next,
        previous = state.previous;

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
  });
}

final class SelectedEventState extends NowState {
  SelectedEventState({
    super.session,
    super.scheduled,
    super.next,
    super.previous,
    ScheduledEvent? selected,
  }) : _selected = selected;
  SelectedEventState.copy(
    NowState copy, {
    ScheduledEvent? selected,
  })  : _selected = selected,
        super.copy(copy);

  final ScheduledEvent? _selected;

  ScheduledEvent get selected => _selected ?? current;

  @override
  SelectedEventState copyWith({
    ScheduledEvent? selected,
    Session? session,
    List<ScheduledEvent>? scheduled,
    List<ScheduledEvent>? next,
    List<ScheduledEvent>? previous,
  }) {
    return SelectedEventState(
      session: session ?? this.session,
      scheduled: scheduled ?? this.scheduled,
      next: next ?? this.next,
      previous: previous ?? this.previous,
      selected: selected ?? _selected,
    );
  }

  @override
  List<Object?> get props => super.props + [selected];
}

final class SelectedEventErrorState extends NowState {
  SelectedEventErrorState({
    required this.error,
    super.session,
    super.scheduled,
    super.next,
    super.previous,
  });
  SelectedEventErrorState.copy(
    NowState copy, {
    required this.error,
  }) : super.copy(copy);

  final String error;

  @override
  SelectedEventErrorState copyWith({
    String? error,
    Session? session,
    List<ScheduledEvent>? scheduled,
    List<ScheduledEvent>? next,
    List<ScheduledEvent>? previous,
  }) {
    return SelectedEventErrorState(
      session: session ?? this.session,
      scheduled: scheduled ?? this.scheduled,
      next: next ?? this.next,
      previous: previous ?? this.previous,
      error: error ?? this.error,
    );
  }

  @override
  List<Object?> get props => super.props + [error];
}

final class SelectedEventLoadingState extends NowState {
  SelectedEventLoadingState({
    super.session,
    super.scheduled,
    super.next,
    super.previous,
  });
  SelectedEventLoadingState.copy(NowState copy) : super.copy(copy);

  @override
  SelectedEventLoadingState copyWith({
    Session? session,
    List<ScheduledEvent>? scheduled,
    List<ScheduledEvent>? next,
    List<ScheduledEvent>? previous,
  }) {
    return SelectedEventLoadingState(
      session: session ?? this.session,
      scheduled: scheduled ?? this.scheduled,
      next: next ?? this.next,
      previous: previous ?? this.previous,
    );
  }
}
