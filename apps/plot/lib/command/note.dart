import 'command.dart';
import 'package:flutter/services.dart';
import 'package:plot/router.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/editor_clipboard.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/now.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'logging.dart';

class AddNote extends Command {
  AddNote(this._note)
    : super(
        title: 'Add note',
        eventObject: EventObject.note,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final Future<Note> _note;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Try to get ThreadBloc from context before any async operations
    ThreadBloc? activityBloc;
    try {
      activityBloc = context.read<ThreadBloc>();
    } catch (e) {
      // No ThreadBloc in context
      activityBloc = null;
    }

    final note = await _note;

    // Use ThreadBloc.add() if available (resets the draft), otherwise save directly
    if (activityBloc != null) {
      await activityBloc.add(note);
    } else {
      await note.save();
    }

    return const CommandDone();
  }
}

abstract class NoteCommand extends Command {
  NoteCommand(
    this.note, {
    required super.eventObject,
    required super.eventAction,
    super.icon,
    super.hoverIcon,
    super.on,
    super.shortcut,
    String? title,
  }) : super(title: title ?? 'Note', subtitle: '');

  final Note note;
}

class AssignNote extends NoteCommand {
  AssignNote(super.note, {this.actorId})
    : super(
        title: 'Assign to me',
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
        icon: PlotIcon.todo,
      );

  final ActorId? actorId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Use current user ID if no actor specified
      final targetActorId = actorId ?? Base.actorId;

      // Check if already assigned
      final isAssigned = note.isAssignedTo(targetActorId);

      if (isAssigned) {
        // Already assigned - skip or could unassign
        return const CommandMessage('Already assigned');
      }

      // Assign the note by adding Tag.todo for the actor
      final updatedNote = note.assignTo(targetActorId);
      await updatedNote.save();

      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in AssignNote: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to assign note', isError: true);
    }
  }
}

enum _SelfTaskState { unassigned, todo, done }

class SelfTaskAction extends NoteCommand {
  SelfTaskAction(super.note)
    : _state = _computeState(note),
      super(
        title: _titleForState(_computeState(note)),
        eventObject: EventObject.note,
        eventAction: _eventActionForState(_computeState(note)),
        icon: _iconForState(_computeState(note)),
        hoverIcon: _hoverIconForState(_computeState(note)),
      );

  final _SelfTaskState _state;

  static _SelfTaskState _computeState(Note note) {
    final actorId = Base.actorId;
    if (note.isCompletedBy(actorId)) return _SelfTaskState.done;
    if (note.isAssignedTo(actorId)) return _SelfTaskState.todo;
    return _SelfTaskState.unassigned;
  }

  static String _titleForState(_SelfTaskState state) => switch (state) {
    _SelfTaskState.unassigned => 'Make a task',
    _SelfTaskState.todo => 'Mark done',
    _SelfTaskState.done => 'Remove done',
  };

  static EventAction _eventActionForState(_SelfTaskState state) =>
      switch (state) {
        _SelfTaskState.unassigned => EventAction.started,
        _SelfTaskState.todo => EventAction.finished,
        _SelfTaskState.done => EventAction.untagged,
      };

  static IconData _iconForState(_SelfTaskState state) => switch (state) {
    _SelfTaskState.unassigned => PlotIcon.selfTask,
    _SelfTaskState.todo => PlotIcon.selfTaskTodo,
    _SelfTaskState.done => PlotIcon.selfTaskDone,
  };

  static IconData? _hoverIconForState(_SelfTaskState state) => switch (state) {
    _SelfTaskState.unassigned => null,
    _SelfTaskState.todo => PlotIcon.selfTaskHover,
    _SelfTaskState.done => null,
  };

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final actorId = Base.actorId;
      final Note updatedNote;

