part of 'priority.dart';

class PriorityState extends Equatable {
  factory PriorityState({
    required Priority context,
    Activity? activity,
    Event? event,
    Activity? draft,
    List<Activity> pinned = const [],
    Map<Date, ScheduledDay> schedule = const {},
    int first = 0,
    Date? firstDate,
    bool doneStart = false,
    bool doneEnd = false,
    DateRange? range,
    bool showArchived = false,
    List<AgendaItem>? agendaItems,
  }) {
    final agenda = agendaItems ?? _makeAgenda(schedule, context: context);
    return PriorityState._(
      context: context,
      activity: activity,
      event: event,
      draft:
          draft ??
          Activity(
            priority: context,
            parent: activity,
            parentEvent: event,
            draft: true,
          ),
      pinned: pinned,
      schedule: schedule,
      agendaItems: agenda,
      first: firstDate != null ? -_findDate(agenda, firstDate) : first,
      doneStart: doneStart,
      doneEnd: doneEnd,
      range: range,
      showArchived: showArchived,
    );
  }

  const PriorityState._({
    required this.context,
    this.activity,
    this.event,
    required this.draft,
    this.pinned = const [],
    this.schedule = const {},
    this.first = 0,
    this.doneStart = false,
    this.doneEnd = false,
    this.range,
    this.showArchived = false,
    required this.agendaItems,
  });

  final Priority context;
  final Activity? activity;
  final Event? event;
  final Activity draft;
  final List<Activity> pinned;
  final Map<Date, ScheduledDay> schedule;
  final bool doneStart;
  final bool doneEnd;
  final int first;
  final DateRange? range;
  final bool showArchived;
  final List<AgendaItem> agendaItems;

  static List<AgendaItem> _makeAgenda(
    Map<Date, ScheduledDay> schedule, {
    required Priority context,
  }) {
    final items = <AgendaItem>[];

    // Add items and return remaining activities
    List<Activity> makeBlock({
      required Event event,
      required List<Activity> activities,
    }) {
      if (!(event.draft && event.start == event.start.startOfDay)) {
        items.add(EventAgendaItem(event));
      }

      final pastEvent = !event.end.isAfter(DateTime.now());
      final (matchingActivities, remainingActivities) = activities.partition(
        (Activity a) =>
            // Priority match
            (event.priority == null ||
                event.priorityId == a.priorityId ||
                event.priority!.isParent(a.priority)) &&
            // Created or completed during this event
            (event.at.includes(a.doneAt ?? a.createdAt) ||
                // Scheduled during this event
                (!pastEvent && a.scheduled)),
      );

      final prioritzedActivities = Activity.prioritize(matchingActivities);

      List<Activity>? otherActivities;
      bool otherPriorities = false;
      for (final entry in prioritzedActivities.entries) {
        if (entry.key.id == (event.priorityId ?? context.id)) {
          otherActivities = entry.value;
          continue;
        }
        otherPriorities = true;
        items.add(PriorityAgendaItem(entry.key));
        items.addAll(entry.value.map((Activity a) => ActivityAgendaItem(a)));
      }
      if (otherActivities != null) {
        // Add the context priority last
        if (otherPriorities) {
          items.add(PriorityAgendaItem(event.priority ?? context));
        }
        items.addAll(
          otherActivities.map((Activity a) => ActivityAgendaItem(a)),
        );
      }

      // Return the remaining activities that are not included in the range
      return remainingActivities;
    }

    for (final day in schedule.values) {
      items.add(DateAgendaItem(day.date));
      var activities = day.activities;
      for (final event in day.events) {
        activities = makeBlock(event: event, activities: activities);
      }
    }
    return items;
  }

  PriorityState copyWith({
    Priority? context,
    Activity? activity,
    Event? event,
    Activity? draft,
    List<Activity>? pinned,
    Map<Date, ScheduledDay>? schedule,
    int? first,
    Date? firstDate,
    bool? doneStart,
    bool? doneEnd,
    DateRange? range,
    bool? showArchived,
    List<AgendaItem>? agendaItems,
  }) {
    return PriorityState(
      context: context ?? this.context,
      activity: activity ?? this.activity,
      event: event ?? this.event,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      schedule: schedule ?? this.schedule,
      first: first ?? this.first,
      firstDate: firstDate,
      doneStart: doneStart ?? this.doneStart,
      doneEnd: doneEnd ?? this.doneEnd,
      range: range ?? this.range,
      showArchived: showArchived ?? this.showArchived,
      agendaItems: agendaItems ?? (schedule == null ? this.agendaItems : null),
    );
  }

  @override
  List<Object?> get props => [
    context,
    activity,
    event,
    draft,
    pinned,
    schedule,
    doneStart,
    doneEnd,
    first,
    range,
    showArchived,
    agendaItems,
  ];

  @override
  String toString() {
    return 'PriorityState(context: ${context.title}, activity: ${activity?.title}, event: ${event?.name}, draft: $draft, pinned: $pinned, doneStart: $doneStart, doneEnd: $doneEnd, first: $first, range: $range, showArchived: $showArchived)';
  }

  /// Returns the index of the first DateAgendaItem on or after the given date.
  /// Returns 0 if no such DateAgendaItem is found.
  static int _findDate(List<AgendaItem> agendaItems, Date targetDate) {
    for (int i = 0; i < agendaItems.length; i++) {
      final item = agendaItems[i];
      final itemDate = item.iff<Date>(date: (date) => date);
      if (itemDate != null && itemDate >= targetDate) {
        return i;
      }
    }
    return 0;
  }
}

abstract class AgendaItem {
  T? iff<T>({
    T Function(Date)? date,
    T Function(Event)? event,
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  });

  T when<T>({
    required T Function(Date) date,
    required T Function(Event) event,
    required T Function(Priority) priority,
    required T Function(Activity) activity,
  }) =>
      iff(date: date, event: event, priority: priority, activity: activity)
          as T;
}

class DateAgendaItem extends AgendaItem {
  DateAgendaItem(this.date);

  final Date date;

  @override
  T? iff<T>({
    T Function(Date)? date,
    T Function(Event)? event,
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  }) {
    return date?.call(this.date);
  }

  @override
  String toString() => 'DateAgendaItem(date: $date)';
}

class EventAgendaItem extends AgendaItem {
  EventAgendaItem(this.event);

  final Event event;

  @override
  T? iff<T>({
    T Function(Date)? date,
    T Function(Event)? event,
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  }) {
    return event?.call(this.event);
  }

  @override
  String toString() => 'EventAgendaItem(event: ${event.name})';
}

class ActivityAgendaItem extends AgendaItem {
  ActivityAgendaItem(this.activity);

  final Activity activity;

  @override
  T? iff<T>({
    T Function(Date)? date,
    T Function(Event)? event,
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  }) {
    return activity?.call(this.activity);
  }

  @override
  String toString() => 'ActivityAgendaItem(activity: ${activity.title})';
}

class PriorityAgendaItem extends AgendaItem {
  PriorityAgendaItem(this.priority);

  final Priority priority;

  @override
  T? iff<T>({
    T Function(Date)? date,
    T Function(Event)? event,
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  }) {
    return priority?.call(this.priority);
  }

  @override
  String toString() => 'PriorityAgendaItem(priority: ${priority.title})';
}
