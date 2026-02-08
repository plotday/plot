import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/now.dart';
import 'package:plot/router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'logging.dart';

class AddNote extends Command {
  AddNote(this._note)
    : super(
        title: 'Add Note',
        eventObject: EventObject.note,
        eventAction: EventAction.added,
        icon: PlotIcon.addActivity,
      );

  final Future<Note> _note;

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

    final note = await _note;

    // Use ActivityBloc.add() if available (resets the draft), otherwise save directly
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
        title: 'Assign to Me',
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
        icon: PlotIcon.now,
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

      // Assign the note by adding Tag.now for the actor
      final updatedNote = note.assignTo(targetActorId);
      await updatedNote.save();

      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in AssignNote: $e', e, stackTrace);
      return CommandMessage('Failed to assign note', isError: true);
    }
  }
}

class StartTask extends NoteCommand {
  StartTask(super.note)
    : super(
        title: 'Make a Task',
        eventObject: EventObject.note,
        eventAction: EventAction.started,
        icon: PlotIcon.now,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final actorId = Base.actorId;
      log.info('StartNote.run called - noteId: ${note.id}, actorId: $actorId');

      // Check if already assigned
      final isAssigned = note.isAssignedTo(actorId);
      log.info(
        'StartNote - isAssigned: $isAssigned, current tags: ${note.tags}',
      );

      if (isAssigned) {
        // Already assigned - skip
        log.info('StartNote - note already assigned to user');
        return const CommandMessage('Already assigned');
      }

      // Assign the note by adding Tag.now for current user
      log.info('StartNote - calling note.assignTo($actorId)');
      final updatedNote = note.assignTo(actorId);
      await updatedNote.save();
      log.info('StartNote - note.assignTo completed successfully');

      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in StartNote: $e', e, stackTrace);
      return CommandMessage('Failed to start note', isError: true);
    }
  }
}

class FinishTask extends NoteCommand {
  FinishTask(super.note, {this.actorId})
    : super(
        title: 'Mark Done',
        eventObject: EventObject.note,
        eventAction: EventAction.finished,
        icon: note.isAssignedTo(actorId ?? Base.actorId)
            ? FontAwesomeIcons.circle
            : PlotIcon.done,
        hoverIcon: note.isAssignedTo(actorId ?? Base.actorId)
            ? FontAwesomeIcons.circleCheck
            : null,
      );

  final ActorId? actorId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final ActorId targetActorId;
      final assignees = note.activeAssignees;

      if (actorId != null) {
        // Explicit actor specified
        targetActorId = actorId!;
      } else if (assignees.length == 1) {
        // Single assignee: complete for them (even if different user)
        targetActorId = assignees.first;
      } else {
        // Multiple (or zero) assignees: complete for current user
        targetActorId = Base.actorId;
      }

      // Check if already completed by this actor
      if (note.isCompletedBy(targetActorId)) {
        return const CommandMessage('Already marked as done');
      }

      // Complete the note for this actor (replaces Tag.now with Tag.done)
      final updatedNote = note.completeFor(targetActorId);
      await updatedNote.save();

      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in FinishNote: $e', e, stackTrace);
      return CommandMessage('Failed to finish note', isError: true);
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
      ActivityBloc? activityBloc;
      try {
        activityBloc = context.read<ActivityBloc>();
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
        title: note.private ? 'Make Public' : 'Make Private',
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

class SplitNoteToNewActivity extends NoteCommand {
  SplitNoteToNewActivity(super.note)
    : super(
        title: 'Split to New Activity',
        eventObject: EventObject.note,
        eventAction: EventAction.moved,
        icon: PlotIcon.move,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Look up parent activity to get its priority
      final parentActivity = await Activity.getOne(note.activityId);

      // Create a new activity in the same priority with preview from note content
      final newActivity = Activity(
        priority: parentActivity.priority,
        draft: false,
        preview: note.content,
        title: note.content,
      );
      await newActivity.save();

      // Move the note to the new activity
      await note.copyWith(activityId: newActivity.id).save();

      // Fire-and-forget AI title generation
      if (note.content != null && note.content!.trim().isNotEmpty) {
        newActivity
            .generateTitle(note.content!)
            .then((title) async {
              if (title != newActivity.title) {
                await newActivity.copyWith(title: Value(title)).save();
              }
            })
            .catchError((Object e) {
              // Error already logged by generateTitle(), just ignore here
            });
      }

      // Navigate to the new activity in the current priority context
      var routePriority = newActivity.priority;
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
            ActivityRoute(activityIdString: newActivity.id.toShortString()),
          ],
        ),
        replace: true,
      );
    } catch (e, stackTrace) {
      log.severe('Error in SplitNoteToNewActivity: $e', e, stackTrace);
      return CommandMessage(
        'Failed to split note to new activity',
        isError: true,
      );
    }
  }
}

