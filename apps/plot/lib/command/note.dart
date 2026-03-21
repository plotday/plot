import 'package:flutter/services.dart';

import 'command.dart';
import 'package:plot/router.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
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
  ToggleNoteTag(super.note, this.tag, this.actorId)
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

  @override
  Future<CommandReturn> run(BuildContext context) async {
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

class ToggleNotePrivate extends NoteCommand {
  ToggleNotePrivate(super.note)
    : super(
        title: note.private ? 'Make public' : 'Make private',
        eventObject: EventObject.note,
        eventAction: note.private ? EventAction.untagged : EventAction.tagged,
        icon: PlotIcon.private,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final updatedNote = note.copyWith(private: !note.private);
      await updatedNote.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleNotePrivate: $e', e, stackTrace);
      return CommandMessage('Failed to toggle private', isError: true);
    }
  }
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
  ReplyToNote(super.note)
    : super(
        title: 'Reply',
        eventObject: EventObject.note,
        eventAction: EventAction.added,
        icon: FontAwesomeIcons.reply,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final activityBloc = context.read<ThreadBloc>();
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
      await note.delete();
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

      // Create a new thread in the same priority with preview from note content
      final newThread = Thread(
        priority: parentThread.priority,
        draft: false,
        preview: note.content,
        title: note.content,
      );
      await newThread.save();

      // Move the note to the new thread and unarchive it
      await note.copyWith(threadId: newThread.id, clearArchivedAt: true).save();

      // Fire-and-forget AI title generation
      if (note.content != null && note.content!.trim().isNotEmpty) {
        newThread
            .generateTitle(note.content!)
            .then((title) async {
              if (title != newThread.title) {
                await newThread.copyWith(title: Value(title)).save();
              }
            })
            .catchError((Object e) {
              // Error already logged by generateTitle(), just ignore here
            });
      }

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
        title: note.assignees.isEmpty ? 'Assign' : 'Assigned',
        icon: _computeIcon(note),
        commandsBuilder: (context) => _getAssigneeCommands(note),
        showFilter: true,
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
      );

  final Note note;

  /// Whether there are other assignees (not the current user)
  bool get hasOtherAssignees => note.assignees.any((id) => id != Base.actorId);

  static IconData _computeIcon(Note note) {
    final otherAssignees = note.assignees.where((id) => id != Base.actorId);
    if (otherAssignees.isEmpty) return PlotIcon.assignAdd;
    final allOthersDone = otherAssignees.every((id) => note.isCompletedBy(id));
    return allOthersDone ? PlotIcon.othersTaskDone : PlotIcon.othersTask;
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

    return Commands(
      prompt: 'Assign to',
      groups: [
        if (assignedActors.isNotEmpty)
          StaticCommandGroup(
            title: 'Assigned',
            commands: assignedActors
                .map((actor) => AssignNoteActor(freshNote, actor))
                .toList(),
          ),
        ActorGroup(
          title: 'Contacts',
          priorityId: activity.priority.id,
          excludeActorIds: assigneeIds,
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
            ? PlotIcon.assignRemove
            : PlotIcon.assignAdd,
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
    for (final tag in activeTags) tag: note.tags[tag]?.length ?? 0,
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
            StaticCommandGroup(
              title: 'Remove tag',
              commands: freshRemove,
            ),
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
      title: null,
      commands: [],
      infoBuilder: (context) => TagRow(
        activeTags: activeTags,
        suggestedTags: suggestedTags,
        activeTagCounts: activeTagCounts,
        commandBuilder: (tag) => ToggleNoteTag(note, tag, actorId),
        showAllBuilder: makeShowAll,
      ),
      onActivate: (ctx) => makeShowAll().run(ctx),
    ),
  ];
}

List<Command> noteCommands(Note note, {ThreadBloc? activityBloc}) {
  final isViewer = activityBloc?.state.thread.priority.isViewer ?? false;

  // Viewers can only reply (forced private by DB), edit own notes, and copy
  if (isViewer) {
    return [
      if (!note.draft) ReplyToNote(note),
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
    if (!note.draft) ReplyToNote(note),
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
    if ((activityBloc?.state.thread.priority.personal != true || note.draft) &&
        (!note.private || note.authorId.isCurrentUser))
      ToggleNotePrivate(note),
  ];
}

/// Returns up to 3 tag suggestions for quick actions.
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

  // Calculate how many tags to show: 3 minus active non-hardcoded tags
  final maxToShow = 3 - activeNonHardcodedCount;
  if (maxToShow <= 0) return [];

  // Filter out tags already on note (and archived, which is menu-only) and take maxToShow
  return tagSuggestions
      .where(
        (tag) =>
            tag != Tag.archived &&
            !note.hasTag(tag, actorId) &&
            !(tag == Tag.done && note.hasTag(Tag.todo, actorId)),
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
      await Clipboard.setData(ClipboardData(text: note.content!));
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
          groups: noteCommandGroups(
            note,
            activityBloc: activityBloc,
          ),
        ),
      );
}

/// Assign picker for draft notes on NewThreadPage (uses callback instead of ThreadBloc).
class PickDraftNoteAssignee extends ShowCommands {
  PickDraftNoteAssignee({
    required this.note,
    required this.priorityId,
    required this.onUpdate,
  }) : super(
         title: note.assignees.isEmpty ? 'Assign' : 'Assigned',
         icon: _computeIcon(note),
         commandsBuilder: (context) =>
             _getAssigneeCommands(note, priorityId, onUpdate),
         showFilter: true,
         eventObject: EventObject.note,
         eventAction: EventAction.updated,
       );

  final Note note;
  final Uuid priorityId;
  final Future<void> Function(Note note) onUpdate;

  static IconData _computeIcon(Note note) {
    final otherAssignees = note.assignees.where((id) => id != Base.actorId);
    if (otherAssignees.isEmpty) return PlotIcon.assignAdd;
    final allOthersDone = otherAssignees.every((id) => note.isCompletedBy(id));
    return allOthersDone ? PlotIcon.othersTaskDone : PlotIcon.othersTask;
  }

  static Future<Commands> _getAssigneeCommands(
    Note note,
    Uuid priorityId,
    Future<void> Function(Note note) onUpdate,
  ) async {
    final assigneeIds = note.activeAssignees;

    // Resolve assigned actors for the "Assigned" section
    final assignedActors = assigneeIds.isNotEmpty
        ? await Future.wait(assigneeIds.map(Actor.getOne))
        : <Actor>[];

    return Commands(
      prompt: 'Assign to',
      groups: [
        if (assignedActors.isNotEmpty)
          StaticCommandGroup(
            title: 'Assigned',
            commands: assignedActors
                .map(
                  (actor) =>
                      _AssignDraftNoteActor(note, actor, onUpdate: onUpdate),
                )
                .toList(),
          ),
        ActorGroup(
          title: 'Contacts',
          priorityId: priorityId,
          excludeActorIds: assigneeIds,
          builder: (actor) =>
              _AssignDraftNoteActor(note, actor, onUpdate: onUpdate),
        ),
      ],
    );
  }
}

class _AssignDraftNoteActor extends NoteCommand {
  _AssignDraftNoteActor(super.note, this.actor, {required this.onUpdate})
    : super(
        title: actor.nameOrEmail,
        eventObject: EventObject.note,
        eventAction: note.isAssignedTo(actor.id)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: note.isCompletedBy(actor.id)
            ? PlotIcon.othersTaskDone
            : note.isAssignedTo(actor.id)
            ? PlotIcon.assignRemove
            : PlotIcon.assignAdd,
      );

  final Actor actor;
  final Future<void> Function(Note note) onUpdate;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final isAssigned = note.isAssignedTo(actor.id);
      final updatedNote = note.setTag(Tag.todo, actor.id, !isAssigned);
      await onUpdate(updatedNote);
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in _AssignDraftNoteActor: $e', e, stackTrace);
      return CommandMessage('Failed to update assignment', isError: true);
    }
  }
}
