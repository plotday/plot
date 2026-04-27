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
            style: context.theme.typography.md.copyWith(
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

    // No-op if the thread is already selected
    if (thread != null && priorityBloc.state.thread?.id == thread!.id) {
      return const CommandDone();
    }

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
        title: "New thread",
        eventObject: EventObject.activity,
        eventAction: EventAction.opened,
        icon: PlotIcon.addNote,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyN, alt: kIsWeb),
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
    final thread = draft.copyWith(
      title: Value(threadTitle),
      icon: Value(linkFavicon ?? 'link'),
    );

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
        shortcut: thread.archivedAt == null
            ? platformSingleActivator(LogicalKeyboardKey.backspace)
            : null,
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

    // Capture navigation BEFORE archive (only when archiving, not un-archiving)
    if (!context.mounted) return const CommandDone();
    final priorityBloc = context.read<PriorityBloc?>();
    final isCurrentThread = priorityBloc?.state.thread?.id == thread.id;
    final isAgenda =
        priorityBloc?.resolveThreadListSource() == ThreadListSource.agenda;
    CommandReturn? navigationResult;
    if (!isArchived && isCurrentThread && isAgenda) {
      navigationResult = await OpenNextThread().run(context);
      if (navigationResult is CommandSkipped) {
        if (!context.mounted) return const CommandDone();
        navigationResult = await NewThread().run(context);
      }
    }

    if (isArchived) {
      // Un-archive: set archivedAt to null
      final unarchived = thread.copyWith(archivedAt: const Value(null));
      priorityBloc?.optimisticallyUpdateThread(unarchived);
      await unarchived.save();
    } else {
      // Archive: set archivedAt to current time
      final archived = thread.copyWith(archivedAt: Value(DateTime.now()));
      priorityBloc?.optimisticallyArchiveThread(archived);
      await archived.save();
    }
    return navigationResult ?? const CommandDone();
  }
}

class ToggleRsvp extends _UpdateThreadCommand {
  ToggleRsvp(super.thread)
    : _targetStatus = _effectiveRsvp(thread) == 'attend' ? 'skip' : 'attend',
      super(
        title: _effectiveRsvp(thread) == 'attend' ? 'Skip' : 'Attend',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: _effectiveRsvp(thread) == 'attend'
            ? PlotIcon.calendarCheck
            : thread.currentUserRsvp == 'skip'
            ? PlotIcon.calendarXmark
            : PlotIcon.calendarPlus,
        hoverIcon: _effectiveRsvp(thread) == 'attend'
            ? PlotIcon.calendarXmark
            : PlotIcon.calendarCheck,
      );

  /// For link schedule instances (calendar events), treat null RSVP as
  /// implicitly attending — the user's own events default to "attend".
  static String? _effectiveRsvp(Thread thread) =>
      thread.currentUserRsvp ??
      (thread.isLinkScheduleInstance ? 'attend' : null);

  final String _targetStatus;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updated = thread.withRsvpStatus(_targetStatus);
    await saveOptimistically(context, updated);

    // Target the occurrence only when the user has an existing RSVP on
    // this specific occurrence (not inherited from the series). Initial
    // RSVPs and toggles of series-inherited RSVPs target the series.
    final hasExistingRsvp = thread.currentUserRsvp != null;
    final targetsOccurrence =
        hasExistingRsvp &&
        thread.occurrence != null &&
        !thread.rsvpInheritedFromSeries;

    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {
            'thread_id': thread.id.toString(),
            if (targetsOccurrence) 'occurrence': thread.occurrence,
            'status': _targetStatus,
          },
        )
        .catchError((_) {});

    return const CommandDone();
  }
}

class AttendRsvp extends _UpdateThreadCommand {
  AttendRsvp(super.thread)
    : super(
        title: 'Attend',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.calendarCheck,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updated = thread.withRsvpStatus('attend');
    await saveOptimistically(context, updated);

    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {'thread_id': thread.id.toString(), 'status': 'attend'},
        )
        .catchError((_) {});

    return const CommandDone();
  }
}

class SkipRsvp extends _UpdateThreadCommand {
  SkipRsvp(super.thread)
    : super(
        title: 'Skip',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.calendarXmark,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updated = thread.withRsvpStatus('skip');
    await saveOptimistically(context, updated);

    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {'thread_id': thread.id.toString(), 'status': 'skip'},
        )
        .catchError((_) {});

    return const CommandDone();
  }
}

class EditThread extends ShowForm {
  EditThread(Thread thread, {VoidCallback? onSaved, PriorityBloc? priorityBloc})
    : super(
        title: 'Edit',
        icon: FontAwesomeIcons.pen,
        form: (context) async {
          return FormData(
            title: 'Edit',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Title',
                    initialValue: thread.title,
                    required: !thread.draft,
                  ),
                  FormSelect<Priority>(
                    key: 'priority',
                    label: 'Priority',
                    initialValue: thread.priority,
                    required: true,
                    items: (search) async => Priority.get(
                      order: PriorityOrder.nested,
                      search: search,
                    ),
                    labelBuilder: (p) => PriorityLabel(priority: p),
                    titleBuilder: (p) => p.ancestorsLabel() != null
                        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
                        : p.title,
                  ),
                  FormSelect<ThreadSubType>(
                    key: 'type',
                    label: 'Type',
                    initialValue:
                        ThreadSubType.fromIcon(thread.icon) ??
                        ThreadSubType.defaultFor(),
                    items: (_) async => ThreadSubType.values,
                    titleBuilder: (t) => t.label,
                    leadingBuilder: (t) => Icon(t.icon, size: 16),
                  ),
                  FormButton(
                    key: 'save',
                    isPrimary: true,
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final priority = values['priority'] as Priority;
                      final type = values['type'] as ThreadSubType?;
                      return _SaveThreadEdit(
                        thread,
                        title,
                        priority,
                        type,
                        onSaved: onSaved,
                        priorityBloc: priorityBloc,
                      );
                    },
                  ),
                ],
              ),
            ],
          );
        },
      );
}

