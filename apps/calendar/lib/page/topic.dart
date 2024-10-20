import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/context.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/widget/input_action.dart';

class TopicPage extends StatelessWidget {
  const TopicPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (context, state) => Column(
        children: [
          ...state.topicNotes.map((note) => NoteWidget(note: note)),
          InputAction(
            onAdd: (body) {
              if (state.topicId == null) {
                context.read<ContextBloc>().addNote(Note(
                      contextId: state.current?.id,
                      body: body,
                      order: Order.first(),
                    ));
              } else if (state.topicNote != null) {
                context.read<ContextBloc>().addNote(Note.inTopic(
                      parent: state.topicNote!,
                      body: body,
                      order: Order.last(),
                    ));
              }
            },
            label: "Add a note",
          ),
        ],
      ),
    );
  }
}
