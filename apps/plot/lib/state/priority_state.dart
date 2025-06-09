part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    Activity? draft,
    this.pinned = const [],
    this.agendaItems = const [],
    this.anchorIndex = 0,
    this.moreAgendaItems = true,
  }) : draft = draft ?? Activity(priorityId: context.id, draft: true);

  final Priority context;
  final Activity draft;
  final List<AgendaItem> pinned;
  final List<AgendaItem> agendaItems;
  final int anchorIndex;
  final bool moreAgendaItems;

  PriorityState copyWith({
    Priority? context,
    Activity? draft,
    List<AgendaItem>? pinned,
    List<AgendaItem>? agendaItems,
    int? anchorIndex,
    bool? moreAgendaItems,
  }) {
    return PriorityState(
      context: context ?? this.context,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      agendaItems: agendaItems ?? this.agendaItems,
      anchorIndex: anchorIndex ?? this.anchorIndex,
      moreAgendaItems: moreAgendaItems ?? this.moreAgendaItems,
    );
  }

  @override
  List<Object?> get props => [
    context,
    draft,
    pinned,
    agendaItems,
    anchorIndex,
    moreAgendaItems,
  ];
}