class _SaveThreadEdit extends _UpdateThreadCommand {
  _SaveThreadEdit(
    super.thread,
    this.newTitle,
    this.newPriority,
    this.newType, {
    this.onSaved,
    super.priorityBloc,
  }) : super(
         title: 'Save',
         eventObject: EventObject.activity,
         eventAction: EventAction.updated,
       );

  final String newTitle;
  final Priority newPriority;
  final ThreadSubType? newType;
  final VoidCallback? onSaved;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(
      context,
      thread.copyWith(
        title: Value(newTitle.isEmpty ? null : newTitle),
        priority: newPriority,
        icon: Value(newType?.value),
      ),
    );
    onSaved?.call();
    return const CommandDone();
  }
}

abstract class _UpdateThreadCommand extends Command {
  _UpdateThreadCommand(
    this.thread, {
    Future<void> Function(Thread)? onUpdate,
    this.priorityBloc,
    required super.title,
    required super.eventObject,
    required super.eventAction,
    super.icon,
    super.hoverIcon,
    super.shortcut,
    super.on,
  }) : onUpdate = onUpdate ?? ((thread) => thread.save());

  final Thread thread;
  final Future<void> Function(Thread) onUpdate;
  final PriorityBloc? priorityBloc;

  /// Optimistically update the UI, then persist the thread.
  /// Commands that run inside modals must pass [priorityBloc] explicitly
  /// because the modal context doesn't have PriorityBloc in its tree.
  Future<void> saveOptimistically(
    BuildContext context,
    Thread updatedThread,
  ) async {
    PriorityBloc? bloc = priorityBloc;
    if (bloc == null) {
      try {
        bloc = context.read<PriorityBloc>();
      } catch (_) {}
    }
    // Draft threads live in bloc state and must be updated there so the UI
    // reflects the change after the modal closes. optimisticallyUpdateThread
    // ignores drafts, so use updateDraft which emits the new state and
    // persists in one step.
    if (updatedThread.draft &&
        bloc != null &&
        updatedThread.id == bloc.state.draft.id) {
      await bloc.updateDraft(updatedThread);
      return;
    }
    bloc?.optimisticallyUpdateThread(updatedThread);
    await onUpdate(updatedThread);
    // After save, reload the agenda from fresh stream data so changes that
    // add/remove items (e.g. starting a link schedule thread creates a base
    // todo duplicate) appear immediately instead of waiting for the next
    // unsuppressed stream emission.
    bloc?.refreshAgenda();
  }
}

class ToggleThreadToDo extends _UpdateThreadCommand {
  ToggleThreadToDo(
    super.thread, {
    super.onUpdate,
    bool stateIcon = false,
    String? title,
  }) : super(
         title: title ?? (thread.todo ? 'Remove from agenda' : 'Add to agenda'),
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

class StartThread extends _UpdateThreadCommand {
  StartThread(super.thread, {super.onUpdate, bool stateIcon = false})
    : super(
        title: 'Add to agenda',
        eventObject: EventObject.activity,
        eventAction: EventAction.started,
        icon: stateIcon ? PlotIcon.note : PlotIcon.todo,
        hoverIcon: stateIcon ? PlotIcon.todo : null,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyD),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.copyWith(todo: true));
    return const CommandDone();
  }
}

class DisassociateThread extends Command {
  DisassociateThread(this.thread, {this.finish = false, this.onBeforeRun})
    : super(
        title: finish ? 'Remove from agenda' : 'Remove from event',
        eventObject: EventObject.activity,
        eventAction: finish ? EventAction.finished : EventAction.updated,
        icon: finish ? FontAwesomeIcons.circleCheck : FontAwesomeIcons.xmark,
      );

  final Thread thread;
  final bool finish;
  final Future<void> Function(BuildContext context)? onBeforeRun;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (onBeforeRun != null) {
      await onBeforeRun!(context);
      if (!context.mounted) return const CommandDone();
    }
    final priorityBloc = context.read<PriorityBloc?>();
    if (finish) {
      // Finish + disassociate: remove all copies (associated and todo)
      priorityBloc?.optimisticallyRemoveThread(thread.id, finishTodo: true);
      await thread.copyWith(todo: false).save();
    } else {
      // Just disassociate: remove only the associated copies
      priorityBloc?.optimisticallyDisassociate(thread.id);
    }
    await thread.disassociate(order: Order.first());
    return const CommandDone();
  }
}

class MarkReadThread extends _UpdateThreadCommand {
  MarkReadThread(super.thread, {super.onUpdate})
    : super(
        title: 'Mark read',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: FontAwesomeIcons.eye,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (!thread.unread) return const CommandDone();
    await saveOptimistically(context, thread.copyWith(unread: false));
    return const CommandDone();
  }
}

class FinishThread extends _UpdateThreadCommand {
  FinishThread(
    super.thread, {
    super.onUpdate,
    bool stateIcon = false,
    this.bump = true,
    this.onBeforeRun,
  }) : super(
         title: 'Remove from agenda',
         eventObject: EventObject.activity,
         eventAction: EventAction.finished,
         icon: stateIcon && thread.todo
             ? FontAwesomeIcons.circle
             : FontAwesomeIcons.circleCheck,
         hoverIcon: stateIcon && thread.todo
             ? FontAwesomeIcons.circleCheck
             : null,
         shortcut: platformSingleActivator(LogicalKeyboardKey.keyD),
       );

  final bool bump;

