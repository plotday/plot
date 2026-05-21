import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

class NoteViewerState extends Equatable {
  const NoteViewerState({this.note});

  final Note? note;

  @override
  List<Object?> get props => [note?.id, note?.updatedAt];
}

/// Holds the note currently being read in the full-screen / panel-overlay
/// reading view. Lives at the app-shell level so the overlay can be mounted
/// above the panel layout while NoteWidget (inside the thread panel) can
/// trigger it.
class NoteViewerBloc extends Cubit<NoteViewerState> {
  NoteViewerBloc() : super(const NoteViewerState());

  void view(Note note) => emit(NoteViewerState(note: note));

  void dismiss() => emit(const NoteViewerState());
}
