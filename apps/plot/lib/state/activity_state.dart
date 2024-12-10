part of 'activity.dart';

final class ActivityState extends Equatable {
  static List<Note> _filterNotes(List<Note> notes,
      {bool? pinned, bool? draft, bool? doNow}) {
    return notes
        .where((note) =>
            (pinned == null || note.pinned == pinned) &&
            (draft == null || note.draft == draft) &&
            (doNow == null || note.doNow == doNow))
        .toList();
  }

  ActivityState({
    required this.week,
    this.current,
    List<Activity>? children,
  })  : children = current?.children ?? children ?? const [],
        _notes = const [],
        moreNotes = true,
        topicNotes = [Note.draft(activityId: current?.id)],
        moreTopicNotes = false,
        balances = null {
    topicId = topicNotes.first.topicId;
  }

  ActivityState._({
    required this.week,
    required this.current,
    required List<Note> notes,
    required this.topicNotes,
    required this.moreNotes,
    required this.moreTopicNotes,
    required this.topicId,
    List<Activity>? children,
    this.balances,
  })  : _notes = notes,
        children = children ?? current?.children ?? const [];

  final Activity? current;
  final List<Activity> children;

  final List<Note> _notes;
  final bool moreNotes;
  List<Note> get notes =>
      _filterNotes(_notes, pinned: false, draft: false, doNow: false);
  List<Note> get pinnedNotes =>
      _filterNotes(_notes, pinned: true, draft: false, doNow: false);
  List<Note> get doNowNotes =>
      _filterNotes(_notes, pinned: false, draft: false, doNow: true);

  late final TopicId? topicId;
  final List<Note> topicNotes;
  final bool moreTopicNotes;
  Note get topic => topicNotes.first;
  Note get draft => topicNotes.last;

  final Week week;
  final BalanceByActivityType? balances;

  ActivityState copyWith({
    Value<Activity?> current = const Value.absent(),
    List<Activity>? children,
    Week? week,
    Value<BalanceByActivityType?> balances = const Value.absent(),
    List<Note>? notes,
    bool? moreNotes,
    Value<TopicId?> topicId = const Value.absent(),
    List<Note>? topicNotes,
    bool? moreTopicNotes,
  }) {
    if (topicId.or(this.topicId) == null) {
      final newTopic = [
        if (notes != null) ...notes,
        // If changing the topic to null, look in the current notes for a draft
        if (notes == null && topicId.present) ..._notes,
      ].where((note) => note.root && note.draft).firstOrNull;
      if (newTopic != null) {
        topicId = Value(newTopic.topicId);
        topicNotes = [newTopic];
      }
    }

    notes ??= _notes;
    topicNotes ??= this.topicNotes;
    if (!topicNotes.any((note) => note.draft)) {
      topicNotes.add(
        Note.draft(
          activityId: current.or(this.current)?.id,
          parent: topicNotes.firstOrNull,
        ),
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
      topicNotes: topicNotes,
      moreTopicNotes: moreTopicNotes ?? this.moreTopicNotes,
    );
  }

  @override
  List<Object?> get props => [
        current,
        children,
        week,
        balances,
        _notes,
        moreNotes,
        topicId,
        topicNotes,
        moreTopicNotes,
      ];
}
