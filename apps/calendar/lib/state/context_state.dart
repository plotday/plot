part of 'context.dart';

final class ContextState extends Equatable {
  static List<Context> _filterChildren(List<Context> all, Context? current) {
    final children = all.where((context) => context.parent == current).toList();
    children.sort();
    return children;
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
        topic = null,
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
    this.topic,
    List<Note> topicNotes = const [],
    this.moreTopicNotes = true,
    List<Budget>? budgets,
  })  : all = contexts,
        children = _filterChildren(contexts, current),
        notes = _filterPinnedNotes(notes, false),
        pinnedNotes = _filterPinnedNotes(notes, false),
        topicNotes = _filterPinnedNotes(notes, false),
        pinnedTopicNotes = _filterPinnedNotes(notes, false),
        _budgets = budgets
            ?.asMap()
            .map((index, budget) => MapEntry(budget.context!.id!, budget));

  static List<Note> _filterPinnedNotes(List<Note> notes, bool pinned) {
    return notes.where((note) => note.order.pinned == pinned).toList();
  }

  final List<Context> all;
  final Context? current;
  final List<Context> children;

  final List<Note> notes;
  final List<Note> pinnedNotes;
  final bool moreNotes;

  final int? topic;
  final List<Note> topicNotes;
  final List<Note> pinnedTopicNotes;
  final bool moreTopicNotes;
  Note get topicNote => topicNotes.first;

  final Week week;
  final Map<int, Budget>? _budgets;
  List<Budget>? get budgets => _budgets?.values.toList();
  Budget? budgetFor(Context context) => _budgets?[context.id];

  ContextState copyWith({
    List<Context>? contexts,
    Optional<List<Budget>> budgets = const Optional.absent(),
    Optional<Context> current = const Optional.absent(),
    Week? week,
    List<Note>? notes,
    bool? moreNotes,
    Optional<int> topic = const Optional.absent(),
    List<Note>? topicNotes,
    bool? moreTopicNotes,
  }) {
    return ContextState._(
      contexts: contexts ?? all,
      budgets: budgets.or(this.budgets),
      current: current.or(this.current),
      week: week ?? this.week,
      notes: notes ?? this.notes,
      moreNotes: moreNotes ?? this.moreNotes,
      topic: topic.or(this.topic),
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
        topic,
        topicNotes,
        pinnedTopicNotes,
        moreTopicNotes,
      ];
}
