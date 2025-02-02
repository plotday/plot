part of 'priority.dart';

sealed class PriorityState extends Equatable {
  const PriorityState();
}

final class NoPriorityState extends PriorityState {
  const NoPriorityState();

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

  PrioritySelectedState({
    required this.current,
  })  : _activities = null,
        _activity = null,
        moreActivities = true,
        _activityNotes = [],
        moreActivityNotes = false;

  const PrioritySelectedState._({
    required this.current,
    required List<Activity>? activities,
    required List<Note> activityNotes,
    required this.moreActivities,
    required this.moreActivityNotes,
    required Activity? activity,
  })  : _activities = activities,
        _activity = activity,
        _activityNotes = activityNotes;

  final Priority current;
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
      Activity.draft(priorityId: current.id);

  final Activity? _activity;
  Activity get activity => _activity ?? draftActivity;
  final List<Note> _activityNotes;
  List<Note> get activityNotes =>
      _activityNotes.whereNot((note) => note.draft).toList();
  final bool moreActivityNotes;
  Note get draft => _activityNotes.reversed.where((note) => note.draft).first;

  PrioritySelectedState copyWith({
    Priority? current,
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

    return PrioritySelectedState._(
      activity: activity.or(_activity),
      activities: activities ?? _activities,
      current: current ?? this.current,
      moreActivities: moreActivities ?? this.moreActivities,
      activityNotes: activityNotes,
      moreActivityNotes: moreActivityNotes ?? this.moreActivityNotes,
    );
  }

  @override
  List<Object?> get props => [
        current,
        _activities,
        moreActivities,
        _activity,
        _activityNotes,
        moreActivityNotes,
      ];
}
