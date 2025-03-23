import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/command/command.dart';

class ActivityToolbar extends StatelessWidget {
  const ActivityToolbar({
    required this.activity,
    super.key,
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
class ActivityPage extends StatelessWidget {
  ActivityPage({
    Activity? activity,
    ActivityId? activityId,
    @PathParam("activityId") String? activityIdString,
    super.key,
  }) : activityId = activity?.id ??
            activityId ??
            (activityIdString != null
                ? ActivityId.fromShortString(activityIdString)
                : null);

  final ActivityId? activityId;

  @override
  Widget build(BuildContext context) {
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
            ActivityToolbar(activity: state.activity),
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
