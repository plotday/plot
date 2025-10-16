import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'command.dart';
import 'logging.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';

abstract class ActivityCommand extends Command {
  ActivityCommand(this.activity)
    : super(
        title: activity?.displayTitle ?? 'None',
        subtitle: activity?.parent?.displayTitle ?? '',
      );

  final Activity? activity;

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (activity?.parent?.displayTitle.isNotEmpty == true) ...[
          Flexible(
            child: Text(
              activity!.parent?.displayTitle ?? '',
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.sm.copyWith(
                color: context.colour.muted,
              ),
            ),
          ),
          Text(
            Activity.separator,
            style: context.theme.typography.sm.copyWith(
              color: context.colour.muted,
            ),
          ),
        ],
        Flexible(
          child: Text(
            activity?.displayTitle ?? 'None',
            overflow: TextOverflow.ellipsis,
            style: context.theme.typography.sm.copyWith(
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
  Future<CommandReturn> run(BuildContext context) async {
    // HACK: We need to make the panel visible before navigating to it
    log.info(
      'ChangeCurrentActivity: ${activity!.priority.id.toShortString()} / ${activity!.id.toShortString()}',
    );
    context.read<LayoutBloc>().setRightPanelVisible(true);
    return CommandRoute(
      ActivityRoute(activityIdString: activity!.id.toShortString()),
    );
  }
}

class NewActivity extends Command {
  NewActivity() : super(title: "New Activity", icon: PlotIcon.add);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<LayoutBloc>().setRightPanelVisible(true);
    return CommandRoute(NewActivityRoute());
  }
}

class OpenActivity extends Command {
  OpenActivity(Activity activity)
    // ignore: prefer_initializing_formals
    : activity = activity,
      super(title: "Open", icon: PlotIcon.open);

  final Activity activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(
      PriorityRoute(
        priorityIdString: activity.priority.id.toShortString(),
        children: [
          ActivityRoute(activityIdString: activity.id.toShortString()),
        ],
      ),
      replace: true,
    );
  }
}

class AddActivity extends Command {
  AddActivity(this._activity) : super(title: 'Add');

  final Future<Activity> _activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final activity = await _activity;
    await activity.copyWith(draft: false).save();
    Posthog().capture(eventName: 'Activity Added');
    return CommandRoute(
      PriorityRoute(
        priorityIdString: activity.priority.id.toShortString(),
        children: [
          ActivityRoute(activityIdString: activity.id.toShortString()),
        ],
      ),
      replace: true,
    );
  }
}

class ArchiveActivity extends Command {
  ArchiveActivity(Activity activity)
    : _activity = Future.value(activity),
      super(
        title: activity.deletedAt != null ? 'Un-archive' : 'Archive',
        icon: PlotIcon.archived,
      );

  ArchiveActivity.future(this._activity)
    : super(title: 'Archive', icon: PlotIcon.archived);

  final Future<Activity> _activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
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
    return const CommandDone();
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
    : super(title: 'Do Now', icon: PlotIcon.now);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final start = !activity.doNow;

    if (start) {
      // Starting the task - preserve existing scheduling type or default to date-based
      final hasDateTime = activity.at != null;

      await onUpdate(
        activity.copyWith(
          type: ActivityType.task,
          // If already has datetime scheduling, use current time; otherwise use date-based
          at: hasDateTime
              ? Value(
                  DateTimeRange(
                    DateTime.now(),
                    DateTime.now().add(Duration(hours: 1)),
                  ),
                )
              : const Value.absent(),
          on: !hasDateTime
              ? Value(CustomDateRange(Date.today(), null))
              : const Value.absent(),
        ),
      );
    } else {
      // Stopping the task - clear scheduling
      await onUpdate(
        activity.copyWith(on: const Value(null), at: const Value(null)),
      );
    }

    Posthog().capture(
      eventName: start ? 'Activity Started' : 'Activity Finished',
    );
    return const CommandDone();
  }
}

class FinishActivity extends _UpdateActivityCommand {
  FinishActivity(super.activity, {super.onUpdate})
    : super(title: 'Finish', icon: PlotIcon.done);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: Value(DateTime.now())));
    Posthog().capture(eventName: 'Activity Finished');
    return const CommandDone();
  }
}

class ScheduleActivity extends _UpdateActivityCommand {
  ScheduleActivity(super.activity, {required this.when, super.onUpdate})
    : super(
        title: activity.todo ? 'Reschedule' : 'Schedule',
        icon: PlotIcon.later,
      );