  /// Optional callback invoked before the finish logic runs.
  /// When set, the caller is responsible for optimistic removal (e.g. via
  /// animation). When null, FinishThread calls optimisticallyRemoveThread
  /// directly as a fallback (keyboard shortcuts, command palette, etc.).
  final Future<void> Function(BuildContext context)? onBeforeRun;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Capture navigation BEFORE removal (thread must still be in agenda list)
    final priorityBloc = context.read<PriorityBloc?>();
    final isCurrentThread = priorityBloc?.state.thread?.id == thread.id;
    final isAgenda =
        priorityBloc?.resolveThreadListSource() == ThreadListSource.agenda;
    CommandReturn? navigationResult;
    if (isCurrentThread && isAgenda) {
      navigationResult = await OpenNextThread().run(context);
      if (navigationResult is CommandSkipped) {
        if (!context.mounted) return const CommandDone();
        navigationResult = await NewThread().run(context);
      }
    }

    // Navigate now, while context is still mounted. The onBeforeRun animation
    // (onDesktopFinish) awaits a widget removal that unmounts this context, so
    // we cannot defer navigation to the runner — it would arrive too late.
    if (navigationResult is CommandRoute) {
      if (!context.mounted) return const CommandDone();
      await navigationResult.go(context);
      navigationResult = null;
    }

    if (!context.mounted) return const CommandDone();
    HapticFeedback.mediumImpact();
    if (onBeforeRun != null) {
      // Animation layer handles optimistic removal
      await onBeforeRun!(context);
    } else {
      // No animation: remove the base todo and update remaining link schedule
      // instances to todo=false so the icon reflects the finished state.
      priorityBloc?.optimisticallyRemoveThread(thread.id, finishTodo: true);
    }
    await onUpdate(thread.copyWith(todo: false, bump: bump));

    // Complete notes assigned to current user
    final actorId = Base.actorId;
    final notes = await Note.getForThread(thread.id);
    for (final note in notes) {
      if (note.hasTag(Tag.todo, actorId)) {
        await note.completeFor(actorId).save();
      }
    }

    // Set done status on links assigned to user or unassigned
    if (context.mounted) {
      await _setLinkDoneStatusForUser(context, thread.id, actorId);
    }

    return navigationResult ?? const CommandDone();
  }

  static Future<void> _setLinkDoneStatusForUser(
    BuildContext context,
    ThreadId threadId,
    ActorId actorId,
  ) async {
    final links = await Link.getForThread(threadId);

    // Block if any link belongs to an unconnected source
    for (final link in links) {
      final ptId = link.createdBy;
      if (ptId != null) {
        final pt = TwistInstance.fromCache(ptId);
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

    // Collect links that have done statuses, aren't already done,
    // and are assigned to the current user or unassigned
    final linksWithDoneStatuses = <(Link, List<LinkStatus>)>[];
    for (final link in links) {
      // Skip links assigned to other users
      if (link.assigneeId != null && link.assigneeId != actorId) continue;

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
          );
          if (result.present) {
            await Link.updateStatus(link, result.value);
          }
        }
      }
    }
  }
}

class ActorGroup extends CommandGroup {
  ActorGroup({super.title, required this.builder, this.excludeActorIds});

  final Command Function(Actor actor) builder;
  final List<ActorId>? excludeActorIds;

  @override
  Future<List<Command>> list({String? search}) async {
    final actors = await Actor.get(
      types: [ActorType.user, ActorType.contact],
      search: search,
      limit: 50,
      inviteable: true,
      primary: true,
    );
    if (excludeActorIds != null && excludeActorIds!.isNotEmpty) {
      final excluded = excludeActorIds!.toSet();
      actors.removeWhere((a) => excluded.contains(a.id));
    }
    return actors.map((actor) => builder(actor)).toList();
  }
}

class ScheduleThread extends _UpdateThreadCommand {
  ScheduleThread(
    super.thread, {
    required this.when,
    super.onUpdate,
    super.priorityBloc,
  }) : super(
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
    var updated = thread;
    // Ensure thread is a todo (creates per-user schedule if needed)
    if (!updated.todo) {
      updated = updated.copyWith(todo: true);
    }
    // Move to the target date on the per-user schedule only
    updated = updated.reorderTo(
      updated.order,
      date: when == Thread.todoNowDate ? null : when,
    );
    await saveOptimistically(context, updated);
    return const CommandDone();
  }
}

