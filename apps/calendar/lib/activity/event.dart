part of 'bloc.dart';

sealed class ActivityEvent {
  const ActivityEvent();
}

final class ActivitySelected extends ActivityEvent {
  const ActivitySelected(this.activity);

  final Activity activity;
}

final class ActivityStarted extends ActivityEvent {
  ActivityStarted(this.activity, {Duration? duration, DateTime? end})
      : at = Interval(
            DateTime.now(),
            end ??
                (duration != null
                    ? DateTime.now().add(duration)
                    : DateTime.now()));

  final Activity activity;
  final Interval at;
}

final class ActivityPaused extends ActivityEvent {
  const ActivityPaused();
}

final class ActivityResumed extends ActivityEvent {
  const ActivityResumed();
}

class ActivityStopped extends ActivityEvent {
  const ActivityStopped();
}

class _ActivityInit extends ActivityEvent {
  const _ActivityInit();
}
