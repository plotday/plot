import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'logging.dart';

/// Holds data for creating a new Thread with its first Note
class ThreadWithNote {
  ThreadWithNote({required this.thread, this.note, this.assignNote = true});

  final Thread thread;
  final Note? note;

  /// Whether to assign the note to the current user (adding Tag.todo).
  /// True for task-type threads, false for note-type threads with todo.
  final bool assignNote;
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
    final layoutBloc = context.read<LayoutBloc>();

    // Get the currently viewed priority before making any changes
    final currentPriority = priorityBloc.state.context;
    final hadThread = priorityBloc.state.thread != null;

    // Propagate the list source from the widget tree (if available).
    // When tapped from a list, the BuildContext is inside a
    // ThreadListSourceProvider. When called from Next/Previous commands
    // or URL navigation, source will be null (preserving existing source).
    final source = ThreadListSourceProvider.maybeOf(context);
    priorityBloc.setThread(thread, source: source);

    // Prefer middle panel on resize when a thread is open
    layoutBloc.preferMiddle = thread != null;

    // Auto-slide panels when exactly one sidebar is visible
    final layoutState = layoutBloc.state;
    final exactlyTwoPanels =
        layoutState.multiPanel &&
        (layoutState.leftPanelVisible != layoutState.middlePanelVisible);
    if (exactlyTwoPanels) {
      if (thread != null && !hadThread) {
        // Opening thread from browsing → slide to Middle+Right
        layoutBloc.setPanelVisibility(left: false, middle: true);
      } else if (thread == null) {
        // Closing thread → slide back to Left+Right (browsing)
        layoutBloc.setPanelVisibility(left: true, middle: false);
      }
    }

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
    if (context.router.current.name == NewThreadRoute.name) return false;
    // Disable for viewer priorities
    final priority = context.read<PriorityBloc>().state.context;
    if (priority.isViewer) return false;
    return true;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final priorityId = priorityBloc.state.context.id;

    // Prefer middle panel on resize when new thread is open
    final layoutBloc = context.read<LayoutBloc>();
    layoutBloc.preferMiddle = true;

    // Auto-slide panels when exactly one sidebar is visible
    final layoutState = layoutBloc.state;
    final exactlyTwoPanels =
        layoutState.multiPanel &&
        (layoutState.leftPanelVisible != layoutState.middlePanelVisible);
    if (exactlyTwoPanels) {
      layoutBloc.setPanelVisibility(left: false, middle: true);
    }

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
        title: 'Next thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        shortcut: platformSingleActivator(LogicalKeyboardKey.arrowDown),
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
        title: 'Previous thread',
        eventObject: EventObject.activity,
        eventAction: EventAction.viewed,
        shortcut: platformSingleActivator(LogicalKeyboardKey.arrowUp),
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
        title: 'Create thread',
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
    final savedThread = await priorityBloc.add(
      _data.thread,
      note: _data.note,
      assignNote: _data.assignNote,
    );

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
  AddThreadWithLink({
    required this.linkUrl,
    required this.linkTitle,
    this.linkFavicon,
  }) : super(
         title: 'Add link',
         eventObject: EventObject.activity,
         eventAction: EventAction.added,
         icon: PlotIcon.link,
       );

  final String linkUrl;
  final String? linkTitle;
  final String? linkFavicon;

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
      logo: linkFavicon,
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

class ToggleRsvp extends _UpdateThreadCommand {
  ToggleRsvp(super.thread)
    : _targetStatus = thread.currentUserRsvp == 'attend' ? 'skip' : 'attend',
      super(
        title: thread.currentUserRsvp == 'attend' ? 'Decline' : 'Attend',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: thread.currentUserRsvp == 'attend'
            ? PlotIcon.calendarCheck
            : thread.currentUserRsvp == 'skip'
            ? PlotIcon.calendarXmark
            : PlotIcon.calendarPlus,
        hoverIcon: thread.currentUserRsvp == 'attend'
            ? PlotIcon.calendarXmark
            : PlotIcon.calendarCheck,
      );

  final String _targetStatus;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updated = thread.withRsvpStatus(_targetStatus);
    await saveOptimistically(context, updated);