class ScheduleEvent extends _UpdateThreadCommand {
  ScheduleEvent(
    super.thread, {
    required this.at,
    super.onUpdate,
    super.priorityBloc,
  }) : super(
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
    this.priorityBloc,
  }) : super(
         title: 'Reschedule',
         eventObject: EventObject.activity,
         eventAction: EventAction.rescheduled,
         icon: stateIcon ? PlotIcon.event : PlotIcon.reschedule,
         hoverIcon: stateIcon ? PlotIcon.reschedule : null,
       );

  final Thread thread;
  final bool showPrioritySelector;
  final PriorityBloc? priorityBloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await Modal(
      builder: (modalContext) => RescheduleEventModal(
        activity: thread,
        showPrioritySelector: showPrioritySelector,
      ),
    ).show<DateTimeRange>(context);

    if (result.present && context.mounted) {
      await ScheduleEvent(
        thread,
        at: result.value,
        priorityBloc: priorityBloc,
      ).run(context);
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
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyD, shift: true),
      );

  final Thread _thread;
  final Future<void> Function(Thread)? _onUpdate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Capture PriorityBloc before showing modal — modal context won't have it
    PriorityBloc? bloc;
    try {
      bloc = context.read<PriorityBloc>();
    } catch (_) {}

    final actionReturn = await Modal(
      constraints: const BoxConstraints(maxWidth: 380, maxHeight: 640),
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Schedule',
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
              style: FCalendarStyleDelta.delta(
                decoration: DecorationDelta.value(const BoxDecoration()),
                padding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
              ),
              onPress: (date) async {
                final actionReturn = await ScheduleThread(
                  _thread,
                  when: date.toDate(),
                  onUpdate: _onUpdate,
                  priorityBloc: bloc,
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
                    variant: FButtonVariant.secondary,
                    onPress: () async {
                      final actionReturn = await ScheduleThread(
                        _thread,
                        when: Thread.todoNowDate,
                        onUpdate: _onUpdate,
                        priorityBloc: bloc,
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
                    variant: FButtonVariant.secondary,
                    onPress: () async {
                      final actionReturn = await FinishThread(
                        _thread,
                        onUpdate: _onUpdate,
                      ).run(context);
                      if (!context.mounted) return;
                      Modal.pop(context, Value(actionReturn));
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 6,
                      children: [
                        Icon(FontAwesomeIcons.circleCheck, size: 14),
                        const Text('Done'),
                      ],
                    ),
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
  bool enabled(BuildContext context) =>
      !(tag == Tag.private && thread.priority.isViewer);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (!enabled(context)) return const CommandDone();
    final isRemovingReply = tag == Tag.reply && thread.hasTag(tag);

    // When adding to to-do, use the async path that also unarchives the
    // thread, flips any done-status links to their connector's todo status,
    // and re-propagates tags — matching the server-side logic so offline
    // users see the same end state.
    if (tag == Tag.todo && !thread.hasTag(Tag.todo)) {
      final updated = await thread.addToTodoWithPropagation();
      if (!context.mounted) return const CommandDone();
      await saveOptimistically(context, updated);
    } else {
      await saveOptimistically(context, thread.toggleTag(tag));
    }

    if (isRemovingReply) {
      // Remove reply tag from all notes on this thread
      final notes = await Note.getForThread(thread.id);
      for (final note in notes) {
        if (note.hasTag(Tag.reply, Base.actorId)) {
          final updated = note.setTag(Tag.reply, Base.actorId, false);
          await updated.save(skipReplyPropagation: true);
        }
      }
    }
    return const CommandDone();
  }
}

class ToggleThreadPrivate extends _UpdateThreadCommand {
  ToggleThreadPrivate(super.thread, {super.onUpdate})
    : super(
        title: 'Private',
        eventObject: EventObject.activity,
        eventAction: EventAction.tagged,
        icon: PlotIcon.private,
        on: null,
      );

  @override
  bool enabled(BuildContext context) => false;

  @override
  Future<CommandReturn> run(BuildContext context) async {
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
    // Record the explicit move so the server can learn from it and
    // retroactively re-file similar threads. The thread_priority.priority_id
    // is already in sync via the save() call above; this endpoint sets
    // user_moved = TRUE and triggers reclassify_user_threads. Best-effort:
    // a failure here leaves the thread move intact.
    try {
      await api.post<dynamic>(
        '/sync/priority-moves',
        body: {
          'thread_id': thread.id.toString(),
          'priority_id': priority!.id.toString(),
        },
      );
    } catch (_) {
      // Offline / transient — the move itself is already synced via
      // thread save; the learning signal will be re-sent next time.
    }
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
        title: 'Move',
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
      prompt: 'Move thread to priority',
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
        title: 'Merge',
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
        commandsBuilder: (context) async =>
            Commands(groups: await threadCommandGroups(thread, open: open)),
      );
}

class ChangeThreadSubType extends ShowCommands {
  ChangeThreadSubType(Thread thread)
    : super(
        title: 'Change type',
        icon: PlotIcon.notes,
        commandsBuilder: (context) async {
          final types = ThreadSubType.values;
          return Commands(
            groups: [
              StaticCommandGroup(
                title: null,
                commands: types
                    .map((t) => SetThreadSubType(thread, t))
                    .toList(),
              ),
            ],
          );
        },
      );
}

class SetThreadSubType extends Command {
  SetThreadSubType(this.thread, this.subType)
    : super(
        title: subType.label,
        icon: subType.icon,
        on: thread.icon == subType.value ? true : null,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Thread thread;
  final ThreadSubType subType;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await thread.copyWith(icon: Value(subType.value)).save();
    return const CommandDone();
  }
}

// Thread sharing commands

class PickThreadShared extends ShowCommands {
  factory PickThreadShared(Thread thread) {
    // Mutable reference so commandsBuilder (and each toggle command) always
    // sees the latest in-memory thread without re-reading from drift.
    final threadRef = [thread];
    final candidatesCache = _ShareCandidatesCache();

    Future<void> onUpdate(Thread updated) async {
      threadRef[0] = updated;
      // Persist in the background — drift is local-first and the UI should
      // reflect the new sharing state immediately. Errors are captured so
      // we still learn about drift failures.
      unawaited(_persistSharedChange(updated));
    }

    return PickThreadShared._(
      thread: thread,
      commandsBuilder: (context) => _buildSharedCommands(
        threadRef[0],
        onUpdate: onUpdate,
        isDraft: false,
        candidates: candidatesCache,
      ),
    );
  }

  PickThreadShared._({
    required this.thread,
    required Future<Commands> Function(BuildContext) commandsBuilder,
  }) : super(
         title: _computeSharedTitle(thread),
         icon: _computeSharedIcon(thread),
         commandsBuilder: commandsBuilder,
         showFilter: true,
         eventObject: EventObject.activity,
         eventAction: EventAction.updated,
         shortcut: platformSingleActivator(
           LogicalKeyboardKey.keyS,
           shift: true,
         ),
       );

  final Thread thread;

  /// Non-self contacts on the thread resolved from the in-memory Actor cache,
  /// suitable for sync rendering in an [AvatarGroup].
  List<Actor> get sharedDisplayActors => _sharedDisplayActors(thread);

  /// Like [sharedDisplayActors], but resolves uncached contacts via
  /// [Actor.getOne]. The first time a thread's contacts are rendered they
  /// may not yet be in [Actor]'s in-memory cache (the agenda doesn't eagerly
  /// load them), so the synchronous getter returns an empty list and the
  /// avatar group renders nothing. Awaiting this future populates the cache,
  /// which lets subsequent builds — and other widgets sharing the same
  /// contacts — resolve synchronously.
  Future<List<Actor>> loadSharedDisplayActors() =>
      _loadSharedDisplayActors(thread);

  /// Total number of shared targets on the thread (self + other contacts +
  /// groups + pending email invites), used for the overflow counter.
  int get sharedTotalCount => _sharedCount(thread);
}

Future<void> _persistSharedChange(Thread thread) async {
  try {
    await thread.save();
  } catch (e, stackTrace) {
    log.severe('Error persisting shared change: $e', e, stackTrace);
    Tracker.captureException(e, stackTrace);
  }
}

/// Share picker for draft threads on NewThreadPage (uses callback instead of
/// direct save).
class PickDraftThreadShared extends ShowCommands {
  factory PickDraftThreadShared({
    required Thread thread,
    required Future<void> Function(Thread thread) onUpdate,
  }) {
    // Mutable reference so commandsBuilder always sees the latest thread
    final threadRef = [thread];
    final candidatesCache = _ShareCandidatesCache();

    Future<void> wrappedOnUpdate(Thread updated) async {
      threadRef[0] = updated;
      await onUpdate(updated);
    }

    return PickDraftThreadShared._(
      thread: thread,
      onUpdate: onUpdate,
      commandsBuilder: (context) => _buildSharedCommands(
        threadRef[0],
        onUpdate: wrappedOnUpdate,
        isDraft: true,
        candidates: candidatesCache,
      ),
    );
  }

  PickDraftThreadShared._({
    required this.thread,
    required this.onUpdate,
    required Future<Commands> Function(BuildContext) commandsBuilder,
  }) : super(
         title: _computeSharedTitle(thread),
         icon: _computeSharedIcon(thread),
         commandsBuilder: commandsBuilder,
         showFilter: true,
         eventObject: EventObject.activity,
         eventAction: EventAction.updated,
         shortcut: platformSingleActivator(
           LogicalKeyboardKey.keyS,
           shift: true,
         ),
       );

  final Thread thread;
  final Future<void> Function(Thread thread) onUpdate;
}

/// Caches sorted sharing candidates by search string for the lifetime of a
/// single share-picker modal. Toggling a contact doesn't change the candidate
/// pool (only which side of the "Shared" / "Contacts" partition each actor is
/// on), so we avoid re-running the thread scan in [Actor.getSortedForSharing]
/// on every toggle.
class _ShareCandidatesCache {
  final Map<String, List<Actor>> _byQuery = {};

  Future<List<Actor>> get({
    required String? search,
    required Priority? priority,
  }) async {
    final key = (search ?? '').toLowerCase();
    final cached = _byQuery[key];
    if (cached != null) return cached;
    final fresh = await Actor.getSortedForSharing(
      search: search,
      priority: priority,
    );
    _byQuery[key] = fresh;
    return fresh;
  }
}

String _computeSharedTitle(Thread thread) {
  return isThreadShared(thread) ? 'Shared' : 'Share';
}

IconData _computeSharedIcon(Thread thread) {
  return isThreadShared(thread) ? PlotIcon.user : PlotIcon.shareAdd;
}

/// Canonical check for whether a thread is shared with anyone other than the
/// current user. Drives every "is this thread shared?" decision in the UI:
/// whether to show an [AvatarGroup] vs. the plain share icon, whether to hoist
/// the share command into the hover row, and the share modal's title/icon.
///
/// Returns true iff the thread has at least one of:
/// - a pending email invite,
/// - a non-system group it's been shared into, or
/// - a non-self, non-twist contact.
///
/// System participants don't count as user-initiated sharing:
/// - twist-instance contacts (a thread shared only with twists is unshared);
/// - auto-maintained groups (e.g. workspace-wide "Everyone"/announce groups
///   that twists publish into) — the viewer didn't initiate that share.
///
/// [_sharedCount] and [_sharedDisplayActors] apply the same filters so the
/// count, the rendered actors, and this predicate can never disagree.
bool isThreadShared(Thread thread) {
  if (thread.inviteEmails.isNotEmpty) return true;
  if (thread.groups.any((id) => !_isSystemGroup(id))) return true;
  if (thread.contacts.isEmpty) return false;
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  return thread.contacts.any(
    (id) => !selfUuids.contains(id) && !_isTwistContact(id),
  );
}

bool _isTwistContact(Uuid id) {
  final actorId = ActorId.fromUuid(id);
  // Either cache is authoritative on its own; check both so a thread doesn't
  // briefly look "shared" during cold start before the Actor cache fills.
  if (actorId.isTwist) return true;
  return Actor.fromCache(actorId)?.type == ActorType.twistInstance;
}

/// True for groups whose membership the system manages — e.g. workspace
/// "Everyone" announce groups twists publish into. The viewer can't add or
/// remove themselves from these groups, so a thread filed only into such a
/// group isn't "shared" from a user-initiated standpoint. Cache misses
/// conservatively return false so a synced-but-uncached group keeps its
/// existing visible behaviour.
bool _isSystemGroup(Uuid id) => Group.fromCache(id)?.autoMaintained ?? false;

int _sharedCount(Thread thread) {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final others = thread.contacts
      .where((id) => !selfUuids.contains(id) && !_isTwistContact(id))
      .length;
  final groupsCount = thread.groups.where((id) => !_isSystemGroup(id)).length;
  // When a group is on the thread, it implicitly represents the current user
  // (either directly or because the user is a member). Don't also add the
  // separate +1 for self in that case.
  final selfCount = groupsCount > 0 ? 0 : 1;
  return selfCount + others + groupsCount + thread.inviteEmails.length;
}

/// Resolves the actors to display in the Avatar group for a shared thread,
/// using only the in-memory Actor cache so the lookup is synchronous. The
/// current user is excluded — the button label/count conveys self presence.
///
/// Two contact rows for the same person (e.g. a primary email + a linked
/// alias) collapse to a single entry, preferring the primary actor so the
/// canonical name/avatar wins.
List<Actor> _sharedDisplayActors(Thread thread) {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final actors = <Actor>[];
  for (final contactId in thread.contacts) {
    if (selfUuids.contains(contactId)) continue;
    final actor = Actor.fromCache(ActorId.fromUuid(contactId));
    if (actor == null) continue;
    if (actor.type == ActorType.twistInstance) continue;
    actors.add(actor);
  }
  return _dedupePerPerson(actors);
}

Future<List<Actor>> _loadSharedDisplayActors(Thread thread) async {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final actors = <Actor>[];
  for (final contactId in thread.contacts) {
    if (selfUuids.contains(contactId)) continue;
    try {
      final actor = await Actor.getOne(ActorId.fromUuid(contactId));
      if (actor.type == ActorType.twistInstance) continue;
      actors.add(actor);
    } catch (_) {
      // Skip contacts whose actors can't be resolved.
    }
  }
  return _dedupePerPerson(actors);
}

/// Dedup key that collapses contact rows belonging to the same person.
/// Falls back to the actor id when [Actor.linkedUserId] is null (unlinked
/// external contacts), preserving the existing per-contact granularity.
/// Returns a string so [Uuid] and [ActorId] (unrelated extension types)
/// can share a single Map keyspace.
String _personKey(Actor actor) {
  final linkedUserId = actor.linkedUserId;
  if (linkedUserId != null) return 'user:$linkedUserId';
  return 'actor:${actor.id}';
}

/// Collapses [actors] so each underlying person appears once, in their
/// original order. When both a primary and a non-primary actor exist for
/// the same person, the primary wins so the canonical name/avatar is shown.
List<Actor> _dedupePerPerson(Iterable<Actor> actors) {
  final byKey = <String, Actor>{};
  final order = <String>[];
  for (final actor in actors) {
    final key = _personKey(actor);
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = actor;
      order.add(key);
    } else if (!existing.primary && actor.primary) {
      byKey[key] = actor;
    }
  }
  return [for (final key in order) byKey[key]!];
}

Future<Commands> _buildSharedCommands(
  Thread thread, {
  required Future<void> Function(Thread) onUpdate,
  required bool isDraft,
  required _ShareCandidatesCache candidates,
}) async {
  // Resolve groups filed on the thread. Groups are shown in the "Shared"
  // list so the viewer can see (and remove) the team the thread is shared
  // with.
  final sharedGroups = <GroupRow>[];
  for (final groupId in thread.groups) {
    final group = await Group.getOne(groupId);
    if (group != null) sharedGroups.add(group);
  }

  // Resolve shared actors, then dedupe per person so a user with multiple
  // linked contacts doesn't appear twice (and the primary wins over alias
  // rows).
  final resolved = <Actor>[];
  for (final contactId in thread.contacts) {
    try {
      resolved.add(await Actor.getOne(ActorId.fromUuid(contactId)));
    } catch (_) {
      // Skip contacts whose actors can't be resolved
    }
  }
  final sharedActors = _dedupePerPerson(resolved);

  // Inject the current user into the shared list on draft threads (the
  // NewThreadPage flow, where self gets saved into thread.contacts), or on
  // existing threads that have no group filed — in which case self isn't
  // implicitly represented.
  //
  // When a group is already on an existing thread, skip injection: the
  // group stands in for its members (including the viewer). If the viewer
  // later removes the group, ShareThreadGroup adds their contact back into
  // thread.contacts so they retain access.
  final shouldInjectSelf = isDraft || sharedGroups.isEmpty;
  if (shouldInjectSelf) {
    final selfIndex = sharedActors.indexWhere((a) => a.self);
    if (selfIndex < 0) {
      final primarySelfId = Base.actorIdOrNull;
      if (primarySelfId != null) {
        try {
          final selfActor = await Actor.getOne(primarySelfId);
          sharedActors.insert(0, selfActor);
        } catch (_) {
          // No self actor available, skip
        }
      }
    } else if (selfIndex > 0) {
      // Move self to the top so the current user is always listed first.
      final self = sharedActors.removeAt(selfIndex);
      sharedActors.insert(0, self);
    }
  }

  final sharedActorIds = sharedActors.map((a) => a.id).toList();

  Command toggleActor(Actor actor) =>
      ShareThreadActor(thread, actor, onUpdate: onUpdate);

  Command toggleInvite(String email) =>
      InviteThreadEmail(thread, email, onUpdate: onUpdate);

  Command toggleGroup(GroupRow group) =>
      ShareThreadGroup(thread, group, onUpdate: onUpdate);

  return Commands(
    prompt: 'Share with',
    emptyMessage: 'Enter an email address to invite someone',
    groups: [
      if (sharedActors.isNotEmpty ||
          sharedGroups.isNotEmpty ||
          thread.inviteEmails.isNotEmpty)
        StaticCommandGroup(
          title: 'Shared',
          commands: [
            ...sharedGroups.map(toggleGroup),
            ...sharedActors.map(toggleActor),
            ...thread.inviteEmails.map(toggleInvite),
          ],
        ),
      _ThreadShareContactsGroup(
        thread: thread,
        excludeActorIds: sharedActorIds,
        onUpdate: onUpdate,
        candidates: candidates,
      ),
    ],
  );
}

class _ThreadShareContactsGroup extends CommandGroup {
  _ThreadShareContactsGroup({
    required this.thread,
    required this.excludeActorIds,
    required this.onUpdate,
    required this.candidates,
  }) : super(title: 'Contacts');

  final Thread thread;
  final List<ActorId> excludeActorIds;
  final Future<void> Function(Thread) onUpdate;
  final _ShareCandidatesCache candidates;

  @override
  Future<List<Command>> list({String? search}) async {
    final sorted = await candidates.get(
      search: search,
      priority: thread.priority,
    );
    final excluded = excludeActorIds.toSet();
    final actors = sorted
        .where((a) => !excluded.contains(a.id))
        .toList(growable: false);

    final commands = <Command>[
      for (final actor in actors)
        ShareThreadActor(thread, actor, onUpdate: onUpdate),
    ];

    if (search != null && _isValidShareEmail(search)) {
      final normalized = search.toLowerCase();
      final emailExists = actors.any(
        (a) => a.email?.toLowerCase() == normalized,
      );
      final alreadyInvited = thread.inviteEmails.contains(normalized);
      if (!emailExists && !alreadyInvited) {
        commands.insert(
          0,
          InviteThreadEmail(thread, normalized, onUpdate: onUpdate),
        );
      }
    }

    return commands;
  }
}

/// Gatekeeps self-removal from a shared thread.
///
/// Returns a [CommandReturn] the caller should return immediately (to block
/// or cancel the removal), or null to proceed.
Future<CommandReturn?> _checkSelfRemoval(
  BuildContext context,
  Thread thread,
) async {
  if (!isThreadShared(thread)) {
    return CommandMessage(
      'Add someone else before removing yourself.',
      isError: true,
    );
  }
  if (!context.mounted) return const CommandSkipped();
  final confirmed = await ConfirmModal(
    title: 'Remove yourself from this thread?',
    message: "You won't be able to access it anymore.",
    confirmLabel: 'Remove',
    destructive: true,
  ).run(context);
  if (!confirmed) return const CommandSkipped();
  return null;
}

/// Removes all of the current user's linked contacts from [thread.contacts].
List<Uuid> _contactsWithoutSelf(Thread thread) {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  return thread.contacts.where((id) => !selfUuids.contains(id)).toList();
}

/// Whether [actor] is currently effectively shared on [thread]. Self is
/// always treated as shared so they appear fully added in the modal — the
/// actual [thread.contacts] row is only mutated when self-removal is
/// explicitly confirmed.
///
/// Looks at the whole person, not just [actor.id]: a thread that lists a
/// linked alias of [actor] (different contact id, same underlying user)
/// already has that person, so the picker should treat them as shared.
bool _actorShared(Thread thread, Actor actor) =>
    actor.self || _linkedContactIdsOnThread(thread, actor).isNotEmpty;

/// Returns every contact id on [thread] that belongs to the same person as
/// [actor] — i.e. [actor.id] itself plus any cached actor whose
/// [_personKey] matches. Used by the share modal so toggling a person off
/// removes all of their linked contact ids in one go (otherwise alias rows
/// would linger in [Thread.contacts] after the primary was removed).
List<Uuid> _linkedContactIdsOnThread(Thread thread, Actor actor) {
  final personKey = _personKey(actor);
  final result = <Uuid>[];
  for (final contactId in thread.contacts) {
    if (contactId == actor.id.toUuid()) {
      result.add(contactId);
      continue;
    }
    final cached = Actor.fromCache(ActorId.fromUuid(contactId));
    if (cached == null) continue;
    if (_personKey(cached) == personKey) result.add(contactId);
  }
  return result;
}

class ShareThreadActor extends Command {
  ShareThreadActor(this.thread, this.actor, {required this.onUpdate})
    : _isShared = _actorShared(thread, actor),
      super(
        title: actor.nameOrEmail,
        eventObject: EventObject.activity,
        eventAction: _actorShared(thread, actor)
            ? EventAction.updated
            : EventAction.shared,
        icon: _actorShared(thread, actor) ? PlotIcon.user : PlotIcon.shareAdd,
        on: _actorShared(thread, actor),
      );

  final Thread thread;
  final Actor actor;
  final Future<void> Function(Thread) onUpdate;
  final bool _isShared;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      Avatar(actor: actor);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (actor.self) {
        final blocker = await _checkSelfRemoval(context, thread);
        if (blocker != null) return blocker;
        await onUpdate(
          thread.copyWith(contacts: Value(_contactsWithoutSelf(thread))),
        );
        return const CommandRefresh();
      }
      final contactUuid = actor.id.toUuid();
      final List<Uuid> newContacts;
      if (_isShared) {
        // Remove every linked alias for this person, not just actor.id —
        // otherwise toggling off the primary would leave the alias contact
        // behind on the thread.
        final toRemove = _linkedContactIdsOnThread(thread, actor).toSet();
        newContacts = thread.contacts
            .where((id) => !toRemove.contains(id))
            .toList();
      } else {
        newContacts = [...thread.contacts, contactUuid];
      }
      await onUpdate(thread.copyWith(contacts: Value(newContacts)));
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareThreadActor: $e', e, stackTrace);
      return CommandMessage('Failed to update sharing', isError: true);
    }
  }
}

