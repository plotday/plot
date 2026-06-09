import 'dart:async';

import 'command.dart';
import 'package:flutter/services.dart';
import 'package:plot/router.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/editor_clipboard.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/now.dart';
import 'package:plot/util/link_type_copy.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'logging.dart';

class AddNote extends Command {
  AddNote(this._note, {LinkTypeConfig? linkType})
    : super(
        title: commandTitleAddNote(linkType),
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

// Two states only: "To do" (assign the note as the user's own task) and
// "Done" (complete it). Un-completing a done note is handled by the check
// toggle under the note ([ToggleSelfDone]), so this action is never offered
// for notes the user has already completed.
enum _SelfTaskState { unassigned, todo }

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
    if (note.isAssignedTo(actorId)) return _SelfTaskState.todo;
    return _SelfTaskState.unassigned;
  }

  static String _titleForState(_SelfTaskState state) => switch (state) {
    _SelfTaskState.unassigned => 'To do',
    _SelfTaskState.todo => 'Done',
  };

  static EventAction _eventActionForState(_SelfTaskState state) =>
      switch (state) {
        _SelfTaskState.unassigned => EventAction.started,
        _SelfTaskState.todo => EventAction.finished,
      };

  static IconData _iconForState(_SelfTaskState state) => switch (state) {
    _SelfTaskState.unassigned => PlotIcon.selfTask,
    _SelfTaskState.todo => PlotIcon.selfTaskTodo,
  };

  static IconData? _hoverIconForState(_SelfTaskState state) => switch (state) {
    _SelfTaskState.unassigned => null,
    _SelfTaskState.todo => PlotIcon.selfTaskHover,
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
        title: 'To do',
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

/// Inline chip shown when *other* users have made the note their own task.
///
/// Renders the userCircle glyph (circlePlus on hover) and, like an emoji
/// reaction, tapping it toggles the current user's own [Tag.todo] on/off — it
/// never marks done. Joining surfaces the user's own circle chip before this
/// one; tapping again removes that circle.
class JoinNoteTask extends NoteCommand {
  JoinNoteTask(super.note)
    : super(
        title: 'Assigned themselves this task',
        eventObject: EventObject.note,
        eventAction: note.isAssignedTo(Base.actorId)
            ? EventAction.untagged
            : EventAction.tagged,
        icon: PlotIcon.othersTask,
        hoverIcon: PlotIcon.selfTask,
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
      log.severe('Error in JoinNoteTask: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to update task', isError: true);
    }
  }
}

/// Toggles the current user's completion of a note, like an emoji reaction.
///
/// Turning it on also clears the user's [Tag.todo] (via [Note.completeFor]) so
/// the local optimistic state matches the server, which archives todo when done
/// is added. Turning it off just removes [Tag.done].
class ToggleSelfDone extends NoteCommand {
  ToggleSelfDone(super.note)
    : super(
        title: 'Done',
        eventObject: EventObject.note,
        eventAction: note.isCompletedBy(Base.actorId)
            ? EventAction.untagged
            : EventAction.finished,
        icon: PlotIcon.done,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final actorId = Base.actorId;
      ThreadBloc? activityBloc;
      try {
        activityBloc = context.read<ThreadBloc>();
      } catch (e) {
        activityBloc = null;
      }

      final updatedNote = note.isCompletedBy(actorId)
          ? note.setTag(Tag.done, actorId, false)
          : note.completeFor(actorId);
      if (activityBloc != null &&
          activityBloc.state.draft.id == updatedNote.id) {
        await activityBloc.updateDraft(updatedNote);
      }
      await updatedNote.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleSelfDone: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to update task', isError: true);
    }
  }
}

/// Toggles an emoji reaction for the current user on a note.
///
/// Optimistically updates the local `note_reactions` row, marks the
/// reaction as pending (`reactions_updated`), and schedules a push. The
/// server's `update_note_reactions` RPC enforces only-self ownership;
/// matching client-side behaviour is implicit because we always toggle
/// the current user's canonical actor.
/// Opens the [EmojiPicker] and toggles the chosen emoji on the note.
/// Routes through [ToggleNoteReaction] for the actual write so all the
/// optimistic-local + sync-push logic stays in one place.
///
/// Filters the picker by the thread's primary connector capability when
/// known — same lookup used by [_NoteReactionsRow] (see widget/note.dart).
class AddNoteReaction extends NoteCommand {
  AddNoteReaction(super.note, {this.activityBloc})
    : super(
        title: 'Add reaction',
        eventObject: EventObject.note,
        eventAction: EventAction.tagged,
        icon: FontAwesomeIcons.faceSmilePlus,
      );

