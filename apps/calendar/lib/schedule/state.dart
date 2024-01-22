part of 'bloc.dart';

class EventList {
  const EventList(this.events, this.nextAnchor);
  final Map<DateTime, List<ScheduledEvent>> events;
  final DateTime? nextAnchor;
}

final class ScheduleState extends Equatable {
  const ScheduleState(
      {this.lists = const {
        TimeDirection.descending: EventList({}, null),
        TimeDirection.ascending: EventList({}, null)
      }});

  final Map<TimeDirection, EventList> lists;

  @override
  List<Object> get props => [lists];
}
