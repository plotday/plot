import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/command/thread_merge.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/util/link_type_copy.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/style/plot_colors.dart';
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

    // Opening an event thread also selects it as the current event.
    // Done BEFORE the no-op short-circuit so re-selecting the same
    // event from the agenda (after returning from another priority
    // that cleared currentEvent) reliably re-arms the selection.
    // Match the canonical event predicate in priority_state.dart:617 —
    // a user-scheduled todo with a date (e.g. the onboarding threads
    // seeded into "Using Plot") also has `at.start != null`, so without
    // `!todo` clicking one wrongly arms it as the current event and the
    // header/feed switch into event-agenda mode.
    final isEvent =
        thread != null &&
        ((thread!.at?.start != null && !thread!.todo) ||
            thread!.isLinkScheduleInstance);
    if (isEvent) {
      nowBloc.setCurrentEvent(thread);
    }

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

      // Pop both ThreadRoute and NewThreadRoute off the inner stack so
      // the cupertino slide-back actually animates. `maybePop` would
      // defer to the page's canPop:false PopScope and silently loop —
      // forced `pop()` bypasses it. The fallback `root.navigate(...)`
      // replaces the inner stack instead of popping, skipping the
      // transition entirely.
      //
      // Only pop when there's something underneath. Notification taps and
      // `/p/X/Y` / `/t/Y` deep links install a single ThreadRoute as the
      // entire inner stack — popping it empties the AutoRouter and reveals
      // its `LoadingPage` placeholder (spinner forever) instead of the
      // activity feed.
      final innerRouter = _innerRouter(context);
      final topName = innerRouter?.current.name;
      if (innerRouter != null &&
          (topName == ThreadRoute.name || topName == NewThreadRoute.name) &&
          innerRouter.stack.length > 1) {
        innerRouter.pop();
        return const CommandDone();
      }

      // Navigate to just the PriorityRoute without ThreadRoute
      return CommandRoute(
        PriorityRoute(priorityIdString: currentPriority.id.toShortString()),
      );
    }

    // Keep NowBloc.context aligned with the priority shown in the header
    // title (the page priority), not the thread's specific priority. The
    // header's tracking pill checks `nowState.context.id ==
    // widget.priority.id` to decide whether to show — when this drifts to
    // the thread's sub-priority the pill silently disappears, which is
    // never what the user wants while the activity feed is still visible.
    nowBloc.setFocus(currentPriority);

    // Push directly onto the inner stack so the cupertino slide fires.
    // `root.navigate(PriorityRoute > ThreadRoute)` (the fallback) swaps
    // PriorityOnlyRoute for ThreadRoute as siblings inside PriorityRoute
    // instead of pushing one on top of the other, so it never animates.
    //
    // The URL uses `currentPriority` (the priority page the user is
    // viewing) — the thread itself may belong to a descendant priority,
    // but routing keeps the parent context so back returns to the right
    // priority page.
    final innerRouter = _innerRouter(context);
    if (innerRouter != null) {
      final threadRoute = ThreadRoute(
        threadIdString: thread!.id.toShortString(),
      );
      // Fire and forget: auto_route's push/replace return Futures that resolve
      // on POP, not on push. Awaiting blocks indefinitely.
      if (innerRouter.current.name == ThreadRoute.name) {
        // Already on a thread (Next/Previous) — replace in place so the back
        // stack stays one ThreadRoute deep. Note: ThreadRoute must declare
        // `usesPathAsKey: true` in the router for replace to actually swap the
        // page widget; otherwise Flutter's Navigator updates the existing
        // route in place via canUpdate=true and the right panel keeps showing
        // the previous thread.
        // ignore: unawaited_futures
        innerRouter.replace(threadRoute);
      } else {
        // ignore: unawaited_futures
        innerRouter.push(threadRoute);
      }
      return const CommandDone();
    }

    // Navigate using the CURRENT priority (not thread's priority)
    // This keeps PriorityPage showing the parent priority
    final route = PriorityRoute(
      priorityIdString: currentPriority.id.toShortString(),
      children: [ThreadRoute(threadIdString: thread!.id.toShortString())],
    );

    return CommandRoute(route);
  }

  /// Returns the inner [StackRouter] hosted by the active [PriorityRoute],
  /// or null when no PriorityRoute is currently mounted (e.g. when called
  /// from the Agenda or Priorities tabs).
  ///
  /// auto_route's [innerRouterOf] only checks immediate child controllers,
  /// so a deeply-nested route like PriorityRoute (root → AppShell → tabs →
  /// ActivityShell → PriorityRoute) is never found in one shot. This
  /// walks the controller tree manually.
  StackRouter? _innerRouter(BuildContext context) {
    return _findInnerRouter(context.router.root, PriorityRoute.name);
  }

  StackRouter? _findInnerRouter(RoutingController root, String routeName) {
    final direct = root.innerRouterOf<StackRouter>(routeName);
    if (direct != null) return direct;
    for (final child in root.childControllers) {
      final hit = _findInnerRouter(child, routeName);
      if (hit != null) return hit;
    }
    return null;
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
    // The command bar surfaces commands across scopes, so this can be
    // called from a context without a PriorityBloc (e.g. Agenda tab).
    final priority = context.read<PriorityBloc?>()?.state.context;
    if (priority == null) return false;
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

      // The agenda no longer contains thread items — only priority block
      // headers. Thread navigation only operates on the activity feed.
      int offset = 1;
      while (offset < 100) {
        // Safety limit
        final item = priorityBloc.getActivityFeedItem(offset);
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

      // The agenda no longer contains thread items — only priority block
      // headers. Thread navigation only operates on the activity feed.
      int offset = -1;
      while (offset > -100) {
        // Safety limit
        final item = priorityBloc.getActivityFeedItem(offset);
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
  AddThread(this._thread, {this.navigate = true, LinkTypeConfig? linkType})
    : super(
        title: commandTitleCreateThread(linkType),
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
    final priorityBloc = context.read<PriorityBloc>();

    // Persist the thread + first note before navigating. Running these in
    // parallel with the route flip let a late `_saveDraft` from the
    // disposing NewThreadPage NoteEditor flip the just-published note row
    // back to draft=true, which the sync push filter excludes — the note
    // would then never reach the server.
    final savedThread = await priorityBloc.add(_data.thread, note: _data.note);

    if (!navigate) {
      return const CommandDone();
    }

    if (context.mounted) {
      // Prime the cache so ThreadBlocProvider builds synchronously, skipping
      // a redundant Thread.getOne and the LoadingPage flash.
      priorityBloc.setThread(savedThread);
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
    final draftNote = priorityBloc.state.draftNote;

    // Honor a user-set title/icon (via the title or type chip on
    // NewThreadPage). Otherwise derive from the link metadata.
    final hasUserTitle = draft.title?.isNotEmpty ?? false;
    final hasUserIcon = draft.icon?.isNotEmpty ?? false;
    final thread = draft.copyWith(
      title: hasUserTitle ? const Value.absent() : Value(linkTitle ?? linkUrl),
      icon: hasUserIcon ? const Value.absent() : Value(linkFavicon ?? 'link'),
    );
    final savedThread = thread.copyWith(draft: false);

    // The draft note may have been persisted locally while the user added
    // the link (NoteEditor saves on every edit). The link is being moved
    // to a thread-level LinkRow and the body is empty, so retire the draft
    // row — otherwise ThreadBloc.getDraftByActivity loads it on the new
    // ThreadPage and the link reappears in the editor. Mark it
    // `draft: false, archivedAt: now` so it's filtered out by both the
    // draft lookup (`draft = true`) and the published-notes watch
    // (`archivedAt is null`).
    final hasPersistedActions = (draftNote.actions?.isNotEmpty ?? false);
    final hasPersistedContent = (draftNote.content?.isNotEmpty ?? false);

    // Persist everything before navigating to avoid the same race that
    // dropped notes from AddThreadWithNote — late `_saveDraft` writes from
    // the disposing NewThreadPage NoteEditor must not interleave with these.
    if (hasPersistedActions || hasPersistedContent) {
      await draftNote
          .copyWith(draft: false, archivedAt: Value(DateTime.now()))
          .save(pushToRemote: false);
    }
    await priorityBloc.add(thread);
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
    await Store.get.save(
      Store.get.links,
      linkRow.toCompanion(false),
      LinksBase(),
    );

    if (context.mounted) {
      priorityBloc.setThread(savedThread);
      await context.router.replace(
        ThreadRoute(threadIdString: savedThread.id.toShortString()),
      );
    }

    return const CommandDone();
  }
}

/// "Skip active for threads like this" — toggles a mute rule for the
/// thread's channel + author + similar-title cluster. On set, the seed
/// thread is marked read + inactive (moves to Done) and the server fans
/// out per-user to every matching thread (find_mute_candidates); future
/// matching threads arrive directly in Done instead of unread in Doing.
/// On clear, the rule reverses — only the rule anchor is removed; threads
/// the user already saw stay where they are.
class MuteSimilarThreads extends Command {
  MuteSimilarThreads(this._thread, {PriorityBloc? bloc})
    // ignore: prefer_initializing_formals
    : _bloc = bloc,
      super(
        title: _thread.muteByThreadId == null
            ? 'Skip active for threads like this'
            : 'Stop skipping active for these',
        eventObject: EventObject.activity,
        eventAction: _thread.muteByThreadId == null
            ? EventAction.tagged
            : EventAction.untagged,
        icon: PlotIcon.broom,
      );

  final Thread _thread;
  final PriorityBloc? _bloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = _bloc ?? context.read<PriorityBloc?>();
    final wasMuted = _thread.muteByThreadId != null;
    if (wasMuted) {
      // Clear: drop the rule anchor on this thread. The server's clear_mute
      // clears the anchor on every peer with the same seed; clients pick
      // those up on the next sync pull. read_at / active are left as-is so
      // the user's prior state is preserved.
      final unmuted = _thread.copyWith(muteByThreadId: const Value(null));
      priorityBloc?.optimisticallyUpdateThread(unmuted);
      await unmuted.save();
    } else {
      // Set: mark the seed read + inactive (move to Done) and stamp it as
      // the rule anchor. Server-side apply_mute fans out to matching peers;
      // clients see the additional reads + inactives on the next sync pull.
      final muted = _thread.asInactive().copyWith(
        muteByThreadId: Value(_thread.id),
      );
      priorityBloc?.optimisticallyUpdateThread(muted);
      await muted.save();
    }
    return const CommandDone();
  }
}

class ArchiveThread extends Command {
  ArchiveThread(Thread thread, {PriorityBloc? bloc})
    : _thread = Future.value(thread),
      // ignore: prefer_initializing_formals
      _bloc = bloc,
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

  ArchiveThread.future(this._thread, {PriorityBloc? bloc})
    // ignore: prefer_initializing_formals
    : _bloc = bloc,
      super(
        title: 'Archive',
        eventObject: EventObject.activity,
        eventAction: EventAction.archived,
        icon: PlotIcon.archived,
      );

  final Future<Thread> _thread;

  /// Captured at construction time when the caller has a context that
  /// resolves [PriorityBloc]. The CommandModal flow may dispatch `run` with
  /// a context whose nearest ancestor is the global Overlay (no bloc above
  /// it), so the run-time `context.read` returns null and the optimistic
  /// update silently no-ops. Capturing here keeps the optimistic path firing
  /// regardless of dispatch.
  final PriorityBloc? _bloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final thread = await _thread;
    final isArchived = thread.archivedAt != null;

    // Capture navigation BEFORE archive (only when archiving, not un-archiving)
    if (!context.mounted) return const CommandDone();
    final priorityBloc = _bloc ?? context.read<PriorityBloc?>();
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

/// Whether an RSVP change should target this specific occurrence rather than
/// the series. True only when the user already has an occurrence-level RSVP
/// that was set directly on the occurrence (not inherited from the series).
/// Initial RSVPs and toggles of series-inherited RSVPs target the series.
bool rsvpTargetsOccurrence({
  required bool hasExistingRsvp,
  required String? occurrence,
  required bool inheritedFromSeries,
}) =>
    hasExistingRsvp && occurrence != null && !inheritedFromSeries;

/// Shared base for the three RSVP-setting commands. Applies the optimistic
/// status change and POSTs `/sync/schedule/status`, targeting the occurrence
/// or series per [rsvpTargetsOccurrence].
abstract class _RsvpCommand extends _UpdateThreadCommand {
  _RsvpCommand(
    super.thread, {
    required super.title,
    required super.icon,
  }) : super(
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  Future<CommandReturn> apply(BuildContext context, String? status) async {
    final updated = thread.withRsvpStatus(status);
    await saveOptimistically(context, updated);

    final targetsOccurrence = rsvpTargetsOccurrence(
      hasExistingRsvp: thread.currentUserRsvp != null,
      occurrence: thread.occurrence,
      inheritedFromSeries: thread.rsvpInheritedFromSeries,
    );

    api
        .post<dynamic>(
          '/sync/schedule/status',
          body: {
            'thread_id': thread.id.toString(),
            if (targetsOccurrence) 'occurrence': thread.occurrence,
            'status': status,
          },
        )
        .catchError((_) {});

    return const CommandDone();
  }
}

class AttendRsvp extends _RsvpCommand {
  AttendRsvp(super.thread)
      : super(title: 'Going', icon: PlotIcon.rsvpGoing);

  @override
  Future<CommandReturn> run(BuildContext context) => apply(context, 'attend');
}

class SkipRsvp extends _RsvpCommand {
  SkipRsvp(super.thread)
      : super(title: 'Not going', icon: PlotIcon.rsvpDeclined);

  @override
  Future<CommandReturn> run(BuildContext context) => apply(context, 'skip');
}

class ClearRsvp extends _RsvpCommand {
  ClearRsvp(super.thread)
      : super(title: 'Clear response', icon: PlotIcon.rsvpUndecided);

  @override
  Future<CommandReturn> run(BuildContext context) => apply(context, null);
}

/// Opens a standard [CommandModal] letting the user set their RSVP. "Clear
/// response" only appears when the user currently has a response. Invoked by
/// the RSVP chip's tap.
class ShowRsvpOptions extends ShowCommands {
  ShowRsvpOptions(Thread thread)
      : super(
          title: 'RSVP',
          icon: PlotIcon.rsvpGoing,
          eventObject: EventObject.activity,
          eventAction: EventAction.opened,
          commands: _build(thread),
        );

  static Commands _build(Thread thread) => Commands(
        prompt: 'Your RSVP',
        groups: [
          StaticCommandGroup(
            commands: [
              AttendRsvp(thread),
              SkipRsvp(thread),
              if (thread.currentUserRsvp != null) ClearRsvp(thread),
            ],
          ),
        ],
      );
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
                    label: 'Focus',
                    initialValue: thread.priority,
                    required: true,
                    items: (search) async {
                      final priorities = await Priority.get(
                        order: PriorityOrder.nested,
                      );
                      if (search == null || search.isEmpty) return priorities;
                      return priorities
                          .where((p) => p.matchesSearch(search))
                          .toList();
                    },
                    labelBuilder: (p) => FocusLabel(priority: p),
                    titleBuilder: (p) => p.ancestorsLabel() != null
                        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
                        : p.title,
                  ),
                  FormButton(
                    key: 'save',
                    isPrimary: true,
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final priority = values['priority'] as Priority;
                      return _SaveThreadEdit(
                        thread,
                        title,
                        priority,
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
    this.newPriority, {
    this.onSaved,
    super.priorityBloc,
  }) : super(
         title: 'Save',
         eventObject: EventObject.activity,
         eventAction: EventAction.updated,
       );

  final String newTitle;
  final Priority newPriority;
  final VoidCallback? onSaved;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(
      context,
      thread.copyWith(
        title: Value(newTitle.isEmpty ? null : newTitle),
        priority: newPriority,
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
  }) : onUpdate = onUpdate ?? ((thread) => thread.save());

  final Thread thread;
  final Future<void> Function(Thread) onUpdate;
  final PriorityBloc? priorityBloc;

  /// Optimistically update the UI, then persist the thread.
  /// Commands that run inside modals must pass [priorityBloc] explicitly
  /// because the modal context doesn't have PriorityBloc in its tree.
  ///
  /// [watchScheduleAction] forwards to [PriorityBloc.optimisticallyUpdateThread]
  /// so the override won't settle until the new `schedule.action` lands.
  /// Retained for the legacy action-tab path; no current command sets it.
  Future<void> saveOptimistically(
    BuildContext context,
    Thread updatedThread, {
    bool watchScheduleAction = false,
  }) async {
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
    bloc?.optimisticallyUpdateThread(
      updatedThread,
      watchScheduleAction: watchScheduleAction,
    );
    // Also push the optimistic update into ThreadBloc (when present) so the
    // open ThreadPage rebuilds immediately instead of waiting for the
    // SQLite save → Thread.watchOne stream to tick.
    try {
      context.read<ThreadBloc>().optimisticallyUpdateThread(updatedThread);
    } catch (_) {}
    await onUpdate(updatedThread);
    // After save, reload the agenda from fresh stream data so changes that
    // add/remove items (e.g. starting a link schedule thread creates a base
    // todo duplicate) appear immediately instead of waiting for the next
    // unsuppressed stream emission.
    bloc?.refreshAgenda();
  }
}

/// Flips `thread.active`. When activating, marks the thread read (the
/// leading icon's "mark done" branch handled by [FinishThread]). Used by:
///   - leading-icon tap on non-active threads in the activity feed
///   - swipe-right short on touch
///   - ⌘D shortcut on ThreadPage
///   - command palette
class ToggleThreadActive extends _UpdateThreadCommand {
  ToggleThreadActive(super.thread, {super.onUpdate})
    : super(
        title: thread.todo ? 'Move to Done' : 'Add to Active',
        eventObject: EventObject.activity,
        eventAction: thread.todo ? EventAction.finished : EventAction.started,
        icon: thread.todo
            ? FontAwesomeIcons.circleCheck
            : FontAwesomeIcons.circlePlus,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyD),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(
      context,
      thread.copyWith(
        todo: !thread.todo,
        unread: false,
        readAt: thread.unread
            ? Value(thread.contentTimestamp)
            : const Value.absent(),
      ),
    );
    return const CommandDone();
  }
}

/// Toggles `thread.task` — the per-user "task list" flag. Independent of
/// `active` / `toRead`. Surfaced as a hover-row command that stays visible
/// when the flag is set (like an enabled tag).
class ToggleThreadTask extends _UpdateThreadCommand {
  ToggleThreadTask(super.thread, {super.onUpdate})
    : super(
        title: thread.task ? 'Remove from task list' : 'Add to task list',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.activity,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyT),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.withTask(!thread.task));
    return const CommandDone();
  }
}

/// Toggles `thread.toRead` — the per-user "reading list" flag. Independent
/// of `active` / `task`. Surfaced as a hover-row command that stays
/// visible when the flag is set (like an enabled tag).
class ToggleThreadToRead extends _UpdateThreadCommand {
  ToggleThreadToRead(super.thread, {super.onUpdate})
    : super(
        title: thread.toRead
            ? 'Remove from reading list'
            : 'Add to reading list',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.bookOpenLines,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyE),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await saveOptimistically(context, thread.withToRead(!thread.toRead));
    return const CommandDone();
  }
}

