import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/command/command.dart';

class _ActivityToolbar extends StatelessWidget {
  const _ActivityToolbar({
    required this.activity,
  });

  final Activity activity;

  @override
  Widget build(BuildContext context) => Header(
        commands: [
          if (!activity.doNow && !activity.done) StartActivity(activity),
          if (activity.doNow) FinishActivity(activity),
          if (activity.done) MarkActivityIncomplete(activity),
          if (!activity.doNow) PinActivity(activity),
        ],
      );
}

@RoutePage()
class NewActivityPage extends StatelessWidget {
  const NewActivityPage({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    print("NewActivityPage build");
    return BlocBuilder<PriorityBloc, PriorityState>(builder: (context, state) {
      // Added a null check and some safety conditions
      if (state is! PrioritySelectedState) {
        return const Spinner();
      }

      if (state.loading || state.activityLoading) {
        return const Spinner();
      }

      return Scaffold(
        body: Column(
          children: [
            _ActivityToolbar(activity: state.activity),
            Expanded(child: NotesView(notes: state.activityNotes)),
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
                  if (!context.mounted) return;
                  await context.router.push(ActivityRoute(activity: activity));
                  return;
                }
                await context
                    .read<PriorityBloc>()
                    .updateNote(state.draft.copyWith(body: body, draft: false));
              },
            )
          ],
        ),
      );
    });
  }
}
