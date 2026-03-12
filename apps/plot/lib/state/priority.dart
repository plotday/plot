import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:drift/drift.dart' hide Column;

import 'package:plot/store/store.dart';
import 'package:plot/util/async.dart';
import 'package:plot/util/list.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/state/now.dart';
import 'package:plot/router.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority, Thread? thread})
    : _subscriptions = [],
      _threadSubscription = null,
      _agendaSubscription = null,
      _tagsSubscription = null,
      _draftModified = false,
      super(PriorityState(context: priority, thread: thread)) {
    _loadPriority();

    // Register callback to reload agenda when time changes (e.g., via TimeTravel)
    Time.setOnTimeChanged(() {
      log.fine('Time changed, reloading agenda to update time-dependent UI');
      _loadAgenda();
    });

    // Re-trigger demand-driven syncs after a full resync
    _subscriptions.add(Store.onFullResync.stream.listen((_) {
      log.fine('Full resync completed, reloading priority');
      _loadPriority();
    }));
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));

    // Reload agenda items with new archived filter
    _loadPriority();
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    emit(state.copyWith(filter: filter));

    // Reload agenda items with new filter
    _loadPriority();
  }

  void updateSearch(String search) {
    log.info('Updating search to "$search"');
    emit(state.copyWith(search: search));

    // Reset limits but preserve sync state - search filters local data only
    _agendaLimit = 50;
    _agendaLastRawRowCount = 0;
    _loadAgenda(triggerSync: false);

    _activityFeedLimit = 50;
    _activityFeedLastRawRowCount = 0;
    _loadActivityFeed(triggerSync: false);
  }

  /// Whether the draft has been modified by user actions (e.g. type toggle).
  /// Prevents _loadDraft from overwriting user-initiated changes.
  bool _draftModified;

  /// Remembered default priority for new threads (session-only).
  /// Set when the user selects a priority in NewThreadPage; cleared when
  /// the context priority changes via [setPriority].
  static Priority? _newThreadDefaultPriority;

  /// The remembered default priority for new threads, if any.
  Priority? get newThreadDefaultPriority => _newThreadDefaultPriority;

  /// Remember a priority as the default for new threads.
  void setNewThreadDefaultPriority(Priority priority) {
    _newThreadDefaultPriority = priority;
  }

  /// Timestamp of last reorder operation. Used to suppress agenda rebuilds
  /// briefly after a reorder so the optimistic update isn't overwritten.
  DateTime? _reorderTimestamp;

  /// The expected order value of the last reordered thread. Used to detect
  /// when the DB stream data has settled and includes the reorder, so we
  /// can safely transition from optimistic reorderViewItems to _makeAgenda.
  (ThreadId, double)? _pendingReorderOrder;

  /// Timestamp of last optimistic thread update. Used to suppress agenda
  /// rebuilds briefly so the optimistic state isn't overwritten by stale
  /// stream notifications (which may arrive with partial data, e.g. thread
  /// saved but schedule not yet saved).
  DateTime? _optimisticTimestamp;

  /// Optimistic reorder: caches the moved agendaViewItems so the UI
  /// doesn't re-derive them (which can produce different item counts).
  void moveAgendaItem(int viewOldIndex, int viewNewIndex,
      {AgendaItem? updatedItem}) {
    if (viewOldIndex == viewNewIndex) return;

    _reorderTimestamp = DateTime.now();
    final viewItems = List<AgendaItem>.from(state.agendaViewItems);

    // The page strips the leading "Now" header from agendaViewItems before
    // passing items to InfiniteList, so indices from onReorder are relative
    // to the Now-stripped list. Adjust to agendaViewItems indices.
    final nowOffset = (viewItems.isNotEmpty &&
            viewItems.first is AgendaHeaderItem &&
            (viewItems.first as AgendaHeaderItem).now)
        ? 1
        : 0;
    final adjOld = viewOldIndex + nowOffset;
    final adjNew = viewNewIndex + nowOffset;

    final item = viewItems.removeAt(adjOld);
    viewItems.insert(adjNew, updatedItem ?? item);

    // Record the expected order so the stream listener can detect when
    // the DB data has settled and safely transition from the optimistic
    // reorderViewItems to the derived _makeAgenda result.
    final movedItem = viewItems[adjNew];
    if (movedItem is AgendaThreadItem) {
      _pendingReorderOrder = (movedItem.thread.id, movedItem.thread.order.value);
    }

    log.info(
      '[moveAgendaItem] old=$viewOldIndex new=$viewNewIndex '
      'adjOld=$adjOld adjNew=$adjNew nowOffset=$nowOffset '
      'viewItems=${viewItems.length} emitting reorderViewItems '
      'pendingOrder=${_pendingReorderOrder?.$2}',
    );
    emit(state.copyWith(reorderViewItems: Value(viewItems)));
    log.info('[moveAgendaItem] emit returned');

    // Cancel and restart the agenda subscription to flush any stale events
    // sitting in the debounce pipeline. The fresh subscription will only
    // produce events reflecting the post-reorder DB state.
    _loadAgenda(triggerSync: false);
  }

  Future<void> fetchMoreAgendaItems(int first, int count) async {
    final needed = first + count;
    if (needed > _agendaLimit) {
      _agendaLimit = needed;
      _agendaHorizonDays += 90;
      _loadAgenda(triggerSync: !_agendaSyncNoMore);
    } else if (!state.agendaDoneEnd) {
      // JOIN multiplication: need more raw rows to get enough unique threads
      _agendaLimit += 50;
      _agendaHorizonDays += 90;
      _loadAgenda(triggerSync: !_agendaSyncNoMore);
    }
    // Wait for sync so InfiniteList's _fetching stays true until data arrives
    final future = _agendaSyncFuture;
    if (future != null) {
      try { await future; } catch (_) {}
    }
  }

  @override
  Future<void> close() {
    // Unregister time change callback
    Time.setOnTimeChanged(null);

    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _threadSubscription?.cancel();
    _agendaSubscription?.cancel();
    _activityFeedSubscription?.cancel();
    _tagsSubscription?.cancel();
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  /// Optimistically remove a thread from the agenda for instant UI feedback.
  /// The stream-based update will confirm the same state when it catches up.
  /// Keeps link schedule instances so they remain at their scheduled times.
  void optimisticallyRemoveThread(ThreadId id) {
    _optimisticTimestamp = DateTime.now();
    final updatedItems = state.agendaItems
        .where((item) => item.when(
              header: (_) => true,
              activity: (a) =>
                  a.thread.id != id || a.thread.isLinkScheduleInstance,
            ))
        .toList();
    emit(state.copyWith(agendaItems: updatedItems));
  }

  /// Optimistically update a thread in the agenda for instant UI feedback.
  /// The stream-based update will confirm the same state when it catches up.
  void optimisticallyUpdateThread(Thread updatedThread) {
    if (updatedThread.draft) return;
    _optimisticTimestamp = DateTime.now();

    final foundInAgenda = state.agendaItems.any((item) => item.when(
      header: (_) => false,
      activity: (a) => a.thread.id == updatedThread.id,
    ));

    List<AgendaItem> updatedAgendaItems;
    if (foundInAgenda) {
      // Thread is in agenda — check if it should be removed or updated.
      final shouldRemove = !updatedThread.todo &&
          updatedThread.at == null &&
          updatedThread.on == null;
      if (shouldRemove) {
        // Thread was only in agenda as a todo — remove it
        updatedAgendaItems = state.agendaItems
            .where((item) => item.when(
                  header: (_) => true,
                  activity: (a) => a.thread.id != updatedThread.id,
                ))
            .toList();
      } else {
        // In-place replacement (still belongs in agenda)
        updatedAgendaItems = state.agendaItems.map((item) {
          return item.when(
            header: (_) => item,
            activity: (a) => a.thread.id == updatedThread.id
                ? AgendaThreadItem(updatedThread, now: a.now)
                : item,
          );
        }).toList();
      }
    } else if (updatedThread.todo) {
      // Thread becoming a todo but not in agenda yet — insert it after
      // the last existing todo in today's section.
      updatedAgendaItems = List<AgendaItem>.from(state.agendaItems);
      final today = Date.today();
      int insertIndex = -1;
      bool inTodaySection = false;
      for (int i = 0; i < updatedAgendaItems.length; i++) {
        final item = updatedAgendaItems[i];
        if (item is AgendaHeaderItem && item.date != null) {
          if (!item.date!.isAfter(today)) {
            inTodaySection = true;
            if (insertIndex == -1) insertIndex = i + 1;
          } else if (inTodaySection) {
            break; // Passed today's section
          }
        }
        if (inTodaySection &&
            item is AgendaThreadItem &&
            item.thread.todo &&
            !item.thread.isLinkScheduleInstance) {
          insertIndex = i + 1;
        }
      }
      if (insertIndex == -1) {
        // No today header found — insert after the first header
        insertIndex = updatedAgendaItems.isNotEmpty ? 1 : 0;
      }
      updatedAgendaItems.insert(
        insertIndex,
        AgendaThreadItem(updatedThread),
      );
    } else {
      updatedAgendaItems = state.agendaItems;
    }

    final updatedFeedItems = state.activityFeedItems.map((item) {
      return item.when(
        header: (_) => item,
        activity: (a) => a.thread.id == updatedThread.id
            ? AgendaThreadItem(updatedThread)
            : item,
      );
    }).toList();

    emit(state.copyWith(
      thread: state.thread?.id == updatedThread.id
          ? Value(updatedThread)
          : const Value.absent(),
      agendaItems: updatedAgendaItems,
      activityFeedItems: updatedFeedItems,
    ));
  }

  Future<void> setPriority(Priority newPriority) async {
    if (state.context.id == newPriority.id) return;
    _newThreadDefaultPriority = null;

    log.info(
      'Updating priority from ${state.context.title} to ${newPriority.title}',
    );

    // Cancel existing subscriptions
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _threadSubscription?.cancel();
    _watchingThreadId = null;
    _agendaSubscription?.cancel();
    _activityFeedSubscription?.cancel();
    _tagsSubscription?.cancel();

    // Load or create draft for new priority
    // Load the latest draft regardless of archived status, so we can reuse it
    log.info(
      '[setPriority] Switching to priority: ${newPriority.id} (${newPriority.title})',
    );
    final drafts = await Thread.get(
      priorityId: newPriority.id,
      draft: true,
      archived: null, // Get both archived and non-archived
    );
    // Sort by updatedAt descending to get the latest
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final existingDraft = drafts.firstOrNull;

    Thread newDraft;
    if (existingDraft != null) {
      newDraft = existingDraft;
      log.info(
        '[setPriority] Loaded existing draft: id=${existingDraft.id}, priority=${existingDraft.priority.id} (${existingDraft.priority.title}), archived=${existingDraft.archivedAt != null}',
      );
    } else {
      newDraft = Thread(priority: newPriority, draft: true);
      log.info(
        '[setPriority] Creating new draft for priority: id=${newDraft.id}, priority=${newPriority.id} (${newPriority.title})',
      );
    }

    // Load draft note for the draft thread (also load archived notes)
    // We get all draft notes (archived or not) and take the latest one
    final draftNotes =
        await (Store.get.select(Store.get.notes)
              ..where((tbl) => tbl.threadId.equalsValue(newDraft.id))
              ..where((tbl) => tbl.draft.equals(true))
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
              ..limit(1))
            .get();
    Note? draftNote = draftNotes.isEmpty
        ? null
        : Note(
            id: draftNotes.first.id,
            threadId: draftNotes.first.threadId,
            authorId: draftNotes.first.authorId,
            draft: draftNotes.first.draft,
            private: draftNotes.first.private,
            content: draftNotes.first.content,
            actions: draftNotes.first.actions,
            mentions: draftNotes.first.mentions,
            createdAt: draftNotes.first.createdAt,
            sourceCreatedAt: draftNotes.first.sourceCreatedAt,
            updatedAt: draftNotes.first.updatedAt,
            archivedAt: draftNotes.first.archivedAt,
          );

    if (draftNote != null) {
      log.info(
        '[setPriority] Loaded draft note: id=${draftNote.id}, threadId=${draftNote.threadId}, content="${draftNote.content?.substring(0, draftNote.content!.length > 50 ? 50 : draftNote.content!.length) ?? ''}", archived=${draftNote.archivedAt != null}',
      );
    } else {
      // Create draft note in memory (will be saved when content is added)
      draftNote = Note.draft(threadId: newDraft.id);
      log.info(
        '[setPriority] Created draft note in state: id=${draftNote.id}, threadId=${newDraft.id}',
      );
    }

    // Set target priority without changing context (delay context update until data loads)
    emit(
      state.copyWith(
        targetPriority: Value(newPriority),
        draft: newDraft,
        draftNote: draftNote,
      ),
    );

    // Reload with new priority
    _loadPriority();
  }

  /// Which list the user last selected a thread from.
  /// Used by Previous/Next Thread commands to determine navigation list.
  ThreadListSource? threadListSource;

  void setThread(Thread? thread, {ThreadListSource? source}) {
    if (source != null) {
      threadListSource = source;
    }
    if (thread == null) {
      threadListSource = null;
    }
    if (state.thread == thread) {
      return;
    }
    emit(state.copyWith(thread: Value(thread)));

    // Manage thread subscription
    if (thread != null) {
      _loadThread(thread);
    } else {
      _threadSubscription?.cancel();
      _threadSubscription = null;
      _watchingThreadId = null;
    }
  }

  /// Resets the draft to a new empty thread for the current priority.
  /// This should be called when navigating to create a new thread.
  /// Reuses the existing draft ID to minimize archived drafts.
  void resetDraft() {
    final clearedDraft = state.draft.copyWith(
      title: const Value(null),
      at: const Value(null),
      on: const Value(null),
      duration: const Value(null),
      preview: const Value(null),
    );
    emit(state.copyWith(draft: clearedDraft));
  }

  /// Updates the draft thread and optionally the note, saving both to the database.
  /// This provides instant UI updates while persisting changes.
  ///
  /// [thread] - Required thread to update
  /// [note] - Optional note to save (must be a draft note for this thread)
  Future<void> updateDraft(Thread thread, {Note? note}) async {
    if (thread.id != state.draft.id) {
      log.warning(
        '[updateDraft] Attempted to update draft with mismatched thread ID: ${thread.id} (expected ${state.draft.id})',
      );
      return;
    }

    final threadChanged = thread != state.draft;
    _draftModified = true;

    emit(state.copyWith(draft: thread));

    if (note != null) {
      if (note.id == state.draftNote.id) {
        emit(state.copyWith(draftNote: note));
      } else {
        log.warning(
          "[updateDraft] Note ID does not match draft note ID: ${note.id} (expected ${state.draftNote.id})",
        );
      }
    }

    if (threadChanged) {
      await thread.save();
    }
    if (note != null && note != state.draftNote) {
      log.info(
        '[updateDraft] Saving note: id=${note.id}, threadId=${note.threadId}, content length=${note.content?.length ?? 0}',
      );
      await note.save(pushToRemote: false);
    }
  }

  /// Gets an agenda item relative to the current thread by offset.
  ///
  /// [offset] - Positive for forward, negative for backward (e.g., +1 = next, -1 = previous)
  /// [includeThread] - Include AgendaThreadItem in navigation (default: true)
  /// [includePriority] - Include PriorityAgendaItem in navigation (default: false)
  /// [includeDate] - Include DateAgendaItem in navigation (default: false)
  ///
  /// Returns the agenda item at the offset position. Boundary behavior:
  /// - If offset would go out of bounds but items exist in that direction, returns the furthest item
  /// - If already at the furthest item and trying to move further, returns null
  /// - If no current thread is set, navigates relative to the "now" header position
  AgendaItem? getAgendaItem(
    int offset, {
    bool includeThread = true,
    bool includePriority = false,
    bool includeDate = false,
  }) {
    int currentIndex = -1;

    if (state.thread == null) {
      // No thread selected: start from the "now" header.
      // There can be two now headers; use the last one (labeled "Now").
      for (int i = 0; i < state.agendaItems.length; i++) {
        final item = state.agendaItems[i];
        if (item is AgendaHeaderItem && item.now) {
          currentIndex = i;
        }
      }
      if (currentIndex == -1) {
        currentIndex = 0;
      }
    } else {
      // Thread selected: find its index
      for (int i = 0; i < state.agendaItems.length; i++) {
        final thread = state.agendaItems[i].when<Thread?>(
          header: (header) => null,
          activity: (agendaItem) => agendaItem.thread,
        );
        if (thread?.id == state.thread!.id) {
          currentIndex = i;
          break;
        }
      }
      if (currentIndex == -1) {
        // Thread not in filtered list (e.g. search active) - fall back to
        // "no thread" behavior: start from the "Now" header
        for (int i = 0; i < state.agendaItems.length; i++) {
          final item = state.agendaItems[i];
          if (item is AgendaHeaderItem && item.now) {
            currentIndex = i;
          }
        }
        if (currentIndex == -1) {
          currentIndex = 0;
        }
      }
    }

    // Helper to check if an item matches the filter criteria
    bool matchesFilter(AgendaItem item) {
      return item.when<bool>(
        activity: (agendaItem) => includeThread,
        header: (header) =>
            (header.date != null && includeDate) ||
            (header.date == null && includePriority),
      );
    }

    // Find the furthest valid item in the direction of offset
    final direction = offset > 0 ? 1 : -1;
    int targetIndex = currentIndex;
    int moved = 0;
    int? lastValidIndex;

    while (moved != offset) {
      final nextIndex = targetIndex + direction;

      // Check if we've reached the bounds
      if (nextIndex < 0 || nextIndex >= state.agendaItems.length) {
        // If we found at least one valid item, return it
        if (lastValidIndex != null && lastValidIndex != currentIndex) {
          return state.agendaItems[lastValidIndex];
        }
        // If we're already at the boundary and trying to move further, return null
        return null;
      }

      targetIndex = nextIndex;

      // Check if this item matches our filter
      if (matchesFilter(state.agendaItems[targetIndex])) {
        lastValidIndex = targetIndex;
        moved += direction;
      }
    }

    // Successfully moved the full offset
    return state.agendaItems[targetIndex];
  }

  /// Gets an activity feed item relative to the current thread by offset.
  /// Mirrors [getAgendaItem] but operates on [state.activityFeedItems].
  AgendaItem? getActivityFeedItem(int offset) {
    final items = state.activityFeedItems;
    if (items.isEmpty) return null;

    int currentIndex = -1;

    if (state.thread == null) {
      // No thread selected: start from index 0 (most recent)
      currentIndex = 0;
      // If first item is a header, start before it so offset=1 finds first thread
      if (items.first is AgendaHeaderItem) {
        currentIndex = -1;
      }
    } else {
      // Thread selected: find its index
      for (int i = 0; i < items.length; i++) {
        final thread = items[i].when<Thread?>(
          header: (_) => null,
          activity: (a) => a.thread,
        );
        if (thread?.id == state.thread!.id) {
          currentIndex = i;
          break;
        }
      }
      if (currentIndex == -1) {
        // Thread not in filtered list (e.g. search active) - fall back to
        // "no thread" behavior: start from most recent
        currentIndex = 0;
        if (items.isNotEmpty && items.first is AgendaHeaderItem) {
          currentIndex = -1;
        }
      }
    }

    // Navigate through items, skipping headers
    final direction = offset > 0 ? 1 : -1;
    int targetIndex = currentIndex;
    int moved = 0;
    int? lastValidIndex;

    while (moved != offset) {
      final nextIndex = targetIndex + direction;

      if (nextIndex < 0 || nextIndex >= items.length) {
        if (lastValidIndex != null && lastValidIndex != currentIndex) {
          return items[lastValidIndex];
        }
        return null;
      }

      targetIndex = nextIndex;

      // Only navigate threads (skip headers)
      if (items[targetIndex] is AgendaThreadItem) {
        lastValidIndex = targetIndex;
        moved += direction;
      }
    }

    return items[targetIndex];
  }

  /// Determines which list to navigate based on prior context.
  /// If the user previously selected from a list, use that.
  /// Otherwise, prefer agenda if the current thread is in it.
  ThreadListSource resolveThreadListSource() {
    if (threadListSource != null) return threadListSource!;
    // Check if current thread is in the agenda
    if (state.thread != null) {
      final inAgenda = state.agendaItems.any((item) => item.when(
        header: (_) => false,
        activity: (a) => a.thread.id == state.thread!.id,
      ));
      if (inAgenda) return ThreadListSource.agenda;
    }
    return ThreadListSource.activityFeed;
  }

  void _loadPriority() {
    final priorityToLoad = state.targetPriority ?? state.context;

    // Load draft from database if this is initial load
    if (state.targetPriority == null) {
      _loadDraft(priorityToLoad);
    }

    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.add(
      Priority.watchOne(priorityToLoad.id).listen((priority) {
        log.fine('Priority updated');
        // Only update context if not switching priorities (targetPriority is null)
        if (state.targetPriority == null) {
          emit(state.copyWith(context: priority));
        }
      }),
    );
    if (state.thread != null) {
      _loadThread(state.thread!);
    }

    // Watch tags for the priority
    _tagsSubscription?.cancel();
    _tagsSubscription = Thread.watchTagsForPriority(priorityToLoad.path)
        .listen((tags) {
          // Common tags (excluding action tags)
          final commonTagsFiltered = tags
              .where((tagData) => tagData.$1.type != .compute)
              .map((tagData) => tagData.$1)
              .toList();

          // All tags excluding action tags and common tags
          final commonTagSet = commonTagsFiltered.toSet();
          final otherTags = Tag.getAll(onlyAddable: true)
              .where(
                (tag) => tag.type != .compute && !commonTagSet.contains(tag),
              )
              .toList();

          // Combine: common tags first, then other tags
          final tagSuggestions = [...commonTagsFiltered, ...otherTags];

          emit(state.copyWith(tags: tags, tagSuggestions: tagSuggestions));
        });

    // Watch twists for the priority (including ancestors)
    _subscriptions.add(
      PriorityTwist.watch(priority: priorityToLoad).listen((twists) {
        log.fine('Priority twists updated: ${twists.length} twists');
        emit(state.copyWith(twists: twists));
      }),
    );

    // Watch actors for the priority (users and contacts for mentions)
    _subscriptions.add(
      Actor.watch(
        priorityId: priorityToLoad.id,
        types: [ActorType.user, ActorType.contact],
      ).listen((actors) {
        log.fine('Priority actors updated: ${actors.length} actors');
        emit(state.copyWith(actors: actors));
      }),
    );

    _agendaLimit = 50;
    _agendaHorizonDays = 90;
    _agendaSyncNoMore = false;
    _agendaLastRawRowCount = 0;
    _loadAgenda();

    _activityFeedLimit = 50;
    _activityFeedSyncNoMore = false;
    _activityFeedLastRawRowCount = 0;
    _loadActivityFeed();
  }

  ThreadId? _watchingThreadId;

  void _loadThread(Thread thread) {
    // Skip if already watching the same thread
    if (_watchingThreadId == thread.id) return;

    // Cancel existing thread subscription
    _threadSubscription?.cancel();
    _watchingThreadId = thread.id;

    // Watch the thread
    _threadSubscription = Thread.watchOne(thread.id).listen((
      watchedThread,
    ) {
      emit(state.copyWith(thread: Value(watchedThread)));
    });
  }

  /// Loads draft from database for the given priority.
  /// Skips if the draft has already been modified by user actions to avoid
  /// overwriting user-initiated changes with stale DB state.
  Future<void> _loadDraft(Priority priority) async {
    final existingDraft = await Thread.getDraftByPriority(priority.id);
    if (existingDraft != null) {
      if (_draftModified) return;
      emit(state.copyWith(draft: existingDraft));
    }
  }

  /// Adds a thread by converting the current draft to a non-draft.
  /// Creates a fresh draft for the priority afterward.
  /// If note is provided, converts it from draft to published and asynchronously generates a title.
  /// Returns the saved thread.
  Future<Thread> add(Thread thread, {Note? note, bool assignNote = true}) async {
    // Convert the draft to a non-draft
    final savedThread = thread.copyWith(draft: false);
    await savedThread.save();

    // Convert draft note to published if provided
    if (note != null &&
        note.content != null &&
        note.content!.trim().isNotEmpty) {
      var publishedNote = note.copyWith(
        threadId: savedThread.id,
        draft: false,
      );

      // If the thread is a task and note assignment is requested, assign the note to the current user
      if (savedThread.todo && assignNote) {
        publishedNote = publishedNote.assignTo(Base.actorId);
      }

      await publishedNote.save();

      // Asynchronously generate a better title using AI (fire and forget)
      // The thread is already saved with a fallback title, so this update
      // will happen in the background without blocking the UI
      savedThread
          .generateTitle(note.content!)
          .then((title) async {
            if (title != savedThread.title) {
              await savedThread.copyWith(title: Value(title)).save();
            }
          })
          .catchError((Object e) {
            // Error already logged by generateTitle(), just ignore here
          });
    }

    // Create fresh draft for the priority (use remembered default if set)
    final newDraft = Thread(priority: _newThreadDefaultPriority ?? thread.priority, draft: true);
    emit(
      state.copyWith(
        draft: newDraft,
        draftNote: Note.draft(threadId: newDraft.id),
      ),
    );

    return savedThread;
  }

  void _loadAgenda({bool triggerSync = true}) {
    final priorityToLoad = state.targetPriority ?? state.context;

    log.fine('Loading agenda for priority ${priorityToLoad.id}');
    _agendaSubscription?.cancel();

    _agendaSubscription = Thread.watch(
      priorityPath: priorityToLoad.path,
      archived: state.showArchived,
      filter: state.filter.isNotEmpty ? state.filter : null,
      search: state.search.isNotEmpty ? state.search : null,
      order: ThreadOrder.sorted,
      limit: _agendaLimit,
      includeUnscheduled: false,
      range: CustomBoundedDateRange(
        Date.today(),
        Date.today().addDays(_agendaHorizonDays),
      ),
    ).transform(
      ExpiringStreamTransformer((result) {
        // Re-evaluate every minute on the minute to update time-dependent UI
        final now = Time.now();
        final expiry = now.add(
          Duration(
            seconds: 60 - now.second,
            milliseconds: -now.millisecond,
          ),
        );
        return ExpiringResult(value: result, expiry: expiry);
      }),
    ).debounceTime(const Duration(milliseconds: 100)).listen((result) {
      final (:threads, :rawRowCount) = result;
      _agendaLastRawRowCount = rawRowCount;

      // After a reorder or optimistic update, suppress agenda rebuilds
      // briefly so the optimistic state stays visible until all DB writes
      // (thread, schedule, tags) are complete and the stream settles.
      final now = DateTime.now();

      // Time-based suppression for optimistic thread updates (non-reorder).
      final suppressOptimistic = _optimisticTimestamp != null &&
          now.difference(_optimisticTimestamp!) <
              const Duration(milliseconds: 500);

      // Data-driven suppression for reorders: keep reorderViewItems until
      // the stream data includes the reordered thread at its expected order.
      // Stale events are prevented by cancelling and restarting the
      // subscription in moveAgendaItem, so no time-based fallback is needed.
      final bool suppressReorder;
      if (_pendingReorderOrder != null) {
        final (threadId, expectedOrder) = _pendingReorderOrder!;
        final settled = threads.any(
          (t) => t.id == threadId && t.order.value == expectedOrder,
        );
        suppressReorder = !settled;
        if (settled) {
          _pendingReorderOrder = null;
          _reorderTimestamp = null;
        }
      } else {
        suppressReorder = false;
      }

      final suppressRebuild = suppressReorder || suppressOptimistic;

      log.fine(
        '[_loadAgenda] stream fired: suppress=$suppressRebuild '
        '(reorder=$suppressReorder optimistic=$suppressOptimistic) '
        'reorderAge=${_reorderTimestamp != null ? now.difference(_reorderTimestamp!).inMilliseconds : "null"}ms '
        'hasReorderViewItems=${state.reorderViewItems != null} '
        'pendingOrder=${_pendingReorderOrder?.$2}',
      );

      final agendaItems = suppressRebuild
          ? state.agendaItems
          : PriorityState._makeAgenda(threads, context: priorityToLoad, horizonDays: _agendaHorizonDays);

      emit(
        state.copyWith(
          // If switching priorities, update context atomically with new agenda
          context: state.targetPriority,
          agendaItems: agendaItems,
          agendaDoneEnd: rawRowCount < _agendaLimit && (state.search.isNotEmpty || _agendaSyncNoMore),
          // Keep reorderViewItems during suppress, clear when real data arrives
          reorderViewItems: suppressRebuild
              ? const Value.absent()
              : const Value(null),
          // Clear targetPriority after switching
          targetPriority: state.targetPriority != null
              ? const Value(null)
              : const Value.absent(),
        ),
      );
    });

    if (triggerSync) {
      _agendaSyncFuture = _triggerAgendaSync(priorityToLoad);
    }
  }

  bool get _effectiveShowArchived =>
      state.showArchived || state.filter.contains(Tag.archived);

  Future<void> _triggerAgendaSync(Priority priorityToLoad) async {
    final archived = _effectiveShowArchived;
    await Thread.pullAgenda(
      priorityToLoad.id, priorityToLoad.path,
      archived: archived,
    );
    final path = priorityToLoad.path.value;
    final suffix = archived ? '_archived' : '';
    final entityName = 'agenda:$path$suffix';
    final syncState = await (Store.get.select(Store.get.syncStates)
      ..where((row) => row.entity.equals(entityName)))
      .getSingleOrNull();
    // If no sync state exists after pulling, the pull was satisfied by an
    // ancestor's noMore flag — treat this entity as fully synced too.
    _agendaSyncNoMore = syncState?.noMore ?? true;
    if (_agendaSyncNoMore && _agendaLastRawRowCount < _agendaLimit) {
      emit(state.copyWith(agendaDoneEnd: true));
    }
  }

  void _loadActivityFeed({bool triggerSync = true}) {
    final priorityToLoad = state.targetPriority ?? state.context;
    _activityFeedSubscription?.cancel();
    _activityFeedSubscription = Thread.watch(
      order: ThreadOrder.reverse,
      priorityPath: priorityToLoad.path,
      archived: state.showArchived,
      filter: state.filter.isNotEmpty ? state.filter : null,
      search: state.search.isNotEmpty ? state.search : null,
      limit: _activityFeedLimit,
    ).listen((result) {
      final (:threads, :rawRowCount) = result;
      _activityFeedLastRawRowCount = rawRowCount;

      // Suppress rebuilds briefly after optimistic updates so stale
      // intermediate stream events (e.g. thread saved but schedule not yet)
      // don't overwrite the optimistic state.
      final suppressOptimistic = _optimisticTimestamp != null &&
          DateTime.now().difference(_optimisticTimestamp!) <
              const Duration(milliseconds: 500);
      if (suppressOptimistic) return;

      // doneEnd when sync is complete AND either:
      // - raw rows are below limit (no more data), OR
      // - thread count hasn't grown despite limit increase (JOIN multiplication)
      final threadCountStalled = _activityFeedSyncNoMore &&
          rawRowCount >= _activityFeedLimit &&
          threads.length == state.activityFeedItems
              .whereType<AgendaThreadItem>()
              .length &&
          threads.length < _activityFeedLimit;
      final isSearching = state.search.isNotEmpty;
      final doneEnd = (rawRowCount < _activityFeedLimit && (isSearching || _activityFeedSyncNoMore)) ||
          threadCountStalled;
      final items = <AgendaItem>[];
      String? currentBucket;
      for (final thread in threads) {
        final (label, bucketDate) = PriorityState._timeAgoBucket(
          thread.activityAt.toDate(),
        );
        if (label != currentBucket) {
          currentBucket = label;
          if (label != 'Today') {
            items.add(AgendaHeaderItem(text: label, date: bucketDate));
          }
        }
        items.add(AgendaThreadItem(thread));
      }
      emit(state.copyWith(
        activityFeedItems: items,
        activityFeedDoneEnd: doneEnd,
      ));
    });

    if (triggerSync) {
      _activityFeedSyncFuture = _triggerActivityFeedSync(priorityToLoad);
    }
  }

  Future<void> _triggerActivityFeedSync(Priority priorityToLoad) async {
    final archived = _effectiveShowArchived;
    await Thread.pullActivityFeed(
      priorityToLoad.id, priorityToLoad.path,
      archived: archived,
    );
    final path = priorityToLoad.path.value;
    final suffix = archived ? '_archived' : '';
    final entityName = 'activity-feed:$path$suffix';
    final syncState = await (Store.get.select(Store.get.syncStates)
      ..where((row) => row.entity.equals(entityName)))
      .getSingleOrNull();
    // If no sync state exists after pulling, the pull was satisfied by an
    // ancestor's noMore flag — treat this entity as fully synced too.
    _activityFeedSyncNoMore = syncState?.noMore ?? true;
    if (_activityFeedSyncNoMore && _activityFeedLastRawRowCount < _activityFeedLimit) {
      emit(state.copyWith(activityFeedDoneEnd: true));
    }
  }

  Future<void> fetchMoreActivityFeedItems(int first, int count) async {
    final needed = first + count;
    if (needed > _activityFeedLimit) {
      _activityFeedLimit = needed;
      _loadActivityFeed(triggerSync: !_activityFeedSyncNoMore && state.search.isEmpty);
    } else if (!state.activityFeedDoneEnd) {
      // JOIN multiplication: need more raw rows to get enough unique threads
      _activityFeedLimit += 50;
      _loadActivityFeed(triggerSync: !_activityFeedSyncNoMore && state.search.isEmpty);
    }
    // Wait for sync so InfiniteList's _fetching stays true until data arrives
    final future = _activityFeedSyncFuture;
    if (future != null) {
      try { await future; } catch (_) {}
    }
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _threadSubscription;
  StreamSubscription<void>? _agendaSubscription;
  StreamSubscription<void>? _activityFeedSubscription;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
  int _agendaLimit = 50;
  int _agendaHorizonDays = 90;
  int _activityFeedLimit = 50;
  bool _agendaSyncNoMore = false;
  bool _activityFeedSyncNoMore = false;
  Future<void>? _agendaSyncFuture;
  Future<void>? _activityFeedSyncFuture;
  int _agendaLastRawRowCount = 0;
  int _activityFeedLastRawRowCount = 0;
}

/// Provides the [ThreadListSource] to descendant widgets so that
/// [ChangeCurrentThread] can record which list a thread was selected from.
class ThreadListSourceProvider extends InheritedWidget {
  const ThreadListSourceProvider({
    required this.source,
    required super.child,
    super.key,
  });

  final ThreadListSource source;

  static ThreadListSource? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ThreadListSourceProvider>()
        ?.source;
  }

  @override
  bool updateShouldNotify(ThreadListSourceProvider old) =>
      source != old.source;
}

