import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';

abstract class ActivityCommand extends Command {
  ActivityCommand(this.activity)
    : super(
        title: activity?.title ?? 'None',
        subtitle: activity?.parent?.title ?? '',
      );

  final Activity? activity;

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (activity?.parent?.title.isNotEmpty == true) ...[
          Flexible(
            child: Text(
              activity!.parent?.title ?? '',
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
            activity?.title ?? 'None',
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

class ChangeCurrentActivity extends ActivityCommand {
  ChangeCurrentActivity(super.activity);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandRoute(ActivityRoute(activityId: activity?.id));
  }
}

class ActivityGroup extends CommandGroup {
  ActivityGroup({required super.title, required this.builder, this.priorityId});

  final Command Function(Activity activity) builder;
  final PriorityId? priorityId;

  @override
  Future<List<Command>> list({String? search}) async {
    final all = (await Activity.get(
      priorityId: priorityId,
      order: ActivityOrder.recent,
      search: search,
    )).map((activity) => builder(activity)).toList();
    return CommandGroup.filter(all, search);
  }
}

class OpenActivity extends Command {
  OpenActivity(Activity activity)
    // ignore: prefer_initializing_formals
    : activity = activity,
      activityId = activity.id,
      super(title: "Open", icon: PlotIcon.open);

  OpenActivity.byId(this.activityId)
    : activity = null,
      super(title: "Open", icon: PlotIcon.open);

  final Activity? activity;
  final ActivityId activityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandRoute(ActivityRoute(activityId: activityId));
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
    return CommandRoute(ActivityRoute(activityId: activity.id), replace: true);
  }
}

class ArchiveActivity extends Command {
  ArchiveActivity(Activity activity)
    : _activity = Future.value(activity),
      super(
        title: activity.deletedAt != null ? 'Un-archive' : 'Archive',
        icon: activity.deletedAt != null
            ? PlotIcon.unarchive
            : PlotIcon.archive,
      );

  ArchiveActivity.future(this._activity)
    : super(title: 'Archive', icon: PlotIcon.archive);

  final Future<Activity> _activity;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final activity = await _activity;
    final isArchived = activity.deletedAt != null;

    if (isArchived) {
      // Un-archive: set deletedAt to null
      await activity.copyWith(deletedAt: const Value(null)).save();
      Posthog().capture(eventName: 'Activity Un-archived');
    } else {
      // Archive: set deletedAt to current time
      await activity.delete();
      Posthog().capture(eventName: 'Activity Archived');
    }
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

class PickScheduleActivity extends ShowPage {
  PickScheduleActivity(Activity activity)
    : super(
        title: 'Schedule',
        icon: PlotIcon.scheduled,
        builder: (context) => Dialog(
          builder: (context) => FCalendar(
            controller: FCalendarController.date(),
            onPress: (date) async {
              final commandReturn = await ScheduleActivity(
                activity,
                when: date.toDate(),
              ).run(context);
              if (!context.mounted) return;
              DialogProvider.of(context).pop(context, Value(commandReturn));
            },
          ),
        ),
      );

  // @override
  // void onSelect(BuildContext context, Date value) async {
  //   ScheduleActivity(activity, when: value).run(context);
  // }
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

class ShowActivityCommands extends ShowCommands {
  ShowActivityCommands(Activity activity)
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) => Future.value(
          Commands(
            groups: [
              StaticCommandGroup(
                title: activity.title,
                commands: activityCommands(activity),
              ),
            ],
          ),
        ),
      );
}

Command activityPrimaryCommand(Activity activity) => CommandWrapper(
  switch (activity) {
    _ when activity.pinned => PinActivity(activity),
    _ when activity.scheduled => FinishActivity(activity),
    _ when activity.done => MarkActivityIncomplete(activity),
    _ => StartActivity(activity),
  },
  icon: Value(switch (activity) {
    _ when activity.pinned => PlotIcon.pinned,
    _ when activity.scheduled => PlotIcon.todo,
    _ when activity.done => PlotIcon.done,
    _ => PlotIcon.doNow,
  }),
);

List<Command> activitySecondaryCommands(Activity activity) => [
  PickScheduleActivity(activity),
  PinActivity(activity),
  ArchiveActivity(activity),
];

List<Command> activityCommands(Activity activity) => [
  activityPrimaryCommand(activity),
  ...activitySecondaryCommands(activity),
];
