part of 'activity.dart';

final class ActivityState extends Equatable {
  static List<Note> _filterPinnedNotes(List<Note> notes, bool pinned) {
    return notes.where((note) => note.order.pinned == pinned).toList();
  }

  ActivityState({
    required this.week,
    this.current,
    List<Activity>? children,
  })  : children = current?.children ?? children ?? const [],
        notes = const [],
        moreNotes = true,
        pinnedNotes = const [],
        topicId = null,
        topicNotes = const [],
        pinnedTopicNotes = const [],
        moreTopicNotes = false,
        balances = null;

  ActivityState._({
    required this.week,
    this.current,
    List<Activity>? children,
    List<Note> notes = const [],
    this.moreNotes = true,
    this.topicId,
    List<Note> topicNotes = const [],
    this.moreTopicNotes = true,
    this.balances,
  })  : children = children ?? current?.children ?? const [],
        notes = _filterPinnedNotes(notes, false),
        pinnedNotes = _filterPinnedNotes(notes, true),
        topicNotes = _filterPinnedNotes(topicNotes, false),
        pinnedTopicNotes = _filterPinnedNotes(topicNotes, true);

  final Activity? current;
  final List<Activity> children;

  final List<Note> notes;
  final List<Note> pinnedNotes;
  final bool moreNotes;

  final TopicId? topicId;
  final List<Note> topicNotes;
  final List<Note> pinnedTopicNotes;
  final bool moreTopicNotes;
  Note? get topicNote => topicNotes.firstOrNull;

  final Week week;
  final Map<ActivityId?, Balance>? balances;

  ActivityState copyWith({
    Optional<Activity> current = const Optional.absent(),
    List<Activity>? children,
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

    return ActivityState._(
      balances: balances.or(this.balances),
      current: current.or(this.current),
      children: children ?? current.orNull?.children ?? this.children,
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
