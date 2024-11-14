import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/widget/input_action.dart';
import 'package:plot/widget/toggle.dart';

class TopicPage extends StatelessWidget {
  const TopicPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Column(
        children: [
          Toggle(
            value: state.topicNote.doAt != null,
            onChanged: (on) => context
                .read<ActivityBloc>()
                .updateNote(state.topicNote.copyWith(
                  doAt: on ? Value(DateTime.now()) : const Value(null),
                  doneAt: const Value(null),
                  pinned: false,
                )),
            child: const Text("Do now"),
          ),
          Toggle(
            value: state.topicNote.pinned,
            onChanged: (on) => context
                .read<ActivityBloc>()
                .updateNote(state.topicNote.copyWith(
                  pinned: on,
                  doAt: const Value(null),
                )),
            child: const Text("Pin"),
          ),
          ...state.topicNotes
              .take(state.topicNotes.length - 1)
              .map((note) => NoteWidget(note: note)),
          InputAction(
            // TODO update body while editing
            onAdd: (body) {
              context.read<ActivityBloc>().updateNote(
                  state.draftNote.copyWith(body: body, draft: false));
            },
            label: state.topicNotes.isEmpty ? "Start a topic" : "Add a note",
          ),
        ],
      ),
    );
  }
}
