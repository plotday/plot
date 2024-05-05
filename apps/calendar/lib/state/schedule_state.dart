part of 'schedule.dart';

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
    Date? anchor,
  })  : anchor = anchor ?? Date.today(),
        _sequence = 1;

  const ScheduleState._int(
    this.anchor,
    this._sequence,
  );

  ScheduleState copyWith({Date? anchor}) {
    return ScheduleState._int(
      anchor ?? this.anchor,
      _sequence + 1,
    );
  }

  final Date anchor;
  final int _sequence;

  @override
  List<Object> get props => [_sequence];
}
