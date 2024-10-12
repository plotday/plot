part of 'context.dart';

final class ContextState extends Equatable {
  static List<Note> _filterPinnedNotes(List<Note> notes, bool pinned) {
    return notes.where((note) => note.order.pinned == pinned).toList();
  }

  ContextState({
    required this.week,
    this.current,
    List<Context>? children,
  })  : children = current?.children ?? children ?? const [],
        notes = const [],
        moreNotes = true,
        pinnedNotes = const [],
        topicId = null,
        topicNotes = const [],
        pinnedTopicNotes = const [],
        moreTopicNotes = false,
        balances = null;

  ContextState._({
    required this.week,
    this.current,
    List<Context>? children,
    List<Note> notes = const [],
    this.moreNotes = true,
    this.topicId,
    List<Note> topicNotes = const [],
    this.moreTopicNotes = true,
    this.balances,
  })  : children = current?.children ?? children ?? const [],
        notes = _filterPinnedNotes(notes, false),
        pinnedNotes = _filterPinnedNotes(notes, true),
        topicNotes = _filterPinnedNotes(notes, false),
        pinnedTopicNotes = _filterPinnedNotes(notes, true);

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
  final Map<ContextId?, Balance>? balances;

  ContextState copyWith({
    Optional<Context> current = const Optional.absent(),
    List<Context>? children,
    Week? week,
    Optional<Map<Uuid?, Balance>> balances = const Optional.absent(),
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
      balances: balances.or(this.balances),
      current: current.or(this.current),
      children: current.or(this.current)?.children ?? children ?? const [],
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
        current,
        children,
        week,
        balances,
        notes,
        moreNotes,
        pinnedNotes,
        topicId,
        topicNotes,
        pinnedTopicNotes,
        moreTopicNotes,
      ];
}
