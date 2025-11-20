import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'command.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'logging.dart';

abstract class ActivityCommand extends Command {
  ActivityCommand(
    this.activity, {
    required super.eventObject,
    required super.eventAction,
    super.icon,
    String? title,
  }) : super(
         title: title ?? activity?.displayTitle ?? 'None',
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
            title,
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
  ChangeCurrentActivity(super.activity)
    : super(
        eventObject: EventObject.activity,
        eventAction: activity == null ? EventAction.closed : EventAction.opened,
        title: 'Open ${activity?.displayTitle}',
        icon: PlotIcon.open,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Update PriorityBloc to track current activity for navigation
    context.read<PriorityBloc>().setActivity(activity);

    if (activity == null) {
      // Navigate to just the PriorityRoute without ActivityRoute
      final priority = context.read<PriorityBloc>().state.context;
      return CommandRoute(
        PriorityRoute(priorityIdString: priority.id.toShortString()),
      );
    }

    final route = PriorityRoute(
      priorityIdString: activity!.priority.id.toShortString(),
      children: [ActivityRoute(activityIdString: activity!.id.toShortString())],
    );

    return CommandRoute(route);
  }
}

class NewActivity extends Command {
  NewActivity()
    : super(
        title: "New Activity",
        eventObject: EventObject.activity,
        eventAction: EventAction.opened,
        icon: PlotIcon.add,
        shortcut: SingleActivator(LogicalKeyboardKey.keyN, meta: true),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final nowBloc = context.read<NowBloc>();
    final priorityId = nowBloc.loadedState.priority.id;
    return CommandRoute(
      PriorityRoute(
        priorityIdString: priorityId.toShortString(),
        children: [NewActivityRoute()],
      ),
    );
  }
}

class NextActivityThread extends Command {
  NextActivityThread()
    : super(
        title: 'Next Activity Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        shortcut: const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          meta: true,
        ),
        icon: PlotIcon.next,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final priorityBloc = context.read<PriorityBloc>();

      // Search for next root activity
      int offset = 1;
      while (offset < 100) {
        // Safety limit
        final item = priorityBloc.getAgendaItem(offset);
        if (item == null) {
          return const CommandSkipped();
        }

        final activity = item.iff<Activity>(activity: (a) => a);
        if (activity != null && activity.path.isRoot) {
          return ChangeCurrentActivity(activity).run(context);
        }
        offset++;
      }

      return const CommandSkipped();
    } catch (e, stackTrace) {
      log.severe('Error in NextActivityThread: $e', e, stackTrace);
      return const CommandSkipped();
    }
  }
}

class PreviousActivityThread extends Command {
  PreviousActivityThread()
    : super(
        title: 'Previous Activity Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        shortcut: const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          meta: true,
        ),
        icon: PlotIcon.previous,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final priorityBloc = context.read<PriorityBloc>();

      // Search for previous root activity
      int offset = -1;
      while (offset > -100) {
        // Safety limit
        final item = priorityBloc.getAgendaItem(offset);
        if (item == null) {
          return const CommandSkipped();
        }

        final activity = item.iff<Activity>(activity: (a) => a);
        if (activity != null && activity.path.isRoot) {
          return ChangeCurrentActivity(activity).run(context);
        }
        offset--;
      }

      return const CommandSkipped();
    } catch (e, stackTrace) {
      log.severe('Error in PreviousActivityThread: $e', e, stackTrace);
      return const CommandSkipped();
    }
  }
}

class AddActivity extends Command {
  AddActivity(this._activity, {this.navigate = true})
    : super(
        title: 'Add',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final Future<Activity> _activity;
  final bool navigate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Try to get ActivityBloc from context before any async operations
    ActivityBloc? activityBloc;
    try {
      activityBloc = context.read<ActivityBloc>();
    } catch (e) {
      // No ActivityBloc in context
      activityBloc = null;
    }

    // Get PriorityBloc before async operations
    final priorityBloc = context.read<PriorityBloc>();

    final activity = await _activity;

    // Use ActivityBloc.add() if available (resets the draft), otherwise save directly
    if (activityBloc != null) {
      await activityBloc.add(activity);
    } else {
      await activity.copyWith(draft: false).save();
    }

    // Only navigate if we're not already in an ActivityPage thread context
    // If activityBloc exists, we're adding a child to an existing thread - stay in place
    if (!navigate || activityBloc != null) {
      return const CommandDone();
    }

    // Update PriorityBloc to track the new activity
    priorityBloc.setActivity(activity);

    return CommandRoute(
      PriorityRoute(
        priorityIdString: activity.priority.id.toShortString(),
        children: [
          ActivityRoute(activityIdString: activity.id.toShortString()),
        ],
      ),
    );
  }
}

