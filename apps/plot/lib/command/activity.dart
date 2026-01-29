import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/platform.dart';
import 'logging.dart';

abstract class ActivityCommand extends Command {
  ActivityCommand(
    this.activity, {
    required super.eventObject,
    required super.eventAction,
    super.icon,
    String? title,
  }) : super(title: title ?? activity?.displayTitle ?? 'None', subtitle: '');

  final Activity? activity;

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: context.theme.typography.base.copyWith(
              color: context.theme.colors.foreground,
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
        title: 'Open',
        icon: PlotIcon.open,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Read blocs once to avoid multiple lookups
    final priorityBloc = context.read<PriorityBloc>();
    final nowBloc = context.read<NowBloc>();

    // Get the currently viewed priority before making any changes
    final currentPriority = priorityBloc.state.context;

    // Update PriorityBloc to track current activity for navigation
    priorityBloc.setActivity(activity);

    if (activity == null) {
      // Update NowBloc to match the current priority being viewed
      nowBloc.setFocus(currentPriority);

      // Navigate to just the PriorityRoute without ActivityRoute
      return CommandRoute(
        PriorityRoute(priorityIdString: currentPriority.id.toShortString()),
      );
    }

    // Update NowBloc to the activity's priority (what user is working on)
    nowBloc.setFocus(activity!.priority);

    // Navigate using the CURRENT priority (not activity's priority)
    // This keeps PriorityPage showing the parent priority
    final route = PriorityRoute(
      priorityIdString: currentPriority.id.toShortString(),
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
        icon: PlotIcon.addNote,
        shortcut: SingleActivator(LogicalKeyboardKey.keyN, meta: true),
      );

  @override
  bool enabled(BuildContext context) {
    // Disable when already on the new activity page
    return context.router.current.name != NewActivityRoute.name;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final priorityId = priorityBloc.state.context.id;
    return CommandRoute(
      PriorityRoute(
        priorityIdString: priorityId.toShortString(),
        children: [NewActivityRoute()],
      ),
    );
  }
}

class NewAction extends Command {
  NewAction()
    : super(
        title: "New Action",
        eventObject: EventObject.activity,
        eventAction: EventAction.opened,
        icon: PlotIcon.add,
        shortcut: SingleActivator(LogicalKeyboardKey.keyT, meta: true),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final priorityId = priorityBloc.state.context.id;
    return CommandRoute(
      PriorityRoute(
        priorityIdString: priorityId.toShortString(),
        children: [NewActivityRoute(activityType: 'action')],
      ),
    );
  }
}

class NewEvent extends Command {
  NewEvent({
    required this.priority,
    required this.startTime,
    required this.duration,
  }) : super(
         title: "New Event",
         eventObject: EventObject.activity,
         eventAction: EventAction.opened,
         icon: PlotIcon.add,
       );

  final Priority priority;
  final DateTime startTime;
  final Duration duration;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(
      PriorityRoute(
        priorityIdString: priority.id.toShortString(),
        children: [
          NewActivityRoute(
            startTime: startTime.toIso8601String(),
            duration: duration.inMinutes,
            priorityId: priority.id.toShortString(),
          ),
        ],
      ),
    );
  }
}

class OpenNextActivity extends Command {
  OpenNextActivity()
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