class PriorityBlocProvider extends StatefulWidget {
  const PriorityBlocProvider({
    this.priorityId,
    this.threadId,
    this.priority,
    required this.child,
    super.key,
  });

  final PriorityId? priorityId;
  final ThreadId? threadId;
  final Priority? priority;
  final Widget child;

  @override
  PriorityBlocProviderState createState() => PriorityBlocProviderState();
}

/// Result of priority loading (success or error)
class _LoadResult {
  final PriorityBloc? bloc;
  final String? error;
  final bool isFallback;

  _LoadResult.success(this.bloc, {this.isFallback = false}) : error = null;
  _LoadResult.error(this.error) : bloc = null, isFallback = false;
}

class PriorityBlocProviderState extends State<PriorityBlocProvider> {
  late Future<_LoadResult> _bloc;

  @override
  void initState() {
    super.initState();
    _bloc = _loadPriorityWithFallback();
  }

  Future<_LoadResult> _loadPriorityWithFallback() async {
    try {
      // Level 1: Try to load requested priority
      final priority = await (widget.priority != null
          ? Future.value(widget.priority!)
          : widget.priorityId != null
          ? Priority.getOne(widget.priorityId!)
          : widget.threadId != null
          ? Thread.getOne(
              widget.threadId!,
            ).then((thread) => thread.priority)
          : Future<Priority>.error(
              'Either priorityId or threadId must be provided',
            ));

      // Success - update theme and create bloc
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<NowBloc>().setContext(priority);
        }
      });

      return _LoadResult.success(PriorityBloc(priority: priority));
    } catch (e, stackTrace) {
      // Level 1 failed - log and try fallback
      log.warning(
        'Failed to load requested priority (${widget.priorityId ?? widget.threadId}): $e',
        e,
        stackTrace,
      );

      try {
        // Level 2: Fallback to default priority
        log.info('Attempting to load default priority as fallback');
        final hasDefault = await Priority.hasDefault();

        if (!hasDefault) {
          return _LoadResult.error('No priorities exist in the database');
        }

        final defaultPriority = await Priority.getDefault();

        // Update theme with fallback priority
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            context.read<NowBloc>().setContext(defaultPriority);
          }
        });

        return _LoadResult.success(
          PriorityBloc(priority: defaultPriority),
          isFallback: true,
        );
      } catch (fallbackError, fallbackStack) {
        // Level 2 also failed - return error
        log.severe(
          'Failed to load fallback priority: $fallbackError',
          fallbackError,
          fallbackStack,
        );
        return _LoadResult.error(
          'Could not load priority: ${fallbackError.toString()}',
        );
      }
    }
  }

  @override
  void didUpdateWidget(PriorityBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.priority != null && widget.priority != oldWidget.priority) {
      _bloc.then((result) {
        final priority = widget.priority;
        if (priority == null || result.bloc == null) return;
        result.bloc!.setPriority(priority);
        // Theme will be updated when new agenda loads (in _loadAgenda)
      });
    } else if (widget.priorityId != null &&
        widget.priorityId != oldWidget.priorityId) {
      _bloc.then((result) async {
        if (result.bloc == null) return;
        final priority = await Priority.getOne(widget.priorityId!);
        result.bloc!.setPriority(priority);
        // Theme will be updated when new agenda loads (in _loadAgenda)
      });
    }
  }

  @override
  void dispose() {
    _bloc.then((result) => result.bloc?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LoadResult>(
      future: _bloc,
      builder: (context, snapshot) {
        // Loading state
        if (!snapshot.hasData) {
          return const LoadingPage();
        }

        final result = snapshot.data!;

        // Error state - show error page
        if (result.error != null) {
          return _ErrorPage(
            message: result.error!,
            onRetry: () {
              setState(() {
                _bloc = _loadPriorityWithFallback();
              });
            },
            onViewPriorities: () {
              context.router.navigate(PrioritiesRoute());
            },
          );
        }

        // Success - provide bloc
        return BlocProvider.value(value: result.bloc!, child: widget.child);
      },
    );
  }
}

/// Error page shown when priority loading fails completely
class _ErrorPage extends StatelessWidget {
  const _ErrorPage({
    required this.message,
    required this.onRetry,
    required this.onViewPriorities,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onViewPriorities;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      center: true,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 16,
          children: [
            Icon(
              PlotIcon.warning,
              size: 48,
              color: context.theme.colors.destructive,
            ),
            Text(
              'Error Loading Priority',
              style: context.theme.typography.lg.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              message,
              style: context.theme.typography.sm.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 8,
              children: [
                FButton(
                  onPress: onViewPriorities,
                  style: FButtonStyle.secondary(),
                  child: const Text('View Priorities'),
                ),
                FButton(
                  onPress: onRetry,
                  style: FButtonStyle.primary(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
