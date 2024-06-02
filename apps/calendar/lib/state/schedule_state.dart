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
    Date? day,
  })  : day = day ?? Date.today(),
        _sequence = 1;

  const ScheduleState._int(this._sequence, {required this.day});

  ScheduleState copyWith({Date? day}) {
    return ScheduleState._int(
      _sequence + 1,
      day: day ?? this.day,
    );
  }

  final Date day;
  final int _sequence;

  Week get week => Week(day);

  @override
  List<Object> get props => [day, _sequence];
}
