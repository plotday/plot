import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/async.dart';
import 'store.dart';

class ScheduledDay extends Equatable {
  static Stream<Map<Date, ScheduledDay>> watch(
    DateRange range, {
    bool? deleted = false,
  }) {
    return Date.current().switchMap((today) {
      final includesCurrentDay = range.includes(today);
      
      if (includesCurrentDay) {
        // If range includes current day, combine with _watchToday for that day
        return Rx.combineLatest2(
          _watchRangeExcludingToday(range, today, deleted: deleted),
          _watchToday(today),
          (rangeMap, todaySchedule) {
            final result = Map<Date, ScheduledDay>.from(rangeMap);
            result[today] = todaySchedule;
            return result;
          },
        );
      } else {
        // If range doesn't include current day, use standard range watching
        return _watchRangeExcludingToday(range, today, deleted: deleted);
      }
    });
  }

  static Stream<Map<Date, ScheduledDay>> _watchRangeExcludingToday(
    DateRange range,
    Date today, {
    bool? deleted = false,
  }) {
    return Rx.combineLatest3(
      Event.watch(range, withPriority: true, deleted: deleted),
      Priority.watchDefault(),
      Priority.watch(range: range, deleted: deleted),
      (events, defaultPriority, allPriorities) {
        var (start, end) = range.bounds;

        final direction =
            start < end ? TimeDirection.ascending : TimeDirection.descending;
        Map<Date, ScheduledDay> days = {};
        Iterator<Event> eventIterator = events.iterator;
        bool hasMore = eventIterator.moveNext();

        while (start != end) {
          // Skip today if it's in the range - it will be handled by _watchToday
          if (start == today) {
            start = start.next(direction: direction);
            continue;
          }

          List<Event> dayEvents = [];
          while (hasMore && eventIterator.current.start.toDate() == start) {
            dayEvents.add(eventIterator.current);
            hasMore = eventIterator.moveNext();
          }

          // Get priorities for this day
          List<Priority> dayPriorities = [];
          for (final priority in allPriorities) {
            bool shouldInclude = false;

            if (start <= today) {
              // If the day is current or in the past, include if created that day
              if (priority.createdAt.toDate() == start) {
                shouldInclude = true;
              }
            }

            if (start >= today) {
              // If the day is current or in the future, include if doAt is that day
              if (priority.doAt == start) {
                shouldInclude = true;
              }
              // Also include if priorityNextEvent.start is that day
              // This is handled by the doAt logic above since Priority.fromStore
              // sets doAt to nextEventStart when available
            }

            if (shouldInclude) {
              dayPriorities.add(priority);
            }
          }

          days[start] = ScheduledDay(
            date: start,
            events: dayEvents,
            priorities: dayPriorities,
            defaultPriority: defaultPriority,
          );
          start = start.next(direction: direction);
        }
        return days;
      },
    );
  }

  static Stream<ScheduledDay> watchToday() {
    return Date.current().switchMap((today) => _watchToday(today));
  }

  static Stream<ScheduledDay> _watchToday(Date today) {
    return Rx.combineLatest2(
      Priority.watchDefault(),
      Priority.watch(range: Day(today), deleted: false),
      (Priority defaultPriority, List<Priority> allPriorities) => (defaultPriority, allPriorities),
    ).switchMap(
      ((Priority, List<Priority>) tuple) {
        final defaultPriority = tuple.$1;
        final allPriorities = tuple.$2;
        return Event.watch(today.toDateRange()).transform(
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

            // Get priorities for today
            List<Priority> dayPriorities = [];
            for (final priority in allPriorities) {
              bool shouldInclude = false;

              // For today: include if created today or if doAt is today
              if (priority.createdAt.toDate() == today || priority.doAt == today) {
                shouldInclude = true;
              }

              if (shouldInclude) {
                dayPriorities.add(priority);
              }
            }

            return ExpiringResult(
              value: ScheduledDay(
                date: today,
                events: events,
                priorities: dayPriorities,
                defaultPriority: defaultPriority,
              ),
              expiry: expiry,
            );
          }),
        );
      },
    );
  }

  ScheduledDay({
    required this.date,
    required List<Event> events,
    this.priorities = const [],
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
  final List<Priority> priorities;
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
      priorities: priorities,
      defaultPriority: defaultPriority,
    );
  }

  Event getAt(DateTime time) {
    return events.firstWhere((e) => e.at.includes(time));
  }

  @override
  List<Object> get props => [date, events, priorities];

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
