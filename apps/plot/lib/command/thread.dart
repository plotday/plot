import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'logging.dart';

/// Holds data for creating a new Thread with its first Note
class ThreadWithNote {
  ThreadWithNote({required this.thread, this.note});

  final Thread thread;
  final Note? note;
}

abstract class ThreadCommand extends Command {
  ThreadCommand(
    this.thread, {
    required super.eventObject,
    required super.eventAction,
    super.icon,
    String? title,
  }) : super(title: title ?? thread?.displayTitle ?? 'None', subtitle: '');

  final Thread? thread;

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

class ChangeCurrentThread extends ThreadCommand {
  ChangeCurrentThread(super.thread)
    : super(
        eventObject: EventObject.activity,
        eventAction: thread == null ? EventAction.closed : EventAction.opened,
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

    // Propagate the list source from the widget tree (if available).
    // When tapped from a list, the BuildContext is inside a
    // ThreadListSourceProvider. When called from Next/Previous commands
    // or URL navigation, source will be null (preserving existing source).
    final source = ThreadListSourceProvider.maybeOf(context);
    priorityBloc.setThread(thread, source: source);

    if (thread == null) {
      // Update NowBloc to match the current priority being viewed
      nowBloc.setFocus(currentPriority);

      // Navigate to just the PriorityRoute without ThreadRoute
      return CommandRoute(
        PriorityRoute(priorityIdString: currentPriority.id.toShortString()),
      );
    }

    // Update NowBloc to the thread's priority (what user is working on)
    nowBloc.setFocus(thread!.priority);

    // Navigate using the CURRENT priority (not thread's priority)
    // This keeps PriorityPage showing the parent priority
    final route = PriorityRoute(
      priorityIdString: currentPriority.id.toShortString(),
      children: [ThreadRoute(threadIdString: thread!.id.toShortString())],
    );

    return CommandRoute(route);
  }
}

class NewThread extends Command {
  NewThread()
    : super(
        title: "New Thread",
        eventObject: EventObject.activity,
        eventAction: EventAction.opened,
        icon: PlotIcon.addNote,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyN,
          shift: kIsWeb,
        ),
      );

  @override
  bool enabled(BuildContext context) {
    // Disable when already on the new thread page
    return context.router.current.name != NewThreadRoute.name;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final priorityId = priorityBloc.state.context.id;
    return CommandRoute(
      PriorityRoute(
        priorityIdString: priorityId.toShortString(),
        children: [NewThreadRoute()],
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
          NewThreadRoute(
            startTime: startTime.toIso8601String(),
            duration: duration.inMinutes,
            priorityId: priority.id.toShortString(),
          ),
        ],
      ),
    );
  }
}

class OpenNextThread extends Command {
  OpenNextThread()
    : super(
        title: 'Next Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.arrowDown,
        ),
        icon: PlotIcon.next,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final priorityBloc = context.read<PriorityBloc>();
      final source = priorityBloc.resolveThreadListSource();

      // Search for next root thread in the resolved list
      int offset = 1;
      while (offset < 100) {
        // Safety limit
        final item = source == ThreadListSource.agenda
            ? priorityBloc.getAgendaItem(offset)
            : priorityBloc.getActivityFeedItem(offset);
        if (item == null) {
          return const CommandSkipped();
        }

        final activity = item.when<Thread?>(
          header: (header) => null,
          activity: (agendaActivity) => agendaActivity.thread,
        );
        if (activity != null) {
          return ChangeCurrentThread(activity).run(context);
        }
        offset++;
      }

      return const CommandSkipped();
    } catch (e, stackTrace) {
      log.severe('Error in NextThread: $e', e, stackTrace);
      return const CommandSkipped();
    }
  }
}

class OpenPreviousThread extends Command {
  OpenPreviousThread()
    : super(
        title: 'Previous Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.arrowUp,
        ),
        icon: PlotIcon.previous,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final priorityBloc = context.read<PriorityBloc>();
      final source = priorityBloc.resolveThreadListSource();

