part of 'bloc.dart';

sealed class PriorityEvent {
  const PriorityEvent();
}

final class PrioritiesWeekChanged extends PriorityEvent {
  const PrioritiesWeekChanged(this.week);

  final DateTimeRange week;
}

final class PriorityChanged extends PriorityEvent {
  const PriorityChanged(this.budget);

  final Budget budget;
}

final class PriorityAdded extends PriorityEvent {
  const PriorityAdded(this.name, {this.parent});

  final String name;
  final Activity? parent;
}