        final activity = item.when<Activity?>(
          header: (header) => null,
          activity: (agendaActivity) => agendaActivity.activity,
        );
        if (activity != null) {
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

class OpenPreviousActivity extends Command {
  OpenPreviousActivity()
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

        final activity = item.when<Activity?>(
          header: (header) => null,
          activity: (agendaActivity) => agendaActivity.activity,
        );
        if (activity != null) {
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
    final activity = await _activity;

    // Save the activity directly
    await activity.copyWith(draft: false).save();

    // Only navigate if requested
    if (!navigate) {
      return const CommandDone();
    }

    var routePriority = activity.priority;
    if (context.mounted) {
      final priorityBloc = context.read<PriorityBloc>();
      final nowBloc = context.read<NowBloc>();

      // Update PriorityBloc to track the new activity
      priorityBloc.setActivity(activity);

      // Get the currently displayed priority context to preserve it in navigation
      if (nowBloc.loadedState.context != null) {
        routePriority = nowBloc.loadedState.context!;
      }
    }

    return CommandRoute(
      PriorityRoute(
        priorityIdString: routePriority.id.toShortString(),
        children: [
          ActivityRoute(activityIdString: activity.id.toShortString()),
        ],
      ),
    );
  }
}

class AddActivityWithNote extends Command {
  AddActivityWithNote(this._data, {this.navigate = true})
    : super(
        title: 'Add',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final ActivityWithNote _data;
  final bool navigate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Add the activity (handles saving, note creation, title generation, and draft reset)
    final priorityBloc = context.read<PriorityBloc>();
    final savedActivity = await priorityBloc.add(
      _data.activity,
      note: _data.note,
    );

    // Only navigate if requested
    if (!navigate) {
      return const CommandDone();
    }

    // Get the currently displayed priority context to preserve it in navigation
    var routePriority = savedActivity.priority;
    if (context.mounted) {
      final nowBloc = context.read<NowBloc>();
      if (nowBloc.loadedState.context != null) {
        routePriority = nowBloc.loadedState.context!;
      }
    }

    return CommandRoute(
      PriorityRoute(
        priorityIdString: routePriority.id.toShortString(),
        children: [
          ActivityRoute(activityIdString: savedActivity.id.toShortString()),
        ],
      ),
    );
  }
}

class AddEvent extends Command {
  AddEvent(this._activity, this._note, {this.navigate = true})
    : super(
        title: 'Add',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final Activity _activity;
  final Note? _note;
  final bool navigate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Add the activity (handles saving, note creation, title generation, and draft reset)
    final priorityBloc = context.read<PriorityBloc>();
    final savedActivity = await priorityBloc.add(_activity, note: _note);

    // Only navigate if requested
    if (!navigate) {
      return const CommandDone();
    }

    // Get the currently displayed priority context to preserve it in navigation
    var routePriority = savedActivity.priority;
    if (context.mounted) {
      final nowBloc = context.read<NowBloc>();
      if (nowBloc.loadedState.context != null) {
        routePriority = nowBloc.loadedState.context!;
      }
    }

    return CommandRoute(
      PriorityRoute(
        priorityIdString: routePriority.id.toShortString(),
        children: [
          ActivityRoute(activityIdString: savedActivity.id.toShortString()),
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
    super.subtitle,
    super.icon,
    super.hoverIcon,
  }) : onUpdate = onUpdate ?? ((activity) => activity.save());

  final Activity activity;
  final Future<void> Function(Activity) onUpdate;
}

class ToggleAction extends _UpdateActivityCommand {
  ToggleAction(super.activity, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'Do Now',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: stateIcon ? activity.icon : PlotIcon.now,
        hoverIcon: stateIcon ? PlotIcon.now : null,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final start = !activity.doNow;

    if (start) {
      await onUpdate(
        activity.copyWith(
          type: ActivityType.action,
          on: Value(CustomDateRange(Date.today(), null)),
          order: Order.first(),
          doneAt: const Value(null),
        ),
      );
    } else {
      // Stopping the task - clear scheduling
      await onUpdate(
        activity.copyWith(
          type: .note,
          on: const Value(null),
          at: const Value(null),
        ),
      );
    }

    return const CommandDone();
  }
}

class StartAction extends _UpdateActivityCommand {
  StartAction(super.activity, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'Do Now',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: stateIcon ? activity.icon : PlotIcon.now,
        hoverIcon: stateIcon ? PlotIcon.now : null,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(
      activity.copyWith(
        type: ActivityType.action,
        // If already has datetime scheduling, use current time; otherwise use date-based
        on: Value(activity.on ?? CustomDateRange(Date.today(), null)),
        at: Value(null),
        order: Order.first(),
        doneAt: const Value(null),
      ),
    );

    return const CommandDone();
  }
}

class FinishAction extends _UpdateActivityCommand {
  FinishAction(super.activity, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'Mark Done',
        eventObject: EventObject.activity,
        eventAction: EventAction.finished,
        icon: stateIcon && activity.doNow
            ? FontAwesomeIcons.circle
            : FontAwesomeIcons.circleCheck,
        hoverIcon: stateIcon && activity.doNow
            ? FontAwesomeIcons.circleCheck
            : null,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(activity.copyWith(doneAt: Value(DateTime.now())));
    return const CommandDone();
  }
}

class ActorGroup extends CommandGroup {
  ActorGroup({required this.priorityId, required this.builder});

  final Uuid priorityId;
  final Command Function(Actor? actor) builder;

  @override
  Future<List<Command>> list({String? search}) async {
    final actors = await Actor.get(
      priorityId: priorityId,
      types: [ActorType.user, ActorType.contact],
      search: search, // Backend search by name/email
      limit: 50,
    );

    return [
      builder(null), // Unassign option
      ...actors.map((actor) => builder(actor)),
    ];
  }
}

class AssignAction extends _UpdateActivityCommand {
  final Actor? assignee;
  final bool stateIcon;

  AssignAction(
    super.activity, {
    required this.assignee,
    super.onUpdate,
    this.stateIcon = false,
  }) : super(
         title: assignee?.name ?? 'Unassign',
         subtitle: assignee?.email,
         eventObject: EventObject.activity,
         eventAction: EventAction.updated,
         icon: assignee != null
             ? FontAwesomeIcons.circleUser
             : FontAwesomeIcons.circleUserCircleXmark,
       );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final actor = assignee; // Create local variable for null safety

    if (actor == null) {
      // Unassign: clear assigneeId, on, and at
      await onUpdate(
        activity.copyWith(
          assigneeId: null,
          on: const Value(null),
          at: const Value(null),
        ),
      );
    } else {
      // Assign to selected actor
      await onUpdate(
        activity.copyWith(
          assigneeId: actor.id,
          type: ActivityType.action,
          on: Value(activity.on ?? CustomDateRange(Date.today(), null)),
          at: Value(null),
          order: Order.first(),
          doneAt: const Value(null),
        ),
      );
    }

    return const CommandDone();
  }
}

class PickActionAssignee extends ShowCommands {
  PickActionAssignee(this.activity, {this.onUpdate, this.stateIcon = false})
    : super(
        title: 'Assign',
        icon: stateIcon ? activity.icon : FontAwesomeIcons.circleUserCirclePlus,
        hoverIcon: stateIcon ? FontAwesomeIcons.circleUserCirclePlus : null,
        commands: (context) => _getAssigneeCommands(activity, onUpdate),
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Activity activity;
  final Future<void> Function(Activity)? onUpdate;
  final bool stateIcon;

  static Future<Commands> _getAssigneeCommands(
    Activity activity,
    Future<void> Function(Activity)? onUpdate,
  ) async {
    return Commands(
      prompt: 'Assign to',
      groups: [
        ActorGroup(
          priorityId: activity.priority.id,
          builder: (actor) =>
              AssignAction(activity, assignee: actor, onUpdate: onUpdate),
        ),
      ],
    );
  }
}

class ScheduleAction extends _UpdateActivityCommand {
  ScheduleAction(super.activity, {required this.when, super.onUpdate})
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
        doneAt: const Value(null), // Mark as not done if previously done
      ),
    );
    return const CommandDone();
  }
}

class ScheduleEvent extends _UpdateActivityCommand {
  ScheduleEvent(super.activity, {required this.at, super.onUpdate})
    : super(
        title: activity.type == .event ? 'Reschedule' : 'Schedule',
        eventObject: EventObject.activity,
        eventAction: activity.type == .event
            ? EventAction.rescheduled
            : EventAction.scheduled,
        icon: PlotIcon.event,
      );