  final Date when;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(
      activity.copyWith(
        type: ActivityType.task,
        on: Value(CustomDateRange(when, null)),
        at: const Value(null), // Clear any existing datetime scheduling
      ),
    );
    Posthog().capture(
      eventName: activity.todo ? 'Activity Rescheduled' : 'Activity Scheduled',
    );
    return const CommandDone();
  }
}

class PickScheduleActivity extends ShowPage {
  PickScheduleActivity(Activity activity)
    : super(
        title: 'Schedule',
        icon: PlotIcon.later,
        builder: (context) => FCalendar(
          controller: FCalendarController.date(),
          onPress: (date) async {
            final commandReturn = await ScheduleActivity(
              activity,
              when: date.toDate(),
            ).run(context);
            if (!context.mounted) return;
            Dialog.pop(context, Value(commandReturn));
          },
        ),
      );
}

class MarkActivityIncomplete extends _UpdateActivityCommand {
  MarkActivityIncomplete(super.activity, {super.onUpdate})
    : super(title: 'Mark Activity Not Finished', icon: PlotIcon.done);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: const Value(null)));
    Posthog().capture(eventName: 'Activity Marked Not Finished');
    return const CommandDone();
  }
}

class PinActivity extends _UpdateActivityCommand {
  PinActivity(super.activity, {super.onUpdate})
    : super(
        title: _isPinned(activity) ? 'Unpin' : 'Pin',
        icon: PlotIcon.pinned,
      );

  static bool _isPinned(Activity activity) {
    return activity.hasTag(Tag.pinned);
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updatedActivity = activity.toggleTag(Tag.pinned);
    await onUpdate(updatedActivity);

    Posthog().capture(
      eventName: _isPinned(activity) ? 'Activity Un-pinned' : 'Activity Pinned',
    );
    return const CommandDone();
  }
}

class ToggleActivityTag extends _UpdateActivityCommand {
  ToggleActivityTag(super.activity, this.tag, {super.onUpdate})
    : super(title: tag.name, icon: tag.icon);

  final Tag tag;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (tag == Tag.later) {
      await PickScheduleActivity(activity).run(context);
      return const CommandDone();
    }

    final hadTag = activity.hasTag(tag);
    final updatedActivity = activity.toggleTag(tag);
    await onUpdate(updatedActivity);

    Posthog().capture(
      eventName: hadTag ? 'Activity Tag Removed' : 'Activity Tag Added',
      properties: {'tag': tag.name},
    );
    return const CommandDone();
  }
}

class ShowActivityCommands extends ShowCommands {
  ShowActivityCommands(Activity activity)
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) =>
            Future.value(Commands(groups: activityCommandGroups(activity))),
      );
}

Command activityPrimaryCommand(Activity activity) => switch (activity) {
  _ when PinActivity._isPinned(activity) => PinActivity(activity),
  _ when activity.todo => FinishActivity(activity),
  _ when activity.done => MarkActivityIncomplete(activity),
  _ => StartActivity(activity),
};

List<Command> activitySecondaryCommands(Activity activity) => [
  if (activity.path.isRoot) PickScheduleActivity(activity),
  if (!PinActivity._isPinned(activity)) PinActivity(activity),
  ArchiveActivity(activity),
];

List<CommandGroup> activityCommandGroups(Activity activity) {
  final commands = Tag.getAll()
      .map((tag) => ToggleActivityTag(activity, tag))
      .toList();
  final actions = activityCommands(activity);
  final remove = commands
      .where(
        (cmd) => cmd.tag.type != TagType.compute && activity.hasTag(cmd.tag),
      )
      .toList();
  final add = commands
      .where(
        (cmd) => cmd.tag.type != TagType.compute && !activity.hasTag(cmd.tag),
      )
      .toList();
  return [
    if (actions.isNotEmpty)
      StaticCommandGroup(title: 'Actions', commands: actions),
    if (remove.isNotEmpty)
      StaticCommandGroup(title: 'Remove Tag', commands: remove),
    if (add.isNotEmpty) StaticCommandGroup(title: 'Add Tag', commands: add),
  ];
}

List<Command> activityCommands(Activity activity) {
  final actions = Tag.getAll()
      .where((tag) => tag.type == TagType.compute)
      .map((tag) => ToggleActivityTag(activity, tag))
      .toList();
  return [OpenActivity(activity), ...actions];
}
