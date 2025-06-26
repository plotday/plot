import 'package:equatable/equatable.dart';
import 'package:plot/store/store.dart';

class Agenda extends Equatable {
  final List<AgendaItem> items;
  final int anchorIndex;
  final int nowIndex;

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
  /// 1. Activities appear in the past based on their doneAt time (if set) or createdAt time, except on the current day if doAt is the current day.
  /// 2. Activities with doAt set appear on that day as well as their doneAt/createdAt day.
  /// 3. Use doNow to see if an event should be included in the current day. (This includes events with previous doAt that are not yet done.)
  /// 4. Events show at their scheduled time, preceded by a HeaderAgendaItem with the event's priority and date.
  /// 5. On current/future days, Activities with eventSeries equal to an event's series are shown below the event (with no intervening header).
  /// 6. When there's a time gap between events, add a HeaderAgendaItem for it (but not an event), with priority set to the default priority.
  /// 7. On the current day, activities with doAt always appear after the now header, under the first header for which their priority matches or is a child.
  /// 8. On future days, Activities with doAt set but without eventSeries are shown before the first (if any) event.
  /// 9. All doNow/doAt activities are grouped and ordered by priority.order and preceeded by a HeaderAgendaItem.
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
    int anchorIndex = 0;
    int nowIndex = 0;

    // Add to agendaItems and return remaining activities
    List<Activity> buildBlock({
      required List<Activity> activities,
      required DateTimeRange at,
      Event? event,
    }) {
      if (at.includes(DateTime.now())) {
        nowIndex = agendaItems.length;
      }
      if (event != null) {
        agendaItems.add(
          HeaderAgendaItem(event: event, priority: event.priority),
        );
        if (event.name != null) {
          agendaItems.add(EventAgendaItem(event));
        }
      }

      var pastActivities = <Activity>[];
      var scheduledActivities = <Activity>[];
      // Filter activities to include only those doneAt/createdAt within the range (unless also doAt for the same day)
      final remainingActivities = <Activity>[];
      for (final activity in activities) {
        if (at.end.isAfter(DateTime.now()) && activity.scheduled) {
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
          final activityPriority = priorities[activity.priorityId];
          priorityGroups.putIfAbsent(activityPriority, () => []).add(activity);
        }

        // Sort priority groups
        final sortedPriorities =
            priorityGroups.keys
                .where((p) => p != null)
                .cast<Priority>()
                .toList()
              ..sort();
        final activitiesWithoutPriority = priorityGroups[null] ?? [];

        // Add priority headers and activities
        for (final priority in sortedPriorities) {
          final activitiesForPriority = priorityGroups[priority]!;

          // Skip adding HeaderAgendaItem if this is the only priority and it equals contextPriority
          if (priorityGroups.length > 1 || priority != context) {
            print(
              'Adding header for priority: ${priority.title} because ${priorityGroups.length} groups found or priority is not ${context?.title}',
            );
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

      // Iterate through each time block in the day
      Event? previous;
      var items = <AgendaItem>[];
      for (int i = 0; i < scheduledDay.events.length; i++) {
        var current = scheduledDay.events[i];

        // Handle gap between events
        if (current.start.isAfter(
          previous?.end ?? scheduledDay.date.toStart(),
        )) {
          activities = buildBlock(
            activities: activities,
            at: DateTimeRange(
              previous?.end ?? scheduledDay.date.toStart(),
              current.start,
            ),
            event: null,
          );
        }

        // Current event block
        activities = buildBlock(
          activities: activities,
          at: current.at,
          event: current,
        );
        agendaItems.addAll(items);

        previous = current;
      }
      // Handle gap after last event
      if (previous == null ||
          previous.end.isBefore(scheduledDay.date.toEnd())) {
        activities = buildBlock(
          activities: activities,
          at: DateTimeRange(
            previous?.end ?? scheduledDay.date.toStart(),
            scheduledDay.date.toEnd(),
          ),
          event: null,
        );
      }

      if (anchor == scheduledDay.date) {
        anchorIndex = agendaItems.length - 1;
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
    required T Function(Event) event,
    required T Function(HeaderAgendaItem) header,
  });
}

class ActivityAgendaItem extends AgendaItem {
  final Activity activity;
  const ActivityAgendaItem(this.activity);

  @override
  T when<T>({
    required T Function(Activity) activity,
    required T Function(Event) event,
    required T Function(HeaderAgendaItem) header,
  }) {
    return activity(this.activity);
  }

  @override
  List<Object?> get props => [activity];
}

class EventAgendaItem extends AgendaItem {
  final Event event;
  const EventAgendaItem(this.event);

  @override
  T when<T>({
    required T Function(Activity) activity,
    required T Function(Event) event,
    required T Function(HeaderAgendaItem) header,
  }) {
    return event(this.event);
  }

  @override
  List<Object?> get props => [event];
}

class HeaderAgendaItem extends AgendaItem {
  final Event? event;
  final Priority? priority;
  final Date? date;
  final bool now;

  const HeaderAgendaItem({
    this.event,
    this.priority,
    this.date,
    this.now = false,
  });

  @override
  T when<T>({
    required T Function(Activity) activity,
    required T Function(Event) event,
    required T Function(HeaderAgendaItem) header,
  }) {
    return header(this);
  }

  @override
  List<Object?> get props => [event, priority, date, now];
}
