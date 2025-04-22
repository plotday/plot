import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';

class ActivityCommand extends ValueCommand<Activity> {
  ActivityCommand(Activity activity)
    : super(title: activity.title, icon: PlotIcon.activity, value: activity);
}

class ChangeCurrentActivity extends Command {
  ChangeCurrentActivity(Activity activity)
    : priorityId = activity.priorityId,
      activityId = activity.id,
      super(title: activity.title, icon: PlotIcon.activity);

  ChangeCurrentActivity.byId({
    required this.priorityId,
    required this.activityId,
  }) : super(title: 'View Activity');

  final PriorityId priorityId;
  final ActivityId activityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.push(ActivityRoute(activityId: activityId));
    return null;
  }
}

abstract class _UpdateActivityCommand extends Command {
  _UpdateActivityCommand(
    this.activity, {
    Future<void> Function(Activity)? onUpdate,
    required super.title,
    super.icon,
  }) : onUpdate = onUpdate ?? ((activity) => activity.save());

  final Activity activity;
  final Future<void> Function(Activity) onUpdate;
}

class StartActivity extends _UpdateActivityCommand {
  StartActivity(super.activity, {super.onUpdate})
    : super(title: 'Do Now', icon: PlotIcon.doNow);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final start = !activity.doNow;
    await onUpdate(
      activity.copyWith(
        doAt:
            start
                ? Value(DateTime.now().subtract(Duration(seconds: 10)))
                : const Value(null),
      ),
    );
    Posthog().capture(
      eventName: start ? 'Activity Started' : 'Activity Stopped',
    );
    return null;
  }
}

class FinishActivity extends _UpdateActivityCommand {
  FinishActivity(super.activity, {super.onUpdate})
    : super(title: 'Finish Activity', icon: PlotIcon.done);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: Value(DateTime.now())));
    Posthog().capture(eventName: 'Activity Finished');
    return null;
  }
}

class MarkActivityIncomplete extends _UpdateActivityCommand {
  MarkActivityIncomplete(super.activity, {super.onUpdate})
    : super(title: 'Mark Activity Not Finished', icon: PlotIcon.done);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: const Value(null)));
    Posthog().capture(eventName: 'Activity Marked Not Finished');
    return null;
  }
}

class PinActivity extends _UpdateActivityCommand {
  PinActivity(super.activity, {super.onUpdate})
    : super(title: activity.pinned ? 'Unpin' : 'Pin', icon: PlotIcon.pinned);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(activity.copyWith(pinned: !activity.pinned));
    Posthog().capture(
      eventName: activity.pinned ? 'Activity Un-pinned' : 'Activity Pinned',
    );
    return null;
  }
}

Command primaryActivityCommand(Activity activity) => CommandWrapper(
  switch (activity) {
    _ when activity.pinned => PinActivity(activity),
    _ when activity.doNow => FinishActivity(activity),
    _ when activity.done => MarkActivityIncomplete(activity),
    _ => StartActivity(activity),
  },
  statusIcon: Value(switch (activity) {
    _ when activity.pinned => PlotIcon.pinned,
    _ when activity.doNow => PlotIcon.todo,
    _ when activity.done => PlotIcon.done,
    _ => PlotIcon.doNow,
  }),
);