/// If the current user is a member of [group], returns a new contacts list
/// that includes the user's primary contact so they retain access when the
/// group is removed from thread sharing. Returns null when no change is
/// needed (user isn't a member, or their contact is already in the list).
List<Uuid>? _contactsWithSelfIfGroupMember(Thread thread, GroupRow group) {
  if (!group.isMember) return null;
  final selfUuid = Base.actorIdOrNull?.toUuid();
  if (selfUuid == null) return null;
  if (thread.contacts.contains(selfUuid)) return null;
  return [...thread.contacts, selfUuid];
}

class ShareThreadGroup extends Command {
  ShareThreadGroup(this.thread, this.group, {required this.onUpdate})
    : super(
        title: group.name,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.users,
        on: true,
      );

  final Thread thread;
  final GroupRow group;
  final Future<void> Function(Thread) onUpdate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final newGroups = thread.groups.where((id) => id != group.id).toList();
      final newContacts = _contactsWithSelfIfGroupMember(thread, group);
      await onUpdate(
        thread.copyWith(
          groups: Value(newGroups.isEmpty ? null : newGroups),
          contacts: newContacts != null
              ? Value(newContacts)
              : const Value.absent(),
        ),
      );
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareThreadGroup: $e', e, stackTrace);
      return CommandMessage('Failed to update sharing', isError: true);
    }
  }
}

