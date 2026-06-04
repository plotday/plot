import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/analytics/tracker.dart';
import 'logging.dart';

part 'thread_state.dart';

class ThreadBloc extends Cubit<ThreadState> {
  ThreadBloc({required Thread thread})
    : _subscriptions = [],
      _tagsSubscription = null,
      _reactionsSubscription = null,
      super(ThreadState(thread: thread)) {
    _loadThread();
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));
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
    if (note.mentions != null && note.mentions!.isNotEmpty) {
      final newContacts = {...currentThread.contacts};
      bool changed = false;
      for (final mention in note.mentions!) {
        if (!mention.isTwist) {
          if (newContacts.add(mention.toUuid())) {
            changed = true;
          }
        }
      }

      if (changed) {
        final updatedThread = currentThread.copyWith(
          contacts: Value(newContacts.toList()),
        );
        // Save the thread to persist the contacts. This will trigger a
        // DB change and we update our local state too.
        await updatedThread.save();
        emit(state.copyWith(thread: updatedThread));
        currentThread = updatedThread;
      }
    }

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

    final cfg = links.isNotEmpty ? links.first.getTypeConfig() : null;
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
    final existingDraft = await Note.getDraftByActivity(state.thread.id);
    if (existingDraft != null) {
      emit(state.copyWith(draft: existingDraft));
    } else {
      await _defaultDraftToPrivateIfViewers();
    }
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
          archived: state.showArchived,
          draft: false,
          filter: state.filter.isNotEmpty ? state.filter : null,
          reactionFilter: state.reactionFilter.isNotEmpty
              ? state.reactionFilter
              : null,
          threadNoteId: state.threadNoteId,
        ).listen((notes) {
          emit(state.copyWith(notes: notes));
        });
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
  StreamSubscription<List<(Reaction, int)>>? _reactionsSubscription;
  StreamSubscription<List<Note>>? _notesSubscription;
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
    final initial = widget.thread ?? _cachedThread();
    if (initial != null) {
      _syncBloc = ThreadBloc(thread: initial);
    } else {
      _asyncBloc = Thread.getOne(
        widget.threadId,
      ).then((thread) => ThreadBloc(thread: thread));
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

    if (widget.thread != null && widget.thread != oldWidget.thread) {
      _replaceWithSync(ThreadBloc(thread: widget.thread!));
    } else if (widget.threadId != oldWidget.threadId) {
      final cached = _cachedThread();
      if (cached != null) {
        _replaceWithSync(ThreadBloc(thread: cached));
      } else {
        _replaceWithAsync(
          Thread.getOne(
            widget.threadId,
          ).then((thread) => ThreadBloc(thread: thread)),
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