    // Determine whether this is an occurrence-level or series-level RSVP.
    // Initial accept (no prior RSVP) always targets the series.
    // Subsequent toggles on recurring occurrences target the occurrence.
    final hasExistingRsvp = thread.currentUserRsvp != null;
    final isOccurrenceLevel = hasExistingRsvp && thread.occurrence != null;

    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {
            'thread_id': thread.id.toString(),
            if (isOccurrenceLevel) 'occurrence': thread.occurrence,
            'status': _targetStatus,
          },
        )
        .catchError((_) {});

    return const CommandDone();
  }
}

class SkipRsvpSeries extends _UpdateThreadCommand {
  SkipRsvpSeries(super.thread)
    : super(
        title: 'Decline all',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.calendarXmark,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updated = thread.withRsvpStatus('skip');
    await saveOptimistically(context, updated);

    // Skip the entire series (no occurrence)
    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {'thread_id': thread.id.toString(), 'status': 'skip'},
        )
        .catchError((_) {});

    return const CommandDone();
  }
}

class RenameThread extends ShowForm {
  RenameThread(Thread thread)
    : super(
        title: 'Rename',
        icon: FontAwesomeIcons.pen,
        form: (context) async {
          return FormData(
            title: 'Rename',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Title',
                    initialValue: thread.title,
                    required: true,
                  ),
                  FormButton(
                    key: 'save',
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      return _SaveThreadTitle(thread, title);
                    },
                  ),
                ],
              ),
            ],
          );
        },
      );
}

class _SaveThreadTitle extends _UpdateThreadCommand {
  _SaveThreadTitle(super.thread, this.newTitle)
    : super(
        title: 'Save',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final String newTitle;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.copyWith(title: Value(newTitle)));
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
        title: 'To do',
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
    await saveOptimistically(context, thread.copyWith(todo: !thread.todo));
    return const CommandDone();
  }
}

class ThreadToDo extends _UpdateThreadCommand {
  ThreadToDo(super.thread, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'To do',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: stateIcon ? PlotIcon.note : PlotIcon.todo,
        hoverIcon: stateIcon ? PlotIcon.todo : null,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.copyWith(todo: true));
    return const CommandDone();
  }
}

class ThreadDone extends _UpdateThreadCommand {
  ThreadDone(
    super.thread, {
    super.onUpdate,
    bool stateIcon = false,
    this.bump = true,
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

  final bool bump;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Optimistic removal for instant UI feedback
    context.read<PriorityBloc?>()?.optimisticallyRemoveThread(thread.id);
    HapticFeedback.mediumImpact();
    await onUpdate(thread.copyWith(todo: false, bump: bump));
    return const CommandDone();
  }
}

class ActorGroup extends CommandGroup {
  ActorGroup({
    super.title,
    required this.priorityId,
    required this.builder,
    this.excludeActorIds,
  });

  final Uuid priorityId;
  final Command Function(Actor actor) builder;
  final List<ActorId>? excludeActorIds;