  final DateTimeRange at;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(
      activity.copyWith(
        type: ActivityType.event,
        at: Value(at),
        on: const Value(null), // Clear any existing datetime scheduling
      ),
    );
    return const CommandDone();
  }
}

class RescheduleEvent extends Command {
  RescheduleEvent(
    this.activity, {
    bool stateIcon = false,
    this.showPrioritySelector = false,
  }) : super(
         title: 'Reschedule',
         eventObject: EventObject.activity,
         eventAction: EventAction.rescheduled,
         icon: stateIcon ? PlotIcon.event : PlotIcon.reschedule,
         hoverIcon: stateIcon ? PlotIcon.reschedule : null,
       );

  final Activity activity;
  final bool showPrioritySelector;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await Modal(
      builder: (modalContext) => RescheduleEventModal(
        activity: activity,
        showPrioritySelector: showPrioritySelector,
      ),
    ).show<DateTimeRange>(context);

    if (result.present && context.mounted) {
      // User confirmed rescheduling with new time
      await ScheduleEvent(activity, at: result.value).run(context);
      return const CommandDone();
    }

    return const CommandSkipped();
  }
}

/// RSVP Attend command - shown when user hasn't RSVP'd or is undecided
class RsvpAttend extends Command {
  RsvpAttend(this.activity, {bool stateIcon = false})
    : super(
        title: 'Attend',
        eventObject: EventObject.activity,
        eventAction: EventAction.tagged,
        icon: stateIcon ? activity.icon : PlotIcon.calendarPlus,
      );

  final Activity activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return await ToggleActivityTag(activity, Tag.attend).run(context);
  }
}

/// RSVP Skip command - shown when user has RSVP'd attend
class RsvpSkip extends Command {
  RsvpSkip(this.activity, {bool stateIcon = false})
    : super(
        title: 'Skip',
        eventObject: EventObject.activity,
        eventAction: EventAction.tagged,
        icon: PlotIcon.event,
        hoverIcon: PlotIcon.calendarXmark,
      );