      // Search for previous root thread in the resolved list
      int offset = -1;
      while (offset > -100) {
        // Safety limit
        final item = source == ThreadListSource.agenda
            ? priorityBloc.getAgendaItem(offset)
            : priorityBloc.getActivityFeedItem(offset);
        if (item == null) {
          return const CommandSkipped();
        }

        final activity = item.when<Thread?>(
          header: (header) => null,
          activity: (agendaActivity) => agendaActivity.thread,
        );
        if (activity != null) {
          return ChangeCurrentThread(activity).run(context);
        }
        offset--;
      }

      return const CommandSkipped();
    } catch (e, stackTrace) {
      log.severe('Error in PreviousThread: $e', e, stackTrace);
      return const CommandSkipped();
    }
  }
}

class AddThread extends Command {
  AddThread(this._thread, {this.navigate = true})
    : super(
        title: 'Create Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final Future<Thread> _thread;
  final bool navigate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final thread = await _thread;

    // Save the thread directly
    await thread.copyWith(draft: false).save();

    // Only navigate if requested
    if (!navigate) {
      return const CommandDone();
    }

    if (context.mounted) {
      final priorityBloc = context.read<PriorityBloc>();

      // Update PriorityBloc to track the new thread
      priorityBloc.setThread(thread);

      // Replace NewThreadRoute with ThreadRoute on the inner stack
      await context.router.replace(
        ThreadRoute(threadIdString: thread.id.toShortString()),
      );
    }

    return const CommandDone();
  }
}

class AddThreadWithNote extends Command {
  AddThreadWithNote(this._data, {this.navigate = true})
    : super(
        title: 'Add',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final ThreadWithNote _data;
  final bool navigate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Add the thread (handles saving, note creation, title generation, and draft reset)
    final priorityBloc = context.read<PriorityBloc>();
    final savedThread = await priorityBloc.add(_data.thread, note: _data.note);

    // Only navigate if requested
    if (!navigate) {
      return const CommandDone();
    }

    // Replace NewThreadRoute with ThreadRoute on the inner stack
    if (context.mounted) {
      await context.router.replace(
        ThreadRoute(threadIdString: savedThread.id.toShortString()),
      );
    }

    return const CommandDone();
  }
}

class AddThreadWithLink extends Command {
  AddThreadWithLink({required this.linkUrl, required this.linkTitle})
    : super(
        title: 'Add Link',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
        icon: PlotIcon.link,
      );

  final String linkUrl;
  final String? linkTitle;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final draft = priorityBloc.state.draft;

    // Set the thread title to the fetched page title or the URL
    final threadTitle = linkTitle ?? linkUrl;
    final thread = draft.copyWith(title: Value(threadTitle));

    // Save the thread via PriorityBloc.add (handles draft reset)
    final savedThread = await priorityBloc.add(thread);

    // Create and save the link row
    final now = DateTime.now();
    final linkRow = LinkRow(
      id: Uuid.generate(),
      createdAt: now,
      updatedAt: now,
      threadId: savedThread.id,
      sourceCreatedAt: now,
      sourceUrl: linkUrl,
      title: linkTitle,
    );
    await Store.get.save(Store.get.links, linkRow, LinksBase());

    // Navigate to the new thread
    if (context.mounted) {
      await context.router.replace(
        ThreadRoute(threadIdString: savedThread.id.toShortString()),
      );
    }

    return const CommandDone();
  }
}

class ArchiveThread extends Command {
  ArchiveThread(Thread thread)
    : _thread = Future.value(thread),
      super(
        title: thread.archivedAt != null ? 'Un-archive' : 'Archive',
        eventObject: EventObject.activity,
        eventAction: thread.archivedAt != null
            ? EventAction.unarchived
            : EventAction.archived,
        icon: PlotIcon.archived,
      );

  ArchiveThread.future(this._thread)
    : super(
        title: 'Archive',
        eventObject: EventObject.activity,
        eventAction: EventAction.archived,
        icon: PlotIcon.archived,
      );

  final Future<Thread> _thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final thread = await _thread;
    final isArchived = thread.archivedAt != null;

    if (isArchived) {
      // Un-archive: set archivedAt to null
      await thread.copyWith(archivedAt: const Value(null)).save();
    } else {
      // Archive: set archivedAt to current time
      await thread.delete();
    }
    return const CommandDone();
  }
}

