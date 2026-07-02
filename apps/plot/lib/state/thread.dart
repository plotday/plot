import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/screenshot/scenes.dart';
import 'logging.dart';

part 'thread_state.dart';

class ThreadBloc extends Cubit<ThreadState> {
  ThreadBloc({required Thread thread, required LocalPreferencesBloc localPreferences})
    : _subscriptions = [],
      _tagsSubscription = null,
      _reactionsSubscription = null,
      super(
        // Seed from the single persisted archived-visibility flag so opening a
        // thread honours a "Show archived items" toggle made elsewhere.
        ThreadState(
          thread: thread,
          showArchived: localPreferences.state.showAllPriorities,
        ),
      ) {
    _loadThread();
    _initNotesLoaded();

    // React to the global archived-visibility flag (the unified "Show archived
    // items" command) so archived notes appear/hide here in lockstep.
    _showArchivedFromPrefs = localPreferences.state.showAllPriorities;
    _localPreferencesSubscription = localPreferences.stream.listen((prefs) {
      if (prefs.showAllPriorities == _showArchivedFromPrefs) return;
      _showArchivedFromPrefs = prefs.showAllPriorities;
      _applyShowArchived(prefs.showAllPriorities);
    });
  }

  /// Resolves the [ThreadState.notesLoaded] latch once this thread's notes are
  /// guaranteed loaded: immediately if a per-thread pull already ran, otherwise
  /// after [Note.ensureNotesLoadedForActivity] (the on-demand pull) completes —
  /// even if the thread turns out to have zero notes. Flipped to true on error
  /// too, so the loading spinner never spins forever. Called once from the
  /// constructor (not from [_loadNotes], which re-runs on filter changes) so
  /// the latch is sticky across filtering. The [_loadNotes] listener also flips
  /// it the instant any non-empty local list arrives, so already-local threads
  /// never show a spinner.
  Future<void> _initNotesLoaded() async {
    try {
      await Note.ensureNotesLoadedForActivity(state.thread.id);
    } catch (e, stackTrace) {
      log.warning('ensureNotesLoadedForActivity failed', e, stackTrace);
    }
    if (!isClosed && !state.notesLoaded) {
      emit(state.copyWith(notesLoaded: true));
    }
  }

  /// Applies a new archived-visibility value, driven by the global
  /// `showAllPriorities` flag on [LocalPreferencesBloc]. No-ops when unchanged.
  void _applyShowArchived(bool showArchived) {
    if (state.showArchived == showArchived) return;
    log.info('Applying showArchived = $showArchived');
    emit(state.copyWith(showArchived: showArchived));
    _loadNotes();
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    emit(state.copyWith(filter: filter));
    _loadNotes();
  }

  void updateReactionFilter(List<Reaction> reactionFilter) {
    log.info('Updating reaction filter to $reactionFilter');
    emit(state.copyWith(reactionFilter: reactionFilter));
    _loadNotes();
  }

  void updateSearch(String search) {
    log.info('Updating search to "$search"');
    emit(state.copyWith(search: search));
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _tagsSubscription?.cancel();
    _reactionsSubscription?.cancel();
    _notesSubscription?.cancel();
    _localPreferencesSubscription?.cancel();
    return super.close();
  }

  Future<void> save(Note note) async {
    await note.save();
  }

  /// Updates the draft note optimistically and saves it to the database.
  /// This provides instant UI updates while persisting changes.
  Future<void> updateDraft(Note draft) async {
    emit(state.copyWith(draft: draft));
    await draft.save();
  }

  /// Optimistically update [state.thread] so widgets that read this bloc
  /// (e.g. the thread actions row's Finish/To-do button) rebuild without
  /// waiting for the SQLite save → `Thread.watchOne` round trip. The
  /// watcher will reconcile to the persisted value shortly after.
  void optimisticallyUpdateThread(Thread updated) {
    if (updated.id != state.thread.id) return;
    emit(state.copyWith(thread: updated));
  }