  final Activity activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return await ToggleActivityTag(activity, Tag.skip).run(context);
  }
}

/// RSVP Re-attend command - shown when user has RSVP'd skip
class RsvpReattend extends Command {
  RsvpReattend(this.activity, {bool stateIcon = false})
    : super(
        title: 'Attend',
        eventObject: EventObject.activity,
        eventAction: EventAction.tagged,
        icon: PlotIcon.calendarXmark,
        hoverIcon: PlotIcon.calendarCheck,
      );

  final Activity activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return await ToggleActivityTag(activity, Tag.attend).run(context);
  }
}

class UnscheduleEvent extends _UpdateActivityCommand {
  UnscheduleEvent(super.activity, {super.onUpdate})
    : super(
        title: 'Unschedule',
        eventObject: EventObject.activity,
        eventAction: EventAction.unscheduled,
        icon: PlotIcon.event,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(activity.copyWith(type: .note, at: const Value(null)));
    return const CommandDone();
  }
}

class UnscheduleAction extends _UpdateActivityCommand {
  UnscheduleAction(super.activity, {super.onUpdate})
    : super(
        title: 'Do Someday',
        eventObject: EventObject.activity,
        eventAction: EventAction.unscheduled,
        icon: PlotIcon.someday,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(
      activity.copyWith(
        type: .action,
        on: const Value(null),
        at: const Value(null),
      ),
    );
    return const CommandDone();
  }
}

class PickScheduleActivity extends ShowPage {
  PickScheduleActivity(Activity activity)
    : super(
        title: activity.doLater ? 'Reschedule' : 'Schedule to Do Later',
        icon: PlotIcon.later,
        builder: (context) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Schedule Action',
                  style: context.theme.typography.xl2.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FCalendar(
                control: .managedDate(
                  controller: FCalendarController.date(
                    selectable: (date) {
                      final today = DateTime.now();
                      final todayStart = DateTime(
                        today.year,
                        today.month,
                        today.day,
                      );
                      final dateStart = DateTime(
                        date.year,
                        date.month,
                        date.day,
                      );
                      return !dateStart.isBefore(todayStart);
                    },
                  ),
                ),
                style: (style) =>
                    style.copyWith(decoration: const BoxDecoration()),
                onPress: (date) async {
                  final actionReturn = await ScheduleAction(
                    activity,
                    when: date.toDate(),
                  ).run(context);
                  if (!context.mounted) return;
                  Modal.pop(context, Value(actionReturn));
                },
              ),
            ],
          ),
        ),
      );
}

class ActivityToNote extends _UpdateActivityCommand {
  ActivityToNote(super.activity, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'Convert to Note',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: stateIcon ? activity.icon : PlotIcon.note,
        hoverIcon: stateIcon ? PlotIcon.note : null,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onUpdate(
      activity.copyWith(
        type: .note,
        at: const Value(null),
        on: const Value(null),
        doneAt: const Value(null),
      ),
    );
    return const CommandDone();
  }
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

class MoveToNewThread extends Command {
  MoveToNewThread(this.activity)
    : super(
        title: 'Move to New Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.moved,
        icon: PlotIcon.move,
      );

  final Activity activity;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Get PriorityBloc before async operations
    final priorityBloc = context.read<PriorityBloc>();

    // Note: Thread functionality has been removed. This command is now a no-op.
    // Keeping it for compatibility but it doesn't change the activity.
    await activity.save();

    // Update PriorityBloc to track the activity as current
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

class EnterReorderMode extends Command {
  EnterReorderMode()
    : super(
        title: 'Reorder',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: FontAwesomeIcons.gripDotsVertical,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().setReorderMode(true);
    return const CommandDone();
  }
}

class MoveActivityToPriority extends ShowCommands {
  MoveActivityToPriority(this.activity)
    : super(
        title: 'Move to Another Priority',
        icon: PlotIcon.move,
        shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
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
          Commands(
            groups: activityCommandGroups(
              activity,
              open: open,
              isTouchDevice: !hasPhysicalKeyboard(),
            ),
          ),
        ),
      );
}

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
  bool isTouchDevice = false,
}) {
  final tags = Tag.getAll()
      .where(
        (tag) =>
            activity.type != ActivityType.event ||
            ![Tag.now, Tag.later, Tag.done].contains(tag),
      )
      .map((tag) => ToggleActivityTag(activity, tag))
      .toList();
  final commands = activityCommands(
    activity,
    open: open,
    isTouchDevice: isTouchDevice,
  );
  final remove = tags
      .where(
        (cmd) => cmd.tag.type != TagType.compute && activity.hasTag(cmd.tag),
      )
      .toList();
  final add = tags
      .where(
        (cmd) =>
            cmd.tag.addable == true &&
            cmd.tag.type != TagType.compute &&
            !activity.hasTag(cmd.tag),
      )
      .toList();
  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(
        title: 'Activity: ${activity.title}',
        commands: commands,
      ),
    if (remove.isNotEmpty)
      StaticCommandGroup(title: 'Remove Tag', commands: remove),
    if (add.isNotEmpty) StaticCommandGroup(title: 'Add Tag', commands: add),
  ];
}

