import 'package:plot/store/store.dart';

abstract class AgendaItem {
  const AgendaItem();

  T when<T>({
    required T Function(Activity) activity,
    required T Function(Event) event,
    required T Function(HeaderAgendaItem) header,
  });

  /// Converts a list of ScheduledDay objects into AgendaItems with appropriate headers.
  /// Returns a combined list of all agenda items in reverse chronological order.
  /// The list is ready to be reversed for display.
  static List<AgendaItem> fromScheduledDays(
    List<ScheduledDay> scheduledDays,
    Date today,
  ) {
    final agendaItems = <AgendaItem>[];

    for (final scheduledDay in scheduledDays) {
      if (scheduledDay.date < today) {
        // Add date header BEFORE items (since list will be reversed)
        if (scheduledDay.activities.isNotEmpty || scheduledDay.events.isNotEmpty) {
          agendaItems.add(HeaderAgendaItem(date: scheduledDay.date));
        }

        agendaItems.addAll(
          scheduledDay.activities.map((a) => ActivityAgendaItem(a)),
        );
        for (final event in scheduledDay.events) {
          agendaItems.add(
            HeaderAgendaItem(
              event: event,
              priorityAncestry: event.priority?.ancestors(includeSelf: true),
            ),
          );
          agendaItems.add(EventAgendaItem(event));
        }
      } else if (scheduledDay.date == today) {
        // For today, we need to handle scheduled items (doNow activities and events) first,
        // then unscheduled activities, to maintain the original ordering

        // Add scheduled items (doNow activities and events)
        final scheduledItems = <AgendaItem>[];
        bool hasScheduledItems = false;
        
        for (final activityItem in scheduledDay.activities) {
          if (activityItem.doNow) {
            scheduledItems.add(ActivityAgendaItem(activityItem));
            hasScheduledItems = true;
          }
        }
        
        for (final event in scheduledDay.events) {
          scheduledItems.add(
            HeaderAgendaItem(
              event: event,
              priorityAncestry: event.priority?.ancestors(includeSelf: true),
            ),
          );
          scheduledItems.add(EventAgendaItem(event));
          hasScheduledItems = true;
        }

        if (hasScheduledItems) {
          agendaItems.add(HeaderAgendaItem(date: scheduledDay.date));
          agendaItems.addAll(scheduledItems);
        }

        // Add unscheduled activities
        final unscheduledActivities = scheduledDay.activities.where((a) => !a.doNow).toList();
        if (unscheduledActivities.isNotEmpty) {
          if (!hasScheduledItems) {
            agendaItems.add(HeaderAgendaItem(date: scheduledDay.date));
          }
          agendaItems.addAll(
            unscheduledActivities.map((a) => ActivityAgendaItem(a)),
          );
        }
      } else {
        // Add date header BEFORE items (since list will be reversed)
        if (scheduledDay.activities.isNotEmpty || scheduledDay.events.isNotEmpty) {
          agendaItems.add(HeaderAgendaItem(date: scheduledDay.date));
        }

        agendaItems.addAll(
          scheduledDay.activities.map((a) => ActivityAgendaItem(a)),
        );
        for (final event in scheduledDay.events) {
          agendaItems.add(
            HeaderAgendaItem(
              event: event,
              priorityAncestry: event.priority?.ancestors(includeSelf: true),
            ),
          );
          agendaItems.add(EventAgendaItem(event));
        }
      }
    }

    return agendaItems;
  }
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

  const HeaderAgendaItem({
    this.event,
    this.priorityAncestry,
    this.date,
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