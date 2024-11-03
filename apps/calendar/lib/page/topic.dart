import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/widget/input_action.dart';

class TopicPage extends StatelessWidget {
  const TopicPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Column(
        children: [
          ...state.topicNotes.map((note) => NoteWidget(note: note)),
          InputAction(
            onAdd: (body) {
              if (state.topicId == null) {
                context.read<ActivityBloc>().addNote(Note(
                      activityId: state.current?.id,
                      body: body,
                      order: Order.first(),
                    ));
              } else if (state.topicNote != null) {
                context.read<ActivityBloc>().addNote(Note.inTopic(
                      parent: state.topicNote!,
                      body: body,
                      order: Order.last(),
                    ));
              }
            },
            label: state.topicNotes.isEmpty ? "Start a topic" : "Add a note",
          ),
        ],
      ),
    );
  }
}
