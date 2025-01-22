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
        if (state.loading) {
          return const Spinner();
        }
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Switch(
                      value: state.activity.doAt != null,
                      onChanged: (on) => context
                          .read<PriorityBloc>()
                          .updateActivity(state.activity.copyWith(
                            doAt:
                                on ? Value(DateTime.now()) : const Value(null),
                          )),
                      label: const Text("Do now"),
                    ),
                    Switch(
                      value: state.activity.pinned,
                      onChanged: (on) => context
                          .read<PriorityBloc>()
                          .updateActivity(state.activity.copyWith(
                            pinned: on,
                          )),
                      label: const Text("Pin"),
                    ),
                    SelectionArea(
                        child: Column(
                      children: state.activityNotes
                          .take(state.activityNotes.isNotEmpty
                              ? state.activityNotes.length - 1
                              : 0)
                          .map((note) => NoteWidget(note: note))
                          .toList(),
                    )),
                  ],
                ),
              ),
            ),
            Editor(
              hint: state.activityNotes.isNotEmpty
                  ? 'Start an activity'
                  : 'Add a note',
              autofocus: true,
              onSubmitted: (body) async {
                if (state.activity.draft) {
                  await context.read<PriorityBloc>().updateActivity(
                      state.activity.copyWith(body: body, draft: false));
                  if (context.mounted) {
                    ActivityRoute.byId(
                            state.activity.priorityId, state.activity.id)
                        .go(context);
                  }
                  return;
                }
                await context
                    .read<PriorityBloc>()
                    .updateNote(state.draft.copyWith(body: body, draft: false));
              },
            ),
          ],
        );
      });
}