class InviteThreadEmail extends Command {
  InviteThreadEmail(this.thread, this.email, {required this.onUpdate})
    : _isInvited = thread.inviteEmails.contains(email.toLowerCase()),
      super(
        title: thread.inviteEmails.contains(email.toLowerCase())
            ? email
            : 'Invite $email',
        subtitle: thread.inviteEmails.contains(email.toLowerCase())
            ? 'Pending invitation'
            : 'Invite by email',
        eventObject: EventObject.activity,
        eventAction: thread.inviteEmails.contains(email.toLowerCase())
            ? EventAction.updated
            : EventAction.shared,
        icon: thread.inviteEmails.contains(email.toLowerCase())
            ? PlotIcon.user
            : PlotIcon.shareAdd,
        on: thread.inviteEmails.contains(email.toLowerCase()),
      );

  final Thread thread;
  final String email;
  final Future<void> Function(Thread) onUpdate;
  final bool _isInvited;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      Avatar(email: email);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final normalized = email.toLowerCase();
      final newEmails = _isInvited
          ? thread.inviteEmails.where((e) => e != normalized).toList()
          : [...thread.inviteEmails, normalized];
      await onUpdate(thread.copyWith(inviteEmails: Value(newEmails)));
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in InviteThreadEmail: $e', e, stackTrace);
      return CommandMessage('Failed to update invitation', isError: true);
    }
  }
}