abstract class _UpdateThreadCommand extends Command {
  _UpdateThreadCommand(
    this.thread, {
    Future<void> Function(Thread)? onUpdate,
    required super.title,
    required super.eventObject,
    required super.eventAction,
    super.icon,
    super.hoverIcon,
  }) : onUpdate = onUpdate ?? ((thread) => thread.save());

  final Thread thread;
  final Future<void> Function(Thread) onUpdate;

  /// Optimistically update the UI, then persist the thread.
  Future<void> saveOptimistically(
    BuildContext context,
    Thread updatedThread,
  ) async {
    context.read<PriorityBloc?>()?.optimisticallyUpdateThread(updatedThread);
    await onUpdate(updatedThread);
  }
}

class ToggleThreadToDo extends _UpdateThreadCommand {
  ToggleThreadToDo(super.thread, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'To Do',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: stateIcon
            ? PlotIcon.note
            : thread.todo
            ? PlotIcon.todo
            : PlotIcon.addTodo,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.toggleTag(Tag.todo));
    return const CommandDone();
  }
}

class ThreadToDo extends _UpdateThreadCommand {
  ThreadToDo(super.thread, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'To Do',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: stateIcon ? PlotIcon.note : PlotIcon.todo,
        hoverIcon: stateIcon ? PlotIcon.todo : null,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.toggleTag(Tag.todo));
    return const CommandDone();
  }
}

class ThreadDone extends _UpdateThreadCommand {
  ThreadDone(
    super.thread, {
    super.onUpdate,
    bool stateIcon = false,
    this.setDoneAt = true,
  }) : super(
         title: 'Done',
         eventObject: EventObject.activity,
         eventAction: EventAction.finished,
         icon: stateIcon && thread.todo
             ? FontAwesomeIcons.circle
             : FontAwesomeIcons.circleCheck,
         hoverIcon: stateIcon && thread.todo
             ? FontAwesomeIcons.circleCheck
             : null,
       );

  final bool setDoneAt;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Optimistic removal for instant UI feedback
    context.read<PriorityBloc?>()?.optimisticallyRemoveThread(thread.id);
    HapticFeedback.mediumImpact();
    // Clear dates to mark as done; setDoneAt controls whether doneAt is set
    await onUpdate(thread.toggleTag(Tag.done, setDoneAt: setDoneAt));
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

class ScheduleThread extends _UpdateThreadCommand {
  ScheduleThread(super.thread, {required this.when, super.onUpdate})
    : super(
        title: thread.on != null ? 'Reschedule' : 'Schedule',
        eventObject: EventObject.activity,
        eventAction: thread.on != null
            ? EventAction.rescheduled
            : EventAction.scheduled,
        icon: PlotIcon.schedule,
      );

  final Date when;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(
      context,
      thread.copyWith(
        on: Value(CustomDateRange(when, null)),
        at: const Value(null), // Clear any existing datetime scheduling
      ),
    );
    return const CommandDone();
  }
}

class ScheduleEvent extends _UpdateThreadCommand {
  ScheduleEvent(super.thread, {required this.at, super.onUpdate})
    : super(
        title: thread.at != null ? 'Reschedule' : 'Schedule',
        eventObject: EventObject.activity,
        eventAction: thread.at != null
            ? EventAction.rescheduled
            : EventAction.scheduled,
        icon: PlotIcon.event,
      );

  final DateTimeRange at;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(
      context,
      thread.copyWith(
        at: Value(at),
        on: const Value(null), // Clear any existing date-range scheduling
      ),
    );
    return const CommandDone();
  }
}

class RescheduleEvent extends Command {
  RescheduleEvent(
    this.thread, {
    bool stateIcon = false,
    this.showPrioritySelector = false,
  }) : super(
         title: 'Reschedule',
         eventObject: EventObject.activity,
         eventAction: EventAction.rescheduled,
         icon: stateIcon ? PlotIcon.event : PlotIcon.reschedule,
         hoverIcon: stateIcon ? PlotIcon.reschedule : null,
       );