class ArchiveActivity extends Command {
  ArchiveActivity(Activity activity)
    : _activity = Future.value(activity),
      super(
        title: activity.archivedAt != null ? 'Un-archive' : 'Archive',
        eventObject: EventObject.activity,
        eventAction: activity.archivedAt != null
            ? EventAction.unarchived
            : EventAction.archived,
        icon: PlotIcon.archived,
      );

  ArchiveActivity.future(this._activity)
    : super(
        title: 'Archive',
        eventObject: EventObject.activity,
        eventAction: EventAction.archived,
        icon: PlotIcon.archived,
      );

  final Future<Activity> _activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final activity = await _activity;
    final isArchived = activity.archivedAt != null;

    if (isArchived) {
      // Un-archive: set archivedAt to null
      await activity.copyWith(archivedAt: const Value(null)).save();
    } else {
      // Archive: set archivedAt to current time
      await activity.delete();
    }
    return const CommandDone();
  }
}

abstract class _UpdateActivityCommand extends Command {
  _UpdateActivityCommand(
    this.activity, {
    Future<void> Function(Activity)? onUpdate,
    required super.title,
    required super.eventObject,
    required super.eventAction,
    super.icon,
  }) : onUpdate = onUpdate ?? ((activity) => activity.save());

  final Activity activity;
  final Future<void> Function(Activity) onUpdate;
}

class StartActivity extends _UpdateActivityCommand {
  StartActivity(super.activity, {super.onUpdate})
    : super(
        title: 'Do Now',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: PlotIcon.now,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final start = !activity.doNow;

    if (start) {
      // Starting the task - preserve existing scheduling type or default to date-based
      final hasDateTime = activity.at != null;

      await onUpdate(
        activity.copyWith(
          type: ActivityType.action,
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

    return const CommandDone();
  }
}

class FinishActivity extends _UpdateActivityCommand {
  FinishActivity(super.activity, {super.onUpdate})
    : super(
        title: 'Finish',
        eventObject: EventObject.activity,
        eventAction: EventAction.finished,
        icon: PlotIcon.done,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: Value(DateTime.now())));
    return const CommandDone();
  }
}

class ScheduleActivity extends _UpdateActivityCommand {
  ScheduleActivity(super.activity, {required this.when, super.onUpdate})
    : super(
        title: activity.todo ? 'Reschedule' : 'Schedule',
        eventObject: EventObject.activity,
        eventAction: activity.todo
            ? EventAction.rescheduled
            : EventAction.scheduled,
        icon: PlotIcon.later,
      );

  final Date when;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(
      activity.copyWith(
        type: ActivityType.action,
        on: Value(CustomDateRange(when, null)),
        at: const Value(null), // Clear any existing datetime scheduling
      ),
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
            final actionReturn = await ScheduleActivity(
              activity,
              when: date.toDate(),
            ).run(context);
            if (!context.mounted) return;
            Dialog.pop(context, Value(actionReturn));
          },
        ),
      );
}

class MarkActivityIncomplete extends _UpdateActivityCommand {
  MarkActivityIncomplete(super.activity, {super.onUpdate})
    : super(
        title: 'Mark Activity Not Finished',
        eventObject: EventObject.activity,
        eventAction: EventAction.unfinished,
        icon: PlotIcon.done,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: const Value(null)));
    return const CommandDone();
  }
}

class PinActivity extends _UpdateActivityCommand {
  PinActivity(super.activity, {super.onUpdate})
    : super(
        title: _isPinned(activity) ? 'Unpin' : 'Pin',
        eventObject: EventObject.activity,
        eventAction: _isPinned(activity)
            ? EventAction.unpinned
            : EventAction.pinned,
        icon: PlotIcon.pinned,
      );

  static bool _isPinned(Activity activity) {
    return activity.hasTag(Tag.pinned);
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updatedActivity = activity.toggleTag(Tag.pinned);
    await onUpdate(updatedActivity);
    return const CommandDone();
  }
}

class ToggleActivityTag extends _UpdateActivityCommand {
  ToggleActivityTag(super.activity, this.tag, {super.onUpdate})
    : super(
        title: tag.name,
        eventObject: EventObject.activity,
        eventAction: activity.hasTag(tag)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: tag.icon,
      );

  final Tag tag;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (tag == Tag.later) {
      await PickScheduleActivity(activity).run(context);
      return const CommandDone();
    }

    final updatedActivity = activity.toggleTag(tag);
    await onUpdate(updatedActivity);
    return const CommandDone();
  }
}

class MoveToPriority extends PriorityCommand {
  MoveToPriority(this.activity, Priority priority)
    : super(
        priority,
        eventObject: EventObject.activity,
        eventAction: EventAction.moved,
      );

  final Activity activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await activity.copyWith(priority: priority!).save();
    return const CommandDone();
  }
}