bool _isValidShareEmail(String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);

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

class ToggleStartFinishCurrentThreadIntent extends Intent {
  const ToggleStartFinishCurrentThreadIntent();
}

class ArchiveCurrentThreadIntent extends Intent {
  const ArchiveCurrentThreadIntent();
}

/// Focuses the current list if nothing is focused; otherwise switches
/// between the Agenda and Activity lists.
class FocusOrToggleAgendaActivityIntent extends Intent {
  const FocusOrToggleAgendaActivityIntent();
}

class ScheduleCurrentThreadIntent extends Intent {
  const ScheduleCurrentThreadIntent();
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
        showFilter: true,
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

    // Call parent to show actions
    final result = await super.run(context);

    // Clear list focus so the editor regains focus naturally
    _controller.clearFocus();

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

  final activeTags = remove.map((cmd) => cmd.tag).toList();
  final suggestedTags = add.map((cmd) => cmd.tag).toList();
  final activeTagCounts = {
    for (final tag in activeTags) tag: TagActors.countOf(thread.tags[tag]),
  };

  ShowCommands makeShowAll() => ShowCommands(
    title: 'All tags',
    icon: PlotIcon.more,
    commandsBuilder: (_) async {
      // Fetch fresh tag state when opened
      final freshThread = await Thread.getOne(thread.id);
      final freshTags = Tag.getAll()
          .where((tag) => !isViewer || tag.type == TagType.count)
          .map((tag) => ToggleThreadTag(freshThread, tag))
          .toList();
      final freshRemove = freshTags
          .where(
            (cmd) =>
                cmd.tag.type != TagType.compute && freshThread.hasTag(cmd.tag),
          )
          .toList();
      final freshAdd = freshTags
          .where(
            (cmd) =>
                cmd.tag.addable == true &&
                cmd.tag.type != TagType.compute &&
                !freshThread.hasTag(cmd.tag),
          )
          .toList();
      return Commands(
        groups: [
          if (freshRemove.isNotEmpty)
            StaticCommandGroup(title: 'Remove tag', commands: freshRemove),
          if (freshAdd.isNotEmpty)
            StaticCommandGroup(title: 'Add tag', commands: freshAdd),
        ],
      );
    },
  );

  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(title: 'Thread: ${thread.title}', commands: commands),
    StaticCommandGroup(
      title: 'Thread: ${thread.title}',
      commands: [],
      infoBuilder: (context, search) {
        final hasSearch = search != null && search.isNotEmpty;
        final filteredActive = hasSearch
            ? activeTags.where((t) => t.matchesSearch(search)).toList()
            : activeTags;
        final filteredSuggested = hasSearch
            ? suggestedTags.where((t) => t.matchesSearch(search)).toList()
            : suggestedTags;
        if (hasSearch && filteredActive.isEmpty && filteredSuggested.isEmpty) {
          return null;
        }
        return TagRow(
          activeTags: filteredActive,
          suggestedTags: filteredSuggested,
          activeTagCounts: activeTagCounts,
          commandBuilder: (tag) => ToggleThreadTag(thread, tag),
          showAllBuilder: makeShowAll,
          showMore: !hasSearch,
        );
      },
      onActivate: (ctx) => makeShowAll().run(ctx),
    ),
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