class DisassociateThread extends Command {
  DisassociateThread(this.thread, {this.finish = false, this.onBeforeRun})
    : super(
        title: finish ? 'Finish' : 'Remove from event',
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
    final order = Order.first();
    if (finish) {
      // Finish + disassociate: remove all copies (associated and todo)
      priorityBloc?.optimisticallyRemoveThread(thread.id, finishTodo: true);
      await thread.copyWith(todo: false).save();
      await thread.disassociate(order: order);
    } else {
      // Just disassociate: prune the association map AND splice in a
      // schedule-restored copy so the thread re-appears as a regular
      // todo on the agenda the instant the user clicks the X — instead
      // of vanishing while the DB write to restore the schedule
      // resolves. `disassociate` is now a pure association op, so we
      // explicitly persist the schedule restore alongside it.
      priorityBloc?.optimisticallyDisassociate(thread.id);
      priorityBloc?.optimisticallyUpdateThread(
        thread.withScheduleRestored(order: order),
      );
      await thread.disassociate(order: order);
      await thread.withScheduleRestored(order: order).save();
    }
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
         title: 'Move to Done',
         eventObject: EventObject.activity,
         eventAction: EventAction.finished,
         icon: stateIcon && thread.todo
             ? FontAwesomeIcons.circle
             : FontAwesomeIcons.circleCheck,
         hoverIcon: stateIcon && thread.todo
             ? FontAwesomeIcons.circleCheck
             : null,
         shortcut: platformSingleActivator(LogicalKeyboardKey.enter),
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
    final finished = thread.copyWith(
      todo: false,
      bump: bump,
      unread: false,
      readAt: thread.unread
          ? Value(thread.contentTimestamp)
          : const Value.absent(),
    );
    // Optimistically flip ThreadBloc's thread (when present) so the Finish
    // button on the open ThreadPage swaps to To-do instantly instead of
    // waiting for the SQLite save → Thread.watchOne stream to tick.
    try {
      context.read<ThreadBloc>().optimisticallyUpdateThread(finished);
    } catch (_) {}
    if (onBeforeRun != null) {
      // Animation layer handles optimistic removal
      await onBeforeRun!(context);
    } else {
      // No animation: remove the base todo and update remaining link schedule
      // instances to todo=false so the icon reflects the finished state.
      priorityBloc?.optimisticallyRemoveThread(thread.id, finishTodo: true);
    }
    await onUpdate(finished);

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

class SetThreadDuration extends _UpdateThreadCommand {
  SetThreadDuration(super.thread, this.newDuration, {super.onUpdate})
    : super(
        title: 'Set duration',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Duration? newDuration;

  /// Pure helper exposed for unit testing. Returns the new [DateTimeRange]
  /// for [at] given a [newDuration] (null clears the end time, leaving an
  /// open-ended scheduled-at-only event). Returns null if [at] has no start.
  static DateTimeRange? computeAt(DateTimeRange? at, Duration? newDuration) {
    if (at?.start == null) return null;
    if (newDuration == null) return DateTimeRange(at!.start, null);
    return DateTimeRange(at!.start, at.start!.add(newDuration));
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final newAt = computeAt(thread.at, newDuration);
    if (newAt == null) return const CommandDone();
    await saveOptimistically(context, thread.copyWith(at: Value(newAt)));
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
    // ignore: prefer_initializing_formals
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
                    final today = Time.now();
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
              onPress: (date) {
                // The optimistic UI update inside saveOptimistically runs
                // synchronously before the first await, so we can pop the
                // modal immediately and let the SQLite writes finish in the
                // background. The agenda underneath has already painted the
                // thread on the new date.
                unawaited(
                  ScheduleThread(
                    _thread,
                    when: date.toDate(),
                    onUpdate: _onUpdate,
                    priorityBloc: bloc,
                  ).run(context),
                );
                Modal.pop(context, Value<CommandReturn>(const CommandDone()));
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FButton(
                    variant: FButtonVariant.secondary,
                    onPress: () {
                      unawaited(
                        ScheduleThread(
                          _thread,
                          when: Thread.todoNowDate,
                          onUpdate: _onUpdate,
                          priorityBloc: bloc,
                        ).run(context),
                      );
                      Modal.pop(
                        context,
                        Value<CommandReturn>(const CommandDone()),
                      );
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

/// Bulk reschedule of every thread in an activity-feed section (Today or a
/// future Scheduled day). Shows the same calendar date picker as
/// [PickScheduleThread], then runs [ScheduleThread] for each thread.
class RescheduleAllInBlock extends Command {
  RescheduleAllInBlock(this.threads, {required this.sectionLabel})
    : super(
        title: 'Reschedule all',
        icon: PlotIcon.reschedule,
        eventObject: EventObject.modal,
        eventAction: EventAction.opened,
      );

  final List<Thread> threads;
  final String sectionLabel;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (threads.isEmpty) return const CommandSkipped();

    // Capture PriorityBloc before showing modal — modal context won't have it
    PriorityBloc? bloc;
    try {
      bloc = context.read<PriorityBloc>();
    } catch (_) {}

    final picked = await Modal(
      constraints: const BoxConstraints(maxWidth: 380, maxHeight: 640),
      builder: (modalContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Reschedule all',
                style: modalContext.theme.typography.xl2.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                threads.length == 1
                    ? '1 thread in $sectionLabel'
                    : '${threads.length} threads in $sectionLabel',
                style: TextStyle(
                  color: modalContext.theme.plotColors.veryMuted,
                  fontSize: modalContext.theme.typography.sm.fontSize,
                ),
              ),
            ),
            FCalendar(
              control: .managedDate(
                controller: FCalendarController.date(
                  selectable: (date) {
                    final today = Time.now();
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
              onPress: (date) => Modal.pop(modalContext, Value(date.toDate())),
            ),
            const SizedBox(height: 12),
            FButton(
              variant: FButtonVariant.secondary,
              onPress: () => Modal.pop(modalContext, Value(Thread.todoNowDate)),
              child: const Text('Today'),
            ),
          ],
        ),
      ),
    ).show<Date>(context);

    if (!picked.present) return const CommandSkipped();
    if (!context.mounted) return const CommandSkipped();

    // Compute the new state for each thread up front. Mirrors ScheduleThread:
    // ensure it's a todo (creates per-user schedule if needed), then move to
    // the target date on the per-user schedule.
    final date = picked.value == Thread.todoNowDate ? null : picked.value;
    final updates = threads.map((thread) {
      final asTodo = thread.todo ? thread : thread.copyWith(todo: true);
      return asTodo.reorderTo(asTodo.order, date: date);
    }).toList();

    // Apply optimistic updates synchronously so every thread visibly moves
    // in the same frame. Each call mutates bloc state in memory; the agenda
    // repaints once on the next vsync regardless of how many we apply.
    for (final updated in updates) {
      bloc?.optimisticallyUpdateThread(updated);
    }

    // Persist in parallel and refresh the agenda once at the end. The old
    // sequential `await ScheduleThread(...).run(...)` loop ran N awaited
    // SQLite save chains and called refreshAgenda() N times — and
    // refreshAgenda cancels and re-subscribes three Drift streams, which
    // dominates the cost for large sections.
    unawaited(() async {
      try {
        await Future.wait(updates.map((t) => t.save()));
      } catch (e, stackTrace) {
        log.warning('Error rescheduling threads in bulk', e, stackTrace);
        Tracker.captureException(e, stackTrace);
      } finally {
        bloc?.refreshAgenda();
      }
    }());

    return const CommandDone();
  }
}

/// Bulk mark-as-read for every unread thread in the activity-feed "New"
/// section. No confirmation modal — fires immediately, mirroring the
/// per-thread read behaviour that runs after 750ms on the thread page.
class MarkAllReadInNewSection extends Command {
  MarkAllReadInNewSection(this.threads)
    : super(
        title: 'Mark all read',
        icon: PlotIcon.doneAll,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final List<Thread> threads;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (threads.isEmpty) return const CommandSkipped();

    PriorityBloc? bloc;
    try {
      bloc = context.read<PriorityBloc>();
    } catch (_) {}

    for (final thread in threads) {
      if (!thread.unread) continue;
      final updated = thread.copyWith(
        unread: false,
        readAt: Value(thread.contentTimestamp),
      );
      bloc?.optimisticallyUpdateThread(updated);
      unawaited(updated.save());
    }
    return const CommandDone();
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
    // Drive the agenda rebuild from PriorityBloc so the thread visibly
    // jumps to its new priority block before the Drift watch fires. The
    // override clears once the stream's emitted thread has the new
    // priority.id (default watched fields include priorityId).
    final priorityBloc = context.read<PriorityBloc?>();
    final updated = thread.copyWith(priority: priority!);
    priorityBloc?.optimisticallyUpdateThread(updated);
    // Fire-and-forget the local save + learning signal so the modal closes
    // the moment the user picks a priority. The optimistic override above
    // already moved the thread in the UI; settling on the Drift watch
    // emission only requires save() to land eventually.
    unawaited(_persistPriorityMove(updated, priority!));
    return const CommandDone();
  }
}

Future<void> _persistPriorityMove(Thread updated, Priority priority) async {
  try {
    await updated.save();
  } catch (e, stackTrace) {
    log.warning('Error persisting priority move', e, stackTrace);
    Tracker.captureException(e, stackTrace);
    // Save failed — skip the learning signal so we don't tell the server
    // about a move that isn't going to land.
    return;
  }
  // Best-effort learning signal — sets user_moved = TRUE and triggers
  // reclassify_user_threads. A failure here leaves the move intact.
  try {
    await api.post<dynamic>(
      '/sync/priority-moves',
      body: {
        'thread_id': updated.id.toString(),
        'priority_id': priority.id.toString(),
      },
    );
  } catch (_) {
    // Offline / transient — the move itself is already synced via thread
    // save; the learning signal will be re-sent next time.
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
    // `getRaw` skips `pullArchived` and the active/unread enrichment (two
    // join queries on threads + schedules) — none of which the move modal
    // displays — so the modal opens immediately instead of stalling on the
    // enrichment round-trip.
    final priorities = await Priority.getRaw(order: PriorityOrder.recent);
    final filteredPriorities = priorities
        .where((p) => p.id != thread.priority.id)
        .toList();

    return Commands(
      prompt: 'Move thread to focus',
      groups: [
        StaticCommandGroup(
          title: 'Focuses',
          commands: filteredPriorities
              .map((priority) => MoveToPriority(thread, priority))
              .toList(),
        ),
      ],
      secondaryCommand: (prompt) => _CreateAndMoveToNewPriority(thread),
    );
  }
}

class _CreateAndMoveToNewPriority extends Command {
  _CreateAndMoveToNewPriority(this.thread)
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.activity,
        eventAction: EventAction.moved,
      );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc?>();
    final priority = await createPriorityInline(
      context,
      parent: thread.priority,
    );
    if (priority == null) return const CommandSkipped();
    final updated = thread.copyWith(priority: priority);
    priorityBloc?.optimisticallyUpdateThread(updated);
    // Fire-and-forget so the modal closes immediately. The optimistic
    // override moved the thread in the UI; save() and the learning signal
    // settle in the background. See [_persistPriorityMove].
    unawaited(_persistPriorityMove(updated, priority));
    return const CommandDone();
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
    final filtered = threads
        .where((t) => t.id != thread.id)
        // Exclude merge sources — they're archived placeholders that
        // would silently re-archive any merge into them.
        .where((t) => t.mergedIntoThreadId == null)
        .toList();
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
    if (source.mergedIntoThreadId != null ||
        target.mergedIntoThreadId != null) {
      // Source is already absorbed, or target is itself a merge source.
      // The picker filters this out; this is a guardrail.
      return const CommandSkipped();
    }

    final db = Store.get;
    final now = DateTime.now();

    final sourceRow = await (db.select(
      db.threads,
    )..where((t) => t.id.equalsValue(source.id))).getSingleOrNull();
    final targetRow = await (db.select(
      db.threads,
    )..where((t) => t.id.equalsValue(target.id))).getSingleOrNull();
    if (sourceRow == null || targetRow == null) return const CommandSkipped();

    // 1. Collect non-draft source notes for later move. The
    // `note_thread_link_key_unique` server index scopes uniqueness to
    // `(thread_id, link_id, key)`, so connector notes from different
    // links coexist on the merged thread without client-side handling.
    final sourceNoteRows =
        await (db.select(db.notes)
              ..where((n) => n.threadId.equalsValue(source.id))
              ..where((n) => n.draft.equals(false)))
            .get();

    // 2. Absorb identity fields onto target in one row write.
    final mergedContacts = mergeAudienceUnion(target.contacts, source.contacts);
    final mergedGroups = mergeAudienceUnion(target.groups, source.groups);
    final newImportance = mergeImportanceMax(
      targetRow.importance,
      sourceRow.importance,
    );
    // urgent merges with OR: if either side flagged urgent, the merged
    // thread stays urgent. Null is treated as "no preference".
    final mergedUrgent =
        (targetRow.urgent ?? false) || (sourceRow.urgent ?? false);
    final newUrgent = (targetRow.urgent == null && sourceRow.urgent == null)
        ? null
        : mergedUrgent;

    await db.add(
      db.threads,
      targetRow
          .copyWith(
            contacts: Value(mergedContacts),
            groups: Value(mergedGroups),
            importance: newImportance,
            urgent: Value(newUrgent),
            updatedAt: now,
          )
          .toCompanion(false),
    );

    // 3. Archive source and set the back-reference. The server-side
    // transfer_twist_key_on_merge trigger handles (twist_id, key)
    // migration on this update; the client doesn't read or write
    // those columns since they're not synced down.
    await source
        .copyWith(archivedAt: Value(now), mergedIntoThreadId: Value(target.id))
        .save();

    // 4. Move notes.
    for (final noteRow in sourceNoteRows) {
      final note = await Note.get(noteRow.id);
      if (note == null) continue;
      await note
          .copyWith(threadId: target.id, mergedFromThreadId: Value(source.id))
          .save(pushToRemote: false);
    }

    // 5. Move links.
    final linkRows = await (db.select(
      db.links,
    )..where((l) => l.threadId.equals(source.id.toBytes()))).get();
    for (final linkRow in linkRows) {
      await db.add(
        db.links,
        linkRow
            .copyWith(
              threadId: Value(target.id),
              mergedFromThreadId: Value(source.id),
              updatedAt: now,
            )
            .toCompanion(false),
      );
    }

    // 6. Tag union (existing behavior).
    final sourceTagRows = await (db.select(
      db.threadTags,
    )..where((t) => t.id.equalsValue(source.id))).get();
    final targetTagRows = await (db.select(
      db.threadTags,
    )..where((t) => t.id.equalsValue(target.id))).get();
    final targetByOccurrence = <String, ThreadTagsRow>{};
    for (final row in targetTagRows) {
      targetByOccurrence[row.occurrence] = row;
    }
    for (final sourceTagRow in sourceTagRows) {
      final sourceTags = sourceTagRow.tags ?? const <Tag, List<ActorId>>{};
      if (sourceTags.isEmpty) continue;
      final targetTagRow = targetByOccurrence[sourceTagRow.occurrence];
      final existing = targetTagRow?.tags ?? <Tag, List<ActorId>>{};
      var changed = false;
      final merged = Map<Tag, List<ActorId>>.from(existing);
      for (final entry in sourceTags.entries) {
        final current = merged[entry.key] ?? const [];
        final newActors = entry.value
            .where((a) => !current.contains(a))
            .toList();
        if (newActors.isNotEmpty) {
          merged[entry.key] = [...current, ...newActors];
          changed = true;
        }
      }
      if (changed) {
        final out = targetTagRow != null
            ? targetTagRow.copyWith(
                tags: Value(merged.isEmpty ? null : merged),
                updatedAt: now,
              )
            : ThreadTagsRow(
                id: target.id,
                occurrence: sourceTagRow.occurrence,
                updatedAt: now,
                tags: merged.isEmpty ? null : merged,
              );
        await db.add(db.threadTags, out.toCompanion(false));
      }
    }

    // 7. Schedule fill-gaps (existing behavior).
    final sourceSchedules = await (db.select(
      db.schedules,
    )..where((s) => s.threadId.equalsValue(source.id))).get();
    final targetSchedules = await (db.select(
      db.schedules,
    )..where((s) => s.threadId.equalsValue(target.id))).get();
    // Per-user schedules are gone; only shared schedules remain, so the
    // slot key collapses to the occurrence string.
    final targetSlots = <String>{
      for (final s in targetSchedules) s.occurrence ?? '',
    };
    for (final s in sourceSchedules) {
      final slot = s.occurrence ?? '';
      if (!targetSlots.contains(slot)) {
        await db.add(
          db.schedules,
          s
              .copyWith(threadId: Value(target.id), updatedAt: now)
              .toCompanion(false),
        );
      }
    }

    // 8. thread_association move.
    final childRows =
        await (db.select(db.threadAssociations)
              ..where((t) => t.childThreadId.equalsValue(source.id))
              ..where((t) => t.archivedAt.isNull()))
            .get();
    final targetHasParent =
        (await (db.select(db.threadAssociations)
                  ..where((t) => t.childThreadId.equalsValue(target.id))
                  ..where((t) => t.archivedAt.isNull()))
                .get())
            .isNotEmpty;
    for (final row in childRows) {
      if (targetHasParent) {
        await db.add(
          db.threadAssociations,
          row
              .copyWith(archivedAt: Value(now), updatedAt: now)
              .toCompanion(false),
        );
      } else {
        await db.add(
          db.threadAssociations,
          row
              .copyWith(childThreadId: target.id, updatedAt: now)
              .toCompanion(false),
        );
      }
    }
    final parentRows =
        await (db.select(db.threadAssociations)
              ..where((t) => t.parentThreadId.equalsValue(source.id))
              ..where((t) => t.archivedAt.isNull()))
            .get();
    for (final row in parentRows) {
      await db.add(
        db.threadAssociations,
        row
            .copyWith(parentThreadId: target.id, updatedAt: now)
            .toCompanion(false),
      );
    }

    // 9. Push and navigate.
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.note));
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.thread));
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
    final viaRef =
        await (db.select(db.threads)
              ..where((t) => t.mergedIntoThreadId.equalsValue(threadId))
              ..limit(1))
            .get();
    if (viaRef.isNotEmpty) return true;

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
    final db = Store.get;

    // Primary: rows that point at this thread via the back-reference.
    final viaRef = await (db.select(
      db.threads,
    )..where((t) => t.mergedIntoThreadId.equalsValue(thread.id))).get();
    final sourceIds = <ThreadId>{for (final r in viaRef) r.id};

    // Fallback: legacy merges before the back-reference column existed.
    final noteRows =
        await (db.select(db.notes)
              ..where((n) => n.threadId.equalsValue(thread.id))
              ..where((n) => n.mergedFromThreadId.isNotNull()))
            .get();
    for (final n in noteRows) {
      if (n.mergedFromThreadId != null) sourceIds.add(n.mergedFromThreadId!);
    }
    final linkRows =
        await (db.select(db.links)
              ..where((l) => l.threadId.equals(thread.id.toBytes()))
              ..where((l) => l.mergedFromThreadId.isNotNull()))
            .get();
    for (final l in linkRows) {
      if (l.mergedFromThreadId != null) sourceIds.add(l.mergedFromThreadId!);
    }

    if (sourceIds.isEmpty || !context.mounted) return const CommandSkipped();

    final sourceThreads = <Thread>[];
    for (final id in sourceIds) {
      final threads = await Thread.get(id: id, archived: null);
      if (threads.isNotEmpty) sourceThreads.add(threads.first);
    }
    if (sourceThreads.isEmpty || !context.mounted) {
      return const CommandSkipped();
    }

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
    final db = Store.get;
    final now = DateTime.now();

    final sourceRow = await (db.select(
      db.threads,
    )..where((t) => t.id.equalsValue(source.id))).getSingleOrNull();
    final currentRow = await (db.select(
      db.threads,
    )..where((t) => t.id.equalsValue(current.id))).getSingleOrNull();
    if (sourceRow == null || currentRow == null) return const CommandSkipped();

    // 1. Move notes back.
    final noteRows =
        await (db.select(db.notes)
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

    // 2. Move links back.
    final linkRows =
        await (db.select(db.links)
              ..where((l) => l.threadId.equals(current.id.toBytes()))
              ..where((l) => l.mergedFromThreadId.equals(source.id.toBytes())))
            .get();
    for (final linkRow in linkRows) {
      await db.add(
        db.links,
        linkRow
            .copyWith(
              threadId: Value(source.id),
              mergedFromThreadId: const Value(null),
              updatedAt: now,
            )
            .toCompanion(false),
      );
    }

    // 2b. Move schedules back (fill-gaps inverse of merge step 7).
    final allSourceSchedules = await (db.select(
      db.schedules,
    )..where((s) => s.threadId.equalsValue(source.id))).get();
    // Per-user schedules are gone; slot key collapses to occurrence.
    final sourceSlots = <String>{
      for (final s in allSourceSchedules) s.occurrence ?? '',
    };
    final currentSchedules = await (db.select(
      db.schedules,
    )..where((s) => s.threadId.equalsValue(current.id))).get();
    for (final s in currentSchedules) {
      final slot = s.occurrence ?? '';
      if (!sourceSlots.contains(slot)) {
        await db.add(
          db.schedules,
          s
              .copyWith(threadId: Value(source.id), updatedAt: now)
              .toCompanion(false),
        );
      }
    }

    // Common query used in steps 2c and 3: other sources still merged into
    // current (excluding the source being split out).
    final otherActiveSourceRows =
        await (db.select(db.threads)
              ..where((t) => t.mergedIntoThreadId.equalsValue(current.id))
              ..where((t) => t.id.isNotValue(source.id.toBytes()))
              ..where((t) => t.archivedAt.isNotNull()))
            .get();

    // 2c. Tag set-subtract on current. Source's thread_tag rows are still
    // on source.id (untouched by merge — merge only copied actors into
    // current's tag rows). Subtract source's actors per (tag, occurrence)
    // from current, keeping any actors carried by other still-merged
    // sources.
    final sourceTagRows = await (db.select(
      db.threadTags,
    )..where((t) => t.id.equalsValue(source.id))).get();
    final otherSourceTagRows = <ThreadTagsRow>[];
    for (final s in otherActiveSourceRows) {
      otherSourceTagRows.addAll(
        await (db.select(
          db.threadTags,
        )..where((t) => t.id.equalsValue(s.id))).get(),
      );
    }
    final currentTagRows = await (db.select(
      db.threadTags,
    )..where((t) => t.id.equalsValue(current.id))).get();
    for (final currentRow in currentTagRows) {
      final occurrence = currentRow.occurrence;
      final currentTags = currentRow.tags ?? const <Tag, List<ActorId>>{};
      if (currentTags.isEmpty) continue;
      // Actors from source for this occurrence:
      final sourceActorsByTag = <Tag, Set<ActorId>>{};
      for (final s in sourceTagRows) {
        if (s.occurrence != occurrence) continue;
        final m = s.tags ?? const <Tag, List<ActorId>>{};
        for (final entry in m.entries) {
          sourceActorsByTag
              .putIfAbsent(entry.key, () => <ActorId>{})
              .addAll(entry.value);
        }
      }
      if (sourceActorsByTag.isEmpty) continue;
      // Actors carried by other still-merged sources for this occurrence:
      final keptByOthers = <Tag, Set<ActorId>>{};
      for (final o in otherSourceTagRows) {
        if (o.occurrence != occurrence) continue;
        final m = o.tags ?? const <Tag, List<ActorId>>{};
        for (final entry in m.entries) {
          keptByOthers
              .putIfAbsent(entry.key, () => <ActorId>{})
              .addAll(entry.value);
        }
      }
      // Compute new tags for current: drop actors that source contributed
      // unless another active source still carries them.
      var changed = false;
      final updated = <Tag, List<ActorId>>{};
      for (final entry in currentTags.entries) {
        final remove = sourceActorsByTag[entry.key] ?? const <ActorId>{};
        final keep = keptByOthers[entry.key] ?? const <ActorId>{};
        final filtered = entry.value
            .where((a) => !remove.contains(a) || keep.contains(a))
            .toList();
        if (filtered.length != entry.value.length) changed = true;
        if (filtered.isNotEmpty) updated[entry.key] = filtered;
      }
      if (changed) {
        await db.add(
          db.threadTags,
          currentRow
              .copyWith(
                tags: Value(updated.isEmpty ? null : updated),
                updatedAt: now,
              )
              .toCompanion(false),
        );
      }
    }

    // 3. Audience subtract on current.
    final otherContacts = otherActiveSourceRows.map((r) => r.contacts).toList();
    final otherGroups = otherActiveSourceRows.map((r) => r.groups).toList();
    final newCurrentContacts = splitAudienceSubtract(
      target: currentRow.contacts,
      source: sourceRow.contacts,
      otherActiveSources: otherContacts,
    );
    final newCurrentGroups = splitAudienceSubtract(
      target: currentRow.groups,
      source: sourceRow.groups,
      otherActiveSources: otherGroups,
    );

    await db.add(
      db.threads,
      currentRow
          .copyWith(
            contacts: Value(newCurrentContacts),
            groups: Value(newCurrentGroups),
            updatedAt: now,
          )
          .toCompanion(false),
    );

    // 4. Unarchive source and clear the back-reference. The server-side
    // thread_merge_preconditions trigger validates that archived_at is cleared
    // in the same UPDATE. (twist_id, key) stays on source's row untouched —
    // upsert_thread() follows the chain to route connector resyncs.
    await source
        .copyWith(
          archivedAt: const Value(null),
          mergedIntoThreadId: const Value(null),
        )
        .save();

    // 5. Push.
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.note));
    unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.thread));

    return const CommandDone();
  }
}

