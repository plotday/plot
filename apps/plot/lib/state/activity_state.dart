part of 'activity.dart';

sealed class ActivityState extends Equatable {
  const ActivityState();

  bool get loading => false;
}

final class NoActivityState extends ActivityState {
  const NoActivityState();

  @override
  bool get loading => true;

  @override
  List<Object?> get props => [];
}

final class ActivitySelectedState extends ActivityState {
  ActivitySelectedState({
    required this.current,
  })  : _notes = [],
        moreNotes = false;

  const ActivitySelectedState._({
    required this.current,
    required List<Note> notes,
    required this.moreNotes,
  }) : _notes = notes;

  final Activity current;
  final List<Note> _notes;
  List<Note> get pinnedNotes =>
      _notes.where((note) => note.pinned && !note.draft).toList();
  List<Note> get notes =>
      _notes.where((note) => !note.pinned && !note.draft).toList();
  final bool moreNotes;
  Note get draft =>
      _notes.reversed.where((note) => note.draft).firstOrNull ??
      Note.draft(activityId: current.id, parent: _notes.firstOrNull);

  ActivitySelectedState copyWith({
    Activity? current,
    List<Note>? notes,
    bool? moreNotes,
  }) {
    notes ??= _notes;

    // If there is no draft note, create one.
    if (!notes.any((note) => note.draft)) {
      notes.add(
        Note.draft(
          activityId: current?.id ?? this.current.id,
          parent: notes.firstOrNull,
        ),
      );
    }

    return ActivitySelectedState._(
      current: current ?? this.current,
      notes: notes,
      moreNotes: moreNotes ?? this.moreNotes,
    );
  }

  @override
  List<Object?> get props => [
        current,
        _notes,
        moreNotes,
      ];
}
