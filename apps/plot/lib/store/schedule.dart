import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/async.dart';
import 'store.dart';

class ScheduledDay extends Equatable {
  static Stream<Map<Date, ScheduledDay>> watch(
    DateRange range, {
    bool? deleted = false,
  }) {
    return Rx.combineLatest2(
      Event.watch(range, withPriority: true, deleted: deleted),
      Priority.watchDefault(),
      (events, defaultPriority) {
        var (start, end) = range.bounds;

        final direction =
            start < end ? TimeDirection.ascending : TimeDirection.descending;
        Map<Date, ScheduledDay> days = {};
        Iterator<Event> eventIterator = events.iterator;
        bool hasMore = eventIterator.moveNext();

        while (start != end) {
          List<Event> dayEvents = [];
          while (hasMore && eventIterator.current.start.toDate() == start) {
            dayEvents.add(eventIterator.current);
            hasMore = eventIterator.moveNext();
          }
          days[start] = ScheduledDay(
            date: start,
            events: dayEvents,
            defaultPriority: defaultPriority,
          );
          start = start.next(direction: direction);
        }
        return days;
      },
    );
  }

  static Stream<ScheduledDay> watchToday() {
    return Priority.watchDefault().switchMap(
      (defaultPriority) => Date.current().switchMap(
        (today) => Event.watch(today.toDateRange()).transform(
          ExpiringStreamTransformer((events) {
            final now = DateTime.now();
            final currentEvent = events.any((event) => event.at.includes(now));
            DateTime? expiry;
            if (currentEvent) {
              // Expire every minute on the minute
              expiry = now + Duration(seconds: 60 - now.second);
            } else {
              // Find the earliest event start or end following now
              expiry = events.fold(
                null,
                (DateTime? next, Event e) =>
                    e.at.start.isAfter(now) &&
                            (next == null || next.isAfter(e.at.start))
                        ? e.at.start
                        : e.at.end.isAfter(now) &&
                            (next == null || next.isAfter(e.at.end))
                        ? e.at.end
                        : next,
              );
            }
            return ExpiringResult(
              value: ScheduledDay(
                date: today,
                events: events,
                defaultPriority: defaultPriority,
              ),
              expiry: expiry,
            );
          }),
        ),
      ),
    );
  }

  ScheduledDay({
    required this.date,
    required List<Event> events,
    required this.defaultPriority,
  }) : events = _addGaps(
         date,
         events
             .where((e) => e.at.duration < const Duration(hours: 22))
             .toList(),
         defaultPriority,
       ),
       allDayEvents =
           events
               .where((e) => e.at.duration >= const Duration(hours: 22))
               .toList();

  final Date date;
  final List<Event> events;
  final List<Event> allDayEvents;
  final Priority defaultPriority;

  ScheduledDay copyWith(Event event) {
    final list = events.where((e) => e.id != event.id).toList();
    var index = list.indexWhere((i) => i.at < event.at);
    if (index == -1) {
      index = list.length;
    }
    list.insert(index, event);
    return ScheduledDay(
      date: date,
      events: list,
      defaultPriority: defaultPriority,
    );
  }

  Event getAt(DateTime time) {
    return events.firstWhere((e) => e.at.includes(time));
  }

  @override
  List<Object> get props => [date, events];

  /* Private */

  static List<Event> _addGaps(
    Date date,
    List<Event> events,
    Priority defaultPriority,
  ) {
    List<Event> expanded = [];
    final start = date.toDateTime();
    final end = start.nextDay;
    if (events.isEmpty ||
        events.first.at.start.difference(start).inMinutes > 0) {
      expanded.add(
        Event(
          at: DateTimeRange(
            start,
            events.isEmpty
                ? end
                : start.at(events.first.at.start.toTimeOfDay()),
          ),
          priority: defaultPriority,
        ),
      );
    }
    for (var i = 0; i < events.length; i++) {
      expanded.add(events[i]);
      // If there is a gap between events or at the end of the day
      if ((i + 1 < events.length &&
              events[i].at.end < events[i + 1].at.start) ||
          (i + 1 == events.length &&
              events[i].at.end.difference(end).inMinutes < 0)) {
        expanded.add(
          Event(
            at: DateTimeRange(
              events[i].at.end,
              i + 1 == events.length ? end : events[i + 1].at.start,
            ),
            priority: defaultPriority,
          ),
        );
      }
    }
    return expanded;
  }
}
