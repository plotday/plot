import 'command.dart';
import 'package:plot/router.dart';
import 'package:plot/analytics/tracker.dart';
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

class ToggleNotePrivate extends NoteCommand {
  ToggleNotePrivate(super.note, {this.isViewer = false})
    : super(
        title: isViewer
            ? (note.isPrivate ? 'Private' : 'Public')
            : (note.isPrivate ? 'Make public' : 'Make private'),
        eventObject: EventObject.note,
        eventAction: note.isPrivate ? EventAction.untagged : EventAction.tagged,
        icon: PlotIcon.private,
        on: isViewer ? note.isPrivate : null,
      );

  final bool isViewer;

  @override
  bool enabled(BuildContext context) => !isViewer;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (isViewer) return const CommandDone();
    try {
      final updatedNote = note.copyWith(
        accessContacts: Value(note.isPrivate ? null : []),
      );
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
      );

  final Note note;

  /// Whether there are other assignees (not the current user)
  bool get hasOtherAssignees => note.assignees.any((id) => id != Base.actorId);

  static String _computeTitle(Note note) {
    final otherAssignees = note.assignees.where((id) => id != Base.actorId);
    if (otherAssignees.isEmpty) return 'Assign';
    return 'Assigned';
  }

  static IconData _computeIcon(Note note) {
    final otherAssignees = note.assignees.where((id) => id != Base.actorId);
    if (otherAssignees.isEmpty) return PlotIcon.assignAdd;
    return PlotIcon.othersTask;
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

    // Resolve members for the "Members" section
    final memberActors = await _getMemberActors(activity.priority.id);
    final memberActorIds = memberActors.map((a) => a.id).toSet();

    // Exclude already-assigned members from the Members section
    final unassignedMembers = memberActors
        .where((a) => !assigneeIds.contains(a.id))
        .toList();

    // Exclude both assigned and member actors from Contacts
    final excludeFromContacts = <ActorId>[...assigneeIds, ...memberActorIds];

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
        if (unassignedMembers.isNotEmpty)
          StaticCommandGroup(
            title: 'Members',
            commands: unassignedMembers
                .map((actor) => AssignNoteActor(freshNote, actor))
                .toList(),
          ),
        ActorGroup(
          title: 'Contacts',
          priorityId: activity.priority.id,
          excludeActorIds: excludeFromContacts,
          builder: (actor) => AssignNoteActor(freshNote, actor),
        ),
      ],
    );
  }

  /// Resolves the members of the sharing priority (direct or ancestor).
  static Future<List<Actor>> _getMemberActors(PriorityId priorityId) async {
    // Fetch enriched priority to get sharingAncestorId
    final enriched = await Priority.get(id: priorityId, archived: null);
    if (enriched.isEmpty) return [];
    final priority = enriched.first;

    // Use the sharing ancestor if this priority inherits sharing
    final sharingId = priority.sharingAncestorId ?? priority.id;

    final members = await PriorityMember.getForPriority(sharingId);
    if (members.isEmpty) return [];

    final actors = <Actor>[];
    for (final member in members) {
      try {
        final actor = await Actor.getOne(member.contactId);
        actors.add(actor);
      } catch (_) {
        // Skip members whose actors can't be resolved
      }
    }
    return actors;
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
    if ((activityBloc?.state.thread.priority.personal != true || note.draft) &&
        (!note.isPrivate || note.authorId.isCurrentUser))
      ToggleNotePrivate(
        note,
        isViewer: activityBloc?.state.thread.priority.isViewer ?? false,
      ),
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
    required Uuid priorityId,
    required Future<void> Function(Note note) onUpdate,
  }) {
    // Mutable reference so commandsBuilder always sees the latest note
    final noteRef = [note];

    Future<void> wrappedOnUpdate(Note updatedNote) async {
      noteRef[0] = updatedNote;
      await onUpdate(updatedNote);
    }

    return PickDraftNoteAssignee._(
      note: note,
      priorityId: priorityId,
      onUpdate: onUpdate,
      commandsBuilder: (context) =>
          _getAssigneeCommands(noteRef[0], priorityId, wrappedOnUpdate),
    );
  }

  PickDraftNoteAssignee._({
    required this.note,
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
       );

  final Note note;
  final Uuid priorityId;
  final Future<void> Function(Note note) onUpdate;

  static String _computeTitle(Note note) {
    final otherAssignees = note.assignees.where((id) => id != Base.actorId);
    if (otherAssignees.isEmpty) return 'Assign';
    return 'Assigned';
  }

  static IconData _computeIcon(Note note) {
    final otherAssignees = note.assignees.where((id) => id != Base.actorId);
    if (otherAssignees.isEmpty) return PlotIcon.assignAdd;
    return PlotIcon.othersTask;
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

    // Resolve members for the "Members" section
    final memberActors = await PickNoteAssignee._getMemberActors(priorityId);
    final memberActorIds = memberActors.map((a) => a.id).toSet();

    // Exclude already-assigned members from the Members section
    final unassignedMembers = memberActors
        .where((a) => !assigneeIds.contains(a.id))
        .toList();

    // Exclude both assigned and member actors from Contacts
    final excludeFromContacts = <ActorId>[...assigneeIds, ...memberActorIds];

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
        if (unassignedMembers.isNotEmpty)
          StaticCommandGroup(
            title: 'Members',
            commands: unassignedMembers
                .map(
                  (actor) =>
                      _AssignDraftNoteActor(note, actor, onUpdate: onUpdate),
                )
                .toList(),
          ),
        ActorGroup(
          title: 'Contacts',
          priorityId: priorityId,
          excludeActorIds: excludeFromContacts,
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
            ? PlotIcon.othersTask
            : PlotIcon.assignAdd,
        on: note.isAssignedTo(actor.id),
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
