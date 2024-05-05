part of 'priority.dart';

sealed class PriorityEvent {
  const PriorityEvent();
}

final class PriorityWeekChanged extends PriorityEvent {
  const PriorityWeekChanged(this.week);

  final Week week;
}

final class PriorityChanged extends PriorityEvent {
  const PriorityChanged(this.priority);

  final Priority priority;
}

final class ContextAdded extends PriorityEvent {
  const ContextAdded(this.context);

  final Context context;
}