  /// Updates the draft note's per-message recipient subset and, optionally,
  /// extends the thread's contacts / groups with newly-added members from the
  /// recipient picker.
  ///
  /// - [accessContacts]: new per-note contact subset. null = thread default
  ///   (no per-note narrowing).
  /// - [accessGroups]: new per-note group subset. null = thread default.
  /// - [threadContactsAdded]: contacts the picker added that weren't already
  ///   on the thread. Will be appended to [thread.contacts].
  /// - [threadGroupsAdded]: groups added by the picker. Will be appended to
  ///   [thread.groups].
  Future<void> editNoteRecipients({
    required List<ActorId>? accessContacts,
    required List<ActorId>? accessGroups,
    List<ActorId> threadContactsAdded = const [],
    List<ActorId> threadGroupsAdded = const [],
  }) async {
    final newDraft = state.draft.copyWith(
      accessContacts: Value(accessContacts),
      accessGroups: Value(accessGroups),
    );

    final contactsToAdd = threadContactsAdded.map((a) => a.value).toList();
    final groupsToAdd = threadGroupsAdded.map((a) => a.value).toList();

    final newThreadContacts = contactsToAdd.isEmpty
        ? state.thread.contacts
        : [
            ...state.thread.contacts,
            ...contactsToAdd.where((id) => !state.thread.contacts.contains(id)),
          ];
    final newThreadGroups = groupsToAdd.isEmpty
        ? state.thread.groups
        : [
            ...state.thread.groups,
            ...groupsToAdd.where((id) => !state.thread.groups.contains(id)),
          ];

    final threadChanged = contactsToAdd.isNotEmpty || groupsToAdd.isNotEmpty;
    final newThread = threadChanged
        ? state.thread.copyWith(
            contacts: Value(newThreadContacts),
            groups: Value(newThreadGroups),
          )
        : state.thread;

    // Save order: draft FIRST (the restrictive per-note constraint), thread
    // SECOND (the audience-widening extension). If only the second fails, the
    // draft is still restrictive — the worst-case is "user has to re-add the
    // contact next time" rather than "audience leaks." The reverse order
    // could leak (thread widened without draft restriction in place).
    // We do NOT wrap in Store.transaction because note.save() may trigger
    // an internal push; the memory note on drift txn zone capture shows that
    // fire-and-forget pushes started inside a transaction capture the txn
    // zone and throw "transaction used after it was closed."
    await newDraft.save();
    if (threadChanged) {
      await newThread.save();
    }

    emit(state.copyWith(draft: newDraft, thread: newThread));
  }

  /// Updates the draft note's per-message recipient subset in memory only —
  /// no DB persistence. Used by mode pills where the draft already lives in
  /// memory and persists on the next save trigger. The recipient picker uses
  /// [editNoteRecipients] instead because picker results may also extend
  /// thread.contacts / thread.groups, which DO need persisting.
  void setDraftRecipients({
    required List<ActorId>? accessContacts,
    required List<ActorId>? accessGroups,
  }) {
    final newDraft = state.draft.copyWith(
      accessContacts: Value(accessContacts),
      accessGroups: Value(accessGroups),
    );
    emit(state.copyWith(draft: newDraft));
  }

  /// Sets the note being replied to. Pass null to clear.
  /// Clears editing state when replying (mutual exclusion).
  /// When replying to a private note, auto-marks the draft as private and
  /// carries over the original note's author + mentions.
  void setReplyTo(Note? note) {
    var draft = state.draft;
    if (note != null && note.isPrivate) {
      final replyAccessContacts = <ActorId>{
        note.authorId,
        ...?note.accessContacts,
      }.toList();
      draft = draft.copyWith(
        accessContacts: Value(replyAccessContacts),
        addMentions: replyAccessContacts,
      );
    } else if (note == null &&
        state.replyTo != null &&
        state.replyTo!.isPrivate) {
      // Clearing reply to a private note — reset draft private and mentions
      draft = draft.copyWith(accessContacts: const Value(null), mentions: []);
    }
    emit(
      state.copyWith(
        replyTo: note,
        clearReplyTo: note == null,
        clearEditingNote: note != null,
        draft: draft,
      ),
    );
  }

  /// Sets the note being edited. Pass null to clear.
  /// Clears reply state when editing (mutual exclusion).
  void setEditingNote(Note? note) {
    emit(
      state.copyWith(
        editingNote: note,
        clearEditingNote: note == null,
        clearReplyTo: note != null,
      ),
    );
  }

  /// Saves an edited note and clears editing state.
  Future<void> updateNote(Note note) async {
    await note.save();
    emit(state.copyWith(clearEditingNote: true));
  }

