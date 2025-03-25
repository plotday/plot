import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/draft_activity.dart';
import 'package:plot/state/now.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

@RoutePage(name: "NewActivityRoute")
class NewActivityWrapper extends AutoRouter implements AutoRouteWrapper {
  NewActivityWrapper({
    Priority? priority,
    PriorityId? priorityId,
    @QueryParam("priorityId") String? priorityIdString,
    super.key,
  }) : priorityId = priority?.id ??
            priorityId ??
            (priorityIdString != null
                ? PriorityId.fromShortString(priorityIdString)
                : null);

  final PriorityId? priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return BlocProvider(
      create: (_) => DraftActivityBloc(
          priorityId: context.read<NowBloc>().loadedState.priority.id),
      child: this,
    );
  }
}

@RoutePage(name: "NewActivityMainRoute")
class NewActivityPage extends StatelessWidget {
  const NewActivityPage({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DraftActivityBloc, DraftActivityState>(
        builder: (context, state) {
      if (state.loading) {
        return const Spinner();
      }

      return Scaffold(
        body: Column(
          children: [
            _ActivityToolbar(activity: state.draft),
            Editor(
              hint: 'Start an activity',
              autofocus: true,
              onSubmitted: (body) async {
                final activity = state.draft.copyWith(body: body, draft: false);
                await context.read<DraftActivityBloc>().updateDraft(activity);
                if (!context.mounted) return;
                await context.router.replace(ActivityRoute(activity: activity));
              },
            )
          ],
        ),
      );
    });
  }
}

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
