import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/note_viewer.dart';
import 'package:plot/widget/icon.dart';

import 'base.dart';

/// Closes the full-screen [NoteViewer] reading view. Bound to the X
/// button in the viewer header.
class CloseNoteViewer extends Command {
  CloseNoteViewer()
    : super(
        title: 'Close',
        icon: PlotIcon.close,
        eventObject: EventObject.note,
        eventAction: EventAction.closed,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<NoteViewerBloc>().dismiss();
    return const CommandDone();
  }
}
