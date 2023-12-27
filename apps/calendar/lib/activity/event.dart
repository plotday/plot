part of 'bloc.dart';

sealed class ActivityEvent {
  const ActivityEvent();
}

final class ActivityStarted extends ActivityEvent {
  const ActivityStarted(this.activity);

  final Activity activity;
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