      switch (_state) {
        case _SelfTaskState.unassigned:
          // Assign to self
          updatedNote = note.assignTo(actorId);
        case _SelfTaskState.todo:
          // Mark done
          updatedNote = note.completeFor(actorId);
        case _SelfTaskState.done:
          // Remove done (reverts to non-task, does NOT re-add todo)
          updatedNote = note.setTag(Tag.done, actorId, false);
      }

      await updatedNote.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in SelfTaskAction: $e', e, stackTrace);
      return CommandMessage('Failed to update task', isError: true);
    }
  }
}

class ToggleSelfTask extends NoteCommand {
  ToggleSelfTask(super.note)
    : super(
        title: 'Add task',
        eventObject: EventObject.note,
        eventAction: note.isAssignedTo(Base.actorId)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: PlotIcon.selfTask,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyT),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      ThreadBloc? activityBloc;
      try {
        activityBloc = context.read<ThreadBloc>();
      } catch (e) {
        activityBloc = null;
      }

      final updatedNote = note.toggleTag(Tag.todo, Base.actorId);
      if (activityBloc != null &&
          activityBloc.state.draft.id == updatedNote.id) {
        await activityBloc.updateDraft(updatedNote);
      }
      await updatedNote.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleSelfTask: $e', e, stackTrace);
      return CommandMessage('Failed to toggle task', isError: true);
    }
  }
}

class ToggleNoteTag extends NoteCommand {
  ToggleNoteTag(super.note, this.tag, this.actorId, {this.isViewer = false})
    : super(
        title: tag.name,
        eventObject: EventObject.note,
        eventAction: note.hasTag(tag, actorId)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: tag.icon,
      );

  final Tag tag;
  final ActorId actorId;
  final bool isViewer;

  @override
  bool enabled(BuildContext context) => !(tag == Tag.private && isViewer);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (!enabled(context)) return const CommandDone();
    try {
      ThreadBloc? activityBloc;
      try {
        activityBloc = context.read<ThreadBloc>();
      } catch (e) {
        activityBloc = null;
      }

      final updatedNote = note.toggleTag(tag, actorId);
      if (activityBloc != null &&
          activityBloc.state.draft.id == updatedNote.id) {
        await activityBloc.updateDraft(updatedNote);
      }
      await updatedNote.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleNoteTag: $e', e, stackTrace);
      return CommandMessage('Failed to toggle tag', isError: true);
    }
  }
}

/// Tap: sets accessContacts to [currentUser] (private to just me).
/// Long-press (when the thread has other contacts): opens the privacy
/// modal with the current user preselected.
class MakeNotePrivate extends NoteCommand {
  MakeNotePrivate(super.note, {required this.threadBloc})
    : super(
        title: 'Make private',
        eventObject: EventObject.note,
        eventAction: EventAction.tagged,
        icon: PlotIcon.private,
      );

  final ThreadBloc threadBloc;

  @override
  Command? get longPressCommand => _threadHasOtherContacts(threadBloc)
      ? ChangeNotePrivacy(note, threadBloc: threadBloc)
      : null;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final updated = note.copyWith(
        accessContacts: Value([Base.actorId]),
      );
      await updated.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in MakeNotePrivate: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to make private', isError: true);
    }
  }
}

/// Opens the privacy modal: select which thread contacts can see the note,
/// or make it public again. The current user is always included.
class ChangeNotePrivacy extends ShowCommands {
  ChangeNotePrivacy(this.note, {required this.threadBloc})
    : super(
        title: note.isPrivate ? 'Change privacy' : 'Make private',
        icon: PlotIcon.private,
        commandsBuilder: (context) => _buildCommands(note, threadBloc),
        showFilter: false,
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
      );

  final Note note;
  final ThreadBloc threadBloc;

