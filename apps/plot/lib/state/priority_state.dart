part of 'priority.dart';

abstract class AgendaItem {
  const AgendaItem();

  T when<T>({
    required T Function(Activity) activity,
    required T Function(Event) event,
  });
}

class ActivityAgendaItem extends AgendaItem {
  final Activity activity;
  const ActivityAgendaItem(this.activity);

  @override
  T when<T>({
    required T Function(Activity) activity,
    required T Function(Event) event,
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
  }) {
    return event(this.event);
  }
}

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    Activity? draft,
    this.pinned = const [],
    this.scheduled = const [],
    this.moreScheduled = true,
    this.activity = const [],
    this.moreActivity = true,
  }) : draft = draft ?? Activity(priorityId: context.id, draft: true);

  final Priority context;
  final Activity draft;
  final List<AgendaItem> pinned;
  final List<AgendaItem> scheduled;
  final bool moreScheduled;
  final List<AgendaItem> activity;
  final bool moreActivity;

  PriorityState copyWith({
    Priority? context,
    Activity? draft,
    List<AgendaItem>? pinned,
    List<AgendaItem>? scheduled,
    bool? moreScheduled,
    List<AgendaItem>? activity,
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

  List<AgendaItem> get agendaItems {
    return [...scheduled, ...activity];
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
