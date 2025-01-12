import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PriorityBloc, PriorityState>(builder: (context, state) {
        if (state.activity == null) {
          return const Spinner();
        }
        final Activity activity = state.activity!;
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Switch(
                value: activity.doAt != null,
                onChanged: (on) => context
                    .read<PriorityBloc>()
                    .updateActivity(activity.copyWith(
                      doAt: on ? Value(DateTime.now()) : const Value(null),
                    )),
                label: const Text("Do now"),
              ),
              Switch(
                value: activity.pinned,
                onChanged: (on) => context
                    .read<PriorityBloc>()
                    .updateActivity(activity.copyWith(
                      pinned: on,
                    )),
                label: const Text("Pin"),
              ),
              SelectionArea(
                  child: Column(
                children: state.activityNotes
                    .take(state.activityNotes.length - 1)
                    .map((note) => NoteWidget(note: note))
                    .toList(),
              )),
              InputAction(
                // TODO update body while editing
                onAdd: (body) async {
                  if (activity.draft) {
                    await context.read<PriorityBloc>().updateActivity(
                        activity.copyWith(body: body, draft: false));
                    if (context.mounted) {
                      ActivityRoute.byId(activity.priorityId, activity.id)
                          .go(context);
                    }
                    return;
                  }
                  await context.read<PriorityBloc>().updateNote(
                      state.draft.copyWith(body: body, draft: false));
                },
                label: activity.draft ? "Create an activity" : "Add a note",
              ),
            ],
          ),
        );
      });
}