  final ThreadBloc? activityBloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Use the store's Link (the data row), not widget/link.dart (the
      // URL widget) — both names exist in the imports above.
      final links = activityBloc?.state.links ?? const [];
      // Resolve the thread's connector via its primary canonical link's owning
      // twist_instance, then read that instance's synced reaction
      // capabilities. Plot-native threads (no link) → open.
      final connectionId = Thread.primaryLink(links)?.createdBy;
      final instance =
          connectionId == null ? null : TwistInstance.fromCache(connectionId);
      final caps = reactionCapabilitiesFromJson(instance?.reactionCapabilities);
      final allowed = caps.allowed;

      // Offer this connection's workspace custom emoji (e.g. Slack
      // `:party_parrot:`). The scope is an opaque token stamped server-side;
      // we never parse it for workspace/provider — just prefix-match the cache.
      var workspaceCustom = const <Reaction>[];
      final scope = instance?.customEmojiScope;
      if (scope != null) {
        final rows = await CustomEmoji.forScope(scope);
        workspaceCustom = rows.map((r) => r.id).toList(growable: false);
      }

      // Guard against the `await` above: opening the picker disposes the hover
      // toolbar that hosts this button, but we still need a live context to
      // open the modal. If it's already gone, bail without reacting.
      if (!context.mounted) return const CommandDone();

      final prefs = context.read<LocalPreferencesBloc>();
      final emoji = await EmojiPicker.pick(
        context,
        allowed: allowed?.toSet(),
        mru: prefs.state.reactionMru,
        workspaceCustom: workspaceCustom,
      );
      if (emoji == null) return const CommandDone();

      // Record before delegating so the MRU reflects the just-picked emoji
      // for the next hover-toolbar render.
      await prefs.recordReactionUsage(emoji);

      // Apply the toggle via the context-free path. Do NOT gate this on
      // `context.mounted`: opening the emoji picker disposes the hover
      // toolbar that hosted this button, so `context` is routinely unmounted
      // by the time the user picks — gating here silently dropped the
      // reaction. `apply()` uses `Store.get`, not the BuildContext, so it's
      // safe to run regardless.
      return await ToggleNoteReaction(note, emoji).apply();
    } catch (e, stackTrace) {
      log.severe('Error in AddNoteReaction: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to react', isError: true);
    }
  }
}

class ToggleNoteReaction extends NoteCommand {
  ToggleNoteReaction(super.note, this.emoji)
    : super(
        title: 'React',
        eventObject: EventObject.note,
        eventAction: EventAction.tagged,
      );

  final Reaction emoji;

  @override
  Future<CommandReturn> run(BuildContext context) => apply();

  /// Toggles the current user's reaction. Pure local-Drift + sync work that
  /// takes no [BuildContext], so it can be invoked after the emoji picker
  /// closes — by which point the hover toolbar that hosted the trigger
  /// button (and its context) is typically already disposed.
  Future<CommandReturn> apply() async {
    try {
      final selfActorId = Base.actorId;
      final canonical = Actor.canonicalId(selfActorId);
      final db = Store.get;

      // Read the current local reactions row (may not exist yet).
      final current = await (db.select(
        db.noteReactions,
      )..where((t) => t.id.equals(note.id.toBytes()))).getSingleOrNull();

      final reactionsNow = <Reaction, List<ActorId>>{
        for (final entry in (current?.reactions ?? const {}).entries)
          entry.key: List<ActorId>.from(entry.value),
      };
      final updatesNow = <String, bool>{...?current?.reactionsUpdated};

      final actors = reactionsNow.putIfAbsent(emoji, () => <ActorId>[]);
      final present = actors.any((id) => Actor.canonicalId(id) == canonical);
      final nowPresent = !present;

      if (nowPresent) {
        actors.add(canonical);
      } else {
        actors.removeWhere((id) => Actor.canonicalId(id) == canonical);
        if (actors.isEmpty) reactionsNow.remove(emoji);
      }
      updatesNow[emoji] = nowPresent;

      // Write back to local Drift; mark pending so it's pushed.
      final companion = NoteReactionsCompanion(
        id: Value(note.id),
        reactions: Value(reactionsNow.isEmpty ? null : reactionsNow),
        reactionsUpdated: Value(updatesNow),
        updatedAt: Value(DateTime.now()),
        pending: const Value(2),
      );
      await db.into(db.noteReactions).insertOnConflictUpdate(companion);

      // Schedule a push.
      unawaited(SyncOrchestrator.instance.push(SyncOrchestrator.note));

      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleNoteReaction: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to react', isError: true);
    }
  }
}

