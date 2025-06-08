part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    Activity? draft,
    this.pinned = const [],
    this.agendaItems = const [],
    this.moreAgendaItems = true,
  }) : draft = draft ?? Activity(priorityId: context.id, draft: true);

  final Priority context;
  final Activity draft;
  final List<AgendaItem> pinned;
  final List<AgendaItem> agendaItems;
  final bool moreAgendaItems;

  PriorityState copyWith({
    Priority? context,
    Activity? draft,
    List<AgendaItem>? pinned,
    List<AgendaItem>? agendaItems,
    bool? moreAgendaItems,
  }) {
    return PriorityState(
      context: context ?? this.context,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      agendaItems: agendaItems ?? this.agendaItems,
      moreAgendaItems: moreAgendaItems ?? this.moreAgendaItems,
    );
  }

  @override
  List<Object?> get props => [
    context,
    draft,
    pinned,
    agendaItems,
    moreAgendaItems,
  ];
}
