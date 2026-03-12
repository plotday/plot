import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';
import 'package:plot/page/loading.dart';
import 'logging.dart';

part 'thread_state.dart';

class ThreadBloc extends Cubit<ThreadState> {
  ThreadBloc({required Thread thread})
    : _subscriptions = [],
      _tagsSubscription = null,
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

  void updateSearch(String search) {
    log.info('Updating search to "$search"');
    emit(state.copyWith(search: search, showAllNotes: false));
    _loadNotes();
  }

  void setShowAllNotes(bool showAll) {
    log.info('Setting showAllNotes to $showAll');
    emit(state.copyWith(showAllNotes: showAll));
    _loadNotes();
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _tagsSubscription?.cancel();
    _totalCountSubscription?.cancel();
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

  /// Sets the note being replied to. Pass null to clear.
  /// Clears editing state when replying (mutual exclusion).
  void setReplyTo(Note? note) {
    emit(state.copyWith(
      replyTo: note,
      clearReplyTo: note == null,
      clearEditingNote: note != null,
    ));
  }

  /// Sets the note being edited. Pass null to clear.
  /// Clears reply state when editing (mutual exclusion).
  void setEditingNote(Note? note) {
    emit(state.copyWith(
      editingNote: note,
      clearEditingNote: note == null,
      clearReplyTo: note != null,
    ));
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
    // Convert the draft to a non-draft
    note = note.copyWith(draft: false);

    // Show all notes after submitting so the new note is visible
    final showAll = state.search.isNotEmpty ? true : null;

    // Create fresh draft for the thread (in-memory only, will be saved when content is added)
    // Don't save empty draft - it will be saved when content is added via updateDraft()
    // Also clear replyTo and editing state
    emit(
      state.copyWith(
        draft: Note.draft(threadId: state.thread.id),
        clearReplyTo: true,
        clearEditingNote: true,
        showAllNotes: showAll,
      ),
    );

    // Async
    note.save();

    // Reload notes if we toggled showAllNotes
    if (showAll == true) _loadNotes();
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

    // Watch links for the thread
    _subscriptions.add(
      Link.watchForThread(state.thread.id).listen((links) {
        emit(state.copyWith(links: links));
      }),
    );

    // Watch tags for the thread
    _tagsSubscription?.cancel();
    _tagsSubscription = Note.watchTagsForActivity(state.thread.id).listen((
      tags,
    ) {
      // Calculate tag suggestions: common tags first, then all other tags
      const actionTags = [
        Tag.todo,
      ];

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

    _loadNotes();
  }

  /// Loads draft note from database for the current thread
  Future<void> _loadDraftNote() async {
    final existingDraft = await Note.getDraftByActivity(state.thread.id);
    if (existingDraft != null) {
      emit(state.copyWith(draft: existingDraft));
    }
  }

  void _loadNotes() {
    log.info('Getting notes for thread ${state.thread.id}');

    final isSearchFiltering = state.search.isNotEmpty && !state.showAllNotes;

    _subscriptions.add(
      Note.watch(
        state.thread.id,
        archived: state.showArchived,
        draft: false,
        filter: state.filter.isNotEmpty ? state.filter : null,
        search: isSearchFiltering ? state.search : null,
        threadNoteId: state.threadNoteId,
      ).listen((notes) {
        emit(state.copyWith(notes: notes));
      }),
    );

    // Watch total (unfiltered) note count when search is actively filtering
    _totalCountSubscription?.cancel();
    if (isSearchFiltering) {
      _totalCountSubscription = Note.watchCount(
        state.thread.id,
        archived: state.showArchived,
        threadNoteId: state.threadNoteId,
      ).listen((count) {
        emit(state.copyWith(totalNoteCount: count));
      });
    } else {
      _totalCountSubscription = null;
      emit(state.copyWith(totalNoteCount: 0));
    }
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
  StreamSubscription<int>? _totalCountSubscription;
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
  late Future<ThreadBloc> _bloc;

  @override
  void initState() {
    super.initState();
    _bloc =
        (widget.thread != null
                ? Future.value(widget.thread!)
                : Thread.getOne(widget.threadId))
            .then((thread) {
              return ThreadBloc(thread: thread);
            });
  }

  @override
  void didUpdateWidget(ThreadBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.thread != null && widget.thread != oldWidget.thread) {
      _bloc.then((bloc) async {
        final thread = widget.thread;
        if (thread == null) return;
        // Create new bloc with updated thread
        bloc.close();
        final newBloc = ThreadBloc(thread: thread);
        setState(() {
          _bloc = Future.value(newBloc);
        });
      });
    } else if (widget.threadId != oldWidget.threadId) {
      _bloc.then((bloc) async {
        bloc.close();
        final thread = await Thread.getOne(widget.threadId);
        final newBloc = ThreadBloc(thread: thread);
        setState(() {
          _bloc = Future.value(newBloc);
        });
      });
    }
  }

  @override
  void dispose() {
    _bloc.then((bloc) => bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _bloc,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LoadingPage();
        }
        return BlocProvider.value(value: snapshot.data!, child: widget.child);
      },
    );
  }
}
