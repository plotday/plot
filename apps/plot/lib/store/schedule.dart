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
    bool? archived = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Date.current().switchMap((today) {
      final includesCurrentDay = range.includes(today);

      final todayStream = includesCurrentDay
          ? ScheduledDay._watchToday(
              today,
              context: context,
              archived: archived,
              filter: filter,
              search: search,
            )
          : Stream.value(null);

      return Rx.combineLatest4(
        _watchRangeExcludingToday(
          range,
          today,
          context: context,
          archived: archived,
          filter: filter,
          search: search,
        ),
        todayStream,
        Activity.watchPrevious(
          range.start,
          context: context,
          archived: archived,
        ).map((activity) => activity?.agendaAt.toDate()),
        Activity.watchNext(range.end, context: context, archived: archived).map(
          (activity) {
            return activity?.agendaAt.toDate();
          },
        ),
        (rangeMap, todaySchedule, previous, next) {
          final result = Map<Date, ScheduledDay>.from(rangeMap);
          // Only include today if it has events or activities and we have a schedule
          if (todaySchedule != null &&
              (todaySchedule.scheduled.isNotEmpty ||
                  todaySchedule.unscheduled.isNotEmpty)) {
            result[today] = todaySchedule;
          }
          final sortedEntries = result.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          final days = LinkedHashMap<Date, ScheduledDay>.fromEntries(
            sortedEntries,
          );

          if (range.start != null) {
            final tightened = _tightenNextWithOccurrences(
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
            // Preserve previous if tightening returns null but we had a value
            previous = tightened ?? previous;
          }

          if (range.end != null) {
            final tightened = _tightenNextWithOccurrences(
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
            // Preserve next if tightening returns null but we had a value
            next = tightened ?? next;
          }

          return Schedule(days: days, previous: previous, next: next);
        },
      ).distinct().doOnData((schedule) {
        log.fine(
          "Range = $range, Previous = ${schedule.previous}, Next = ${schedule.next}",
        );
      });
    });
  }

  /// Tightens next/previous activity with next/previous recurrence.
  ///
  /// When reverse=true, searches backwards from range.start to find the latest previous
  /// occurrence. When reverse=false, searches forwards from range.end to find the earliest
  /// next occurrence. Stops early if the boundary is already within a week of the range edge.
  static Date? _tightenNextWithOccurrences(
    Date? next, {
    required Map<Date, ScheduledDay> days,
    required BoundedDateRange range,
    bool reverse = false,
  }) {
    for (final day in days.values) {
      for (final activity in [...day.scheduled, ...day.unscheduled]) {
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
    bool? archived = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Rx.combineLatest2(
      Activity.watch(
        range: range,
        priorityPath: context?.path,
        archived: archived,
        filter: filter,
        search: search,
      ),
      Priority.watchDefault(),
      (List<Activity> allActivities, Priority defaultPriority) {
        Map<Date, ScheduledDay> days = {};

        // Filter activities: include all events, but only non-events matching context
        final filteredActivities = allActivities.where((activity) {
          // Always include events
          if (activity.type == ActivityType.event) return true;

          // For non-events, only include if they match the context
          if (context == null) return true; // No context filter

          final activityPath = activity.priority.path;
          return activityPath == context.path ||
              activityPath.isChild(context.path);
        }).toList();

        // Group activities by date
        Map<Date, List<Activity>> activitiesByDate = {};
        for (final activity in filteredActivities) {
          final activityDate = activity.agendaAt.toDate();
          // Skip today if it's in the range - it will be handled by _watchToday
          if (activityDate == today) continue;
          // Only include activities within the range
          if (range.includes(activityDate)) {
            activitiesByDate.putIfAbsent(activityDate, () => []).add(activity);
          }
        }

        // Combine all unique dates and create ScheduledDay objects
        final allDates = activitiesByDate.keys;
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
    ).distinct();
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
    bool? archived = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Rx.combineLatest2(
      Activity.watch(
        range: today.toDateRange(),
        priorityPath: context?.path,
        archived: archived,
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
          (a) => a.type == ActivityType.event && a.at?.includes(now) == true,
        );
        DateTime? expiry;
        if (currentEvent) {
          // Expire every minute on the minute
          expiry = now + Duration(seconds: 60 - now.second);
        } else {
          // Find the earliest event start or end following now (including boundary moments)
          expiry = allActivities.fold(null, (DateTime? next, Activity a) {
            // Check event start (after now or at same moment for boundary)
            if (a.at?.start != null &&
                (a.at!.start!.isAfter(now) ||
                    a.at!.start!.isAtSameMomentAs(now)) &&
                (next == null || next.isAfter(a.at!.start!))) {
              return a.at!.start;
            }
            // Check event end (after now or at same moment for boundary)
            if (a.at?.end != null &&
                (a.at!.end!.isAfter(now) || a.at!.end!.isAtSameMomentAs(now)) &&
                (next == null || next.isAfter(a.at!.end!))) {
              return a.at!.end;
            }
            return next;
          });
        }

        List<Activity> dayActivities = [];
        for (final activity in allActivities) {
          if (activity.agendaAt.toDate() == today) {
            // Include all events, but only non-events matching context
            if (activity.type == ActivityType.event) {
              dayActivities.add(activity);
            } else if (context == null) {
              // No context filter
              dayActivities.add(activity);
            } else {
              // For non-events, only include if they match the context
              final activityPath = activity.priority.path;
              if (activityPath == context.path ||
                  activityPath.isChild(context.path)) {
                dayActivities.add(activity);
              }
            }
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

  const ScheduledDay._({
    required this.date,
    required this.activities,
    // defaultPriority parameter kept for backward compatibility but no longer used
    // since gaps are now computed in PriorityState._makeAgenda
    Priority? defaultPriority,
  });

  final Date date;
  final List<Activity> activities;

  /// Events for the day (excluding gaps).
  List<Activity> get scheduled =>
      List.unmodifiable(activities.where((a) => a.type == .event));

  /// Everything but events.
  List<Activity> get unscheduled =>
      List.unmodifiable(activities.where((a) => a.type != .event));

  Activity getAt(DateTime time) {
    return scheduled.firstWhere((e) => e.at?.includes(time) == true);
  }

  @override
  List<Object> get props => [date, scheduled, unscheduled];
}
