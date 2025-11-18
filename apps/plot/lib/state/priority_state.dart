part of 'priority.dart';

@immutable
class PriorityState extends Equatable {
  factory PriorityState({
    required Priority context,
    Activity? activity,
    Activity? draft,
    Map<Date, ScheduledDay> schedule = const {},
    int first = 0,
    Date? firstDate,
    BoundedDateRange? range,
    Date? previous,
    Date? next,
    bool showArchived = false,
    List<AgendaItem>? agendaItems,
    List<Tag> filter = const [],
    String search = '',
    List<PriorityTwist> twists = const [],
  }) {
    final agenda = agendaItems ?? _makeAgenda(schedule, context: context);

    // Calculate range from agenda items if not provided
    BoundedDateRange? calculatedRange = range;
    if (calculatedRange == null && agenda.isNotEmpty) {
      final dates = agenda
          .map((item) => item.iff<Date>(date: (date) => date))
          .where((date) => date != null)
          .cast<Date>()
          .toList();

      if (dates.isNotEmpty) {
        dates.sort();
        calculatedRange = CustomBoundedDateRange(
          dates.first,
          dates.last.addDays(1),
        );
      }
    }

    return PriorityState._(
      context: context,
      activity: activity,
      draft:
          draft ?? Activity(priority: context, parent: activity, draft: true),
      schedule: schedule.isNotEmpty ? Map.unmodifiable(schedule) : schedule,
      agendaItems: agenda.isNotEmpty ? List.unmodifiable(agenda) : agenda,
      first: firstDate != null ? -_findDate(agenda, firstDate) : first,
      range: calculatedRange,
      next: next,
      previous: previous,
      showArchived: showArchived,
      filter: filter.isNotEmpty ? List.unmodifiable(filter) : filter,
      search: search,
      twists: twists.isNotEmpty ? List.unmodifiable(twists) : twists,
    );
  }

  const PriorityState._({
    required this.context,
    this.activity,
    required this.draft,
    required this.range,
    required this.previous,
    required this.next,
    required this.agendaItems,
    this.schedule = const {},
    this.first = 0,
    this.showArchived = false,
    this.filter = const [],
    this.search = '',
    this.twists = const [],
  });

  final Priority context;
  final Activity? activity;
  final Activity draft;
  final Map<Date, ScheduledDay> schedule;
  final int first;
  final BoundedDateRange? range;
  final Date? previous;
  final Date? next;
  final bool showArchived;
  final List<AgendaItem> agendaItems;
  final List<Tag> filter;
  final String search;
  final List<PriorityTwist> twists;

  bool get doneStart => range != null && previous == null;
  bool get doneEnd => range != null && next == null;

  static List<AgendaItem> _makeAgenda(
    Map<Date, ScheduledDay> schedule, {
    required Priority context,
  }) {
    final items = <AgendaItem>[];

    // Add items and return remaining activities
    List<Activity> makeBlock({
      required Activity activity,
      required List<Activity> activities,
    }) {
      if (!(activity.draft &&
          activity.at?.start == activity.at?.start?.startOfDay)) {
        items.add(ActivityAgendaItem(activity));
      }

      final pastEvent = activity.at?.end?.isAfter(DateTime.now()) == false;
      final (matchingActivities, remainingActivities) = activities.partition(
        (Activity a) =>
            // Priority match
            (activity.priority.id == a.priority.id ||
                activity.priority.isParent(a.priority)) &&
            // Created or completed during this event
            (activity.at?.includes(a.doneAt ?? a.createdAt) == true ||
                // Scheduled during this event
                (!pastEvent && a.todo)),
      );

      final prioritzedActivities = Activity.prioritize(matchingActivities);

      List<Activity>? otherActivities;
      bool otherPriorities = false;
      for (final entry in prioritzedActivities.entries) {
        if (entry.key.id == (activity.priority.id ?? context.id)) {
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
          items.add(PriorityAgendaItem(activity.priority));
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
        activities = makeBlock(activity: event, activities: activities);
      }
    }
    return items;
  }

  PriorityState copyWith({
    Priority? context,
    Value<Activity?> activity = const Value.absent(),
    Activity? draft,
    Map<Date, ScheduledDay>? schedule,
    int? first,
    Date? firstDate,
    BoundedDateRange? range,
    Value<Date?> previous = const Value.absent(),
    Value<Date?> next = const Value.absent(),
    bool? showArchived,
    List<AgendaItem>? agendaItems,
    List<Tag>? filter,
    String? search,
    List<PriorityTwist>? twists,
  }) {
    return PriorityState(
      context: context ?? this.context,
      activity: activity.or(this.activity),
      draft: draft ?? this.draft,
      schedule: schedule != null
          ? (schedule.isNotEmpty ? Map.unmodifiable(schedule) : schedule)
          : this.schedule,
      first: first ?? this.first,
      firstDate: firstDate,
      range: range ?? this.range,
      next: next.or(this.next),
      previous: previous.or(this.previous),
      showArchived: showArchived ?? this.showArchived,
      agendaItems: agendaItems != null
          ? (agendaItems.isNotEmpty
                ? List.unmodifiable(agendaItems)
                : agendaItems)
          : (schedule == null ? this.agendaItems : null),
      filter: filter != null
          ? (filter.isNotEmpty ? List.unmodifiable(filter) : filter)
          : this.filter,
      search: search ?? this.search,
      twists: twists != null
          ? (twists.isNotEmpty ? List.unmodifiable(twists) : twists)
          : this.twists,
    );
  }

  @override
  List<Object?> get props => [
    context,
    activity,
    draft,
    schedule,
    first,
    range,
    doneStart,
    doneEnd,
    showArchived,
    agendaItems,
    filter,
    search,
    twists,
  ];

  @override
  String toString() {
    return 'PriorityState(context: ${context.title}, activity: ${activity?.title}, draft: $draft, first: $first, range: $range, showArchived: $showArchived, filter: $filter, search: $search, twists: ${twists.length})';
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
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  });

  T when<T>({
    required T Function(Date) date,
    required T Function(Priority) priority,
    required T Function(Activity) activity,
  }) => iff(date: date, priority: priority, activity: activity) as T;
}

class DateAgendaItem extends AgendaItem {
  DateAgendaItem(this.date);

  final Date date;

  @override
  T? iff<T>({
    T Function(Date)? date,
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  }) {
    return date?.call(this.date);
  }

  @override
  String toString() => 'DateAgendaItem(date: $date)';
}

class ActivityAgendaItem extends AgendaItem {
  ActivityAgendaItem(this.activity);

  final Activity activity;

  @override
  T? iff<T>({
    T Function(Date)? date,
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
    T Function(Priority)? priority,
    T Function(Activity)? activity,
  }) {
    return priority?.call(this.priority);
  }

  @override
  String toString() => 'PriorityAgendaItem(priority: ${priority.title})';
}