class MoveActivityToPriority extends ShowCommands {
  MoveActivityToPriority(this.activity)
    : super(
        title: 'Move',
        icon: PlotIcon.move,
        commands: (context) => _getMoveCommands(activity),
      );

  final Activity activity;

  static Future<Commands> _getMoveCommands(Activity activity) async {
    final priorities = await Priority.get(order: PriorityOrder.recent);
    final filteredPriorities = priorities
        .where((p) => p.id != activity.priority.id)
        .toList();

    return Commands(
      prompt: 'Move to Priority',
      groups: [
        StaticCommandGroup(
          title: 'Priorities',
          commands: filteredPriorities
              .map((priority) => MoveToPriority(activity, priority))
              .toList(),
        ),
      ],
      secondaryCommand: (prompt) => NewPriority(parent: activity.priority),
    );
  }
}

class ShowActivityCommands extends ShowCommands {
  ShowActivityCommands(Activity activity, {bool open = true})
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) => Future.value(
          Commands(groups: activityCommandGroups(activity, open: open)),
        ),
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

// Focus navigation intents and actions for list items

class MoveFocusUpIntent extends Intent {
  const MoveFocusUpIntent();
}

class MoveFocusDownIntent extends Intent {
  const MoveFocusDownIntent();
}

class OpenFocusedItemActionsIntent extends Intent {
  const OpenFocusedItemActionsIntent();
}

class ClearItemFocusIntent extends Intent {
  const ClearItemFocusIntent();
}

class MoveFocusUp extends Command {
  MoveFocusUp(this.controller)
    : super(
        title: 'Move Focus Up',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        icon: PlotIcon.up,
      );

  final BidirectionalListController controller;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    controller.moveFocus(-1);
    return const CommandSkipped();
  }
}

class MoveFocusDown extends Command {
  MoveFocusDown(this.controller)
    : super(
        title: 'Move Focus Down',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        icon: PlotIcon.down,
      );

  final BidirectionalListController controller;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    controller.moveFocus(1);
    return const CommandSkipped();
  }
}

class ClearItemFocus extends Command {
  ClearItemFocus(this.controller, {this.onCleared})
    : super(
        title: 'Clear Item Focus',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
      );

  final BidirectionalListController controller;
  final VoidCallback? onCleared;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    controller.clearFocus();
    // Call optional callback (e.g., to focus ActivityEditor)
    onCleared?.call();
    return const CommandSkipped();
  }
}

class OpenFocusedItemActions extends ShowCommands {
  OpenFocusedItemActions(
    BidirectionalListController controller,
    List<StaticCommandGroup> Function(int index) actionBuilder,
  ) : _controller = controller,
      super(
        title: 'Open Actions for Focused Item',
        commands: (context) async {
          final focusedIndex = controller.focusedIndex;
          if (focusedIndex == null) {
            return Commands(groups: []);
          }
          return Commands(groups: actionBuilder(focusedIndex));
        },
      );

  final BidirectionalListController _controller;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Get currently focused index
    final focusedIndex = _controller.focusedIndex;

    if (focusedIndex == null) {
      return const CommandSkipped();
    }

    // Store the focused node for restoration after menu closes
    final focusedNode = _controller.getFocusNode(focusedIndex);

    // Call parent to show actions
    final result = await super.run(context);

    // Restore focus after menu closes
    if (context.mounted) {
      focusedNode.requestFocus();
    }

    return result;
  }
}

List<StaticCommandGroup> activityCommandGroups(
  Activity activity, {
  bool open = true,
}) {
  final tags = Tag.getAll()
      .where(
        (tag) =>
            activity.type != ActivityType.event ||
            [Tag.now, Tag.later].contains(tag),
      )
      .map((tag) => ToggleActivityTag(activity, tag))
      .toList();
  final commands = activityCommands(activity, open: open);
  final remove = tags
      .where(
        (cmd) => cmd.tag.type != TagType.compute && activity.hasTag(cmd.tag),
      )
      .toList();
  final add = tags
      .where(
        (cmd) => cmd.tag.type != TagType.compute && !activity.hasTag(cmd.tag),
      )
      .toList();
  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(title: 'Commands', commands: commands),
    if (remove.isNotEmpty)
      StaticCommandGroup(title: 'Remove Tag', commands: remove),
    if (add.isNotEmpty) StaticCommandGroup(title: 'Add Tag', commands: add),
  ];
}

List<Command> activityCommands(Activity activity, {bool open = true}) {
  final commands = Tag.getAll()
      .where((tag) => tag.type == TagType.compute)
      .map((tag) => ToggleActivityTag(activity, tag))
      .toList();
  return [
    if (open) ChangeCurrentActivity(activity),
    MoveActivityToPriority(activity),
    ...commands,
  ];
}
