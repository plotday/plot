import 'package:plot/store/store.dart';

class Agenda {
  final List<AgendaItem> items;
  final int anchorIndex;

  const Agenda({required this.items, required this.anchorIndex});

  /// Converts a list of ScheduledDay objects into AgendaItems with appropriate headers.
  /// Returns a combined list of all agenda items in reverse chronological order.
  /// The list is ready to be reversed for display.
  static Agenda fromScheduledDays(
    List<ScheduledDay> scheduledDays, {
    required Date today,
    Date? anchor,
  }) {
    anchor ??= today;
    final agendaItems = <AgendaItem>[];
    int anchorIndex = -1;

    for (final scheduledDay in scheduledDays) {
      // Date header
      if (scheduledDay.date == anchor) {
        anchorIndex = agendaItems.length;
      }
      agendaItems.add(
        HeaderAgendaItem(
          date: scheduledDay.date,
          now: scheduledDay.date == today,
        ),
      );

      if (scheduledDay.date < today) {
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
          agendaItems.addAll(scheduledItems);
        }

        // Add unscheduled activities
        final unscheduledActivities =
            scheduledDay.activities.where((a) => !a.doNow).toList();
        if (unscheduledActivities.isNotEmpty) {
          agendaItems.addAll(
            unscheduledActivities.map((a) => ActivityAgendaItem(a)),
          );
        }
      } else {
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

    return Agenda(items: agendaItems, anchorIndex: anchorIndex);
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
