part of 'bloc.dart';

sealed class ScheduleEvent {
  const ScheduleEvent();
}

final class ScheduleFetch extends ScheduleEvent {
  const ScheduleFetch(this.anchor, this.direction);

  final DateTime anchor;
  final TimeDirection direction;
}

final class ScheduleUpdated extends ScheduleEvent {
  const ScheduleUpdated(this.event, {this.replace});

  final ScheduledEvent event;
  final ScheduledEvent? replace;
}
