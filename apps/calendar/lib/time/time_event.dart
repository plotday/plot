part of 'time_bloc.dart';

sealed class TimeEvent {
  const TimeEvent();
}

final class TimeStarted extends TimeEvent {
  const TimeStarted();
}

final class TimePaused extends TimeEvent {
  const TimePaused();
}

final class TimeResumed extends TimeEvent {
  const TimeResumed();
}

class TimeStopped extends TimeEvent {
  const TimeStopped();
}

class _TimeTicked extends TimeEvent {
  const _TimeTicked({required this.duration});
  final int duration;
}