  /// Sets thread filter to show only a note and its replies. Pass null to clear.
  void setThreadFilter(NoteId? noteId) {
    emit(
      state.copyWith(threadNoteId: noteId, clearThreadNoteId: noteId == null),
    );
    _loadNotes();
  }

  /// Adds a note by converting the current draft to a non-draft.
  /// Creates a fresh draft note for the thread afterward.
  /// Note: Twisting tag for twist mentions is added in Note.save()
  Future<void> add(Note note) async {
    // Snapshot thread + links before any state mutations below.
    var currentThread = state.thread;
    final currentLinks = state.links;

    // Also update thread contacts if there are new user/contact mentions.
    // Done BEFORE converting to non-draft so the mentions are correctly
    // attributed to the original draft content if copyWith was just called.
    currentThread = await _mergeNoteMentionsIntoContacts(note, currentThread);

    // Convert the draft to a non-draft.
    note = note.copyWith(draft: false);

    // Create fresh draft for the thread (in-memory only, will be saved when content is added)
    // Don't save empty draft - it will be saved when content is added via updateDraft()
    // Also clear replyTo and editing state
    emit(
      state.copyWith(
        draft: Note.draft(threadId: currentThread.id),
        clearReplyTo: true,
        clearEditingNote: true,
      ),
    );

    // Default fresh draft to private if priority has viewers
    _defaultDraftToPrivateIfViewers();

    // Async
    note.save();

    // BCC auto-drop: for message-mode threads, remove contacts whose role
    // is hidden (BCC) from thread.contacts after the message is sent.
    // This prevents BCC recipients from being visible to future senders.
    _dropHiddenRoleContactsAfterSend(currentThread, currentLinks);
  }

  /// Merges any non-twist note mentions into [currentThread.contacts], saving
  /// the thread and emitting updated state when the contact list changes.
  /// Returns the (possibly updated) thread.
  Future<Thread> _mergeNoteMentionsIntoContacts(
    Note note,
    Thread currentThread,
  ) async {
    if (note.mentions == null || note.mentions!.isEmpty) return currentThread;
    final newContacts = {...currentThread.contacts};
    bool changed = false;
    for (final mention in note.mentions!) {
      if (!mention.isTwist) {
        if (newContacts.add(mention.toUuid())) changed = true;
      }
    }
    if (!changed) return currentThread;
    final updatedThread = currentThread.copyWith(
      contacts: Value(newContacts.toList()),
    );
    await updatedThread.save();
    emit(state.copyWith(thread: updatedThread));
    return updatedThread;
  }

