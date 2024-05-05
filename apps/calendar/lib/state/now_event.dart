part of 'now.dart';

sealed class NowEvent {
  const NowEvent();
}

final class SessionUpdated extends NowEvent {
  const SessionUpdated(this.session);

  final Session? session;
}

final class ContextSelected extends NowEvent {
  const ContextSelected(this.context);

  final Context context;
}

final class ContextTimeIncreased extends NowEvent {
  ContextTimeIncreased();
}

final class ContextTimeDecreased extends NowEvent {
  ContextTimeDecreased();
}

final class ContextStarted extends NowEvent {
  ContextStarted(this.context, {this.duration, this.end});

  final Context context;
  final Duration? duration;
  final DateTime? end;
}

final class ContextStopped extends NowEvent {
  const ContextStopped();
}

final class ContextResumed extends NowEvent {
  const ContextResumed({this.duration, this.end});

  final Duration? duration;
  final DateTime? end;
}

final class ContextCompleted extends NowEvent {
  const ContextCompleted();
}

final class _ClockTicked extends NowEvent {
  const _ClockTicked();
}
