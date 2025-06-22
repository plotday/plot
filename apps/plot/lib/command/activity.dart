import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'logging.dart';
import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/page/new_activity.dart';

class _ActivityValue extends ValueCommand<Activity?> {
  _ActivityValue(Activity? activity)
    : super(
        title: activity?.title ?? 'None',
        subtitle: activity?.parent?.title ?? '',
        value: activity,
      );

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (value?.parent?.title.isNotEmpty == true) ...[
          Flexible(
            child: Text(
              value!.parent?.title ?? '',
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.xs.copyWith(
                color: context.colour.muted,
              ),
            ),
          ),
          Text(
            Activity.separator,
            style: context.theme.typography.xs.copyWith(
              color: context.colour.muted,
            ),
          ),
        ],
        Flexible(
          child: Text(
            value?.title ?? 'None',
            overflow: TextOverflow.ellipsis,
            style: context.theme.typography.xs.copyWith(
              color: context.colour.foreground,
            ),
          ),
        ),
      ],
    );
  }
}

class ActivityCommandGroup extends CommandGroup {
  ActivityCommandGroup({this.priorityId}) : super(title: 'Activities');

  final PriorityId? priorityId;

  @override
  Future<List<Command>> list({String? search}) async {
    final all = (await Activity.get(
      priorityId: priorityId,
      order: ActivityOrder.recent,
      search: search,
    )).map((activity) => _ActivityValue(activity)).toList();
    return CommandGroup.filter(all, search);
  }
}

class PickActivity extends Commands<Activity> {
  PickActivity({
    super.prompt = 'Pick an activity',
    this.priorityId,
    this.initialActivity,
  }) : super(
         groups: [ActivityCommandGroup(priorityId: priorityId)],
         secondaryCommand: priorityId != null
             ? (prompt) =>
                   NewActivity(priorityId: priorityId!, parent: initialActivity)
             : null,
       );

  final PriorityId? priorityId;
  final Activity? initialActivity;
}

class ChangeCurrentActivity extends Command {
  ChangeCurrentActivity(Activity activity)
    // ignore: prefer_initializing_formals
    : activity = activity,
      activityId = activity.id,
      super(title: "Open", icon: PlotIcon.open);

  ChangeCurrentActivity.byId(this.activityId)
    : activity = null,
      super(title: "Open", icon: PlotIcon.open);

  final Activity? activity;
  final ActivityId activityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.navigate(ActivityRoute(activityId: activityId));
    return null;
  }
}

class PickCurrentActivity extends ShowCommands<Activity> {
  PickCurrentActivity({this.priorityId})
    : super(
        title: 'Pick Current Activity',
        icon: PlotIcon.activity,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
        commands: (context) => PickActivity(
          prompt: 'Change Current Activity',
          priorityId: priorityId,
        ),
      );

  final PriorityId? priorityId;

  @override
  void onSelect(BuildContext context, Activity value) async {
    log.info('Change current activity to ${value.title}');
    ChangeCurrentActivity(value).run(context);
  }
}

class AddActivity extends Command {
  AddActivity(this._activity) : super(title: 'Add');

  final Future<Activity> _activity;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final activity = await _activity;
    await activity.copyWith(draft: false).save();
    Posthog().capture(eventName: 'Activity Added');
    if (context.mounted) {
      await context.router.replace(ActivityRoute(activityId: activity.id));
    }
    return null;
  }
}

class ArchiveActivity extends Command {
  ArchiveActivity(this._activity)
    : super(title: 'Archive', icon: PlotIcon.delete);

  final Future<Activity> _activity;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final activity = await _activity;
    await activity.delete();
    Posthog().capture(eventName: 'Activity Archived');
    return null;
  }
}

class NewActivity extends Command {
  NewActivity({required this.priorityId, this.parent})
    : super(title: 'New Activity', icon: PlotIcon.add);

  final PriorityId priorityId;
  final Activity? parent;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandPage(NewActivityPage(priorityId: priorityId, parent: parent));
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
      activity.copyWith(doAt: start ? Value(Date.today()) : const Value(null)),
    );
    Posthog().capture(
      eventName: start ? 'Activity Started' : 'Activity Finished',
    );
    return null;
  }
}

class FinishActivity extends _UpdateActivityCommand {
  FinishActivity(super.activity, {super.onUpdate})
    : super(title: 'Finish', icon: PlotIcon.done);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: Value(DateTime.now())));
    Posthog().capture(eventName: 'Activity Finished');
    return null;
  }
}

class ScheduleActivity extends _UpdateActivityCommand {
  ScheduleActivity(super.activity, {required this.when, super.onUpdate})
    : super(
        title: activity.scheduled ? 'Reschedule' : 'Schedule',
        icon: PlotIcon.scheduled,
      );

  final Date when;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doAt: Value(when)));
    Posthog().capture(
      eventName: activity.scheduled
          ? 'Activity Rescheduled'
          : 'Activity Scheduled',
    );
    return null;
  }
}

class PickScheduleActivity extends ShowCommand<Date> {
  PickScheduleActivity(this.activity)
    : super(
        title: 'Schedule',
        icon: PlotIcon.scheduled,
        builder: (context) => Dialog(
          builder: (context) => FCalendar(
            controller: FCalendarController.date(),
            onPress: (date) =>
                DialogProvider.of(context).pop(context, Value(date.toDate())),
          ),
        ),
      );

  final Activity activity;

  @override
  void onSelect(BuildContext context, Date value) async {
    ScheduleActivity(activity, when: value).run(context);
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

class ActivityCommands extends Commands<void> {
  final Activity activity;

  ActivityCommands(this.activity)
    : super(
        groups: [
          StaticCommandGroup(
            title: activity.title,
            commands: activityCommands(activity),
          ),
        ],
      );
}

class ShowActivityCommands extends ShowCommands<void> {
  ShowActivityCommands(Activity activity)
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) => ActivityCommands(activity),
      );
}

Command activityPrimaryCommand(Activity activity) => CommandWrapper(
  switch (activity) {
    _ when activity.pinned => PinActivity(activity),
    _ when activity.scheduled => FinishActivity(activity),
    _ when activity.done => MarkActivityIncomplete(activity),
    _ => StartActivity(activity),
  },
  statusIcon: Value(switch (activity) {
    _ when activity.pinned => PlotIcon.pinned,
    _ when activity.scheduled => PlotIcon.todo,
    _ when activity.done => PlotIcon.done,
    _ => PlotIcon.doNow,
  }),
);

List<Command> activitySecondaryCommands(Activity activity) => [
  PickScheduleActivity(activity),
  PinActivity(activity),
  ArchiveActivity(Future.value(activity)),
];

List<Command> activityCommands(Activity activity) => [
  activityPrimaryCommand(activity),
  ...activitySecondaryCommands(activity),
];
