import 'package:plot/store/store.dart';

class Agenda {
  final List<AgendaItem> items;
  final int anchorIndex;

  const Agenda({required this.items, required this.anchorIndex});

  /// Converts a list of ScheduledDay objects into AgendaItems with appropriate headers.
  static Agenda fromScheduledDays(
    List<ScheduledDay> scheduledDays, {
    required Date today,
    Date? anchor,
    required Map<PriorityId, Priority> priorities,
  }) {
    anchor ??= today;
    final agendaItems = <AgendaItem>[];
    int anchorIndex = 0;

    for (final scheduledDay in scheduledDays) {
      // Date header
      agendaItems.add(
        HeaderAgendaItem(
          date: scheduledDay.date,
          now: scheduledDay.date == today,
        ),
      );

      // Group activities by priority
      _addActivitiesByPriority(
        agendaItems,
        scheduledDay.activities.where((a) => !a.doNow).toList(),
        priorities,
      );

      _addActivitiesByPriority(
        agendaItems,
        scheduledDay.activities.where((a) => a.doNow).toList(),
        priorities,
      );

      // Add scheduled events with gaps
      final eventsWithGaps = _addGapsToEvents(
        scheduledDay.date,
        scheduledDay.events,
        scheduledDay.defaultPriority,
      );
      agendaItems.addAll(
        eventsWithGaps.reversed.expand(
          (e) => [
            HeaderAgendaItem(
              event: e,
              priorityAncestry: e.priority?.ancestors(includeSelf: true),
            ),
            EventAgendaItem(e),
          ],
        ),
      );

      if (scheduledDay.date <= anchor) {
        anchorIndex = agendaItems.length - 1;
      }
    }

    return Agenda(items: agendaItems, anchorIndex: anchorIndex);
  }

  /// Groups activities by priority and adds them to the agenda with priority headers
  static void _addActivitiesByPriority(
    List<AgendaItem> agendaItems,
    List<Activity> activities,
    Map<PriorityId, Priority> priorities,
  ) {
    if (activities.isEmpty) return;

    // Group activities by priority
    final priorityGroups = <Priority, List<Activity>>{};
    final activitiesWithoutPriority = <Activity>[];

    for (final activity in activities) {
      final priority = priorities[activity.priorityId];
      if (priority != null) {
        priorityGroups.putIfAbsent(priority, () => []).add(activity);
      } else {
        activitiesWithoutPriority.add(activity);
      }
    }

    // Sort priority groups by priority order
    final sortedPriorities = priorityGroups.keys.toList()..sort();

    // Add groups to agenda
    for (final priority in sortedPriorities) {
      final activitiesForPriority = priorityGroups[priority]!;

      // Sort activities within the priority group by their order
      activitiesForPriority.sort();

      // Add priority header
      agendaItems.add(
        HeaderAgendaItem(
          priorityAncestry: priority.ancestors(includeSelf: true),
        ),
      );

      // Add activities for this priority
      agendaItems.addAll(
        activitiesForPriority.map((a) => ActivityAgendaItem(a)),
      );
    }

    // Add activities without a valid priority at the end
    if (activitiesWithoutPriority.isNotEmpty) {
      activitiesWithoutPriority.sort();
      agendaItems.addAll(
        activitiesWithoutPriority.map((a) => ActivityAgendaItem(a)),
      );
    }
  }

  /// Adds gap events between scheduled events to fill the day
  static List<Event> _addGapsToEvents(
    Date date,
    List<Event> events,
    Priority defaultPriority,
  ) {
    List<Event> expanded = [];
    final start = date.toDateTime();
    final end = start.nextDay;

    for (var i = 0; i < events.length; i++) {
      expanded.add(events[i]);
      if (i + 1 < events.length && events[i].at.end < events[i + 1].at.start) {
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

abstract class AgendaItem {
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
}

class HeaderAgendaItem extends AgendaItem {
  final Event? event;
  final List<PriorityAncestor>? priorityAncestry;
  final Date? date;
  final bool now;

  const HeaderAgendaItem({
    this.event,
    this.priorityAncestry,
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
}
