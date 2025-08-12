part of 'activity.dart';

@immutable
class ActivityState extends Equatable {
  ActivityState({
    required this.context,
    this.activity,
    this.event,
    Activity? draft,
    List<ActivityDateGroup> activityGroups = const [],
    this.showArchived = false,
    List<Tag> filter = const [],
  }) : activityGroups = activityGroups.isNotEmpty ? List.unmodifiable(activityGroups) : activityGroups,
       filter = filter.isNotEmpty ? List.unmodifiable(filter) : filter,
       draft =
           draft ??
           Activity(
             priority: context,
             parent: activity,
             parentEvent: event,
             draft: true,
           );

  final Priority context;
  final Activity? activity;
  final Event? event;
  final Activity draft;
  final List<ActivityDateGroup> activityGroups;
  final bool showArchived;
  final List<Tag> filter;

  ActivityState copyWith({
    Priority? context,
    Activity? activity,
    Event? event,
    Activity? draft,
    List<ActivityDateGroup>? activityGroups,
    bool? showArchived,
    List<Tag>? filter,
  }) {
    return ActivityState(
      context: context ?? this.context,
      activity: activity ?? this.activity,
      event: event ?? this.event,
      draft: draft ?? this.draft,
      activityGroups: activityGroups != null ? (activityGroups.isNotEmpty ? List.unmodifiable(activityGroups) : activityGroups) : this.activityGroups,
      showArchived: showArchived ?? this.showArchived,
      filter: filter != null ? (filter.isNotEmpty ? List.unmodifiable(filter) : filter) : this.filter,
    );
  }

  @override
  List<Object?> get props => [
    context,
    activity,
    event,
    draft,
    activityGroups,
    showArchived,
    filter,
  ];

  @override
  String toString() {
    return 'ActivityState(context: ${context.title}, activity: ${activity?.title}, event: ${event?.name}, draft: $draft, activityGroups: ${activityGroups.length}, showArchived: $showArchived, filter: $filter)';
  }
}

class ActivityDateGroup extends Equatable {
  ActivityDateGroup({
    required this.date,
    required List<Activity> activities,
  }) : activities = activities.isNotEmpty ? List.unmodifiable(activities) : activities;

  final Date date;
  final List<Activity> activities;

  @override
  List<Object?> get props => [date, activities];

  @override
  String toString() {
    return 'ActivityDateGroup(date: $date, activities: ${activities.length})';
  }
}