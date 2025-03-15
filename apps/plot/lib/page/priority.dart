import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';

class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, generalState) {
        if (generalState.loading) {
          return const Spinner();
        }
        final state = generalState as PrioritySelectedState;
        if (state.activityLoading) {
          return const Spinner();
        }
        return Column(
          children: [
            _ActivityToolbar(activity: state.activity),
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
                  final activity =
                      state.activity.copyWith(body: body, draft: false);
                  await context.read<PriorityBloc>().updateActivity(activity);
                  if (context.mounted) {
                    ActivityRoute.byId(activity.priorityId, activity.id)
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

class _ActivityToolbar extends StatelessWidget {
  const _ActivityToolbar({
    required this.activity,
  });

  final Activity activity;

  @override
  Widget build(BuildContext context) => Header(
        actions: [
          if (!activity.doNow && !activity.done)
            IconButton(
              icon: PlotIcon.doNow,
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
              icon: PlotIcon.done,
              onPressed: () => context.read<PriorityBloc>().updateActivity(
                    activity.copyWith(
                      doneAt: Value(DateTime.now()),
                    ),
                  ),
            ),
          if (activity.done)
            IconButton(
              icon: PlotIcon.done,
              onPressed: () => context.read<PriorityBloc>().updateActivity(
                    activity.copyWith(
                      doneAt: const Value(null),
                    ),
                  ),
            ),
          if (!activity.doNow)
            IconButton(
              icon: PlotIcon.pinned,
              onPressed: () => context.read<PriorityBloc>().updateActivity(
                    activity.copyWith(
                      pinned: !activity.pinned,
                    ),
                  ),
            ),
        ],
      );
}
