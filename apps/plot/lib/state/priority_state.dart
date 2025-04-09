part of 'priority.dart';

class PriorityState extends Equatable {
  static List<Activity> _filterActivites(
    List<Activity> activities, {
    bool? pinned,
    bool? draft,
    bool? doNow,
  }) {
    return activities
        .where(
          (activity) =>
              (pinned == null || activity.pinned == pinned) &&
              (draft == null || activity.draft == draft) &&
              (doNow == null || activity.doNow == doNow),
        )
        .toList();
  }

  PriorityState({
    required this.current,
    List<Activity>? activities,
    Map<PriorityId, List<Activity>>? childActivities,
    this.balances,
    this.moreActivities = true,
  }) : _activities = activities,
       _childActivities = childActivities ?? {},
       maxTime = Duration(
         minutes:
             balances?.values
                 .map(
                   (b) => b.values.fold(
                     0,
                     (a, b) =>
                         a + b.pastTime.inMinutes + b.futureTime.inMinutes,
                   ),
                 )
                 .fold<int>(0, (a, b) => max(a, b)) ??
             0,
       );

  final Priority current;
  final List<Activity>? _activities;
  final Map<PriorityId, List<Activity>> _childActivities;
  final BalanceByPriorityType? balances;
  final Duration maxTime;
  final bool moreActivities;

  bool get loading => false;
  bool get activityLoading => _activities == null;

  List<Activity> get pinnedActivities =>
      _activities == null
          ? const []
          : _filterActivites(
            _activities,
            pinned: true,
            draft: false,
            doNow: false,
          );

  List<Activity> get activeActivities =>
      _activities == null
          ? const []
          : _filterActivites(
            _activities,
            pinned: false,
            draft: false,
            doNow: true,
          );

  List<Activity> get inactiveActivities =>
      _activities == null
          ? const []
          : _filterActivites(
            _activities,
            pinned: false,
            draft: false,
            doNow: false,
          );

  Activity get draftActivity =>
      _filterActivites(_activities ?? const [], draft: true).firstOrNull ??
      Activity.draft(priorityId: current.id);

  /// Get active activities for a specific child priority, including those from its descendants
  List<Activity> getChildActiveActivities(PriorityId childId) {
    return _childActivities[childId] ?? const [];
  }

  /// Get all active activities from all children and their descendants
  Map<PriorityId, List<Activity>> get childrenActiveActivities =>
      _childActivities;

  PriorityState copyWith({
    Priority? current,
    List<Activity>? activities,
    Map<PriorityId, List<Activity>>? childActivities,
    Value<BalanceByPriorityType?> balances = const Value.absent(),
    bool? moreActivities,
  }) {
    return PriorityState(
      current: current ?? this.current,
      activities: activities ?? _activities,
      childActivities: childActivities ?? _childActivities,
      balances: balances.or(this.balances),
      moreActivities: moreActivities ?? this.moreActivities,
    );
  }

  @override
  List<Object?> get props => [
    current,
    _activities,
    _childActivities,
    balances,
    moreActivities,
  ];
}