  final Thread thread;
  final bool showPrioritySelector;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await Modal(
      builder: (modalContext) => RescheduleEventModal(
        activity: thread,
        showPrioritySelector: showPrioritySelector,
      ),
    ).show<DateTimeRange>(context);

    if (result.present && context.mounted) {
      // User confirmed rescheduling with new time
      await ScheduleEvent(thread, at: result.value).run(context);
      return const CommandDone();
    }

    return const CommandSkipped();
  }
}

class PickScheduleThread extends ShowPage {
  PickScheduleThread(Thread thread, {Future<void> Function(Thread)? onUpdate})
    : super(
        title: thread.on != null ? 'Reschedule' : 'Schedule',
        icon: PlotIcon.schedule,
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
                  final actionReturn = await ScheduleThread(
                    thread,
                    when: date.toDate(),
                    onUpdate: onUpdate,
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

class ToggleThreadTag extends _UpdateThreadCommand {
  ToggleThreadTag(super.thread, this.tag, {super.onUpdate})
    : super(
        title: tag.name,
        eventObject: EventObject.activity,
        eventAction: thread.hasTag(tag)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: tag.icon,
      );

  final Tag tag;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updatedThread = thread.toggleTag(tag);
    await saveOptimistically(context, updatedThread);
    return const CommandDone();
  }
}

class ToggleThreadPrivate extends _UpdateThreadCommand {
  ToggleThreadPrivate(super.thread, {super.onUpdate})
    : super(
        title: thread.private ? 'Make Public' : 'Make Private',
        eventObject: EventObject.activity,
        eventAction: thread.private ? EventAction.untagged : EventAction.tagged,
        icon: PlotIcon.private,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(
      context,
      thread.copyWith(private: !thread.private),
    );
    return const CommandDone();
  }
}

class MoveToPriority extends PriorityCommand {
  MoveToPriority(this.thread, Priority priority)
    : super(
        priority,
        eventObject: EventObject.activity,
        eventAction: EventAction.moved,
      );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await thread.copyWith(priority: priority!).save();
    return const CommandDone();
  }
}

class MoveToNewThread extends Command {
  MoveToNewThread(this.thread)
    : super(
        title: 'Move to New Thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.moved,
        icon: PlotIcon.move,
      );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Get PriorityBloc before async operations
    final priorityBloc = context.read<PriorityBloc>();

    // Note: Thread functionality has been removed. This command is now a no-op.
    // Keeping it for compatibility but it doesn't change the thread.
    await thread.save();

    // Update PriorityBloc to track the thread as current
    priorityBloc.setThread(thread);

    return CommandRoute(
      PriorityRoute(
        priorityIdString: thread.priority.id.toShortString(),
        children: [ThreadRoute(threadIdString: thread.id.toShortString())],
      ),
    );
  }
}

class MoveThreadToPriority extends ShowCommands {
  MoveThreadToPriority(this.thread)
    : super(
        title: 'Move to Another Priority',
        icon: PlotIcon.move,
        shortcut: platformSingleActivator(LogicalKeyboardKey.period),
        commandsBuilder: (context) => _getMoveCommands(thread),
      );

  final Thread thread;

  static Future<Commands> _getMoveCommands(Thread thread) async {
    final priorities = await Priority.get(order: PriorityOrder.recent);
    final filteredPriorities = priorities
        .where((p) => p.id != thread.priority.id)
        .toList();

    return Commands(
      prompt: 'Move to Priority',
      groups: [
        StaticCommandGroup(
          title: 'Priorities',
          commands: filteredPriorities
              .map((priority) => MoveToPriority(thread, priority))
              .toList(),
        ),
      ],
      secondaryCommand: (prompt) => NewPriority(parent: thread.priority),
    );
  }
}