  static Future<Commands> _buildCommands(
    Note note,
    ThreadBloc threadBloc,
  ) async {
    final freshNote = await note.refresh();
    final selfIds = Actor.getCurrentUserActorIds()
        .map((a) => a.value)
        .toSet();
    final threadContacts = threadBloc.state.thread.contacts;

    final actors = <Actor>[];
    for (final contactId in threadContacts) {
      try {
        actors.add(await Actor.getOne(ActorId.fromUuid(contactId)));
      } catch (_) {
        // Skip contacts we can't resolve
      }
    }

    final selfActors = actors.where((a) => selfIds.contains(a.id.value))
        .toList();
    final otherActors = actors.where((a) => !selfIds.contains(a.id.value))
        .toList();

    return Commands(
      prompt: freshNote.isPrivate
          ? 'Change who can see this note'
          : 'Share privately with',
      groups: [
        if (freshNote.isPrivate)
          StaticCommandGroup(commands: [MakeNotePublic(freshNote)]),
        if (selfActors.isNotEmpty)
          StaticCommandGroup(
            title: 'You',
            commands: selfActors
                .map((a) => ToggleNotePrivacyContact(
                      freshNote,
                      a,
                      isSelf: true,
                    ))
                .toList(),
          ),
        if (otherActors.isNotEmpty)
          StaticCommandGroup(
            title: 'Others in this thread',
            commands: otherActors
                .map((a) => ToggleNotePrivacyContact(
                      freshNote,
                      a,
                      isSelf: false,
                    ))
                .toList(),
          ),
      ],
    );
  }
}

class MakeNotePublic extends NoteCommand {
  MakeNotePublic(super.note)
    : super(
        title: 'Make public',
        eventObject: EventObject.note,
        eventAction: EventAction.untagged,
        icon: FontAwesomeIcons.lockOpen,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await note.copyWith(accessContacts: const Value(null)).save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in MakeNotePublic: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to make public', isError: true);
    }
  }
}

class ToggleNotePrivacyContact extends NoteCommand {
  ToggleNotePrivacyContact(
    super.note,
    this.actor, {
    required this.isSelf,
  }) : super(
          title: actor.nameOrEmail,
          eventObject: EventObject.note,
          eventAction: _isInAccess(note, actor.id)
              ? EventAction.untagged
              : EventAction.tagged,
          icon: (isSelf || _isInAccess(note, actor.id))
              ? PlotIcon.shared
              : PlotIcon.shareAdd,
          on: isSelf || _isInAccess(note, actor.id),
        );

  final Actor actor;
  final bool isSelf;

  static bool _isInAccess(Note note, ActorId id) =>
      note.accessContacts?.contains(id) == true;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  bool enabled(BuildContext context) => !isSelf;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (isSelf) {
      return const CommandMessage(
        "You can't remove yourself from a private note",
      );
    }
    try {
      final current = note.accessContacts;
      final List<ActorId> next;
      if (current == null) {
        // Note is currently public — toggling a contact makes it private
        // including the current user.
        next = [Base.actorId, actor.id];
      } else if (current.contains(actor.id)) {
        next = List.of(current)..remove(actor.id);
      } else {
        next = List.of(current)..add(actor.id);
      }
      await note.copyWith(accessContacts: Value(next)).save();
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleNotePrivacyContact: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to update privacy', isError: true);
    }
  }
}

bool _threadHasOtherContacts(ThreadBloc bloc) {
  final selfIds = Actor.getCurrentUserActorIds().map((a) => a.value).toSet();
  return bloc.state.thread.contacts.any((c) => !selfIds.contains(c));
}

class EditNote extends NoteCommand {
  EditNote(super.note, {this.activityBloc})
    : super(
        title: 'Edit',
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
        icon: FontAwesomeIcons.penToSquare,
      );

  final ThreadBloc? activityBloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final bloc = activityBloc ?? context.read<ThreadBloc>();
    bloc.setEditingNote(note);
    return const CommandDone();
  }
}

class ReplyToNote extends NoteCommand {
  ReplyToNote(super.note, {required this.activityBloc})
    : super(
        title: 'Reply',
        eventObject: EventObject.note,
        eventAction: EventAction.added,
        icon: FontAwesomeIcons.reply,
      );

