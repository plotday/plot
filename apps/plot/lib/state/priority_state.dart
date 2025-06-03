part of 'priority.dart';

abstract class AgendaItem {
  const AgendaItem();

  T when<T>({
    required T Function(Priority) priority,
    required T Function(Event) event,
  });
}

class PriorityAgendaItem extends AgendaItem {
  final Priority priority;
  const PriorityAgendaItem(this.priority);

  @override
  T when<T>({
    required T Function(Priority) priority,
    required T Function(Event) event,
  }) {
    return priority(this.priority);
  }
}

class EventAgendaItem extends AgendaItem {
  final Event event;
  const EventAgendaItem(this.event);

  @override
  T when<T>({
    required T Function(Priority) priority,
    required T Function(Event) event,
  }) {
    return event(this.event);
  }
}

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    Priority? draft,
    this.pinned = const [],
    this.scheduled = const [],
    this.moreScheduled = true,
    List<AgendaItem> activity = const [],
    this.moreActivity = true,
  }) : draft = draft ?? Priority(parent: context, draft: true),
       activity = [
         ...activity,
         if (context.note != null && !moreActivity) PriorityAgendaItem(context),
       ];

  final Priority context;
  final Priority draft;
  final List<AgendaItem> pinned;
  final List<AgendaItem> scheduled;
  final bool moreScheduled;
  final List<AgendaItem> activity;
  final bool moreActivity;

  PriorityState copyWith({
    Priority? context,
    Priority? draft,
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
