import 'package:equatable/equatable.dart';
import 'package:plot/store/store.dart';

class Agenda extends Equatable {
  final List<AgendaItem> items;
  final int? anchorIndex;
  final int? nowIndex;

  const Agenda({
    required this.items,
    required this.anchorIndex,
    required this.nowIndex,
  });

  @override
  List<Object?> get props => [items, anchorIndex, nowIndex];

  /// Converts a list of ScheduledDay objects into AgendaItems with appropriate headers.
  ///
  /// Each day has the following structure:
  /// 1. Activities appear in the past based on their doneAt time (if set) or createdAt time, except on the current day if doOn is the current day.
  /// 2. Activities with doOn set appear on that day as well as their doneAt/createdAt day.
  /// 3. Use doNow to see if an event should be included in the current day. (This includes events with previous doOn that are not yet done.)
  /// 4. Events show at their scheduled time, preceded by a HeaderAgendaItem with the event's priority and date.
  /// 5. On current/future days, Activities with eventSeries equal to an event's series are shown below the event (with no intervening header).
  /// 6. When there's a time gap between events, add a HeaderAgendaItem for it (but not an event), with priority set to the default priority.
  /// 7. On the current day, activities with doOn always appear after the now header, under the first header for which their priority matches or is a child.
  /// 8. On future days, Activities with doOn set but without eventSeries are shown before the first (if any) event.
  /// 9. All doNow/doOn activities are grouped and ordered by priority path and preceeded by a HeaderAgendaItem.
  ///
  /// nowIndex is the index of the current HeaderAgendaItem, either for a current event or gap between events, or the first priority if before/after all events.
  /// anchorIndex is the index of HeaderAgendaItem for the anchor date, which is today by default.
  static Agenda fromScheduledDays(
    List<ScheduledDay> scheduledDays, {
    required Date today,
    Date? anchor,
    required Map<PriorityId, Priority> priorities,
    Priority? context,
  }) {
    anchor ??= today;
    final agendaItems = <AgendaItem>[];
    int? anchorIndex;
    int? nowIndex;

    // Add to agendaItems and return remaining activities
    List<Activity> buildBlock({
      required List<Activity> activities,
      required DateTimeRange at,
      Activity? activity,
    }) {
      if (at.includes(DateTime.now())) {
        nowIndex = agendaItems.length;
      }
      if (activity != null) {
        agendaItems.add(
          HeaderAgendaItem(activity: activity, priority: activity.priority),
        );
      }

      var pastActivities = <Activity>[];
      var scheduledActivities = <Activity>[];
      // Filter activities to include only those doneAt/createdAt within the range (unless also doAt for the same day)
      final remainingActivities = <Activity>[];
      for (final activity in activities) {
        if (at.end?.isAfter(DateTime.now()) == true && activity.todo) {
          scheduledActivities.add(activity);
        } else if (at.includes(activity.doneAt ?? activity.createdAt)) {
          pastActivities.add(activity);
        } else {
          remainingActivities.add(activity);
        }
      }
      scheduledActivities.sort((a, b) => a.order.compareTo(b.order));
      final activitiesInRange = [...pastActivities, ...scheduledActivities];

      // Create ActivityAgendaItem for each activity in the range
      if (activitiesInRange.isNotEmpty) {
        // Group activities by priority and add headers
        final priorityGroups = <Priority?, List<Activity>>{};
        for (final activity in activitiesInRange) {
          priorityGroups.putIfAbsent(activity.priority, () => []).add(activity);
        }

        // Sort priority groups with context priority last
        final sortedPriorities =
            priorityGroups.keys
                .where((p) => p != null)
                .cast<Priority>()
                .toList()
              ..sort((a, b) {
                // If one is the context priority, it comes last
                if (a == context) return 1;
                if (b == context) return -1;
                // Otherwise, sort normally
                return a.compareTo(b);
              });
        final activitiesWithoutPriority = priorityGroups[null] ?? [];

        // Add priority headers and activities
        for (final priority in sortedPriorities) {
          final activitiesForPriority = priorityGroups[priority]!;

          // Skip adding HeaderAgendaItem if this is the only priority and it equals contextPriority
          if (priorityGroups.length > 1 || priority != context) {
            agendaItems.add(HeaderAgendaItem(priority: priority));
          }

          agendaItems.addAll(
            activitiesForPriority.map((a) => ActivityAgendaItem(a)),
          );
        }

        // Add activities without priority at the end
        if (activitiesWithoutPriority.isNotEmpty) {
          agendaItems.addAll(
            activitiesWithoutPriority.map((a) => ActivityAgendaItem(a)),
          );
        }
      }

      // Return the remaining activities that are not included in the range
      return remainingActivities;
    }

    for (final scheduledDay in scheduledDays) {
      var activities = scheduledDay.activities;
      final isToday = scheduledDay.date == today;

      // Date header
      agendaItems.add(HeaderAgendaItem(date: scheduledDay.date, now: isToday));
      if (anchor == scheduledDay.date) {
        anchorIndex = agendaItems.length - 1;
      }

      // Iterate through each time block in the day
      Activity? previous;
      var items = <AgendaItem>[];
      for (int i = 0; i < scheduledDay.events.length; i++) {
        var current = scheduledDay.events[i];

        // Handle gap between events
        final previousEnd = previous?.at?.end ?? scheduledDay.date.toStart();
        if (current.at?.start?.isAfter(previousEnd) == true) {
          activities = buildBlock(
            activities: activities,
            at: DateTimeRange(previousEnd, current.at!.start),
            activity: null,
          );
        }

        // Current event block
        if (current.at != null) {
          activities = buildBlock(
            activities: activities,
            at: current.at!,
            activity: current,
          );
        }
        agendaItems.addAll(items);

        previous = current;
      }
      // Handle gap after last event
      if (previous == null ||
          previous.at?.end?.isBefore(scheduledDay.date.toEnd()) == true) {
        activities = buildBlock(
          activities: activities,
          at: DateTimeRange(
            previous?.at?.end ?? scheduledDay.date.toStart(),
            scheduledDay.date.toEnd(),
          ),
          activity: null,
        );
      }
    }

    return Agenda(
      items: agendaItems,
      anchorIndex: anchorIndex,
      nowIndex: nowIndex,
    );
  }
}

abstract class AgendaItem extends Equatable {
  const AgendaItem();

  T when<T>({
    required T Function(Activity) activity,
    required T Function(HeaderAgendaItem) header,
  });
}

class ActivityAgendaItem extends AgendaItem {
  final Activity activity;
  const ActivityAgendaItem(this.activity);

  @override
  T when<T>({
    required T Function(Activity) activity,
    required T Function(HeaderAgendaItem) header,
  }) {
    return activity(this.activity);
  }

  @override
  List<Object?> get props => [activity];
}

class HeaderAgendaItem extends AgendaItem {
  final Activity? activity;
  final Priority? priority;
  final Date? date;
  final bool now;

  const HeaderAgendaItem({
    this.activity,
    this.priority,
    this.date,
    this.now = false,
  });

  @override
  T when<T>({
    required T Function(Activity) activity,
    required T Function(HeaderAgendaItem) header,
  }) {
    return header(this);
  }

  @override
  List<Object?> get props => [activity, priority, date, now];
}