  final ThreadBloc activityBloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      activityBloc.setReplyTo(note);
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ReplyToNote: $e', e, stackTrace);
      return CommandMessage('Failed to set reply', isError: true);
    }
  }
}

class ArchiveNote extends NoteCommand {
  ArchiveNote(super.note)
    : super(
        title: 'Archive',
        eventObject: EventObject.note,
        eventAction: EventAction.archived,
        icon: PlotIcon.archived,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await note.archive();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ArchiveNote: $e', e, stackTrace);
      return CommandMessage('Failed to archive note', isError: true);
    }
  }
}

class SplitNoteToNewThread extends NoteCommand {
  SplitNoteToNewThread(super.note)
    : super(
        title: 'Split to new thread',
        eventObject: EventObject.note,
        eventAction: EventAction.moved,
        icon: PlotIcon.move,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Look up parent thread to get its priority
      final parentThread = await Thread.getOne(note.threadId);

      // Create a new thread — title null signals AI generation in save() and sync.
      // Preview stores the note content for client-side display.
      final newThread = Thread(
        priority: parentThread.priority,
        draft: false,
        preview: note.content,
      );
      await newThread.save();

      // Move the note to the new thread and unarchive it
      await note.copyWith(threadId: newThread.id, clearArchivedAt: true).save();

      // Navigate to the new thread in the current priority context
      var routePriority = newThread.priority;
      if (context.mounted) {
        final nowBloc = context.read<NowBloc>();
        if (nowBloc.loadedState.context != null) {
          routePriority = nowBloc.loadedState.context!;
        }
      }

      return CommandRoute(
        PriorityRoute(
          priorityIdString: routePriority.id.toShortString(),
          children: [ThreadRoute(threadIdString: newThread.id.toShortString())],
        ),
        replace: true,
      );
    } catch (e, stackTrace) {
      log.severe('Error in SplitNoteToNewThread: $e', e, stackTrace);
      return CommandMessage(
        'Failed to split note to new thread',
        isError: true,
      );
    }
  }
}

class PickNoteAssignee extends ShowCommands {
  PickNoteAssignee(this.note)
    : super(
        title: _computeTitle(note),
        icon: _computeIcon(note),
        commandsBuilder: (context) => _getAssigneeCommands(note),
        showFilter: true,
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyT, shift: true),
      );

  final Note note;

  /// Whether anyone other than the current user is assigned, including
  /// hidden assignees (announce-topic-only members the viewer can't see).
  bool get hasOtherAssignees {
    final selfAssigned = note.activeAssignees.contains(Base.actorId) ||
        note.completedAssignees.contains(Base.actorId);
    return note.assigneeCount > (selfAssigned ? 1 : 0);
  }

  static String _computeTitle(Note note) =>
      _hasOtherAssignees(note) ? 'Assigned' : 'Assign';

  static IconData _computeIcon(Note note) =>
      _hasOtherAssignees(note) ? PlotIcon.othersTask : PlotIcon.assignAdd;

  static bool _hasOtherAssignees(Note note) {
    final selfAssigned = note.activeAssignees.contains(Base.actorId) ||
        note.completedAssignees.contains(Base.actorId);
    return note.assigneeCount > (selfAssigned ? 1 : 0);
  }

  static Future<Commands> _getAssigneeCommands(Note note) async {
    final activity = await Thread.getOne(note.threadId);
    // Refresh note to get latest tag state
    final freshNote = await note.refresh();
    final assigneeIds = freshNote.activeAssignees;

    // Resolve assigned actors for the "Assigned" section
    final assignedActors = assigneeIds.isNotEmpty
        ? await Future.wait(assigneeIds.map(Actor.getOne))
        : <Actor>[];

    // Hidden active assignees (announce-topic-only) — count only, no identity
    final hiddenActiveCount =
        TagActors.countOf(freshNote.tags[Tag.todo]) - assigneeIds.length;
    final assignedSubtitle = hiddenActiveCount > 0
        ? '+$hiddenActiveCount hidden'
        : null;

    // Resolve thread contacts for the "With" section
    final contactActors = <Actor>[];
    for (final contactId in activity.contacts) {
      try {
        final actor = await Actor.getOne(ActorId.fromUuid(contactId));
        if (!actor.self) contactActors.add(actor);
      } catch (_) {
        // Skip contacts whose actors can't be resolved
      }
    }
    final contactActorIds = contactActors.map((a) => a.id).toSet();

    // Exclude already-assigned contacts from the With section
    final unassignedContacts = contactActors
        .where((a) => !assigneeIds.contains(a.id))
        .toList();

    // Exclude both assigned and thread contact actors from Contacts
    final excludeFromContacts = <ActorId>[...assigneeIds, ...contactActorIds];

    return Commands(
      prompt: 'Assign to',
      groups: [
        if (assignedActors.isNotEmpty)
          StaticCommandGroup(
            title: 'Assigned',
            subtitle: assignedSubtitle,
            commands: assignedActors
                .map((actor) => AssignNoteActor(freshNote, actor))
                .toList(),
          ),
        if (unassignedContacts.isNotEmpty)
          StaticCommandGroup(
            title: 'In this thread',
            commands: unassignedContacts
                .map((actor) => AssignNoteActor(freshNote, actor))
                .toList(),
          ),
        ActorGroup(
          title: 'Contacts',
          excludeActorIds: excludeFromContacts,
          builder: (actor) => AssignNoteActor(freshNote, actor),
        ),
      ],
    );
  }
}