  @override
  Future<List<Command>> list({String? search}) async {
    final actors = await Actor.get(
      priorityId: priorityId,
      types: [ActorType.user, ActorType.contact],
      search: search, // Backend search by name/email
      limit: 50,
    );
    if (excludeActorIds != null && excludeActorIds!.isNotEmpty) {
      final excluded = excludeActorIds!.toSet();
      actors.removeWhere((a) => excluded.contains(a.id));
    }
    return actors.map((actor) => builder(actor)).toList();
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

class PickScheduleThread extends Command {
  PickScheduleThread(this._thread, {Future<void> Function(Thread)? onUpdate})
    : _onUpdate = onUpdate,
      super(
        title: _thread.on != null ? 'Reschedule' : 'Schedule',
        icon: PlotIcon.schedule,
        eventObject: EventObject.modal,
        eventAction: EventAction.opened,
      );

  final Thread _thread;
  final Future<void> Function(Thread)? _onUpdate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final actionReturn = await Modal(
      constraints: const BoxConstraints(maxWidth: 380, maxHeight: 640),
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Schedule To Do',
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
                    final dateStart = DateTime(date.year, date.month, date.day);
                    return !dateStart.isBefore(todayStart);
                  },
                ),
              ),
              style: (style) => style.copyWith(
                decoration: const BoxDecoration(),
                padding: EdgeInsets.zero,
              ),
              onPress: (date) async {
                final actionReturn = await ScheduleThread(
                  _thread,
                  when: date.toDate(),
                  onUpdate: _onUpdate,
                ).run(context);
                if (!context.mounted) return;
                Modal.pop(context, Value(actionReturn));
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FButton(
                    style: FButtonStyle.secondary(),
                    onPress: () async {
                      final actionReturn = await ScheduleThread(
                        _thread,
                        when: Thread.todoNowDate,
                        onUpdate: _onUpdate,
                      ).run(context);
                      if (!context.mounted) return;
                      Modal.pop(context, Value(actionReturn));
                    },
                    child: const Text('Today'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FButton(
                    style: FButtonStyle.secondary(),
                    onPress: () async {
                      final actionReturn = await ToggleThreadToDo(
                        _thread,
                        onUpdate: _onUpdate,
                      ).run(context);
                      if (!context.mounted) return;
                      Modal.pop(context, Value(actionReturn));
                    },
                    child: const Text('Unschedule'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ).show<CommandReturn>(context);
    return actionReturn.present ? actionReturn.value : const CommandSkipped();
  }
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
    final isAdding = !thread.hasTag(tag);
    var updatedThread = thread.toggleTag(tag);
    // When adding Tag.done and the user has the thread as to-do, also mark personal to-do as done
    if (tag == Tag.done && isAdding && thread.todo) {
      updatedThread = updatedThread.copyWith(todo: false);
    }
    await saveOptimistically(context, updatedThread);

    // When adding Tag.done, also complete self-assigned note tasks and set link statuses
    if (tag == Tag.done && isAdding) {
      final actorId = Base.actorId;

      // Complete notes assigned to current user
      final notes = await Note.getForThread(thread.id);
      for (final note in notes) {
        if (note.hasTag(Tag.todo, actorId)) {
          await note.completeFor(actorId).save();
        }
      }

      // Set done status on links
      if (context.mounted) {
        await _setLinkDoneStatus(context, thread.id);
      }
    }

    return const CommandDone();
  }

  static Future<void> _setLinkDoneStatus(
    BuildContext context,
    ThreadId threadId,
  ) async {
    final links = await Link.getForThread(threadId);

    // Block if any link belongs to an unconnected source
    for (final link in links) {
      final ptId = link.createdBy;
      if (ptId != null) {
        final pt = PriorityTwist.fromCache(ptId);
        if (pt != null && pt.isSource && !pt.userConnected) {
          if (context.mounted) {
            context.showToast(
              message: 'Connect your ${pt.name} account',
              isError: true,
            );
          }
          return;
        }
      }
    }

    // Collect links that have done statuses and aren't already done
    final linksWithDoneStatuses = <(Link, List<LinkStatus>)>[];
    for (final link in links) {
      final typeConfig = link.getTypeConfig();
      final statuses = typeConfig?.statuses;
      if (statuses == null) continue;

      final doneStatuses = statuses.where((LinkStatus s) => s.done).toList();
      if (doneStatuses.isEmpty) continue;

      // Skip if link is already at a done status
      if (doneStatuses.any((LinkStatus s) => s.status == link.status)) continue;

      linksWithDoneStatuses.add((link, doneStatuses));
    }

    if (linksWithDoneStatuses.isEmpty) return;

    // Collect all unique done statuses across all links
    final allDoneStatuses = linksWithDoneStatuses
        .expand((e) => e.$2.map((s) => (e.$1, s)))
        .toList();

    if (allDoneStatuses.length == 1) {
      // Single done status across all links - auto set
      final (link, status) = allDoneStatuses.first;
      await Link.updateStatus(link, status.status);
    } else {
      // Multiple done statuses - handle per link
      for (final (link, doneStatuses) in linksWithDoneStatuses) {
        if (!context.mounted) return;
        if (doneStatuses.length == 1) {
          await Link.updateStatus(link, doneStatuses.first.status);
        } else {
          // Show picker for links with multiple done statuses
          final result = await SelectModal.open<String>(
            context,
            items: (search) async => [
              SelectGroup(items: doneStatuses.map((s) => s.status).toList()),
            ],
            itemBuilder: (status, _) {
              final s = doneStatuses.firstWhere((ls) => ls.status == status);
              return ListTile(
                title: s.label,
                leadingBuilder: (isHovered, hasFocus) => Padding(
                  padding: const EdgeInsets.only(left: 16, right: 8),
                  child: s.status == link.status
                      ? Icon(
                          PlotIcon.done,
                          size: 14,
                          color: context.theme.colors.primary,
                        )
                      : const SizedBox(width: 14),
                ),
                disableInternalHover: true,
              );
            },
            selectedValue: link.status,
            prompt: 'Set status for ${link.title ?? "link"}',
          );
          if (result.present) {
            await Link.updateStatus(link, result.value);
          }
        }
      }
    }
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
        title: 'Move to new thread',
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
        title: 'Move to another priority',
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

class MergeThreadInto extends ShowCommands {
  MergeThreadInto(this.thread)
    : super(
        title: 'Merge into...',
        icon: FontAwesomeIcons.codeMerge,
        commandsBuilder: (context) => _getMergeTargets(thread),
      );

  final Thread thread;

  static Future<Commands> _getMergeTargets(Thread thread) async {
    final threads = await Thread.get(
      priorityPath: thread.priority.path,
      archived: false,
      draft: false,
      order: ThreadOrder.reverse,
    );
    final filtered = threads.where((t) => t.id != thread.id).toList();
    return Commands(
      prompt: 'Merge into',
      groups: [
        StaticCommandGroup(
          title: 'Threads',
          commands: filtered.map((t) => _ExecuteMerge(thread, t)).toList(),
        ),
      ],
    );
  }
}

class _ExecuteMerge extends ThreadCommand {
  _ExecuteMerge(this.source, Thread target)
    : super(
        target,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Thread source;
  Thread get target => thread!;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // 1. Move all non-draft notes from source to target
    final noteRows =
        await (Store.get.select(Store.get.notes)
              ..where((n) => n.threadId.equalsValue(source.id))
              ..where((n) => n.draft.equals(false)))
            .get();

    for (final noteRow in noteRows) {
      final note = await Note.get(noteRow.id);
      if (note == null) continue;
      await note
          .copyWith(threadId: target.id, mergedFromThreadId: Value(source.id))
          .save(pushToRemote: false);
    }

    // 2. Move links from source to target
    final linkRows = await (Store.get.select(
      Store.get.links,
    )..where((l) => l.threadId.equals(source.id.toBytes()))).get();

    for (final linkRow in linkRows) {
      final updated = linkRow.copyWith(
        threadId: Value(target.id),
        mergedFromThreadId: Value(source.id),
        updatedAt: DateTime.now(),
      );
      await Store.get.add(Store.get.links, updated.toCompanion(false));
    }

    // 3. Union tags: merge source thread tags into target (per occurrence)
    final sourceTagRows = await (Store.get.select(
      Store.get.threadTags,
    )..where((t) => t.id.equalsValue(source.id))).get();
    final targetTagRows = await (Store.get.select(
      Store.get.threadTags,
    )..where((t) => t.id.equalsValue(target.id))).get();

    // Build a map of occurrence -> tags for target
    final targetByOccurrence = <String, ThreadTagsRow>{};
    for (final row in targetTagRows) {
      targetByOccurrence[row.occurrence] = row;
    }

    for (final sourceRow in sourceTagRows) {
      final sourceTags = sourceRow.tags ?? {};
      if (sourceTags.isEmpty) continue;

      final targetRow = targetByOccurrence[sourceRow.occurrence];
      final targetTags = targetRow?.tags ?? <Tag, List<ActorId>>{};

      // Merge: for each source tag, add actors not already in target
      bool changed = false;
      final merged = Map<Tag, List<ActorId>>.from(targetTags);
      for (final entry in sourceTags.entries) {
        final existing = merged[entry.key] ?? [];
        final newActors = entry.value
            .where((a) => !existing.contains(a))
            .toList();
        if (newActors.isNotEmpty) {
          merged[entry.key] = [...existing, ...newActors];
          changed = true;
        }
      }

      if (changed) {
        final updatedTags = targetRow != null
            ? targetRow.copyWith(
                tags: Value(merged.isEmpty ? null : merged),
                updatedAt: DateTime.now(),
              )
            : ThreadTagsRow(
                id: target.id,
                occurrence: sourceRow.occurrence,
                updatedAt: DateTime.now(),
                tags: merged.isEmpty ? null : merged,
              );
        await Store.get.add(
          Store.get.threadTags,
          updatedTags.toCompanion(false),
        );
      }
    }

    // 4. Merge schedules: fill gaps (source schedule moves to target if user has none)
    final sourceSchedules = await (Store.get.select(
      Store.get.schedules,
    )..where((s) => s.threadId.equalsValue(source.id))).get();
    final targetSchedules = await (Store.get.select(
      Store.get.schedules,
    )..where((s) => s.threadId.equalsValue(target.id))).get();

    // Build a set of (userId, occurrence) keys for target schedules
    final targetKeys = <String>{};
    for (final s in targetSchedules) {
      final key = '${s.userId ?? ''}_${s.occurrence ?? ''}';
      targetKeys.add(key);
    }

    for (final s in sourceSchedules) {
      final key = '${s.userId ?? ''}_${s.occurrence ?? ''}';
      if (!targetKeys.contains(key)) {
        // Move this schedule to target
        final moved = s.copyWith(
          threadId: Value(target.id),
          updatedAt: DateTime.now(),
        );
        await Store.get.add(Store.get.schedules, moved.toCompanion(false));
      }
    }

    // 5. Archive source thread
    await source.delete();

    // 6. Push all changes
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.note));
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.thread));

    // 7. Navigate to target thread
    return CommandRoute(
      PriorityRoute(
        priorityIdString: target.priority.id.toShortString(),
        children: [ThreadRoute(threadIdString: target.id.toShortString())],
      ),
    );
  }
}

class SplitThread extends Command {
  SplitThread(this.thread)
    : super(
        title: 'Split thread',
        icon: FontAwesomeIcons.codeBranch,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Thread thread;

  /// Check if this thread has any merged content (used to hide the command).
  static Future<bool> hasMergedContent(ThreadId threadId) async {
    final db = Store.get;
    final notes =
        await (db.select(db.notes)
              ..where((n) => n.threadId.equalsValue(threadId))
              ..where((n) => n.mergedFromThreadId.isNotNull())
              ..limit(1))
            .get();
    if (notes.isNotEmpty) return true;

    final links =
        await (db.select(db.links)
              ..where((l) => l.threadId.equals(threadId.toBytes()))
              ..where((l) => l.mergedFromThreadId.isNotNull())
              ..limit(1))
            .get();
    return links.isNotEmpty;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Find distinct merged source threads
    final noteRows =
        await (Store.get.select(Store.get.notes)
              ..where((n) => n.threadId.equalsValue(thread.id))
              ..where((n) => n.mergedFromThreadId.isNotNull()))
            .get();

    final linkRows =
        await (Store.get.select(Store.get.links)
              ..where((l) => l.threadId.equals(thread.id.toBytes()))
              ..where((l) => l.mergedFromThreadId.isNotNull()))
            .get();

    final sourceIds = <ThreadId>{};
    for (final n in noteRows) {
      if (n.mergedFromThreadId != null) sourceIds.add(n.mergedFromThreadId!);
    }
    for (final l in linkRows) {
      if (l.mergedFromThreadId != null) sourceIds.add(l.mergedFromThreadId!);
    }

    if (sourceIds.isEmpty || !context.mounted) return const CommandSkipped();

    // Load source threads
    final sourceThreads = <Thread>[];
    for (final id in sourceIds) {
      final threads = await Thread.get(id: id, archived: null);
      if (threads.isNotEmpty) sourceThreads.add(threads.first);
    }

    if (sourceThreads.isEmpty || !context.mounted) {
      return const CommandSkipped();
    }

    // Show picker
    final commands = Commands(
      prompt: 'Split from',
      groups: [
        StaticCommandGroup(
          title: 'Source Threads',
          commands: sourceThreads.map((t) => _ExecuteSplit(thread, t)).toList(),
        ),
      ],
    );

    return await CommandModal(commands, rootContext: context).run(context);
  }
}

class _ExecuteSplit extends ThreadCommand {
  _ExecuteSplit(this.current, Thread source)
    : super(
        source,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Thread current;
  Thread get source => thread!;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // 1. Move notes back to source
    final noteRows =
        await (Store.get.select(Store.get.notes)
              ..where((n) => n.threadId.equalsValue(current.id))
              ..where((n) => n.mergedFromThreadId.equalsValue(source.id)))
            .get();

    for (final noteRow in noteRows) {
      final note = await Note.get(noteRow.id);
      if (note == null) continue;
      await note
          .copyWith(threadId: source.id, mergedFromThreadId: const Value(null))
          .save(pushToRemote: false);
    }

    // 2. Move links back to source
    final linkRows =
        await (Store.get.select(Store.get.links)
              ..where((l) => l.threadId.equals(current.id.toBytes()))
              ..where((l) => l.mergedFromThreadId.equals(source.id.toBytes())))
            .get();

    for (final linkRow in linkRows) {
      final updated = linkRow.copyWith(
        threadId: Value(source.id),
        mergedFromThreadId: const Value(null),
        updatedAt: DateTime.now(),
      );
      await Store.get.add(Store.get.links, updated.toCompanion(false));
    }

    // 3. Unarchive source thread
    await source.copyWith(archivedAt: const Value(null)).save();

    // 4. Push changes
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.note));
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.thread));

    return const CommandDone();
  }
}

