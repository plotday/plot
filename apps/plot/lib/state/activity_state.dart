part of 'activity.dart';

class ActivityState extends Equatable {
  ActivityState({
    required this.context,
    this.activity,
    this.event,
    Activity? draft,
    this.pinned = const [],
    this.activityGroups = const [],
    this.showArchived = false,
  }) : draft =
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
  final List<Activity> pinned;
  final List<ActivityDateGroup> activityGroups;
  final bool showArchived;

  ActivityState copyWith({
    Priority? context,
    Activity? activity,
    Event? event,
    Activity? draft,
    List<Activity>? pinned,
    List<ActivityDateGroup>? activityGroups,
    bool? showArchived,
  }) {
    return ActivityState(
      context: context ?? this.context,
      activity: activity ?? this.activity,
      event: event ?? this.event,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      activityGroups: activityGroups ?? this.activityGroups,
      showArchived: showArchived ?? this.showArchived,
    );
  }

  @override
  List<Object?> get props => [
    context,
    activity,
    event,
    draft,
    pinned,
    activityGroups,
    showArchived,
  ];

  @override
  String toString() {
    return 'ActivityState(context: ${context.title}, activity: ${activity?.title}, event: ${event?.name}, draft: $draft, pinned: $pinned, activityGroups: ${activityGroups.length}, showArchived: $showArchived)';
  }
}

class ActivityDateGroup extends Equatable {
  const ActivityDateGroup({
    required this.date,
    required this.activities,
  });

  final Date date;
  final List<Activity> activities;

  @override
  List<Object?> get props => [date, activities];

  @override
  String toString() {
    return 'ActivityDateGroup(date: $date, activities: ${activities.length})';
  }
}