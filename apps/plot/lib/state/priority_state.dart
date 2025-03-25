part of 'priority.dart';

sealed class PriorityState extends Equatable {
  const PriorityState();

  bool get loading => false;
}

final class NoPriorityState extends PriorityState {
  const NoPriorityState();

  @override
  bool get loading => true;

  @override
  List<Object?> get props => [];
}

final class PrioritySelectedState extends PriorityState {
  static List<Activity> _filterActivites(List<Activity> activities,
      {bool? pinned, bool? draft, bool? doNow}) {
    return activities
        .where((activity) =>
            (pinned == null || activity.pinned == pinned) &&
            (draft == null || activity.draft == draft) &&
            (doNow == null || activity.doNow == doNow))
        .toList();
  }

  const PrioritySelectedState({
    required this.current,
  })  : _activities = null,
        moreActivities = true;

  const PrioritySelectedState._({
    required this.current,
    required List<Activity>? activities,
    required this.moreActivities,
  }) : _activities = activities;

  final Priority current;
  final List<Activity>? _activities;
  bool get activityLoading => _activities == null;
  final bool moreActivities;
  List<Activity> get pinnedActivities => _activities == null
      ? const []
      : _filterActivites(_activities, pinned: true, draft: false, doNow: false);
  List<Activity> get activeActivities => _activities == null
      ? const []
      : _filterActivites(_activities, pinned: false, draft: false, doNow: true);
  List<Activity> get inactiveActivities => _activities == null
      ? const []
      : _filterActivites(_activities,
          pinned: false, draft: false, doNow: false);
  Activity get draftActivity =>
      _filterActivites(_activities ?? const [], draft: true).firstOrNull ??
      Activity.draft(priorityId: current.id);

  PrioritySelectedState copyWith({
    Priority? current,
    List<Activity>? activities,
    bool? moreActivities,
  }) {
    return PrioritySelectedState._(
      activities: activities ?? _activities,
      current: current ?? this.current,
      moreActivities: moreActivities ?? this.moreActivities,
    );
  }

  @override
  List<Object?> get props => [
        current,
        _activities,
        moreActivities,
      ];
}
