import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
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
    await context.router.push(
      ActivityRoute(
        activityId: activityId,
      ),
    );
    return null;
  }
}

class NewActivity extends Command {
  NewActivity({this.draft})
      : super(
          title: 'New Activity',
          icon: PlotIcon.add,
        );

  final Activity? draft;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.push<void>(NewActivityRoute(draft: draft));
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
    await activity
        .copyWith(
          doAt: activity.doNow ? const Value(null) : Value(DateTime.now()),
        )
        .save();
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
    await activity
        .copyWith(
          doneAt: Value(DateTime.now()),
        )
        .save();
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
    await activity
        .copyWith(
          doneAt: const Value(null),
        )
        .save();
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
    await activity
        .copyWith(
          pinned: !activity.pinned,
        )
        .save();
    Posthog().capture(
      eventName: activity.pinned ? 'Activity Un-pinned' : 'Activity Pinned',
    );
    return null;
  }

  final Activity activity;
}

List<Command> activityCommands(Activity activity) => [
      if (!activity.doNow && !activity.done && !activity.pinned)
        StartActivity(activity),
      if (activity.doNow) FinishActivity(activity),
      if (activity.done) MarkActivityIncomplete(activity),
      if (!activity.doNow) PinActivity(activity),
    ];