List<Command> activityCommands(
  Activity activity, {
  bool open = false,
  bool skipInfrequent = false,
  bool skipPrimary = false,
  bool isTouchDevice = false,
}) {
  final primary = skipPrimary
      ? null
      : primaryActivityCommand(activity, stateIcon: false);
  // For checks, use the actual primary command (not the nullable primary variable)
  final actualPrimary = primaryActivityCommand(activity, stateIcon: false);
  return [
    if (open) ChangeCurrentActivity(activity),
    ?primary,
    // Add reschedule to commands list for events when not the primary command
    if (activity.type == .event && actualPrimary is! RescheduleEvent)
      RescheduleEvent(activity),
    if (activity.type != .event &&
        !activity.doNow &&
        actualPrimary is! StartAction)
      StartAction(activity),
    if (activity.type != .event && actualPrimary is! PickScheduleActivity)
      PickScheduleActivity(activity),
    if (activity.type != .event &&
        !activity.doSomeday &&
        actualPrimary is! UnscheduleAction)
      UnscheduleAction(activity),
    if (activity.type != .event &&
        !activity.done &&
        actualPrimary is! FinishAction)
      FinishAction(activity),
    if (activity.type != .event && actualPrimary is! PickActionAssignee)
      PickActionAssignee(activity),
    MoveActivityToPriority(activity),
    if (isTouchDevice) EnterReorderMode(),
    if (activity.type != .note && !skipInfrequent) ActivityToNote(activity),
    if (!skipInfrequent) ArchiveActivity(activity),
  ];
}

/// Returns up to 3 tag suggestions for quick actions.
/// The number shown is reduced by the count of non-hardcoded tags already on the activity.
/// Takes from tagSuggestions list which is pre-sorted (common tags first, then all others).
List<Command> topActivityTags(Activity activity, List<Tag> tagSuggestions) {
  // Count non-hardcoded tags already on activity
  final activeNonHardcodedCount = tagSuggestions
      .where((tag) => activity.hasTag(tag))
      .length;

  // Calculate how many tags to show: 3 minus active non-hardcoded tags
  final maxToShow = 3 - activeNonHardcodedCount;
  if (maxToShow <= 0) return [];

  // Filter out tags already on activity and take maxToShow
  return tagSuggestions
      .where((tag) => !activity.hasTag(tag))
      .take(maxToShow)
      .map((tag) => ToggleActivityTag(activity, tag))
      .toList();
}

/// Returns the primary command for an activity based on its current state.
/// This is shown as the leading command in ActivityWidget and as the primary action in ActivityPage header.
/// Use `selected: true` on the button when activity.doNow.
Command primaryActivityCommand(Activity activity, {bool stateIcon = true}) {
  if (activity.type == ActivityType.note ||
      activity.doSomeday ||
      activity.done) {
    return StartAction(activity, stateIcon: stateIcon);
  } else if (activity.type == ActivityType.event) {
    // Check RSVP state for events with different authors
    if (activity.shouldShowRsvpPlus) {
      return RsvpAttend(activity, stateIcon: stateIcon);
    } else if (activity.currentUserRsvpAttend) {
      return RsvpSkip(activity, stateIcon: stateIcon);
    } else if (activity.currentUserRsvpSkip) {
      return RsvpReattend(activity, stateIcon: stateIcon);
    }
    // Default to reschedule for self-authored events and other cases
    return RescheduleEvent(activity, stateIcon: stateIcon);
  } else if (activity.assigneeId != null &&
      !activity.assigneeId!.isCurrentUser) {
    return PickActionAssignee(activity, stateIcon: stateIcon);
  } else if (activity.doNow) {
    return FinishAction(activity, stateIcon: stateIcon);
  } else if (activity.doLater) {
    return PickScheduleActivity(activity);
  } else {
    // Fallback for actions that are not scheduled and not done
    return StartAction(activity, stateIcon: stateIcon);
  }
}