  /// Like [add], but holds the remote push for 5 seconds so the user can undo.
  /// The note is saved as a normal NON-draft row immediately (so it appears in
  /// the list right away and renders seamlessly — only its footer shows
  /// `SENDING`); only its push is held by [PendingSend] until the window
  /// elapses. If the thread is still a draft (e.g. a brand-new thread being
  /// re-sent after an undo), it is promoted to non-draft here too — also push-
  /// held — so it appears in the feed and is never stranded. [PendingSend.commit]
  /// releases the hold and pushes when the window elapses (or on app-close /
  /// sign-out); [PendingSend.undo] hides the note again and demotes the thread.
  ///
  /// Unshared notes (a private note, or any note on a solo thread) are seen
  /// only by the user, so they skip the window and push immediately.
  Future<void> sendWithUndo(Note note) async {
    var currentThread = state.thread;
    final currentLinks = state.links;

    // Merge new non-twist mentions into thread.contacts (mirrors add()).
    currentThread = await _mergeNoteMentionsIntoContacts(note, currentThread);

    // Unshared notes — a private note, or any note on a solo thread — are seen
    // only by the user, so there's nothing to "unsend": send immediately with
    // no undo window (push right away instead of holding it).
    final immediate = note.isPrivate || !currentThread.isShared;

    // Scheduled send: skip the 5-second PendingSend window entirely — the
    // note pushes immediately as draft=false + send_at and the SERVER holds
    // delivery until the instant (visible only to the author until then).
    // The tappable "Scheduled for …" footer is the undo affordance.
    final scheduled =
        note.sendAt != null && note.sendAt!.isAfter(DateTime.now());

    // A still-draft thread means this is the first note of a brand-new thread
    // (typically a re-send after undo). Promote it alongside the note.
    final promoting = currentThread.draft;
    final isSelfTodo = note.hasTag(Tag.todo, Base.actorId);
    final publishNote = note.copyWith(draft: false);
    final promoteThread = promoting
        ? currentThread.copyWith(
            draft: false,
            todo: isSelfTodo ? true : null,
            // Mirror the composing note's hold onto the thread shell so
            // recipients don't see the new thread until release (§ server
            // hold). Replies never set thread.send_at.
            sendAt: scheduled ? Value(note.sendAt) : const Value.absent(),
          )
        : currentThread;

    if (immediate || scheduled) {
      // Finalize any prior held send first (one at a time).
      unawaited(PendingSend.instance.commit());
    } else {
      // Register the hold + 5s timer BEFORE saving so a save-triggered push
      // can't claim the rows before the hold is in place.
      PendingSend.instance.start(
        noteId: publishNote.id,
        threadId: currentThread.id,
        promotedThreadFromDraft: promoting,
      );
    }

    if (promoting) {
      await promoteThread.save();
      emit(state.copyWith(thread: promoteThread));
    }
    // Held sends save WITHOUT pushing (PendingSend holds the push until the
    // window elapses); immediate and scheduled sends push right away (the
    // server holds a scheduled note's delivery, not the client).
    await publishNote.save(pushToRemote: immediate || scheduled);

    // Reset the composer to a fresh draft and clear reply/editing — same UI
    // reset add() performs so the editor clears immediately on send.
    emit(
      state.copyWith(
        draft: Note.draft(threadId: currentThread.id),
        clearReplyTo: true,
        clearEditingNote: true,
      ),
    );
    _defaultDraftToPrivateIfViewers();

    // BCC auto-drop (mirrors add()); runs async.
    _dropHiddenRoleContactsAfterSend(promoteThread, currentLinks);
  }

  /// Cancels a scheduled send and pulls the note back into the composer.
  ///
  /// Server-side cancellation is by ARCHIVING with `send_at` left unchanged
  /// (still future): if the archive write were lost but a null-`send_at`
  /// write applied, the note would fire immediately — the exact failure this
  /// feature guards against. Keeping `send_at` future means the note fails
  /// CLOSED (stays held); the release sweep skips archived rows.
  ///
  /// For a scheduled new-thread compose (thread.sendAt set), the whole thread
  /// is archived server-side too, then demoted back to a LOCAL draft so
  /// re-sending takes the compose path again — `upsert_thread`'s
  /// archived-refile branch revives it, and the re-stashed `create_link`
  /// spec re-dispatches the external item. Draft threads are never pushed,
  /// so the local un-archive can't fight the server-side archive.
  Future<void> unscheduleNote(Note note) async {
    if (!note.isScheduled) return;
    final thread = state.thread;
    final heldThread =
        thread.sendAt != null && thread.sendAt!.isAfter(DateTime.now());

    if (heldThread) {
      await thread.copyWith(archivedAt: Value(DateTime.now())).save();
    }
    await note
        .copyWith(archivedAt: Value(DateTime.now()))
        .save(pushToRemote: false);
    // Push both cancellations and WAIT for the push before the local demote
    // below — a draft thread is excluded from the push claim, so demoting
    // first could strand the thread's archive locally.
    await SyncOrchestrator.instance.push(SyncOrchestrator.note);

    if (heldThread) {
      final fresh = await Thread.getOne(thread.id);
      final demoted =
          fresh.copyWith(draft: true, archivedAt: const Value(null));
      await demoted.save();
      // Emit the DEMOTED thread (not the pre-demote `fresh`, which is still
      // draft=false + archived): `sendWithUndo` reads `state.thread` and only
      // re-promotes/re-pushes when `draft` is true. Emitting the stale snapshot
      // made re-send skip promotion, so the thread stayed archived server-side
      // (held but invisible) and dropped out of the list.
      emit(state.copyWith(thread: demoted));
      // Re-attach the connector create-link spec for the eventual re-send.
      ThreadsBase.stashPendingCreateLink(thread.id, note);
    }

    // Restore the content into a fresh draft with the prior schedule
    // pre-filled, so re-scheduling is one click and Send-now is
    // clear-schedule + Send.
    final restored = Note.draft(threadId: thread.id).copyWith(
      content: note.content,
      actions: note.actions,
      mentions: note.mentions,
      sendAt: Value(note.sendAt),
    );
    Note? replyTarget;
    if (note.reNoteId != null) {
      replyTarget = state.notes.where((n) => n.id == note.reNoteId).firstOrNull;
    }
    emit(
      state.copyWith(
        draft: restored,
        replyTo: replyTarget,
        clearReplyTo: replyTarget == null,
      ),
    );
  }

