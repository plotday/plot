import 'package:equatable/equatable.dart';
import 'dart:collection';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/async.dart';
import 'store.dart';

class ScheduledDay extends Equatable {
  static Stream<Map<Date, ScheduledDay>> watch(
    DateRange range, {
    Priority? context,
    bool? deleted = false,
  }) {
    return Date.current().switchMap((today) {
      final includesCurrentDay = range.includes(today);

      if (includesCurrentDay) {
        // If range includes current day, combine with _watchToday for that day
        return Rx.combineLatest2(
          _watchRangeExcludingToday(
            range,
            today,
            context: context,
            deleted: deleted,
          ),
          _watchToday(today, context: context),
          (rangeMap, todaySchedule) {
            final result = Map<Date, ScheduledDay>.from(rangeMap);
            // Only include today if it has events or activities
            if (todaySchedule.events.isNotEmpty || todaySchedule.activities.isNotEmpty) {
              result[today] = todaySchedule;
            }
            final sortedEntries = result.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key));
            return LinkedHashMap<Date, ScheduledDay>.fromEntries(sortedEntries);
          },
        );
      } else {
        // If range doesn't include current day, use standard range watching
        return _watchRangeExcludingToday(
          range,
          today,
          context: context,
          deleted: deleted,
        );
      }
    });
  }

  static Stream<Map<Date, ScheduledDay>> _watchRangeExcludingToday(
    DateRange range,
    Date today, {
    Priority? context,
    bool? deleted = false,
  }) {
    return Rx.combineLatest3(
      Event.watch(range, withPriority: true, deleted: deleted),
      Priority.watchDefault(),
      context != null
          ? Activity.watch(
              range: range,
              priorityPath: context.path,
              deleted: deleted,
            )
          : Stream.value(<Activity>[]),
      (events, defaultPriority, allActivities) {
        var (start, end) = range.bounds;

        final direction = start < end
            ? TimeDirection.ascending
            : TimeDirection.descending;
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

          // Get activities for this day
          List<Activity> dayActivities = [];
          for (final activity in allActivities) {
            if (activity.createdAt.toDate() == start ||
                (activity.doAt == start && start > today)) {
              dayActivities.add(activity);
            }
          }

          // Only include days that have events or activities
          if (dayEvents.isNotEmpty || dayActivities.isNotEmpty) {
            days[start] = ScheduledDay(
              date: start,
              events: dayEvents,
              activities: dayActivities,
              defaultPriority: defaultPriority,
            );
          }
          start = start.next(direction: direction);
        }
        return days;
      },
    );
  }

  static Stream<ScheduledDay> watchToday() {
    return Date.current().switchMap((today) => _watchToday(today));
  }

  static Stream<ScheduledDay> _watchToday(Date today, {Priority? context}) {
    return Rx.combineLatest2(
      Priority.watchDefault(),
      context != null
          ? Activity.watch(
              range: Day(today),
              priorityPath: context.path,
              deleted: false,
            )
          : Stream.value(<Activity>[]),
      (Priority defaultPriority, List<Activity> allActivities) =>
          (defaultPriority, allActivities),
    ).switchMap(((Priority, List<Activity>) tuple) {
      final defaultPriority = tuple.$1;
      final allActivities = tuple.$2;
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

          // Get activities for today - only include if context is provided
          List<Activity> dayActivities = [];
          for (final activity in allActivities) {
            bool shouldInclude = false;

            // For today: include if created today or if doAt is today
            if (activity.createdAt.toDate() == today ||
                activity.doAt == today) {
              shouldInclude = true;
            }

            if (shouldInclude) {
              dayActivities.add(activity);
            }
          }

          return ExpiringResult(
            value: ScheduledDay(
              date: today,
              events: events,
              activities: dayActivities,
              defaultPriority: defaultPriority,
            ),
            expiry: expiry,
          );
        }),
      );
    });
  }

  ScheduledDay({
    required this.date,
    required List<Event> events,
    this.activities = const [],
    required this.defaultPriority,
  }) : events = events
           .where((e) => e.at.duration < const Duration(hours: 22))
           .toList(),
       allDayEvents = events
           .where((e) => e.at.duration >= const Duration(hours: 22))
           .toList();

  final Date date;
  final List<Event> events;
  final List<Event> allDayEvents;
  final List<Activity> activities;
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
      activities: activities,
      defaultPriority: defaultPriority,
    );
  }

  Event getAt(DateTime time) {
    return events.firstWhere((e) => e.at.includes(time));
  }

  @override
  List<Object> get props => [date, events, activities];
}
