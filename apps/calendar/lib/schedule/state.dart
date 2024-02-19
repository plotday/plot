part of 'bloc.dart';

class EventList {
  const EventList(this.events, this.nextAnchor);

  EventList copyWith(ScheduledEvent event) {
    final events = {...this.events};
    final day = events[event.at.start.startOfDay] ?? [];
    // Remove the event if it already exists
    day.removeWhere(
        (e) => event.id != null ? e.id == event.id : e.at == event.at);
    // Insert the event in the correct order
    final index = day.indexWhere((e) => e.at.start.isAfter(event.at.start));
    if (index == -1) {
      day.add(event);
    } else {
      day.insert(index, event);
    }
    events[event.at.start.startOfDay] = day;
    return EventList(events, nextAnchor);
  }

  final Map<DateTime, List<ScheduledEvent>> events;
  final DateTime? nextAnchor;
}

final class ScheduleState extends Equatable {
  ScheduleState({
    this.lists = const {
      TimeDirection.descending: EventList({}, null),
      TimeDirection.ascending: EventList({}, null)
    },
    DateTime? anchor,
  }) : anchor = anchor ?? Time.today().start;

  ScheduleState copyWith(ScheduledEvent event) {
    var descendingList = lists[TimeDirection.descending]!;
    var ascendingList = lists[TimeDirection.ascending]!;
    if (event.at.start.isSameOrAfter(anchor)) {
      ascendingList = ascendingList.copyWith(event);
    } else {
      descendingList = descendingList.copyWith(event);
    }
    return ScheduleState(
      lists: {
        TimeDirection.descending: descendingList,
        TimeDirection.ascending: ascendingList,
      },
      anchor: anchor,
    );
  }

  final Map<TimeDirection, EventList> lists;
  final DateTime anchor;

  @override
  List<Object> get props => [lists];
}