class ShowThreadCommands extends ShowCommands {
  ShowThreadCommands(Thread thread, {bool open = true})
    : super(
        title: 'More',
        icon: PlotIcon.menu,
        commandsBuilder: (context) async {
          // Capture the bloc here — `context` is the more-button's context,
          // which lives inside the priority page's BlocProvider. Once the
          // CommandModal opens, command dispatch may run with the modal's
          // own context (in the global Overlay) where the bloc is not
          // resolvable, so capture eagerly and pass it through.
          final bloc = context.read<PriorityBloc?>();
          return Commands(
            groups: await threadCommandGroups(
              thread,
              open: open,
              priorityBloc: bloc,
            ),
          );
        },
      );
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
      commandsBuilder: (context) async {
        // Resolve sharing model + notes for the Dropped section. Only
        // message-mode threads use them; the section is hidden otherwise.
        final links = await Link.getForThread(thread.id);
        final sharingModel = Thread.resolveSharingModel(links);
        final notes = sharingModel == SharingModel.message
            ? await Note.getForThread(thread.id)
            : null;
        final roleConfigs = links.isEmpty
            ? null
            : links.first.getTypeConfig()?.contactRoles;
        return _buildSharedCommands(
          threadRef[0],
          onUpdate: onUpdate,
          isDraft: false,
          candidates: candidatesCache,
          notes: notes,
          sharingModel: sharingModel,
          roleConfigs: roleConfigs,
        );
      },
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

