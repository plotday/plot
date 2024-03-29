part of 'bloc.dart';

sealed class PriorityEvent {
  const PriorityEvent();
}

final class PrioritiesWeekChanged extends PriorityEvent {
  const PrioritiesWeekChanged(this.week);

  final DateTimeRange week;
}

final class PriorityChanged extends PriorityEvent {
  const PriorityChanged(this.priority);

  final Priority priority;
}

final class ContextAdded extends PriorityEvent {
  const ContextAdded(this.context);

  final Context context;
}

final class ActivityAdded extends PriorityEvent {
  const ActivityAdded(this.activity);

  final Activity activity;
}