class PickNoteAssignee extends ShowCommands {
  PickNoteAssignee(this.note)
    : super(
        title: 'Assign',
        icon: FontAwesomeIcons.circleUserCirclePlus,
        commandsBuilder: (context) => _getAssigneeCommands(note),
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
      );

  final Note note;

  static Future<Commands> _getAssigneeCommands(Note note) async {
    final activity = await Activity.getOne(note.activityId);
    // Refresh note to get latest tag state
    final freshNote = await note.refresh();
    return Commands(
      prompt: 'Assign to',
      groups: [
        ActorGroup(
          priorityId: activity.priority.id,
          builder: (actor) => actor == null
              ? _UnassignAllFromNote(freshNote)
              : ToggleAssignNoteActor(freshNote, actor),
        ),
      ],
    );
  }
}

class ToggleAssignNoteActor extends NoteCommand {
  ToggleAssignNoteActor(Note note, this.actor)
    : super(
        note,
        title: actor.nameOrEmail,
        eventObject: EventObject.note,
        eventAction: note.isAssignedTo(actor.id)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: note.isAssignedTo(actor.id)
            ? FontAwesomeIcons.circleCheck
            : FontAwesomeIcons.circleUser,
      );

  final Actor actor;

  @override
  String? get subtitle => actor.email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final isAssigned = note.isAssignedTo(actor.id);
      final updatedNote = note.setTag(Tag.now, actor.id, !isAssigned);
      await updatedNote.save();
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleAssignNoteActor: $e', e, stackTrace);
      return CommandMessage('Failed to toggle assignment', isError: true);
    }
  }
}

class _UnassignAllFromNote extends NoteCommand {
  _UnassignAllFromNote(super.note)
    : super(
        title: 'Unassign All',
        eventObject: EventObject.note,
        eventAction: EventAction.untagged,
        icon: FontAwesomeIcons.circleUserCircleXmark,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      Note updatedNote = note;
      for (final actorId in note.activeAssignees) {
        updatedNote = updatedNote.setTag(Tag.now, actorId, false);
      }
      await updatedNote.save();
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in _UnassignAllFromNote: $e', e, stackTrace);
      return CommandMessage('Failed to unassign all', isError: true);
    }
  }
}

List<StaticCommandGroup> noteCommandGroups(Note note) {
  final actorId = Base.actorId;
  final tags = Tag.getAll()
      .map((tag) => ToggleNoteTag(note, tag, actorId))
      .toList();
  final commands = noteCommands(note);
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
  return [
    if (commands.isNotEmpty)
      StaticCommandGroup(title: 'Note', commands: commands),
    if (remove.isNotEmpty)
      StaticCommandGroup(title: 'Remove Tag', commands: remove),
    if (add.isNotEmpty) StaticCommandGroup(title: 'Add Tag', commands: add),
  ];
}

List<Command> noteCommands(Note note) {
  final actorId = Base.actorId;
  final isAssigned = note.isAssignedTo(actorId);

  return [
    if (!isAssigned) StartTask(note),
    if (isAssigned) FinishTask(note),
    PickNoteAssignee(note),
    if (!note.draft && note.content != null && note.content!.trim().isNotEmpty)
      SplitNoteToNewActivity(note),
    if (!note.private || note.authorId == Base.actorId) ToggleNotePrivate(note),
    ArchiveNote(note),
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

  // Filter out tags already on note and take maxToShow
  return tagSuggestions
      .where((tag) => !note.hasTag(tag, actorId))
      .take(maxToShow)
      .map((tag) => ToggleNoteTag(note, tag, actorId))
      .toList();
}

class ShowNoteCommands extends ShowCommands {
  ShowNoteCommands(Note note)
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: Commands(groups: noteCommandGroups(note)),
      );
}