  /// Moves an un-sent (undone) note's content back into the composer. Restores
  /// content + actions and re-enters reply mode if the note was a reply.
  void restoreDraft(Note? note) {
    if (note == null) return;
    final restored = Note.draft(threadId: state.thread.id)
        .copyWith(content: note.content, actions: note.actions);
    Note? replyTarget;
    if (note.reNoteId != null) {
      replyTarget =
          state.notes.where((n) => n.id == note.reNoteId).firstOrNull;
    }
    emit(
      state.copyWith(
        draft: restored,
        replyTo: replyTarget,
        clearReplyTo: replyTarget == null,
      ),
    );
  }

  /// After a note is sent on a message-mode thread, drop any contacts whose
  /// role is marked `hidden` (BCC). The BCC contact is moved to
  /// `dropped_contacts` (retains visibility into the message they were BCC'd
  /// on) rather than removed from `contacts` entirely. Runs asynchronously so
  /// it doesn't delay the UI update from [add].
  void _dropHiddenRoleContactsAfterSend(Thread thread, List<Link> links) {
    unawaited(_doDropHiddenRoleContacts(thread, links));
  }

  Future<void> _doDropHiddenRoleContacts(
    Thread thread,
    List<Link> links,
  ) async {
    final sharingModel = Thread.resolveSharingModel(links);
    if (sharingModel != SharingModel.message) return;

    final cfg = Thread.primaryLink(links)?.getTypeConfig();
    final hiddenRoleIds = (cfg?.contactRoles ?? const <ContactRoleConfig>[])
        .where((r) => r.hidden)
        .map((r) => r.id)
        .toSet();
    if (hiddenRoleIds.isEmpty) return;

    final meta = thread.contactMeta;
    final toDrop = thread.contacts.where((contactId) {
      final entry = meta[contactId.toString()];
      final role = entry is Map<String, dynamic>
          ? entry['role'] as String?
          : null;
      return role != null && hiddenRoleIds.contains(role);
    }).toList();

    if (toDrop.isEmpty) return;

    // Add to dropped_contacts (keeps contact in thread.contacts for visibility)
    // and strip their contact_meta entries (they no longer have an active role).
    final toDropSet = toDrop.toSet();
    final newDropped = [
      ...thread.droppedContacts,
      ...toDropSet.where((id) => !thread.droppedContacts.contains(id)),
    ];
    final newMeta = Map<String, dynamic>.of(meta)
      ..removeWhere((k, _) => toDropSet.any((id) => id.toString() == k));

    final updatedThread = thread.copyWith(
      droppedContacts: Value(newDropped),
      contactMeta: Value(newMeta.isEmpty ? null : newMeta),
    );
    try {
      await updatedThread.save();
      emit(state.copyWith(thread: updatedThread));
    } catch (e, stackTrace) {
      log.severe(
        'Error dropping hidden-role contacts after send: $e',
        e,
        stackTrace,
      );
      Tracker.captureException(e, stackTrace);
    }
  }

