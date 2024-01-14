part of 'bloc.dart';

sealed class PriorityEvent {
  const PriorityEvent();
}

final class PrioritiesWeekChanged extends PriorityEvent {
  const PrioritiesWeekChanged(this.week);

  final Interval week;
}
