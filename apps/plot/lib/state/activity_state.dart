// part of 'priority.dart';
//
// sealed class PriorityState extends Equatable {
//   const PriorityState();
//
//   bool get loading => false;
// }
//
// final class NoPriorityState extends PriorityState {
//   const NoPriorityState();
//
//   @override
//   bool get loading => true;
//
//   @override
//   List<Object?> get props => [];
// }
//
// final class PrioritySelectedState extends PriorityState {
//   PrioritySelectedState({
//     required this.current,
//   })  : _notes = [],
//         moreNotes = false;
//
//   const PrioritySelectedState._({
//     required this.current,
//     required List<Note> notes,
//     required this.moreNotes,
//   }) : _notes = notes;
//
//   final Priority current;
//   final List<Note> _notes;
//   List<Note> get pinnedNotes =>
//       _notes.where((note) => note.pinned && !note.draft).toList();
//   List<Note> get notes =>
//       _notes.where((note) => !note.pinned && !note.draft).toList();
//   final bool moreNotes;
//   Note get draft =>
//       _notes.reversed.where((note) => note.draft).firstOrNull ??
//       Note.draft(priorityId: current.id, parent: _notes.firstOrNull);
//
//   PrioritySelectedState copyWith({
//     Priority? current,
//     List<Note>? notes,
//     bool? moreNotes,
//   }) {
//     notes ??= _notes;
//
//     // If there is no draft note, create one.
//     if (!notes.any((note) => note.draft)) {
//       notes.add(
//         Note.draft(
//           priorityId: current?.id ?? this.current.id,
//           parent: notes.firstOrNull,
//         ),
//       );
//     }
//
//     return PrioritySelectedState._(
//       current: current ?? this.current,
//       notes: notes,
//       moreNotes: moreNotes ?? this.moreNotes,
//     );
//   }
//
//   @override
//   List<Object?> get props => [
//         current,
//         _notes,
//         moreNotes,
//       ];
// }
