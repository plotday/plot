part of 'priority.dart';

final class PriorityState extends Equatable {
  static List<Activity> _filterActivites(List<Activity> activities,
      {bool? pinned, bool? draft, bool? doNow}) {
    return activities
        .where((activity) =>
            (pinned == null || activity.pinned == pinned) &&
            (draft == null || activity.draft == draft) &&
            (doNow == null || activity.doNow == doNow))
        .toList();
  }

  PriorityState({
    required this.week,
    this.current,
    this.rootPriorities = const [],
  })  : priorities = _mapPriorities(rootPriorities),
        _activities = null,
        _activity = null,
        moreActivities = true,
        _activityNotes = [],
        moreActivityNotes = false,
        balances = null;

  PriorityState._({
    required this.week,
    required this.current,
    required List<Activity>? activities,
    required List<Note> activityNotes,
    required this.moreActivities,
    required this.moreActivityNotes,
    required Activity? activity,
    this.rootPriorities = const [],
    this.balances,
  })  : priorities = _mapPriorities(rootPriorities),
        _activities = activities,
        _activity = activity,
        _activityNotes = activityNotes;

  static Map<PriorityId, Priority> _mapPriorities(
      List<Priority> rootPriorities) {
    final priorities = <PriorityId, Priority>{};
    for (final priority in rootPriorities) {
      priorities[priority.id] = priority;
      for (final child in priority.children) {
        priorities[child.id] = child;
      }
    }
    return priorities;
  }

  final Priority? current;
  final List<Priority> rootPriorities;
  final Map<PriorityId, Priority> priorities;
  List<Priority> get children => current?.children ?? rootPriorities;
  List<Priority?> get recent =>
      List<Priority?>.of([null]) + priorities.values.toList();

  final List<Activity>? _activities;
  bool get loading => _activities == null;
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
      Activity.draft(priorityId: current?.id);

  final Activity? _activity;
  Activity get activity => _activity ?? draftActivity;
  final List<Note> _activityNotes;
  List<Note> get activityNotes =>
      _activityNotes.whereNot((note) => note.draft).toList();
  final bool moreActivityNotes;
  Note get draft => _activityNotes.reversed.where((note) => note.draft).first;

  final Week week;
  final BalanceByPriorityType? balances;

  PriorityState copyWith({
    Value<Priority?> current = const Value.absent(),
    List<Priority>? priorities,
    Week? week,
    Value<BalanceByPriorityType?> balances = const Value.absent(),
    List<Activity>? activities,
    bool? moreActivities,
    Value<Activity?> activity = const Value.absent(),
    List<Note>? activityNotes,
    bool? moreActivityNotes,
  }) {
    if (activity.or(_activity) == null) {
      activityNotes ??= const [];
    }
    activityNotes ??= _activityNotes;
    // If the updated activities include the current activity, update it.
    if (activities != null && !activity.present && _activity != null) {
      final currentActivity =
          activities.firstWhereOrNull((a) => a.id == _activity.id);
      if (currentActivity != null) {
        activity = Value(currentActivity);
      }
    }
    // If there is no draft note, create one.
    if (activity.or(_activity) != null &&
        !activityNotes.any((note) => note.draft)) {
      activityNotes.add(
        Note.draft(
          activityId: activity.or(_activity)!.id,
          parent: activityNotes.firstOrNull,
        ),
      );
    }

    return PriorityState._(
      activity: activity.or(_activity),
      activities: activities ?? _activities,
      balances: balances.or(this.balances),
      current: current.or(this.current),
      rootPriorities: priorities ?? rootPriorities,
      week: week ?? this.week,
      moreActivities: moreActivities ?? this.moreActivities,
      activityNotes: activityNotes,
      moreActivityNotes: moreActivityNotes ?? this.moreActivityNotes,
    );
  }

  @override
  List<Object?> get props => [
        current,
        rootPriorities,
        week,
        balances,
        _activities,
        moreActivities,
        _activity,
        _activityNotes,
        moreActivityNotes,
      ];
}