  void _loadThread() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }

    // Load draft note from database
    _loadDraftNote();

    _subscriptions.add(
      Thread.watchOne(state.thread.id).listen((watchedThread) {
        emit(state.copyWith(thread: watchedThread));
      }),
    );

    // Watch links for the thread. The first emission flips [linksLoaded] so
    // link-config-dependent composer chrome can stop holding its neutral
    // state. Drift's `.watch()` always emits at least once (an empty list for
    // link-less threads), so this reliably lands a frame after construction.
    _subscriptions.add(
      Link.watchForThread(state.thread.id).listen((links) {
        emit(state.copyWith(links: links, linksLoaded: true));
      }),
    );

    // Watch tags for the thread
    _tagsSubscription?.cancel();
    _tagsSubscription = Note.watchTagsForActivity(state.thread.id).listen((
      tags,
    ) {
      // Calculate tag suggestions: common tags first, then all other tags
      const actionTags = [Tag.todo];

      // Common tags (excluding action tags)
      final commonTagsFiltered = tags
          .where(
            (tagData) => !actionTags.contains(tagData.$1) && tagData.$1.addable,
          )
          .map((tagData) => tagData.$1)
          .toList();

      // All tags excluding action tags and common tags
      final commonTagSet = commonTagsFiltered.toSet();
      final otherTags = Tag.getAll(onlyAddable: true)
          .where(
            (tag) => !actionTags.contains(tag) && !commonTagSet.contains(tag),
          )
          .toList();

      // Combine: common tags first, then other tags
      final tagSuggestions = [...commonTagsFiltered, ...otherTags];

      emit(state.copyWith(tags: tags, tagSuggestions: tagSuggestions));
    });

    // Watch reactions for the thread (thread-level + note-level union).
    _reactionsSubscription?.cancel();
    _reactionsSubscription = Note.watchReactionsForActivity(state.thread.id)
        .listen((reactions) {
          emit(state.copyWith(reactions: reactions));
        });

    _loadNotes();
  }

  /// Loads draft note from database for the current thread
  Future<void> _loadDraftNote() async {
    final sceneDraft = Scenes.draftContentFor(state.thread.title ?? '');
    if (sceneDraft != null) {
      emit(state.copyWith(
        draft: state.draft.copyWith(content: sceneDraft),
      ));
      return;
    }
    final existingDraft = await Note.getDraftByActivity(state.thread.id);
    if (existingDraft != null) {
      emit(state.copyWith(draft: existingDraft));
      return;
    }
    // Message-mode: a fresh reply defaults to the latest note's participants
    // ("reasonable assumption at that point in the thread") so an un-edited
    // reply sends to the right audience. Falls through to the private-default
    // logic when there are no notes yet.
    if (Thread.resolveSharingModel(state.links) == SharingModel.message) {
      final notes = state.notes.isNotEmpty
          ? state.notes
          : await Note.getForThread(state.thread.id);
      final audience = Thread.latestNoteAudience(notes);
      if (audience.isNotEmpty) {
        emit(state.copyWith(
          draft: state.draft.copyWith(
            accessContacts: Value({Base.actorId, ...audience}.toList()),
          ),
        ));
        return;
      }
    }
    await _defaultDraftToPrivateIfViewers();
  }

  /// No-op: viewers and public/private toggle removed in per-user priorities.
  Future<void> _defaultDraftToPrivateIfViewers() async {}

  void _loadNotes() {
    log.info('Getting notes for thread ${state.thread.id}');

    // Cancel the prior notes watch before subscribing again. Drift fires
    // every active stream on each table update, so a leaked subscription
    // with stale filter args briefly overwrites the latest notes list
    // during sync — producing a "full → 1 note → full" flash.
    _notesSubscription?.cancel();
    _notesSubscription =
        Note.watch(
          state.thread.id,
          // "Show archived items" shows active AND archived notes (null = no
          // archived filter); off shows active only.
          archived: state.showArchived ? null : false,
          draft: false,
          filter: state.filter.isNotEmpty ? state.filter : null,
          reactionFilter: state.reactionFilter.isNotEmpty
              ? state.reactionFilter
              : null,
          threadNoteId: state.threadNoteId,
        ).listen((notes) {
          // Sticky: any non-empty local emission means notes are present, so
          // drop the loading spinner immediately (before _initNotesLoaded's
          // pull resolves). Never flips back to false.
          emit(state.copyWith(
            notes: notes,
            notesLoaded: state.notesLoaded || notes.isNotEmpty,
          ));
        });
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
  StreamSubscription<List<(Reaction, int)>>? _reactionsSubscription;
  StreamSubscription<List<Note>>? _notesSubscription;

  /// Subscription to [LocalPreferencesBloc.stream] so the global
  /// archived-visibility flag drives this thread's `showArchived`.
  StreamSubscription<LocalPreferencesState>? _localPreferencesSubscription;

  /// Last `showAllPriorities` value seen, to ignore unrelated preference
  /// emissions that don't change archived visibility.
  bool _showArchivedFromPrefs = false;
}

