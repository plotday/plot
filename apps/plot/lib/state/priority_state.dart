part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    this.activity,
    this.event,
    Activity? draft,
    this.pinned = const [],
    this.agendaItems = const [],
    this.first = 0,
    this.moreAgendaItems = true,
    this.doneStart = false,
    this.doneEnd = false,
    this.range,
    this.showArchived = false,
  }) : draft =
           draft ??
           Activity(
             priorityId: context.id,
             parent: activity,
             parentEvent: event,
             draft: true,
           );

  final Priority context;
  final Activity? activity;
  final Event? event;
  final Activity draft;
  final List<AgendaItem> pinned;
  final List<AgendaItem> agendaItems;
  final bool moreAgendaItems;
  final bool doneStart;
  final bool doneEnd;
  final int first;
  final DateRange? range;
  final bool showArchived;

  AgendaItem? atIndex(int index) {
    index += first;
    if (index < 0 || index >= agendaItems.length) {
      return null;
    }
    return agendaItems[index];
  }

  PriorityState copyWith({
    Priority? context,
    Activity? activity,
    Event? event,
    Activity? draft,
    List<AgendaItem>? pinned,
    List<AgendaItem>? agendaItems,
    int? first,
    bool? moreAgendaItems,
    bool? doneStart,
    bool? doneEnd,
    DateRange? range,
    bool? showArchived,
  }) {
    return PriorityState(
      context: context ?? this.context,
      activity: activity ?? this.activity,
      event: event ?? this.event,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      agendaItems: agendaItems ?? this.agendaItems,
      first: first ?? this.first,
      moreAgendaItems: moreAgendaItems ?? this.moreAgendaItems,
      doneStart: doneStart ?? this.doneStart,
      doneEnd: doneEnd ?? this.doneEnd,
      range: range ?? this.range,
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
    agendaItems,
    moreAgendaItems,
    doneStart,
    doneEnd,
    first,
    range,
    showArchived,
  ];
}
