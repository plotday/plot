part of 'context.dart';

final class ContextState extends Equatable {
  static List<Context> _filterChildren(List<Context> all, Context? current) {
    final children = all.where((context) => context.parent == current).toList();
    children.sort();
    return children;
  }

  static List<Note> _filterPinnedNotes(List<Note> notes, bool pinned) {
    return notes.where((note) => note.order.pinned == pinned).toList();
  }

  ContextState({
    required List<Context> contexts,
    required this.week,
    this.current,
  })  : all = contexts,
        children = _filterChildren(contexts, current),
        notes = const [],
        moreNotes = true,
        pinnedNotes = const [],
        topicId = null,
        topicNotes = const [],
        pinnedTopicNotes = const [],
        moreTopicNotes = false,
        _budgets = null;

  ContextState._({
    required List<Context> contexts,
    required this.week,
    this.current,
    List<Note> notes = const [],
    this.moreNotes = true,
    this.topicId,
    List<Note> topicNotes = const [],
    this.moreTopicNotes = true,
    List<Budget>? budgets,
  })  : all = contexts,
        children = _filterChildren(contexts, current),
        notes = _filterPinnedNotes(notes, false),
        pinnedNotes = _filterPinnedNotes(notes, true),
        topicNotes = _filterPinnedNotes(notes, false),
        pinnedTopicNotes = _filterPinnedNotes(notes, true),
        _budgets = Map.fromEntries((budgets ?? const [])
            .map((budget) => MapEntry(budget.contextId, budget)));

  final List<Context> all;
  final Context? current;
  final List<Context> children;

  final List<Note> notes;
  final List<Note> pinnedNotes;
  final bool moreNotes;

  final TopicId? topicId;
  final List<Note> topicNotes;
  final List<Note> pinnedTopicNotes;
  final bool moreTopicNotes;
  Note get topicNote => topicNotes.first;

  final Week week;
  final Map<ContextId?, Budget>? _budgets;
  List<Budget>? get budgets => _budgets?.values.toList();
  Budget? budgetFor(Context context) => _budgets?[context.id];

  ContextState copyWith({
    List<Context>? contexts,
    Optional<List<Budget>> budgets = const Optional.absent(),
    Optional<Context> current = const Optional.absent(),
    Week? week,
    List<Note>? notes,
    bool? moreNotes,
    Optional<TopicId> topicId = const Optional.absent(),
    List<Note>? topicNotes,
    bool? moreTopicNotes,
    Note? newNote,
    List<Note> newNotes = const [],
  }) {
    if (newNote != null) {
      newNotes = newNotes + [newNote];
    }
    notes ??= this.notes;
    for (var note in newNotes) {
      List<Note>.from(notes).replaceSorted(
        note,
        (n1, n2) => n1.id == n2.id,
      );
    }

    return ContextState._(
      contexts: contexts ?? all,
      budgets: budgets.or(this.budgets),
      current: current.or(this.current),
      week: week ?? this.week,
      notes: notes,
      moreNotes: moreNotes ?? this.moreNotes,
      topicId: topicId.or(this.topicId),
      topicNotes: topicNotes ?? this.topicNotes,
      moreTopicNotes: moreTopicNotes ?? this.moreTopicNotes,
    );
  }

  @override
  List<Object?> get props => [
        all,
        current,
        children,
        week,
        _budgets,
        notes,
        moreNotes,
        pinnedNotes,
        topicId,
        topicNotes,
        pinnedTopicNotes,
        moreTopicNotes,
      ];
}