class ThreadBlocProvider extends StatefulWidget {
  const ThreadBlocProvider({
    required this.threadId,
    this.thread,
    required this.child,
    super.key,
  });

  final ThreadId threadId;
  final Thread? thread;
  final Widget child;

  @override
  ThreadBlocProviderState createState() => ThreadBlocProviderState();
}

class ThreadBlocProviderState extends State<ThreadBlocProvider> {
  // When the thread is known up front (passed via [widget.thread] or already
  // sitting in PriorityBloc state), the bloc is built synchronously and
  // [_syncBloc] is non-null — the FutureBuilder is bypassed entirely so there
  // is no LoadingPage flash on the way into ThreadPage. Otherwise we fall
  // through to [_asyncBloc], which fetches via Thread.getOne.
  ThreadBloc? _syncBloc;
  Future<ThreadBloc>? _asyncBloc;
  bool _hasNavigatedAway = false;

  @override
  void initState() {
    super.initState();
    // Capture synchronously so the async branch and didUpdateWidget can seed
    // the bloc's archived visibility without touching context after an await.
    final localPreferences = context.read<LocalPreferencesBloc>();
    final initial = widget.thread ?? _cachedThread();
    if (initial != null) {
      _syncBloc = ThreadBloc(
        thread: initial,
        localPreferences: localPreferences,
      );
    } else {
      _asyncBloc = Thread.getOne(widget.threadId).then(
        (thread) =>
            ThreadBloc(thread: thread, localPreferences: localPreferences),
      );
    }
  }

  /// Returns the thread held in PriorityBloc when its id matches
  /// [widget.threadId]. Callers (ChangeCurrentThread, AddThread,
  /// AddThreadWithNote, AddThreadWithLink) call `priorityBloc.setThread`
  /// before routing, so the thread is already in memory by the time
  /// ThreadBlocProvider mounts.
  Thread? _cachedThread() {
    final cached = context.read<PriorityBloc?>()?.state.thread;
    if (cached != null && cached.id == widget.threadId) return cached;
    return null;
  }

  @override
  void didUpdateWidget(ThreadBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    final localPreferences = context.read<LocalPreferencesBloc>();
    if (widget.thread != null && widget.thread != oldWidget.thread) {
      _replaceWithSync(
        ThreadBloc(thread: widget.thread!, localPreferences: localPreferences),
      );
    } else if (widget.threadId != oldWidget.threadId) {
      final cached = _cachedThread();
      if (cached != null) {
        _replaceWithSync(
          ThreadBloc(thread: cached, localPreferences: localPreferences),
        );
      } else {
        _replaceWithAsync(
          Thread.getOne(widget.threadId).then(
            (thread) =>
                ThreadBloc(thread: thread, localPreferences: localPreferences),
          ),
        );
      }
    }
  }

  void _replaceWithSync(ThreadBloc next) {
    final oldSync = _syncBloc;
    final oldAsync = _asyncBloc;
    setState(() {
      _syncBloc = next;
      _asyncBloc = null;
    });
    oldSync?.close();
    oldAsync?.then((bloc) => bloc.close());
  }

  void _replaceWithAsync(Future<ThreadBloc> next) {
    final oldSync = _syncBloc;
    final oldAsync = _asyncBloc;
    setState(() {
      _syncBloc = null;
      _asyncBloc = next;
    });
    oldSync?.close();
    oldAsync?.then((bloc) => bloc.close());
  }

  @override
  void dispose() {
    _syncBloc?.close();
    _asyncBloc?.then((bloc) => bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = _syncBloc;
    if (sync != null) {
      return BlocProvider.value(value: sync, child: widget.child);
    }
    return FutureBuilder<ThreadBloc>(
      future: _asyncBloc,
      builder: (context, snapshot) {
        if (snapshot.hasError && !_hasNavigatedAway) {
          _hasNavigatedAway = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              context.showToast(
                message: 'This thread is no longer available.',
                isError: true,
              );
              context.run(ChangeCurrentThread(null));
            }
          });
          return const LoadingPage();
        }
        if (!snapshot.hasData) {
          return const LoadingPage();
        }
        return BlocProvider.value(value: snapshot.data!, child: widget.child);
      },
    );
  }
}
