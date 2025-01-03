import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';

class TopicPage extends StatelessWidget {
  const TopicPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Switch(
              value: state.topic.doAt != null,
              onChanged: (on) =>
                  context.read<ActivityBloc>().updateNote(state.topic.copyWith(
                        doAt: on ? Value(DateTime.now()) : const Value(null),
                      )),
              label: const Text("Do now"),
            ),
            Switch(
              value: state.topic.pinned,
              onChanged: (on) =>
                  context.read<ActivityBloc>().updateNote(state.topic.copyWith(
                        pinned: on,
                      )),
              label: const Text("Pin"),
            ),
            SelectionArea(
                child: Column(
              children: state.topicNotes
                  .take(state.topicNotes.length - 1)
                  .map((note) => NoteWidget(note: note))
                  .toList(),
            )),
            InputAction(
              // TODO update body while editing
              onAdd: (body) async {
                final destination = state.draft.root
                    ? (state.draft.activityId, state.draft.topicId)
                    : null;
                await context
                    .read<ActivityBloc>()
                    .updateNote(state.draft.copyWith(body: body, draft: false));
                if (context.mounted && destination != null) {
                  TopicRoute.byId(destination.$1, destination.$2).go(context);
                }
              },
              label: state.draft.root ? "Start a topic" : "Add a note",
            ),
          ],
        ),
      ),
    );
  }
}
