import 'package:equatable/equatable.dart';
import 'dart:collection';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/async.dart';
import 'store.dart';
import 'logging.dart';

class Schedule extends Equatable {
  static Stream<Schedule> watch(
    DateRange range, {
    Priority? context,
    bool? deleted = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Date.current().switchMap((today) {
      final includesCurrentDay = range.includes(today);

      final todayStream = includesCurrentDay
          ? ScheduledDay._watchToday(
              today,
              context: context,
              deleted: deleted,
              filter: filter,
              search: search,
            )
          : Stream.value(null);

      return Rx.combineLatest4(
        _watchRangeExcludingToday(
          range,
          today,
          context: context,
          deleted: deleted,
          filter: filter,
          search: search,
        ),
        todayStream,
        Activity.watchPrevious(
          range.start,
          context: context,
          deleted: deleted,
        ).map((activity) => activity?.agendaAt.toDate()),
        Activity.watchNext(range.end, context: context, deleted: deleted).map((
          activity,
        ) {
          return activity?.agendaAt.toDate();
        }),
        (rangeMap, todaySchedule, previous, next) {
          final result = Map<Date, ScheduledDay>.from(rangeMap);
          // Only include today if it has events or activities and we have a schedule
          if (todaySchedule != null &&
              (todaySchedule.events.isNotEmpty ||
                  todaySchedule.activities.isNotEmpty)) {
            result[today] = todaySchedule;
          }
          final sortedEntries = result.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          final days = LinkedHashMap<Date, ScheduledDay>.fromEntries(
            sortedEntries,
          );

          if (range.start != null) {
            previous = _tightenNextWithOccurrences(
              previous,
              days: days,
              range: CustomBoundedDateRange(
                (previous != null && previous.isBefore(range.start!))
                    ? previous
                    : range.start!.subDays(31),
                range.start!,
              ),
              reverse: true,
            );
          }

          if (range.end != null) {
            next = _tightenNextWithOccurrences(
              next,
              days: days,
              range: CustomBoundedDateRange(
                range.end!,
                (next != null && next.isAfter(range.end!))
                    ? next
                    : range.end!.addDays(31),
              ),
              reverse: false,
            );
          }

          return Schedule(days: days, previous: previous, next: next);
        },
      ).distinct().doOnData((schedule) {
        log.fine("Range = $range, Previous = ${schedule.previous}, Next = ${schedule.next}");
      });
    });
  }

  static Date? _tightenNextWithOccurrences(
    Date? next, {
    required Map<Date, ScheduledDay> days,
    required BoundedDateRange range,
    bool reverse = false,
  }) {
    for (final day in days.values) {
      for (final activity in [...day.events, ...day.activities]) {
        // Stop if boundary is within a week of range boundaries
        if (reverse) {
          // For previous: stop if boundary is within a week of range start
          if (next != null && range.end.difference(next).inDays.abs() <= 7) {
            return next;
          }
        } else {
          // For next: stop if boundary is within a week of range end
          if (next != null && next.difference(range.start).inDays.abs() <= 7) {
            return next;
          }
        }

        final occurrenceDate = activity.nextOccurrence(range, reverse: reverse);
        if (occurrenceDate == null) continue;

        if (reverse) {
          // Update boundary if this occurrence is later than current boundary
          if (next == null || occurrenceDate.isAfter(next)) {
            next = occurrenceDate;
          }
        } else {
          // Update boundary if this occurrence is earlier than current boundary
          if (next == null || occurrenceDate.isBefore(next)) {
            next = occurrenceDate;
          }
        }
      }
    }

    return next;
  }

  static Stream<Map<Date, ScheduledDay>> _watchRangeExcludingToday(
    DateRange range,
    Date today, {
    Priority? context,
    bool? deleted = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Rx.combineLatest2(
      Activity.watch(
        range: range,
        priorityPath: context?.path,
        depth: 0,
        deleted: deleted,
        filter: filter,
        search: search,
      ),
      Priority.watchDefault(),
      (List<Activity> allActivities, Priority defaultPriority) {
        Map<Date, ScheduledDay> days = {};

        // Group activities by date
        Map<Date, List<Activity>> activitiesByDate = {};
        Map<Date, List<Activity>> eventsByDate = {};
        for (final activity in allActivities) {
          final activityDate = activity.agendaAt.toDate();
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
          final dayActivities = activitiesByDate[date] ?? [];

          days[date] = ScheduledDay._(
            date: date,
            activities: dayActivities,
            defaultPriority: defaultPriority,
          );
        }

        return days;
      },
    );
  }

  const Schedule({
    required this.days,
    required this.previous,
    required this.next,
  });

  final Map<Date, ScheduledDay> days;
  final Date? previous;
  final Date? next;

  @override
  List<Object?> get props => [days, previous, next];
}

class ScheduledDay extends Equatable {
  static Stream<ScheduledDay> watchToday() {
    return Date.current().switchMap((today) => _watchToday(today));
  }

  static Stream<ScheduledDay> _watchToday(
    Date today, {
    Priority? context,
    bool? deleted = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Rx.combineLatest2(
      Activity.watch(
        range: today.toDateRange(),
        priorityPath: context?.path,
        depth: 0,
        deleted: deleted,
        filter: filter,
        search: search,
      ),
      Priority.watchDefault(),
      (List<Activity> allActivities, Priority defaultPriority) =>
          (allActivities, defaultPriority),
    ).transform(
      ExpiringStreamTransformer((result) {
        final allActivities = result.$1;
        final defaultPriority = result.$2;
        final now = DateTime.now();
        final currentEvent = allActivities.any(
          (a) => a.at?.includes(now) == true,
        );
        DateTime? expiry;
        if (currentEvent) {
          // Expire every minute on the minute
          expiry = now + Duration(seconds: 60 - now.second);
        } else {
          // Find the earliest event start or end following now
          expiry = allActivities.fold(
            null,
            (DateTime? next, Activity a) =>
                a.at?.start?.isAfter(now) == true &&
                    (next == null || next.isAfter(a.at!.start!))
                ? a.at!.start
                : a.at?.end?.isAfter(now) == true &&
                      (next == null || next.isAfter(a.at!.end!))
                ? a.at!.end
                : next,
          );
        }

        List<Activity> dayActivities = [];
        for (final activity in allActivities) {
          if (activity.agendaAt.toDate() == today) {
            dayActivities.add(activity);
          }
        }

        return ExpiringResult(
          value: ScheduledDay._(
            date: today,
            activities: dayActivities,
            defaultPriority: defaultPriority,
          ),
          expiry: expiry,
        );
      }),
    );
  }

  ScheduledDay._({
    required this.date,
    required List<Activity> activities,
    required Priority defaultPriority,
  }) : activities = List.unmodifiable(activities.where((a) => a.at == null)),
       events = _addGaps(
         date,
         activities.where((a) => a.at != null).toList(),
         defaultPriority,
       );

  static List<Activity> _addGaps(
    Date date,
    List<Activity> activities,
    Priority defaultPriority,
  ) {
    List<Activity> eventsWithGaps = [];
    Activity? previous;
    for (final activity in activities) {
      // Handle gap between activities
      if (activity.at!.start?.isAfter(previous?.at?.end ?? date.toStart()) ==
          true) {
        eventsWithGaps.add(
          Activity(
            type: ActivityType.event,
            priority: defaultPriority,
            at: DateTimeRange(
              previous?.at?.start ?? date.toStart(),
              activity.at!.start!,
            ),
            draft: true,
          ),
        );
      }
      eventsWithGaps.add(activity);
      previous = activity;
    }
    // Handle gap after last activity
    if (previous == null || previous.at?.end?.isBefore(date.toEnd()) != false) {
      eventsWithGaps.add(
        Activity(
          type: ActivityType.event,
          priority: defaultPriority,
          at: DateTimeRange(previous?.at?.end ?? date.toStart(), date.toEnd()),
          draft: true,
        ),
      );
    }
    return eventsWithGaps;
  }

  final Date date;
  final List<Activity> events;
  final List<Activity> activities;

  Activity getAt(DateTime time) {
    return events.firstWhere((e) => e.at?.includes(time) == true);
  }

  @override
  List<Object> get props => [date, events, activities];
}
