part of 'bloc.dart';

sealed class ActivityEvent {
  const ActivityEvent();
}

final class ActivitySelected extends ActivityEvent {
  const ActivitySelected(this.activity);

  final Activity activity;
}

final class ActivityTimeIncreased extends ActivityEvent {
  ActivityTimeIncreased();
}

final class ActivityTimeDecreased extends ActivityEvent {
  ActivityTimeDecreased();
}

final class ActivityStarted extends ActivityEvent {
  ActivityStarted(this.activity, {this.duration, this.end});

  final Activity activity;
  final Duration? duration;
  final DateTime? end;
}

final class ActivityStopped extends ActivityEvent {
  const ActivityStopped();
}

final class ActivityResumed extends ActivityEvent {
  const ActivityResumed({this.duration, this.end});

  final Duration? duration;
  final DateTime? end;
}

final class ActivityCompleted extends ActivityEvent {
  const ActivityCompleted();
}

class _ActivityInit extends ActivityEvent {
  const _ActivityInit();
}
