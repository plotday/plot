part of 'bloc.dart';

sealed class NowEvent {
  const NowEvent();
}

final class ActivitySelected extends NowEvent {
  const ActivitySelected(this.activity);

  final Activity activity;
}

final class ActivityTimeIncreased extends NowEvent {
  ActivityTimeIncreased();
}

final class ActivityTimeDecreased extends NowEvent {
  ActivityTimeDecreased();
}

final class ActivityStarted extends NowEvent {
  ActivityStarted(this.activity, {this.duration, this.end});

  final Activity activity;
  final Duration? duration;
  final DateTime? end;
}

final class ActivityStopped extends NowEvent {
  const ActivityStopped();
}

final class ActivityResumed extends NowEvent {
  const ActivityResumed({this.duration, this.end});

  final Duration? duration;
  final DateTime? end;
}

final class ActivityCompleted extends NowEvent {
  const ActivityCompleted();
}

class _ActivityInit extends NowEvent {
  const _ActivityInit();
}