class AssignNoteActor extends NoteCommand {
  AssignNoteActor(super.note, this.actor)
    : _isDone = note.isCompletedBy(actor.id),
      super(
        title: actor.nameOrEmail,
        eventObject: EventObject.note,
        eventAction: note.isCompletedBy(actor.id)
            ? EventAction.clicked
            : note.isAssignedTo(actor.id)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: note.isCompletedBy(actor.id)
            ? PlotIcon.othersTaskDone
            : note.isAssignedTo(actor.id)
            ? PlotIcon.othersTask
            : PlotIcon.assignAdd,
        on: note.isAssignedTo(actor.id),
      );

  final Actor actor;
  final bool _isDone;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (_isDone) {
      return const CommandMessage('Only they can change their done status');
    }
    try {
      ThreadBloc? activityBloc;
      try {
        activityBloc = context.read<ThreadBloc>();
      } catch (e) {
        activityBloc = null;
      }

      final isAssigned = note.isAssignedTo(actor.id);
      final updatedNote = note.setTag(Tag.todo, actor.id, !isAssigned);
      if (activityBloc != null &&
          activityBloc.state.draft.id == updatedNote.id) {
        await activityBloc.updateDraft(updatedNote);
      }
      await updatedNote.save();

      // If assigning (not unassigning) and actor is not on the thread, add them
      if (!isAssigned) {
        final thread = await Thread.getOne(note.threadId);
        final contactUuid = actor.id.toUuid();
        if (!thread.contacts.contains(contactUuid)) {
          final newContacts = [...thread.contacts, contactUuid];
          await thread.copyWith(contacts: Value(newContacts)).save();
        }
      }

      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in AssignNoteActor: $e', e, stackTrace);
      return CommandMessage('Failed to update assignment', isError: true);
    }
  }
}

