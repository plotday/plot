part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    this.activity,
    Activity? draft,
    this.pinned = const [],
    this.agendaItems = const [],
    this.first = 0,
    this.anchorIndex = 0,
    this.moreAgendaItems = true,
    this.doneStart = false,
    this.doneEnd = false,
    this.range,
  }) : draft =
           draft ??
           Activity(priorityId: context.id, parent: activity, draft: true);

  final Priority context;
  final Activity? activity;
  final Activity draft;
  final List<AgendaItem> pinned;
  final List<AgendaItem> agendaItems;
  final int anchorIndex;
  final bool moreAgendaItems;
  final bool doneStart;
  final bool doneEnd;
  final int first;
  final DateRange? range;

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
    Activity? draft,
    List<AgendaItem>? pinned,
    List<AgendaItem>? agendaItems,
    int? first,
    int? anchorIndex,
    bool? moreAgendaItems,
    bool? doneStart,
    bool? doneEnd,
    DateRange? range,
  }) {
    return PriorityState(
      context: context ?? this.context,
      activity: activity ?? this.activity,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      agendaItems: agendaItems ?? this.agendaItems,
      anchorIndex: anchorIndex ?? this.anchorIndex,
      first: first ?? this.first,
      moreAgendaItems: moreAgendaItems ?? this.moreAgendaItems,
      doneStart: doneStart ?? this.doneStart,
      doneEnd: doneEnd ?? this.doneEnd,
      range: range ?? this.range,
    );
  }

  @override
  List<Object?> get props => [
    context,
    activity,
    draft,
    pinned,
    agendaItems,
    anchorIndex,
    moreAgendaItems,
    doneStart,
    doneEnd,
    first,
    range,
  ];
}
