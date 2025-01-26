import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';

class ActivityToolbar extends StatelessWidget {
  const ActivityToolbar({
    required this.activity,
    super.key,
  });

  final Activity activity;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!activity.doNow && !activity.done)
              IconButton(
                icon: const PlotIcon.doNow(),
                onPressed: () => context.read<PriorityBloc>().updateActivity(
                      activity.copyWith(
                        doAt: activity.doNow
                            ? const Value(null)
                            : Value(DateTime.now()),
                      ),
                    ),
              ),
            if (activity.doNow)
              IconButton(
                icon: const PlotIcon.done(),
                onPressed: () => context.read<PriorityBloc>().updateActivity(
                      activity.copyWith(
                        doneAt: Value(DateTime.now()),
                      ),
                    ),
              ),
            if (activity.done)
              IconButton(
                icon: const PlotIcon.done(),
                onPressed: () => context.read<PriorityBloc>().updateActivity(
                      activity.copyWith(
                        doneAt: const Value(null),
                      ),
                    ),
              ),
            if (!activity.doNow)
              IconButton(
                icon: const PlotIcon.pinned(),
                onPressed: () => context.read<PriorityBloc>().updateActivity(
                      activity.copyWith(
                        pinned: !activity.pinned,
                      ),
                    ),
              ),
          ],
        ),
      );
}

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
            ActivityToolbar(activity: state.activity),
            Expanded(
              child: NotesView(notes: state.activityNotes),
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