class ShowThreadCommands extends ShowCommands {
  ShowThreadCommands(Thread thread, {bool open = true})
    : super(
        title: 'More commands',
        icon: PlotIcon.menu,
        commandsBuilder: (context) async => Commands(
          groups: await threadCommandGroups(thread, open: open),
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
        title: 'Move focus up',
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
        title: 'Move focus down',
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
        title: 'Clear item focus',
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
    FutureOr<List<StaticCommandGroup>> Function(int index) actionBuilder,
  ) : _controller = controller,
      super(
        title: 'Open actions for focused item',
        commandsBuilder: (context) async {
          final focusedIndex = controller.focusedIndex;
          if (focusedIndex == null) {
            return Commands(groups: []);
          }
          return Commands(groups: await actionBuilder(focusedIndex));
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

Future<List<StaticCommandGroup>> threadCommandGroups(
  Thread thread, {
  bool open = true,
}) async {
  final hasMerged = await SplitThread.hasMergedContent(thread.id);
  return threadCommandGroupsSync(
    thread,
    open: open,
    showSplitThread: hasMerged,
  );
}

/// Sync variant for callers that cannot await (e.g. CommandScope).
/// Does not include SplitThread unless [showSplitThread] is explicitly true.
List<StaticCommandGroup> threadCommandGroupsSync(
  Thread thread, {
  bool open = true,
  bool showSplitThread = false,
}) {
  final isViewer = thread.priority.isViewer;
  final tags = Tag.getAll()
      .where((tag) => !isViewer || tag.type == TagType.count)
      .map((tag) => ToggleThreadTag(thread, tag))
      .toList();
  final commands = threadCommands(
    thread,
    open: open,
    showSplitThread: showSplitThread,
  );
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
      StaticCommandGroup(title: 'Remove tag', commands: remove),
    if (add.isNotEmpty) StaticCommandGroup(title: 'Add tag', commands: add),
  ];
}

List<Command> threadCommands(
  Thread thread, {
  bool open = false,
  bool skipInfrequent = false,
  bool skipPrimary = false,
  bool showSplitThread = false,
  bool showEventTiming = false,
}) {
  // Viewers can only open threads, not modify them
  if (thread.priority.isViewer) {
    return [if (open) ChangeCurrentThread(thread)];
  }

  final primary = skipPrimary
      ? null
      : primaryThreadCommand(thread, stateIcon: false);
  // For checks, use the actual primary command (not the nullable primary variable)
  final actualPrimary = primaryThreadCommand(thread, stateIcon: false);
  final hideArchive = showEventTiming && thread.hasOtherAttendees;
  return [
    if (open) ChangeCurrentThread(thread),
    ?primary,
    if (actualPrimary is! PickScheduleThread &&
        !(thread.todo && thread.isFuture))
      PickScheduleThread(thread),
    if (!skipInfrequent) RenameThread(thread),
    MoveThreadToPriority(thread),
    if (!skipInfrequent) MergeThreadInto(thread),
    if (!skipInfrequent && showSplitThread) SplitThread(thread),
    if (!skipInfrequent && !thread.priority.personal)
      ToggleThreadPrivate(thread),
    if (!hideArchive) ArchiveThread(thread),
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

  // Always lead with done tag if not already on thread
  final commands = <Command>[];
  if (!thread.hasTag(Tag.done)) {
    commands.add(ToggleThreadTag(thread, Tag.done));
  }

  commands.addAll(
    tagSuggestions
        .where((tag) => !thread.hasTag(tag) && tag != Tag.done)
        .take(maxToShow - commands.length)
        .map((tag) => ToggleThreadTag(thread, tag)),
  );

  return commands.take(maxToShow).toList();
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
