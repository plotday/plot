import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/router.dart';

class ActivityCommand extends ValueCommand<Activity> {
  ActivityCommand(
    Activity activity,
  ) : super(
          title: activity.title,
          icon: PlotIcon.activity,
          value: activity,
        );
}

class ChangeCurrentActivity extends Command {
  ChangeCurrentActivity(Activity activity)
      : priorityId = activity.priorityId,
        activityId = activity.id,
        super(
          title: activity.title,
          icon: PlotIcon.activity,
        );

  ChangeCurrentActivity.byId(
      {required this.priorityId, required this.activityId})
      : super(
          title: 'View Activity',
          icon: PlotIcon.activity,
        );

  final PriorityId priorityId;
  final ActivityId activityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.replaceAll([
      PrioritiesRoute(
        priorityId: priorityId,
      ),
      ActivityRoute(
        activityId: activityId,
      ),
    ]);
    return null;
  }
}

// class PickActivity extends Commands {
//   PickActivity(
//     List<Activity> priorities, {
//     super.prompt = 'Pick an activity',
//   }) : super(groups: [
//           StaticCommandGroup(
//             title: 'Recent',
//             commands: priorities
//                 .map((activity) => ActivityCommand(activity))
//                 .toList(),
//           ),
//         ]);
//
//   PickActivity.recent(
//     BuildContext context, {
//     super.prompt = 'Pick an activity',
//   }) : super(groups: [
//           StaticCommandGroup(
//             title: 'Recent',
//             commands: context
//                 .read<PriorityBloc>()
//                 .state
//                 .activities
//                 .map((activity) => ActivityCommand(activity))
//                 .toList(),
//           ),
//         ]);
// }

// class ChangeActivity extends ShowCommand<Activity> {
//   ChangeActivity()
//       : super(
//           title: 'Switch priorities',
//           icon: PlotIcon.activity,
//           shortcut: const SingleActivator(
//             LogicalKeyboardKey.keyJ,
//             meta: true,
//           ),
//           commands: (context) => PickActivity.recent(
//             context,
//             prompt: 'Switch priorities',
//           ),
//         );
//
//   @override
//   void onSelect(BuildContext context, Activity value) async {
//     ActivityRoute.byId(value.id).go(context);
//   }
// }

class NewActivity extends Command {
  NewActivity()
      : super(
          title: 'New Activity',
          icon: PlotIcon.add,
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    // TODO
    // final state = context // as PrioritySelectedState
    // NewActivityRoute.byId(context.state.current.id).go(context);
    return null;
  }
}

class StartActivity extends Command {
  StartActivity(this.activity)
      : super(
          title: 'Start Activity',
          icon: PlotIcon.doNow,
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.read<PriorityBloc>().updateActivity(
          activity.copyWith(
            doAt: activity.doNow ? const Value(null) : Value(DateTime.now()),
          ),
        );
    Posthog().capture(
      eventName: 'Activity Started',
    );
    return null;
  }

  final Activity activity;
}

class FinishActivity extends Command {
  FinishActivity(this.activity)
      : super(
          title: 'Finish Activity',
          icon: PlotIcon.done,
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.read<PriorityBloc>().updateActivity(
          activity.copyWith(
            doneAt: Value(DateTime.now()),
          ),
        );
    Posthog().capture(
      eventName: 'Activity Finished',
    );
    return null;
  }

  final Activity activity;
}

class MarkActivityIncomplete extends Command {
  MarkActivityIncomplete(this.activity)
      : super(
          title: 'Mark Activity Not Finished',
          icon: PlotIcon.done,
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.read<PriorityBloc>().updateActivity(
          activity.copyWith(
            doneAt: const Value(null),
          ),
        );
    Posthog().capture(
      eventName: 'Activity Marked Not Finished',
    );
    return null;
  }

  final Activity activity;
}

class PinActivity extends Command {
  PinActivity(this.activity)
      : super(
          title: '${activity.pinned ? 'Unpin' : 'Pin'} Activity',
          icon: PlotIcon.pinned,
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.read<PriorityBloc>().updateActivity(
          activity.copyWith(
            pinned: !activity.pinned,
          ),
        );
    Posthog().capture(
      eventName: activity.pinned ? 'Activity Un-pinned' : 'Activity Pinned',
    );
    return null;
  }

  final Activity activity;
}

List<Command> activityCommands(Activity activity) => [
      if (!activity.doNow && !activity.done) StartActivity(activity),
      if (activity.doNow) FinishActivity(activity),
      if (activity.done) MarkActivityIncomplete(activity),
      if (!activity.doNow) PinActivity(activity),
    ];
