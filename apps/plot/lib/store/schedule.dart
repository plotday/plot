import 'package:equatable/equatable.dart';
import 'dart:collection';
import 'dart:math';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/async.dart';
import 'store.dart';

class ScheduledDay extends Equatable {
  static Stream<Map<Date, ScheduledDay>> watch(
    DateRange range, {
    Priority? context,
    bool? deleted = false,
    List<Tag>? filter,
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
            filter: filter,
          ),
          _watchToday(today, context: context, deleted: deleted, filter: filter),
          (rangeMap, todaySchedule) {
            final result = Map<Date, ScheduledDay>.from(rangeMap);
            // Only include today if it has events or activities
            if (todaySchedule.events.isNotEmpty ||
                todaySchedule.activities.isNotEmpty) {
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
          filter: filter,
        );
      }
    });
  }

  static Stream<Map<Date, ScheduledDay>> _watchRangeExcludingToday(
    DateRange range,
    Date today, {
    Priority? context,
    bool? deleted = false,
    List<Tag>? filter,
  }) {
    return Rx.combineLatest2(
      Event.watch(
        range,
        withPriority: true,
        deleted: deleted,
        context: context,
      ),
      Activity.watch(
        range: range,
        priorityPath: context?.path,
        depth: 0,
        deleted: deleted,
        filter: filter,
      ),
      (events, allActivities) {
        Map<Date, ScheduledDay> days = {};

        // Group events by date
        Map<Date, List<Event>> eventsByDate = {};
        for (final event in events) {
          final eventDate = event.start.toDate();
          // Skip today if it's in the range - it will be handled by _watchToday
          if (eventDate == today) continue;
          // Only include events within the range
          if (range.includes(eventDate)) {
            eventsByDate.putIfAbsent(eventDate, () => []).add(event);
          }
        }

        // Group activities by date
        Map<Date, List<Activity>> activitiesByDate = {};
        for (final activity in allActivities) {
          final activityDate = activity.at;
          // Skip today if it's in the range - it will be handled by _watchToday
          if (activityDate == today) continue;
          // Only include activities within the range
          if (range.includes(activityDate)) {
            activitiesByDate.putIfAbsent(activityDate, () => []).add(activity);
          }
        }

        // Combine all unique dates and create ScheduledDay objects
        final allDates = {...eventsByDate.keys, ...activitiesByDate.keys};
        for (final date in allDates) {
          final dayEvents = eventsByDate[date] ?? [];
          final dayActivities = activitiesByDate[date] ?? [];

          days[date] = ScheduledDay(
            date: date,
            events: dayEvents,
            activities: dayActivities,
          );
        }

        return days;
      },
    );
  }

  static Stream<ScheduledDay> watchToday() {
    return Date.current().switchMap((today) => _watchToday(today));
  }

  static Stream<(Date?, Date?)?> watchRange({
    Priority? context,
    bool? deleted = false,
  }) {
    return Rx.combineLatest2(
      Event.watchRange(deleted: deleted, context: context),
      Activity.watchRange(context: context, deleted: deleted),
      (eventRange, activityRange) {
        // If neither events nor activities exist, return null
        if (eventRange == null && activityRange == null) {
          return null;
        }

        Date? earliest;
        Date? latest;

        // Consider event range
        if (eventRange != null) {
          earliest = eventRange.$1;
          latest = eventRange.$2;
        }

        // Consider activity range and merge with event range
        if (activityRange != null) {
          final activityEarliest = activityRange.$1;
          final activityLatest = activityRange.$2;

          if (activityEarliest != null) {
            if (earliest == null || activityEarliest.isBefore(earliest)) {
              earliest = activityEarliest;
            }
          }

          if (activityLatest != null) {
            if (latest == null || activityLatest.isAfter(latest)) {
              latest = activityLatest;
            }
          }
        }

        return (earliest, latest);
      },
    );
  }

  /// Find the next date after [fromDate] that has events or activities
  static Future<Date?> next(
    Date fromDate, {
    Priority? context,
    bool? deleted = false,
    // Return a date that includes at least minimum events or activities after fromDate
    int minimum = 1,
  }) async {
    final List<Date?> dates = await Future.wait([
      Event.next(
        fromDate,
        context: context,
        deleted: deleted,
        offset: max(minimum - 1, 0),
      ).then((event) => event?.start.toDate()),
      Activity.next(
        fromDate,
        context: context,
        deleted: deleted,
        offset: max(minimum - 1, 0),
      ).then((activity) => activity?.at),
    ]);
    return dates.fold<Date?>(null, (Date? next, Date? date) {
      if (date == null) return next;
      if (next == null || date.isBefore(next)) {
        return date;
      }
      return next;
    });
  }

  /// Find the previous date before [fromDate] that has events or activities
  static Future<Date?> previous(
    Date fromDate, {
    Priority? context,
    bool? deleted = false,
    // Return a date that includes at least minimum events or activities before fromDate
    int minimum = 1,
  }) async {
    // Get the previous event and activity using parallel database queries
    final List<Date?> dates = await Future.wait([
      Event.previous(
        fromDate,
        context: context,
        deleted: deleted,
        offset: max(minimum - 1, 0),
      ).then((event) => event?.start.toDate()),
      Activity.previous(
        fromDate,
        context: context,
        deleted: deleted,
        offset: max(minimum - 1, 0),
      ).then((activity) => activity?.createdAt.toDate()),
    ]);
    return dates.fold<Date?>(null, (Date? prev, Date? date) {
      if (date == null) return prev;
      if (prev == null || date.isAfter(prev)) {
        return date;
      }
      return prev;
    });
  }

  static Stream<ScheduledDay> _watchToday(
    Date today, {
    Priority? context,
    bool? deleted = false,
    List<Tag>? filter,
  }) {
    return Rx.combineLatest2(
      Activity.watch(
        range: today.toDateRange(),
        priorityPath: context?.path,
        depth: 0,
        deleted: deleted,
        filter: filter,
      ),
      Event.watch(today.toDateRange(), context: context, deleted: deleted),
      (List<Activity> allActivities, List<Event> events) =>
          (allActivities, events),
    ).transform(
      ExpiringStreamTransformer((result) {
        final allActivities = result.$1;
        final events = result.$2;
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

        List<Activity> dayActivities = [];
        for (final activity in allActivities) {
          if (activity.at == today) {
            dayActivities.add(activity);
          }
        }

        return ExpiringResult(
          value: ScheduledDay(
            date: today,
            events: events,
            activities: dayActivities,
          ),
          expiry: expiry,
        );
      }),
    );
  }

  ScheduledDay({
    required this.date,
    required List<Event> events,
    this.activities = const [],
  }) : allDayEvents = events.where((e) => e.isAllDay).toList(),
       events = _addGaps(date, events.where((e) => !e.isAllDay).toList());

  static List<Event> _addGaps(Date date, List<Event> events) {
    List<Event> eventsWithGaps = [];
    Event? previous;
    for (final event in events) {
      // Handle gap between events
      if (event.start.isAfter(previous?.end ?? date.toStart())) {
        eventsWithGaps.add(
          Event(
            at: DateTimeRange(previous?.end ?? date.toStart(), event.start),
            draft: true,
          ),
        );
      }
      eventsWithGaps.add(event);
      previous = event;
    }
    // Handle gap after last event
    if (previous == null || previous.end.isBefore(date.toEnd())) {
      eventsWithGaps.add(
        Event(
          at: DateTimeRange(previous?.end ?? date.toStart(), date.toEnd()),
          draft: true,
        ),
      );
    }
    return eventsWithGaps;
  }

  final Date date;
  final List<Event> events;
  final List<Event> allDayEvents;
  final List<Activity> activities;

  Event getAt(DateTime time) {
    return events.firstWhere((e) => e.at.includes(time));
  }

  @override
  List<Object> get props => [date, events, activities, allDayEvents];
}