List<StaticCommandGroup> noteCommandGroups(
  Note note, {
  ThreadBloc? activityBloc,
}) {
  final actorId = Base.actorId;
  final isViewer = activityBloc?.state.thread.priority.isViewer ?? false;
  final tags = Tag.getAll()
      .where((tag) => !isViewer || tag.type == TagType.count)
      .map((tag) => ToggleNoteTag(note, tag, actorId))
      .toList();
  final commands = noteCommands(note, activityBloc: activityBloc);
  final remove = tags
      .where(
        (cmd) =>
            cmd.tag.type != TagType.compute && note.hasTag(cmd.tag, actorId),
      )
      .toList();
  final add = tags
      .where(
        (cmd) =>
            cmd.tag.addable == true &&
            cmd.tag.type != TagType.compute &&
            !note.hasTag(cmd.tag, actorId),
      )
      .toList();

  final activeTags = remove.map((cmd) => cmd.tag).toList();
  final suggestedTags = add.map((cmd) => cmd.tag).toList();
  final activeTagCounts = {
    for (final tag in activeTags) tag: TagActors.countOf(note.tags[tag]),
  };

  ShowCommands makeShowAll() => ShowCommands(
    title: 'All tags',
    icon: PlotIcon.more,
    commandsBuilder: (_) async {
      // Fetch fresh tag state when opened
      final freshTags = Tag.getAll()
          .where((tag) => !isViewer || tag.type == TagType.count)
          .map((tag) => ToggleNoteTag(note, tag, actorId))
          .toList();
      final freshRemove = freshTags
          .where(
            (cmd) =>
                cmd.tag.type != TagType.compute &&
                note.hasTag(cmd.tag, actorId),
          )
          .toList();
      final freshAdd = freshTags
          .where(
            (cmd) =>
                cmd.tag.addable == true &&
                cmd.tag.type != TagType.compute &&
                !note.hasTag(cmd.tag, actorId),
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

  if (!note.draft && !isViewer) commands.add(ArchiveNote(note));

  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(title: 'Note', commands: commands),
    StaticCommandGroup(
      title: 'Note',
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
          commandBuilder: (tag) => ToggleNoteTag(note, tag, actorId),
          showAllBuilder: makeShowAll,
          showMore: !hasSearch,
        );
      },
      onActivate: (ctx) => makeShowAll().run(ctx),
    ),
  ];
}

List<Command> noteCommands(Note note, {ThreadBloc? activityBloc}) {
  final isViewer = activityBloc?.state.thread.priority.isViewer ?? false;

  // Viewers can only reply (forced private by DB), edit own notes, and copy
  if (isViewer) {
    return [
      if (!note.draft && activityBloc != null)
        ReplyToNote(note, activityBloc: activityBloc),
      if (!note.draft &&
          note.authorId.isCurrentUser &&
          note.content != null &&
          note.content!.trim().isNotEmpty)
        EditNote(note, activityBloc: activityBloc),
      if (note.content != null && note.content!.trim().isNotEmpty)
        CopyNoteContent(note),
    ];
  }

  return [
    SelfTaskAction(note),
    if (!note.draft && activityBloc != null)
      ReplyToNote(note, activityBloc: activityBloc),
    if (!note.draft &&
        note.authorId.isCurrentUser &&
        note.content != null &&
        note.content!.trim().isNotEmpty)
      EditNote(note, activityBloc: activityBloc),
    PickNoteAssignee(note),
    if (!note.draft && note.content != null && note.content!.trim().isNotEmpty)
      SplitNoteToNewThread(note),
    if (note.content != null && note.content!.trim().isNotEmpty)
      CopyNoteContent(note),
    if (activityBloc != null && !note.isPrivate)
      MakeNotePrivate(note, threadBloc: activityBloc),
    if (activityBloc != null &&
        note.isPrivate &&
        note.authorId.isCurrentUser)
      ChangeNotePrivacy(note, threadBloc: activityBloc),
    ];

}