/// Renders an active emoji reaction inline in the note's command row.
/// Uses the same `Button.icon(selected: true)` accent-color treatment as
/// selected count-tags: no border, no background, just the glyph in
/// accent. Tap toggles the reaction off via [ToggleNoteReaction].
class ActiveNoteReaction extends NoteCommand {
  ActiveNoteReaction(super.note, this.emoji)
    : super(
        title: emojiDisplayName(emoji),
        eventObject: EventObject.note,
        eventAction: EventAction.untagged,
      );

  final Reaction emoji;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      _emojiButtonIcon(context, emoji);

  @override
  Future<CommandReturn> run(BuildContext context) =>
      ToggleNoteReaction(note, emoji).run(context);
}

Widget _emojiButtonIcon(BuildContext _, Reaction emoji) =>
    EmojiCommandIcon(emoji);

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
      final updated = note.copyWith(accessContacts: Value([Base.actorId]));
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
    final selfIds = Actor.getCurrentUserActorIds().map((a) => a.value).toSet();
    final threadContacts = threadBloc.state.thread.contacts;

    final actors = <Actor>[];
    final seenCanonicalIds = <ActorId>{};
    for (final contactId in threadContacts) {
      try {
        final canonical = Actor.canonicalId(ActorId.fromUuid(contactId));
        if (!seenCanonicalIds.add(canonical)) continue;
        actors.add(await Actor.getOne(canonical));
      } catch (_) {
        // Skip contacts we can't resolve
      }
    }

    final selfActors = actors
        .where((a) => selfIds.contains(a.id.value))
        .toList();
    final otherActors = actors
        .where((a) => !selfIds.contains(a.id.value))
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
                .map(
                  (a) => ToggleNotePrivacyContact(freshNote, a, isSelf: true),
                )
                .toList(),
          ),
        if (otherActors.isNotEmpty)
          StaticCommandGroup(
            title: 'Others in this thread',
            commands: otherActors
                .map(
                  (a) => ToggleNotePrivacyContact(freshNote, a, isSelf: false),
                )
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
  ToggleNotePrivacyContact(super.note, this.actor, {required this.isSelf})
    : super(
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
      // Preview stores a normalised single-line summary of the note content.
      final newThread = Thread(
        priority: parentThread.priority,
        draft: false,
        preview: Thread.createPreviewFromMarkdown(note.content),
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

List<StaticCommandGroup> noteCommandGroups(
  Note note, {
  ThreadBloc? activityBloc,
}) {
  final isReadOnly = activityBloc?.state.thread.isReadOnly ?? false;
  final commands = noteCommands(note, activityBloc: activityBloc);
  if (!note.draft && !isReadOnly) commands.add(ArchiveNote(note));
  if (commands.isEmpty) return const [];
  return [StaticCommandGroup(title: 'Note', commands: commands)];
}

List<Command> noteCommands(Note note, {ThreadBloc? activityBloc}) {
  final isReadOnly = activityBloc?.state.thread.isReadOnly ?? false;

  // Read-only threads: can only reply (forced private by DB), edit own
  // notes, and copy.
  if (isReadOnly) {
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
    // "To do" / "Done" — omitted once the user has completed the note; they
    // un-complete via the check toggle under the note instead.
    if (!note.isCompletedBy(Base.actorId)) SelfTaskAction(note),
    if (!note.draft && activityBloc != null)
      ReplyToNote(note, activityBloc: activityBloc),
    if (!note.draft) AddNoteReaction(note, activityBloc: activityBloc),
    if (!note.draft &&
        note.authorId.isCurrentUser &&
        note.content != null &&
        note.content!.trim().isNotEmpty)
      EditNote(note, activityBloc: activityBloc),
    if (!note.draft && note.content != null && note.content!.trim().isNotEmpty)
      SplitNoteToNewThread(note),
    if (note.content != null && note.content!.trim().isNotEmpty)
      CopyNoteContent(note),
    if (activityBloc != null && !note.isPrivate)
      MakeNotePrivate(note, threadBloc: activityBloc),
    if (activityBloc != null && note.isPrivate && note.authorId.isCurrentUser)
      ChangeNotePrivacy(note, threadBloc: activityBloc),
  ];
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
        title: 'More',
        icon: PlotIcon.menu,
        commandsBuilder: (context) async => Commands(
          groups: noteCommandGroups(note, activityBloc: activityBloc),
        ),
      );
}