  /// Like [loadSharedDisplayActors], but resolves actors for an explicit set
  /// of contact IDs instead of reading from [thread.contacts]. Used for
  /// message-mode threads where the visible contacts are derived per-viewer
  /// via [Thread.deriveVisibleContacts].
  Future<List<Actor>> loadSharedDisplayActorsForContacts(
    Iterable<Uuid> contactIds,
  ) => _loadDisplayActorsForContacts(contactIds);

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
///
/// When [dmTwistInstanceId] is non-null, the picker is in DM-mode
/// (`targets: "contacts"`): only contacts with a
/// `contact_external_account` row for that connection appear, groups are
/// hidden, and free-form email invites are blocked.
///
/// When [isAddressMode] is true (`targets: "addresses"`, e.g. Gmail), the
/// picker shows every contact with an email and allows free-form email
/// invites. Groups are still hidden — you compose to addresses, not group
/// rosters.
class PickDraftThreadShared extends ShowCommands {
  factory PickDraftThreadShared({
    required Thread thread,
    required Future<void> Function(Thread thread) onUpdate,
    Uuid? dmTwistInstanceId,
    bool isAddressMode = false,
    List<ContactRoleConfig>? roleConfigs,
    /// Historical notes for the thread. Used to compute the Dropped section
    /// in message-mode: contacts who appear in note history but are no longer
    /// in `thread.contacts`. Typically empty for brand-new draft threads.
    List<Note>? notes,
    /// The resolved sharing model for this thread's link type. When
    /// [SharingModel.message], a Dropped section is shown if non-empty.
    SharingModel sharingModel = SharingModel.thread,
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
        dmTwistInstanceId: dmTwistInstanceId,
        isAddressMode: isAddressMode,
        roleConfigs: roleConfigs,
        notes: notes,
        sharingModel: sharingModel,
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

/// Caches sorted sharing candidates (people + groups, interleaved by MRU)
/// by search string for the lifetime of a single share-picker modal.
/// Toggling a row doesn't change the candidate pool, only which side of
/// the "Shared" / suggestions partition each candidate falls on, so we
/// avoid re-running the thread scan in [Actor.getSortedShareCandidates]
/// on every toggle.
class _ShareCandidatesCache {
  final Map<String, List<ShareCandidate>> _byQuery = {};

  Future<List<ShareCandidate>> get({
    required String? search,
    required Priority? priority,
  }) async {
    final key = (search ?? '').toLowerCase();
    final cached = _byQuery[key];
    if (cached != null) return cached;
    final fresh = await Actor.getSortedShareCandidates(
      search: search,
      priority: priority,
    );
    _byQuery[key] = fresh;
    return fresh;
  }
}

String _computeSharedTitle(Thread thread) {
  return isThreadShared(thread) ? 'Sharing' : 'Share';
}

IconData _computeSharedIcon(Thread thread) {
  return isThreadShared(thread) ? PlotIcon.users : PlotIcon.shareAdd;
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

/// Like [_loadSharedDisplayActors] but operates on an explicit contact-id
/// set instead of [Thread.contacts]. Used for message-mode threads where the
/// visible participants are derived per-viewer.
Future<List<Actor>> _loadDisplayActorsForContacts(
  Iterable<Uuid> contactIds,
) async {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final actors = <Actor>[];
  for (final contactId in contactIds) {
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
  Uuid? dmTwistInstanceId,
  bool isAddressMode = false,
  List<ContactRoleConfig>? roleConfigs,
  List<Note>? notes,
  SharingModel sharingModel = SharingModel.thread,
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
  // rows). For message-mode threads, only show active contacts (contacts
  // minus droppedContacts) — dropped contacts appear in their own section.
  final activeContactIds = sharingModel == SharingModel.message
      ? thread.activeContacts
      : thread.contacts;
  final resolved = <Actor>[];
  for (final contactId in activeContactIds) {
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

  Command toggleActor(Actor actor, {bool isDropped = false}) =>
      ShareThreadActor(
        thread,
        actor,
        onUpdate: onUpdate,
        roleConfigs: roleConfigs,
        sharingModel: sharingModel,
        isDropped: isDropped,
      );

  Command toggleInvite(String email) =>
      InviteThreadEmail(thread, email, onUpdate: onUpdate);

  Command toggleGroup(GroupRow group) =>
      ShareThreadGroup(thread, group, onUpdate: onUpdate);

  // Dropped section (message-mode only): contacts in thread.droppedContacts.
  // Viewer's own contacts are excluded (they can't drop themselves this way).
  final droppedActors = <Actor>[];
  if (sharingModel == SharingModel.message) {
    final viewerContactIds = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    final droppedIds = thread.droppedContacts
        .toSet()
        .difference(viewerContactIds);
    for (final contactId in droppedIds) {
      try {
        final actor = await Actor.getOne(ActorId.fromUuid(contactId));
        droppedActors.add(actor);
      } catch (_) {
        // Skip contacts whose actors can't be resolved
      }
    }
    droppedActors.sort(
      (a, b) => (a.nameOrEmail).compareTo(b.nameOrEmail),
    );
  }

  return Commands(
    prompt: 'Share with contact or email',
    emptyMessage: dmTwistInstanceId != null
        ? 'No contacts found for this connection. '
              'They appear here after the workspace member sync completes.'
        : 'Enter an email address to invite someone',
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
      if (droppedActors.isNotEmpty)
        StaticCommandGroup(
          title: 'Dropped',
          commands: droppedActors
              .map((a) => toggleActor(a, isDropped: true))
              .toList(),
        ),
      _ThreadShareSuggestionsGroup(
        thread: thread,
        // Exclude both currently-shared AND dropped actors from suggestions —
        // dropped actors already appear in their own section, listing them
        // again under "Share with" would double-render them on first paint
        // (before the next CommandRefresh dedupes).
        excludeActorIds: [
          ...sharedActorIds,
          ...droppedActors.map((a) => a.id),
        ],
        excludeGroupIds: thread.groups.toSet(),
        onUpdate: onUpdate,
        candidates: candidates,
        dmTwistInstanceId: dmTwistInstanceId,
        isAddressMode: isAddressMode,
        sharingModel: sharingModel,
        title: 'Share with',
      ),
    ],
  );
}

/// Single merged "people + groups" suggestion list for the thread share
/// modal, ordered by the shared MRU sort from
/// [Actor.getSortedShareCandidates] so a recently-used group can appear
/// beside recently-used contacts instead of pushing them out of view.
///
/// Three modes determined by the constructor flags:
/// - Default: all contacts + groups; email-invite path open.
/// - [dmTwistInstanceId] set (`"contacts"` mode): only contacts with a
///   `contact_external_account` row for that connection; groups hidden;
///   email-invite path closed.
/// - [isAddressMode] true (`"addresses"` mode, e.g. Gmail): only contacts
///   with an email; groups hidden; email-invite path open.
class _ThreadShareSuggestionsGroup extends CommandGroup {
  _ThreadShareSuggestionsGroup({
    required this.thread,
    required this.excludeActorIds,
    required this.excludeGroupIds,
    required this.onUpdate,
    required this.candidates,
    required String title,
    this.dmTwistInstanceId,
    this.isAddressMode = false,
    this.sharingModel = SharingModel.thread,
  }) : super(title: title);

  final Thread thread;
  final List<ActorId> excludeActorIds;
  final Set<Uuid> excludeGroupIds;
  final Future<void> Function(Thread) onUpdate;
  final _ShareCandidatesCache candidates;
  final SharingModel sharingModel;

  /// When non-null, only contacts reachable through this connection are shown.
  final Uuid? dmTwistInstanceId;

  /// When true (`targets: "addresses"`), show all contacts with an email,
  /// hide groups, and allow free-form email invites.
  final bool isAddressMode;

  @override
  Future<List<Command>> list({String? search}) async {
    final sorted = await candidates.get(
      search: search,
      priority: thread.priority,
    );
    final excludedActorIds = excludeActorIds.toSet();
    final twistInstanceId = dmTwistInstanceId;
    final commands = <Command>[];
    final hideGroups = twistInstanceId != null || isAddressMode;
    for (final candidate in sorted) {
      switch (candidate) {
        case ActorShareCandidate(:final actor):
          if (excludedActorIds.contains(actor.id)) continue;
          if (twistInstanceId != null &&
              !actor.hasExternalAccount(twistInstanceId)) {
            continue;
          }
          if (isAddressMode && (actor.email == null || actor.email!.isEmpty)) {
            continue;
          }
          commands.add(ShareThreadActor(
            thread,
            actor,
            onUpdate: onUpdate,
            sharingModel: sharingModel,
          ));
        case GroupShareCandidate(:final group):
          if (hideGroups) continue;
          if (excludeGroupIds.contains(group.id)) continue;
          commands.add(ShareThreadGroup(thread, group, onUpdate: onUpdate));
      }
    }

    // Email invites: allowed in default mode and in address mode (Gmail
    // happily accepts any RFC 822 address). Closed-roster DM mode
    // (`dmTwistInstanceId` set) blocks invites — the recipient must
    // already exist as a contact reached through that specific connection.
    final allowEmailInvites = twistInstanceId == null;
    if (allowEmailInvites && search != null && _isValidShareEmail(search)) {
      final normalized = search.toLowerCase();
      final emailExists = sorted.any(
        (c) =>
            c is ActorShareCandidate &&
            c.actor.email?.toLowerCase() == normalized,
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
  ShareThreadActor(
    this.thread,
    this.actor, {
    required this.onUpdate,
    this.roleConfigs,
    this.sharingModel = SharingModel.thread,
    bool? isDropped,
  }) : _isDropped = isDropped ?? false,
       _isShared = isDropped == true
           ? false  // Dropped contacts appear as "off" so user can re-add
           : _actorShared(thread, actor),
       super(
         title: actor.nameOrEmail,
         eventObject: EventObject.activity,
         eventAction: (isDropped == true || !_actorShared(thread, actor))
             ? EventAction.shared
             : EventAction.updated,
         icon: (isDropped == true || !_actorShared(thread, actor))
             ? PlotIcon.shareAdd
             : PlotIcon.user,
         on: isDropped == true ? false : _actorShared(thread, actor),
       );

  final Thread thread;
  final Actor actor;
  final Future<void> Function(Thread) onUpdate;
  final SharingModel sharingModel;
  final bool _isDropped;
  final bool _isShared;

  /// Per-connector role options. Null or shorter than 2 ⇒ no role badge.
  /// The current row's role is read from `thread.contactMeta` and falls
  /// back to the entry marked `default: true` (or the first entry).
  final List<ContactRoleConfig>? roleConfigs;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      Avatar(actor: actor);

  /// Role config for the current contact, or null when no badge should
  /// render (connector has 0/1 roles, contact isn't shared, or row is for
  /// self — sender doesn't get a recipient role).
  ContactRoleConfig? get _currentRole {
    final configs = roleConfigs;
    if (configs == null || configs.length < 2) return null;
    if (!_isShared) return null;
    if (actor.self) return null;
    final entry = thread.contactMeta[actor.id.toUuid().toString()];
    final roleId = entry is Map<String, dynamic>
        ? entry['role'] as String?
        : null;
    if (roleId != null) {
      final match = configs.where((r) => r.id == roleId).firstOrNull;
      if (match != null) return match;
    }
    return configs.firstWhere((r) => r.isDefault, orElse: () => configs.first);
  }

  @override
  CommandSecondaryAxis? get secondaryAxis {
    final current = _currentRole;
    if (current == null) return null;
    return _ShareThreadActorRoleAxis(this, current);
  }

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

      // Message-mode: dropped contacts are moved to/from dropped_contacts
      // (they retain visibility via thread.contacts). The server's
      // POST /thread/:id/share endpoint handles drop/undrop via the
      // privileged update_thread_dropped_contacts RPC.
      if (sharingModel == SharingModel.message) {
        if (_isDropped) {
          // Un-drop: remove from dropped_contacts (contact is already in contacts).
          final toDrop = <String>[];
          final toUndrop = _linkedContactIdsOnThread(thread, actor)
              .map((id) => id.toString())
              .toList();
          await _callDropEndpoint(thread.id.toString(), toDrop, toUndrop);
          // Optimistically update local state
          final droppedSet = thread.droppedContacts.toSet();
          for (final id in _linkedContactIdsOnThread(thread, actor)) {
            droppedSet.remove(id);
          }
          await onUpdate(
            thread.copyWith(droppedContacts: Value(droppedSet.toList())),
          );
        } else if (_isShared) {
          // Drop: move from active to dropped_contacts.
          final toDrop = _linkedContactIdsOnThread(thread, actor)
              .map((id) => id.toString())
              .toList();
          await _callDropEndpoint(thread.id.toString(), toDrop, []);
          // Optimistically update local state — remove contact_meta entries too
          final toDropSet = _linkedContactIdsOnThread(thread, actor).toSet();
          final newDropped = [
            ...thread.droppedContacts,
            ...toDropSet.where((id) => !thread.droppedContacts.contains(id)),
          ];
          final newMeta = _metaWithout(thread.contactMeta, toDropSet);
          await onUpdate(
            thread.copyWith(
              droppedContacts: Value(newDropped),
              contactMeta: newMeta,
            ),
          );
        } else {
          // Add a new contact (not previously on the thread).
          final contactUuid = actor.id.toUuid();
          final newContacts = [...thread.contacts, contactUuid];
          await onUpdate(
            thread.copyWith(contacts: Value(newContacts)),
          );
        }
        return const CommandRefresh();
      }

      // Non-message-mode: existing behavior (full add/remove from contacts).
      final contactUuid = actor.id.toUuid();
      final List<Uuid> newContacts;
      final Value<Map<String, dynamic>?> newMeta;
      if (_isShared) {
        // Remove every linked alias for this person, not just actor.id —
        // otherwise toggling off the primary would leave the alias contact
        // behind on the thread.
        final toRemove = _linkedContactIdsOnThread(thread, actor).toSet();
        newContacts = thread.contacts
            .where((id) => !toRemove.contains(id))
            .toList();
        newMeta = _metaWithout(thread.contactMeta, toRemove);
      } else {
        newContacts = [...thread.contacts, contactUuid];
        newMeta = const Value.absent();
      }
      await onUpdate(
        thread.copyWith(contacts: Value(newContacts), contactMeta: newMeta),
      );
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareThreadActor: $e', e, stackTrace);
      return CommandMessage('Failed to update sharing', isError: true);
    }
  }

  /// Call POST /thread/:id/share with drop/undrop parameters.
  Future<void> _callDropEndpoint(
    String threadId,
    List<String> toDrop,
    List<String> toUndrop,
  ) async {
    await api.post<dynamic>(
      '/thread/$threadId/share',
      body: {
        if (toDrop.isNotEmpty) 'drop': toDrop,
        if (toUndrop.isNotEmpty) 'undrop': toUndrop,
      },
    );
  }

  /// Apply [nextRoleId] to the contact's `contactMeta` entry. Server merges
  /// additively, so we send only the changed entry (plus existing entries
  /// untouched). `addedBy` is preserved when present, else falls back to
  /// the current actor.
  Future<CommandReturn> _setRole(String nextRoleId) async {
    try {
      final contactKey = actor.id.toUuid().toString();
      final existing = thread.contactMeta[contactKey];
      final addedBy = existing is Map<String, dynamic>
          ? existing['addedBy'] as String?
          : null;
      // `addedBy` is the acting user_id per share_thread.sql.
      final selfId = Base.userIdOrNull?.toString();
      final addedByValue = addedBy ?? selfId;
      final newMeta = <String, dynamic>{
        ...thread.contactMeta,
        contactKey: {'role': nextRoleId, 'addedBy': ?addedByValue},
      };
      await onUpdate(thread.copyWith(contactMeta: Value(newMeta)));
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareThreadActor._setRole: $e', e, stackTrace);
      return CommandMessage('Failed to update role', isError: true);
    }
  }
}

/// Strip [removeIds] from a contactMeta map. Returns `Value.absent()` when
/// nothing would change (lets callers omit the field from copyWith).
Value<Map<String, dynamic>?> _metaWithout(
  Map<String, dynamic> existing,
  Set<Uuid> removeIds,
) {
  if (existing.isEmpty) return const Value.absent();
  final removeKeys = removeIds.map((u) => u.toString()).toSet();
  if (!removeKeys.any(existing.containsKey)) return const Value.absent();
  final next = <String, dynamic>{
    for (final entry in existing.entries)
      if (!removeKeys.contains(entry.key)) entry.key: entry.value,
  };
  return Value(next);
}

class _ShareThreadActorRoleAxis extends CommandSecondaryAxis {
  const _ShareThreadActorRoleAxis(this.cmd, this.current);

  final ShareThreadActor cmd;
  final ContactRoleConfig current;

  @override
  String get badgeLabel => current.label;

  @override
  Future<CommandReturn> cycle(BuildContext context, int delta) {
    final configs = cmd.roleConfigs!;
    final currentIndex = configs.indexWhere((r) => r.id == current.id);
    final raw = currentIndex < 0 ? 0 : (currentIndex + delta) % configs.length;
    final wrapped = raw < 0 ? raw + configs.length : raw;
    return cmd._setRole(configs[wrapped].id);
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
    : _isShared = thread.groups.contains(group.id),
      super(
        title: group.name,
        eventObject: EventObject.activity,
        eventAction: thread.groups.contains(group.id)
            ? EventAction.updated
            : EventAction.shared,
        icon: PlotIcon.users,
        on: thread.groups.contains(group.id),
      );

  final Thread thread;
  final GroupRow group;
  final Future<void> Function(Thread) onUpdate;
  final bool _isShared;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (_isShared) {
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
      } else {
        await onUpdate(
          thread.copyWith(groups: Value([...thread.groups, group.id])),
        );
      }
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
  PriorityBloc? priorityBloc,
}) async {
  final hasMerged = await SplitThread.hasMergedContent(thread.id);
  return threadCommandGroupsSync(
    thread,
    open: open,
    showSplitThread: hasMerged,
    priorityBloc: priorityBloc,
  );
}

/// Sync variant for callers that cannot await (e.g. CommandScope).
/// Does not include SplitThread unless [showSplitThread] is explicitly true.
List<StaticCommandGroup> threadCommandGroupsSync(
  Thread thread, {
  bool open = true,
  bool showSplitThread = false,
  PriorityBloc? priorityBloc,
}) {
  final commands = threadCommands(
    thread,
    open: open,
    showSplitThread: showSplitThread,
    priorityBloc: priorityBloc,
  );

  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(title: 'Thread: ${thread.title}', commands: commands),
  ];
}

/// Returns the per-user list-toggle commands ([ToggleThreadTask] and
/// [ToggleThreadToRead]) in display order. These surface in the hover
/// row and stay visible — like enabled tags — when their underlying
/// flag is set. Both flags are independent of `active` and of each
/// other.
List<Command> threadListToggleCommands(Thread thread) => [
  ToggleThreadTask(thread),
  ToggleThreadToRead(thread),
];

List<Command> threadCommands(
  Thread thread, {
  bool open = false,
  bool skipInfrequent = false,
  bool skipPrimary = false,
  bool showSplitThread = false,
  bool showEventTiming = false,
  PriorityBloc? priorityBloc,
}) {
  // Viewers can't edit shared thread metadata (title, sharing, merge/split,
  // priority move, archive) but per-user filing (Finish / To respond /
  // To do / To read / pick schedule) only mutates the user's own
  // thread_state row — the same affordance the leading icon already
  // exposes regardless of role.
  if (thread.priority.isViewer) {
    Command? primary;
    if (!skipPrimary) {
      if (thread.todo) {
        primary = FinishThread(thread, stateIcon: false);
      } else if (thread.on != null) {
        primary = PickScheduleThread(thread);
      } else {
        primary = ToggleThreadActive(thread);
      }
    }
    return [
      if (open) ChangeCurrentThread(thread),
      ?primary,
      ...threadListToggleCommands(thread),
    ];
  }

  // Read-only viewers (announce-group-only access): no metadata edits, no
  // sharing changes, no merges/splits, no thread tags. Archive routes
  // per-user server-side. Marking read/unread and per-user filing remain.
  if (thread.isReadOnly) {
    return [
      if (open) ChangeCurrentThread(thread),
      if (!skipInfrequent) MoveThreadToPriority(thread),
      if (!skipInfrequent) MuteSimilarThreads(thread, bloc: priorityBloc),
      if (!skipInfrequent) ArchiveThread(thread, bloc: priorityBloc),
    ];
  }

  Command? primary;
  if (!skipPrimary) {
    if (thread.todo) {
      primary = FinishThread(thread, stateIcon: false);
    } else if (thread.on != null) {
      primary = PickScheduleThread(thread);
    } else {
      primary = ToggleThreadActive(thread);
    }
  }

  // Per-user list-toggle commands (task list / reading list). Independent
  // of `active` and of each other; they stay visible like enabled tags
  // when the underlying flag is set (handled by the ThreadCommands widget).
  final listToggleCommands = threadListToggleCommands(thread);

  // For PickScheduleThread inclusion check: is the thread's natural primary a schedule picker?
  final isPrimarySchedule = !thread.todo && thread.on != null;
  final hideArchive = showEventTiming && thread.isLinkScheduleInstance;
  return [
    if (open) ChangeCurrentThread(thread),
    ?primary,
    ...listToggleCommands,
    if (!isPrimarySchedule && !(thread.todo && thread.isFuture))
      PickScheduleThread(thread),
    if (!skipInfrequent) EditThread(thread),
    if (!skipInfrequent) MoveThreadToPriority(thread),
    PickThreadShared(thread),
    if (!skipInfrequent) MergeThreadInto(thread),
    if (!skipInfrequent && showSplitThread) SplitThread(thread),
    if (!skipInfrequent && !hideArchive)
      MuteSimilarThreads(thread, bloc: priorityBloc),
    if (!skipInfrequent && !hideArchive)
      ArchiveThread(thread, bloc: priorityBloc),
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