/// Returns up to 6 tag suggestions for quick actions.
/// The number shown is reduced by the count of non-hardcoded tags already on the note.
/// Takes from tagSuggestions list which is pre-sorted (common tags first, then all others).
List<Command> topNoteTags(
  Note note,
  List<Tag> tagSuggestions,
  ActorId actorId,
) {
  // Count non-hardcoded tags already on note
  final activeNonHardcodedCount = tagSuggestions
      .where((tag) => note.hasTag(tag, actorId))
      .length;

  // Calculate how many tags to show: 6 minus active non-hardcoded tags
  final maxToShow = 4 - activeNonHardcodedCount;
  if (maxToShow <= 0) return [];

  // Filter to count tags not already on note (excluding archived/done)
  return tagSuggestions
      .where(
        (tag) =>
            tag.type == TagType.count &&
            tag != Tag.archived &&
            tag != Tag.done &&
            !note.hasTag(tag, actorId),
      )
      .take(maxToShow)
      .map((tag) => ToggleNoteTag(note, tag, actorId))
      .toList();
}

class CopyNoteContent extends NoteCommand {
  CopyNoteContent(super.note)
    : super(
        title: 'Copy',
        eventObject: EventObject.note,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.copy,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final content = note.content!;
      await writeClipboard(
        plotMarkdown: content,
        plainText: markdownToPlainText(content),
        html: markdownToHtml(content),
      );
      return CommandMessage('Note copied to clipboard');
    } catch (e, stackTrace) {
      log.severe('Error in CopyNoteContent: $e', e, stackTrace);
      return CommandMessage('Failed to copy note', isError: true);
    }
  }
}

class ShowNoteCommands extends ShowCommands {
  ShowNoteCommands(Note note, {ThreadBloc? activityBloc})
    : super(
        title: 'More commands',
        icon: PlotIcon.menu,
        commandsBuilder: (context) async => Commands(
          groups: noteCommandGroups(note, activityBloc: activityBloc),
        ),
      );
}

/// Assign picker for draft notes on NewThreadPage (uses callback instead of ThreadBloc).
class PickDraftNoteAssignee extends ShowCommands {
  factory PickDraftNoteAssignee({
    required Note note,
    required Thread thread,
    required Uuid priorityId,
    required Future<void> Function(Note note, {Thread? thread}) onUpdate,
  }) {
    // Mutable references so commandsBuilder always sees the latest state
    final noteRef = [note];
    final threadRef = [thread];

    Future<void> wrappedOnUpdate(Note updatedNote, {Thread? thread}) async {
      noteRef[0] = updatedNote;
      if (thread != null) threadRef[0] = thread;
      await onUpdate(updatedNote, thread: thread);
    }

    return PickDraftNoteAssignee._(
      note: note,
      thread: thread,
      priorityId: priorityId,
      onUpdate: onUpdate,
      commandsBuilder: (context) => _getAssigneeCommands(
        noteRef[0],
        threadRef[0],
        priorityId,
        wrappedOnUpdate,
      ),
    );
  }

  PickDraftNoteAssignee._({
    required this.note,
    required this.thread,
    required this.priorityId,
    required this.onUpdate,
    required Future<Commands> Function(BuildContext) commandsBuilder,
  }) : super(
         title: _computeTitle(note),
         icon: _computeIcon(note),
         commandsBuilder: commandsBuilder,
         showFilter: true,
         eventObject: EventObject.note,
         eventAction: EventAction.updated,
         shortcut: platformSingleActivator(
           LogicalKeyboardKey.keyT,
           shift: true,
         ),
       );

  final Note note;
  final Thread thread;
  final Uuid priorityId;
  final Future<void> Function(Note note, {Thread? thread}) onUpdate;

  static String _computeTitle(Note note) =>
      _hasOtherAssignees(note) ? 'Assigned' : 'Assign';

  static IconData _computeIcon(Note note) =>
      _hasOtherAssignees(note) ? PlotIcon.othersTask : PlotIcon.assignAdd;

  static bool _hasOtherAssignees(Note note) {
    final selfAssigned = note.activeAssignees.contains(Base.actorId) ||
        note.completedAssignees.contains(Base.actorId);
    return note.assigneeCount > (selfAssigned ? 1 : 0);
  }

