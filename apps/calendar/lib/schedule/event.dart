part of 'bloc.dart';

sealed class ScheduleEvent {
  const ScheduleEvent();
}

final class _ScheduleUpdated extends ScheduleEvent {
  const _ScheduleUpdated(this.current, this.next);

  final List<ScheduledEvent> current;
  final List<ScheduledEvent> next;
}

final class _ScheduleTicked extends ScheduleEvent {
  const _ScheduleTicked();
}
