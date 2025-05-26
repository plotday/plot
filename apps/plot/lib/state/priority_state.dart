part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    Priority? draft,
    this.pinned = const [],
    this.scheduled = const [],
    this.moreScheduled = true,
    List<Priority> activity = const [],
    this.moreActivity = true,
  }) : draft = draft ?? Priority(parent: context, draft: true),
       activity = [
         ...activity,
         if (context.note != null && !moreActivity) context,
       ];

  final Priority context;
  final Priority draft;
  final List<Priority> pinned;
  final List<Priority> scheduled;
  final bool moreScheduled;
  final List<Priority> activity;
  final bool moreActivity;

  PriorityState copyWith({
    Priority? context,
    Priority? draft,
    List<Priority>? pinned,
    List<Priority>? scheduled,
    bool? moreScheduled,
    List<Priority>? activity,
    bool? moreActivity,
  }) {
    return PriorityState(
      context: context ?? this.context,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      scheduled: scheduled ?? this.scheduled,
      moreScheduled: moreScheduled ?? this.moreScheduled,
      activity: activity ?? this.activity,
      moreActivity: moreActivity ?? this.moreActivity,
    );
  }

  List<Priority> get priorities {
    return [...scheduled.reversed, ...activity];
  }

  @override
  List<Object?> get props => [
    context,
    draft,
    pinned,
    scheduled,
    moreScheduled,
    activity,
    moreActivity,
  ];
}