  Command? primary;
  if (!skipPrimary) {
    if (thread.todo) {
      if (!thread.outstandingTasks) {
        primary = FinishThread(thread, stateIcon: false);
      }
    } else if (thread.on != null) {
      primary = PickScheduleThread(thread);
    } else {
      primary = StartThread(thread, stateIcon: false);
    }
  }

  // For PickScheduleThread inclusion check: is the thread's natural primary a schedule picker?
  final isPrimarySchedule = !thread.todo && thread.on != null;
  final hideArchive = showEventTiming && thread.isLinkScheduleInstance;
  return [
    if (open) ChangeCurrentThread(thread),
    ?primary,
    if (!isPrimarySchedule && !(thread.todo && thread.isFuture))
      PickScheduleThread(thread),
    if (!skipInfrequent) EditThread(thread),
    MoveThreadToPriority(thread),
    PickThreadShared(thread),
    if (!skipInfrequent) MergeThreadInto(thread),
    if (!skipInfrequent && showSplitThread) SplitThread(thread),
    if (!skipInfrequent) ToggleThreadPrivate(thread),
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

  return tagSuggestions
      .where((tag) => !thread.hasTag(tag))
      .take(maxToShow)
      .map((tag) => ToggleThreadTag(thread, tag))
      .toList();
}