class ShowThreadCommands extends ShowCommands {
  ShowThreadCommands(Thread thread, {bool open = true})
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: Commands(
          groups: threadCommandGroups(thread, open: open),
          prompt: thread.title ?? 'Thread',
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

class ToggleSearchIntent extends Intent {
  const ToggleSearchIntent();
}

class FocusAgendaIntent extends Intent {
  const FocusAgendaIntent();
}

class FocusActivityListIntent extends Intent {
  const FocusActivityListIntent();
}

class MoveFocusUp extends Command {
  MoveFocusUp(this.controller)
    : super(
        title: 'Move Focus Up',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        icon: PlotIcon.up,
      );

  final InfiniteListController controller;

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

  final InfiniteListController controller;

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

  final InfiniteListController controller;
  final VoidCallback? onCleared;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    controller.clearFocus();
    // Call optional callback (e.g., to focus ThreadEditor)
    onCleared?.call();
    return const CommandSkipped();
  }
}

class OpenFocusedItemActions extends ShowCommands {
  OpenFocusedItemActions(
    InfiniteListController controller,
    List<StaticCommandGroup> Function(int index) actionBuilder,
  ) : _controller = controller,
      super(
        title: 'Open Actions for Focused Item',
        commandsBuilder: (context) async {
          final focusedIndex = controller.focusedIndex;
          if (focusedIndex == null) {
            return Commands(groups: []);
          }
          return Commands(groups: actionBuilder(focusedIndex));
        },
      );

  final InfiniteListController _controller;

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

List<StaticCommandGroup> threadCommandGroups(
  Thread thread, {
  bool open = true,
}) {
  final tags = Tag.getAll().map((tag) => ToggleThreadTag(thread, tag)).toList();
  final commands = threadCommands(thread, open: open);
  final remove = tags
      .where((cmd) => cmd.tag.type != TagType.compute && thread.hasTag(cmd.tag))
      .toList();
  final add = tags
      .where(
        (cmd) =>
            cmd.tag.addable == true &&
            cmd.tag.type != TagType.compute &&
            !thread.hasTag(cmd.tag),
      )
      .toList();
  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(title: 'Thread: ${thread.title}', commands: commands),
    if (remove.isNotEmpty)
      StaticCommandGroup(title: 'Remove Tag', commands: remove),
    if (add.isNotEmpty) StaticCommandGroup(title: 'Add Tag', commands: add),
  ];
}

List<Command> threadCommands(
  Thread thread, {
  bool open = false,
  bool skipInfrequent = false,
  bool skipPrimary = false,
}) {
  final primary = skipPrimary
      ? null
      : primaryThreadCommand(thread, stateIcon: false);
  // For checks, use the actual primary command (not the nullable primary variable)
  final actualPrimary = primaryThreadCommand(thread, stateIcon: false);
  return [
    if (open) ChangeCurrentThread(thread),
    ?primary,
    if (actualPrimary is! PickScheduleThread) PickScheduleThread(thread),
    MoveThreadToPriority(thread),
    if (!skipInfrequent && !thread.priority.personal)
      ToggleThreadPrivate(thread),
    ArchiveThread(thread),
  ];
}

/// Returns up to 3 tag suggestions for quick actions.
/// The number shown is reduced by the count of non-hardcoded tags already on the thread.
/// Takes from tagSuggestions list which is pre-sorted (common tags first, then all others).
List<Command> topThreadTags(Thread thread, List<Tag> tagSuggestions) {
  // Count non-hardcoded tags already on thread
  final activeNonHardcodedCount = tagSuggestions
      .where((tag) => thread.hasTag(tag))
      .length;

  // Calculate how many tags to show: 3 minus active non-hardcoded tags
  final maxToShow = 3 - activeNonHardcodedCount;
  if (maxToShow <= 0) return [];

  // Filter out tags already on thread and take maxToShow
  return tagSuggestions
      .where((tag) => !thread.hasTag(tag))
      .take(maxToShow)
      .map((tag) => ToggleThreadTag(thread, tag))
      .toList();
}

/// Returns the primary command for a thread based on its current schedule state.
/// This is shown as the leading command in ThreadWidget and as the primary action in ThreadPage header.
/// Use `selected: true` on the button when thread.todo.
Command primaryThreadCommand(Thread thread, {bool stateIcon = true}) {
  if (thread.todo) {
    return ThreadDone(thread, stateIcon: stateIcon);
  } else if (thread.on != null) {
    // Thread has a date range (scheduled for later)
    return PickScheduleThread(thread);
  } else {
    // Unscheduled thread - offer to start
    return ThreadToDo(thread, stateIcon: stateIcon);
  }
}
