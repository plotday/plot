import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/command/command.dart';

@RoutePage(name: "ActivityRoute")
class ActivityWrapper extends AutoRouter implements AutoRouteWrapper {
  ActivityWrapper({
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
  Widget wrappedRoute(BuildContext context) {
    return BlocProvider(
      create: (_) => ActivityBloc()..setCurrentId(activityId),
      child: this,
    );
  }
}

@RoutePage(name: "ActivityMainRoute")
class ActivityPage extends StatelessWidget {
  const ActivityPage({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(builder: (context, state) {
      if (state is! ActivitySelectedState) {
        return const Spinner();
      }

      if (state.loading) {
        return const Spinner();
      }

      return Scaffold(
        body: Column(
          children: [
            ActivityToolbar(activity: state.current),
            Expanded(child: NotesView(notes: state.notes)),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    width: 1.0,
                    color: context.colour.border,
                  ),
                ),
              ),
              child: Editor(
                hint: 'Add a note',
                autofocus: true,
                onSubmitted: (body) async {
                  if (state.current.draft) {
                    final activity =
                        state.current.copyWith(body: body, draft: false);
                    await context.read<ActivityBloc>().updateActivity(activity);
                    if (!context.mounted) return;
                    await context.router
                        .push(ActivityRoute(activity: activity));
                    return;
                  }
                  await context.read<ActivityBloc>().updateNote(
                      state.draft.copyWith(body: body, draft: false));
                },
              ),
            ),
          ],
        ),
      );
    });
  }
}

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