  static Future<Commands> _getAssigneeCommands(
    Note note,
    Thread thread,
    Uuid priorityId,
    Future<void> Function(Note note, {Thread? thread}) onUpdate,
  ) async {
    final assigneeIds = note.activeAssignees;

    // Resolve assigned actors for the "Assigned" section
    final assignedActors = assigneeIds.isNotEmpty
        ? await Future.wait(assigneeIds.map(Actor.getOne))
        : <Actor>[];

    // Hidden active assignees (announce-topic-only) — count only, no identity
    final hiddenActiveCount =
        TagActors.countOf(note.tags[Tag.todo]) - assigneeIds.length;
    final assignedSubtitle = hiddenActiveCount > 0
        ? '+$hiddenActiveCount hidden'
        : null;

    // Resolve thread contacts for the "With" section
    final contactActors = <Actor>[];
    for (final contactId in thread.contacts) {
      try {
        final actor = await Actor.getOne(ActorId.fromUuid(contactId));
        if (!actor.self) contactActors.add(actor);
      } catch (_) {
        // Skip contacts whose actors can't be resolved
      }
    }
    final contactActorIds = contactActors.map((a) => a.id).toSet();

    // Exclude already-assigned contacts from the With section
    final unassignedContacts = contactActors
        .where((a) => !assigneeIds.contains(a.id))
        .toList();

    // Exclude both assigned and thread contact actors from Contacts
    final excludeFromContacts = <ActorId>[...assigneeIds, ...contactActorIds];

    return Commands(
      prompt: 'Assign to',
      groups: [
        if (assignedActors.isNotEmpty)
          StaticCommandGroup(
            title: 'Assigned',
            subtitle: assignedSubtitle,
            commands: assignedActors
                .map(
                  (actor) =>
                      _AssignDraftNoteActor(note, actor, onUpdate: onUpdate),
                )
                .toList(),
          ),
        if (unassignedContacts.isNotEmpty)
          StaticCommandGroup(
            title: 'In this thread',
            commands: unassignedContacts
                .map(
                  (actor) => _AssignDraftNoteActor(
                    note,
                    actor,
                    onUpdate: onUpdate,
                    thread: thread,
                  ),
                )
                .toList(),
          ),
        ActorGroup(
          title: 'Contacts',
          excludeActorIds: excludeFromContacts,
          builder: (actor) => _AssignDraftNoteActor(
            note,
            actor,
            onUpdate: onUpdate,
            thread: thread,
          ),
        ),
      ],
    );
  }
}

class _AssignDraftNoteActor extends NoteCommand {
  _AssignDraftNoteActor(
    super.note,
    this.actor, {
    required this.onUpdate,
    this.thread,
  }) : super(
         title: actor.nameOrEmail,
         eventObject: EventObject.note,
         eventAction: note.isAssignedTo(actor.id)
             ? EventAction.untagged
             : EventAction.tagged,
         icon: note.isCompletedBy(actor.id)
             ? PlotIcon.othersTaskDone
             : note.isAssignedTo(actor.id)
             ? PlotIcon.othersTask
             : PlotIcon.assignAdd,
         on: note.isAssignedTo(actor.id),
       );

  final Actor actor;
  final Future<void> Function(Note note, {Thread? thread}) onUpdate;
  final Thread? thread;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final isAssigned = note.isAssignedTo(actor.id);
      final updatedNote = note.setTag(Tag.todo, actor.id, !isAssigned);

      // If assigning (not unassigning) and actor is not on the thread, add
      // them to the draft thread's contacts so sharing follows assignment.
      Thread? updatedThread;
      if (!isAssigned && thread != null) {
        final contactUuid = actor.id.toUuid();
        if (!thread!.contacts.contains(contactUuid)) {
          updatedThread = thread!.copyWith(
            contacts: Value([...thread!.contacts, contactUuid]),
          );
        }
      }

      await onUpdate(updatedNote, thread: updatedThread);

      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in _AssignDraftNoteActor: $e', e, stackTrace);
      return CommandMessage('Failed to update assignment', isError: true);
    }
  }
}
