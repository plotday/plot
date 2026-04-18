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
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  /// Tracks threads that should stay in the unread section while being viewed,
  /// along with their original sort values to prevent position jumps when
  /// urgency is cleared by sync after marking as read.
  ///
  /// Also caches the full [Thread] so that when a thread transitions from
  /// unread→read and falls outside the SQL LIMIT (the ORDER BY puts read
  /// threads after unreads, so the newly-read thread can be pushed past the
  /// row limit), the cached thread can be injected into the feed results.
  final Map<
    ThreadId,
    ({int urgencyRank, int importance, DateTime activityAt, Thread thread})
  >
  _stickyUnreadIds = {};
  ThreadHeaderNotifier? headerNotifier;

  /// Persisted scroll offsets for scroll restoration across route changes.
  double agendaScrollOffset = 0.0;
  double activityFeedScrollOffset = 0.0;

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

    // Re-trigger demand-driven syncs after a full resync.
    // This lives outside _subscriptions so it survives priority switches.
    _fullResyncSubscription = Store.onFullResync.stream.listen((_) {
      log.fine('Full resync completed, reloading priority');
      _loadPriority();
    });
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

    // When filtering, force navigation to use activityFeed (matches UI)
    if (filter.isNotEmpty) {
      threadListSource = ThreadListSource.activityFeed;
    } else {
      threadListSource = null;
    }

    // Reload agenda items with new filter
    _loadPriority();
  }

  void updateIconFilter(String iconValue) {
    final current = List<String>.from(state.iconFilter);
    if (current.contains(iconValue)) {
      current.remove(iconValue);
    } else {
      current.add(iconValue);
    }
    log.info('Updating icon filter to $current');
    emit(state.copyWith(iconFilter: current));

    // Reload agenda items with new filter
    _loadPriority();
  }

  /// Called immediately on every keystroke to update search text in state
  /// and cancel stale subscriptions so old results stop flowing.
  void prepareSearch(String search) {
    if (state.search == search) return;
    emit(state.copyWith(search: search));

    // When searching, force navigation to use activityFeed (matches UI)
    if (search.isNotEmpty) {
      threadListSource = ThreadListSource.activityFeed;
      // Cancel stale subscriptions so unfiltered results don't flash
      _activityFeedSubscription?.cancel();
      _agendaSubscription?.cancel();
    } else {
      threadListSource = null;
    }
  }

  /// Called after debounce to actually run the search query.
  void executeSearch(String search) {
    // Ensure state is up to date (may already be set by prepareSearch)
    if (state.search != search) {
      emit(state.copyWith(search: search));
    }

    // Reset limits but preserve sync state - search filters local data only
    _agendaLimit = 50;
    if (search.isEmpty) {
      _loadAgenda(triggerSync: false);
    }

    _activityFeedLimit = 50;
    _activityFeedLastRawRowCount = 0;
    _activityFeedLimitIncreased = false;
    _loadActivityFeed(triggerSync: false);
  }

  /// Combined prepare + execute for callers that don't need debouncing.
  void updateSearch(String search) {
    prepareSearch(search);
    executeSearch(search);
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

  /// The priority context the user was viewing before the current one
  /// (session-only). Used by NewThreadPage to show a quick-pick chip.
  static Priority? _previousContextPriority;

  /// The previous non-root priority context, if any.
  Priority? get previousContextPriority => _previousContextPriority;

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

  /// Data-driven suppression for optimistic schedule changes: keeps
  /// suppressing stream rebuilds until the stream data confirms the
  /// thread has the expected schedule.
  (ThreadId, DateTimeRange?)? _pendingOptimisticSchedule;

  /// Data-driven suppression for optimistic removals: keeps suppressing
  /// stream rebuilds until the stream data confirms the thread is gone,
  /// preventing sync events from briefly restoring removed threads.
  final Set<ThreadId> _pendingRemovedIds = {};

  /// Current thread associations, keyed by parent thread ID.
  /// Updated via a separate stream subscription.
  Map<Uuid, List<ThreadAssociationRow>>? _associations;
  StreamSubscription<Map<Uuid, List<ThreadAssociationRow>>>?
  _associationsSubscription;

  /// Data-driven suppression for association changes: keeps reorderViewItems
  /// until _associations confirms the child is under the expected parent.
  (ThreadId childId, Uuid parentId)? _pendingAssociation;

  /// Data-driven suppression for disassociation: keeps reorderViewItems
  /// until _associations no longer contains the child.
  ThreadId? _pendingDisassociation;

  /// Optimistic reorder: caches the moved agendaViewItems so the UI
  /// doesn't re-derive them (which can produce different item counts).
  void moveAgendaItem(
    int viewOldIndex,
    int viewNewIndex, {
    AgendaItem? updatedItem,
    Uuid? associatingWithParent,
    bool disassociating = false,
  }) {
    if (viewOldIndex == viewNewIndex) return;

    _reorderTimestamp = DateTime.now();
    final viewItems = List<AgendaItem>.from(state.agendaViewItems);

    // The page strips the leading "Now" header from agendaViewItems before
    // passing items to InfiniteList, so indices from onReorder are relative
    // to the Now-stripped list. Adjust to agendaViewItems indices.
    final nowOffset =
        (viewItems.isNotEmpty &&
            viewItems.first is AgendaHeaderItem &&
            (viewItems.first as AgendaHeaderItem).now)
        ? 1
        : 0;
    final adjOld = viewOldIndex + nowOffset;
    final adjNew = viewNewIndex + nowOffset;

    final item = viewItems.removeAt(adjOld);
    viewItems.insert(adjNew, updatedItem ?? item);

    // Record the expected state so the stream listener can detect when
    // the DB data has settled and safely transition from the optimistic
    // reorderViewItems to the derived _makeAgenda result.
    final movedItem = viewItems[adjNew];
    if (movedItem is AgendaThreadItem) {
      if (associatingWithParent != null) {
        // Association: suppress until _associations confirms child→parent.
        _pendingAssociation = (movedItem.thread.id, associatingWithParent);
        _pendingReorderOrder = null;
      } else if (disassociating) {
        // Disassociation: suppress until _associations no longer has child.
        _pendingDisassociation = movedItem.thread.id;
        _pendingReorderOrder = (
          movedItem.thread.id,
          movedItem.thread.order.value,
        );
      } else {
        _pendingReorderOrder = (
          movedItem.thread.id,
          movedItem.thread.order.value,
        );
      }
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
    final currentItems = state.agendaItems.length;
    if (needed > _agendaLimit) {
      _agendaLimit = needed;
      _agendaHorizonDays += 90;
      _loadAgenda(triggerSync: !_agendaSyncNoMore);
    } else if (!state.agendaDoneEnd && currentItems < needed) {
      // JOIN multiplication: need more raw rows to get enough unique threads.
      // Only bump when we actually don't have enough items — spurious fetcher
      // calls during first-frame layout (pageSize=1) should not inflate limits.
      _agendaLimit += 50;
      _agendaHorizonDays += 90;
      _loadAgenda(triggerSync: !_agendaSyncNoMore);
    }
    // Wait for sync so InfiniteList's _fetching stays true until data arrives
    final future = _agendaSyncFuture;
    if (future != null) {
      try {
        await future;
      } catch (_) {}
    }
  }

  @override
  Future<void> close() {
    // Unregister time change callback
    Time.setOnTimeChanged(null);

    _fullResyncSubscription?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _threadSubscription?.cancel();
    _agendaSubscription?.cancel();
    _activityFeedSubscription?.cancel();
    _associationsSubscription?.cancel();
    _tagsSubscription?.cancel();
    _iconCountsSubscription?.cancel();
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  /// Optimistically remove a thread from the agenda for instant UI feedback.
  /// The stream-based update will confirm the same state when it catches up.
  /// Keeps link schedule instances so they remain at their scheduled times.
  /// When [finishTodo] is true, remaining link schedule instances are also
  /// updated to todo=false so the leading icon reflects the finished state.
  void optimisticallyRemoveThread(ThreadId id, {bool finishTodo = false}) {
    _pendingRemovedIds.add(id);
    _optimisticTimestamp = DateTime.now();
    final updatedItems = state.agendaItems
        .where(
          (item) => item.when(
            header: (_) => true,
            activity: (a) =>
                a.thread.id != id || a.thread.isLinkScheduleInstance,
          ),
        )
        .map((item) {
          if (!finishTodo) return item;
          return item.when(
            header: (_) => item,
            activity: (a) => a.thread.id == id
                ? AgendaThreadItem(
                    a.thread.copyWith(todo: false),
                    now: a.now,
                    isNext: a.isNext,
                  )
                : item,
          );
        })
        .toList();

    // Also update activity feed so the icon reflects the finished state
    // immediately (the activity feed doesn't use removal animations).
    final updatedFeedItems = finishTodo
        ? state.activityFeedItems.map((item) {
            return item.when(
              header: (_) => item,
              activity: (a) => a.thread.id == id
                  ? AgendaThreadItem(a.thread.copyWith(todo: false), now: a.now)
                  : item,
            );
          }).toList()
        : null;

    emit(
      state.copyWith(
        agendaItems: updatedItems,
        activityFeedItems: updatedFeedItems,
      ),
    );
  }

  /// Optimistically remove associated copies of a thread from the agenda.
  /// Non-associated copies (user-scheduled) are preserved.
  void optimisticallyDisassociate(ThreadId id) {
    _optimisticTimestamp = DateTime.now();

    // Also update the associations map so _makeAgenda doesn't re-add them
    if (_associations != null) {
      final updated = <Uuid, List<ThreadAssociationRow>>{};
      for (final entry in _associations!.entries) {
        final filtered = entry.value
            .where((a) => a.childThreadId != id)
            .toList();
        if (filtered.isNotEmpty) {
          updated[entry.key] = filtered;
        }
      }
      _associations = updated;
    }

    final updatedItems = state.agendaItems
        .where(
          (item) => item.when(
            header: (_) => true,
            activity: (a) => !a.isAssociated || a.thread.id != id,
          ),
        )
        .toList();

    emit(state.copyWith(agendaItems: updatedItems));
  }

  /// Optimistically update a thread in the agenda for instant UI feedback.
  /// The stream-based update will confirm the same state when it catches up.
  void optimisticallyUpdateThread(Thread updatedThread) {
    if (updatedThread.draft) return;
    _optimisticTimestamp = DateTime.now();

    // Keep sticky cache in sync so edits (rename, archive, etc.) aren't
    // reverted when the stream re-emits and the thread is outside the LIMIT.
    if (_stickyUnreadIds.containsKey(updatedThread.id)) {
      if (updatedThread.archivedAt != null) {
        // Archived — stop injecting so it disappears from the feed.
        _stickyUnreadIds.remove(updatedThread.id);
      } else {
        final old = _stickyUnreadIds[updatedThread.id]!;
        _stickyUnreadIds[updatedThread.id] = (
          urgencyRank: old.urgencyRank,
          importance: old.importance,
          activityAt: old.activityAt,
          thread: updatedThread,
        );
      }
    }

    final foundInAgenda = state.agendaItems.any(
      (item) => item.when(
        header: (_) => false,
        activity: (a) => a.thread.id == updatedThread.id,
      ),
    );

    List<AgendaItem> updatedAgendaItems;
    if (foundInAgenda) {
      // Thread is in agenda — check if it should be removed or updated.
      final shouldRemove =
          !updatedThread.todo &&
          updatedThread.at == null &&
          updatedThread.on == null;
      if (shouldRemove) {
        // Thread was only in agenda as a todo — remove it
        updatedAgendaItems = state.agendaItems
            .where(
              (item) => item.when(
                header: (_) => true,
                activity: (a) => a.thread.id != updatedThread.id,
              ),
            )
            .toList();
      } else {
        // Match the specific item (not sibling occurrences of recurring
        // threads) for schedule-change detection and repositioning.
        bool exactMatch(Thread a) =>
            a.id == updatedThread.id &&
            a.occurrence == updatedThread.occurrence &&
            a.isLinkScheduleInstance == updatedThread.isLinkScheduleInstance;

        // Check if the event's schedule changed — if so, reposition
        // instead of doing an in-place replacement.
        final exactItem = state.agendaItems
            .whereType<AgendaThreadItem>()
            .where((a) => exactMatch(a.thread))
            .firstOrNull;
        final oldAt = exactItem?.thread.at;
        final scheduleChanged = exactItem != null && oldAt != updatedThread.at;

        if (scheduleChanged && updatedThread.at != null) {
          // Record expected schedule for data-driven suppression
          _pendingOptimisticSchedule = (updatedThread.id, updatedThread.at);

          // Remove only the specific item and its associated event header
          updatedAgendaItems = state.agendaItems.where((item) {
            if (item is AgendaHeaderItem &&
                item.thread != null &&
                exactMatch(item.thread!)) {
              return false;
            }
            if (item is AgendaThreadItem && exactMatch(item.thread)) {
              return false;
            }
            return true;
          }).toList();

          // Find insertion point by date section and start time
          final targetDate = updatedThread.agendaAt.toDate();
          int insertIndex = updatedAgendaItems.length; // default: end

          for (int i = 0; i < updatedAgendaItems.length; i++) {
            final item = updatedAgendaItems[i];
            if (item is AgendaHeaderItem && item.date != null) {
              if (item.date!.isAfter(targetDate)) {
                insertIndex = i;
                break;
              }
              if (item.date == targetDate) {
                // Found the target date section — find position by start time
                insertIndex = i + 1;
                for (int j = i + 1; j < updatedAgendaItems.length; j++) {
                  final sectionItem = updatedAgendaItems[j];
                  if (sectionItem is AgendaHeaderItem &&
                      sectionItem.date != null) {
                    insertIndex = j;
                    break;
                  }
                  if (sectionItem is AgendaHeaderItem &&
                      sectionItem.dateTimeRange?.start != null &&
                      sectionItem.thread != null &&
                      updatedThread.at!.start != null &&
                      sectionItem.dateTimeRange!.start!.isAfter(
                        updatedThread.at!.start!,
                      )) {
                    insertIndex = j;
                    break;
                  }
                  insertIndex = j + 1;
                }
                break;
              }
            }
          }

          updatedAgendaItems.insert(
            insertIndex,
            AgendaHeaderItem(
              dateTimeRange: updatedThread.at,
              thread: updatedThread,
            ),
          );
          updatedAgendaItems.insert(
            insertIndex + 1,
            AgendaThreadItem(updatedThread),
          );
        } else {
          // In-place replacement (schedule unchanged or no schedule).
          // Update the exact item with the full updatedThread; for sibling
          // occurrences of the same thread, propagate todo state only
          // (preserving each occurrence's own schedule and event time).
          updatedAgendaItems = state.agendaItems.map((item) {
            return item.when(
              header: (h) {
                if (h.thread == null || h.thread!.id != updatedThread.id) {
                  return item;
                }
                if (exactMatch(h.thread!)) {
                  return AgendaHeaderItem(
                    dateTimeRange: updatedThread.at,
                    date: h.date,
                    now: h.now,
                    thread: updatedThread,
                    text: h.text,
                    scheduleAt: h.scheduleAt,
                  );
                }
                // Sibling occurrence: propagate todo state only
                return AgendaHeaderItem(
                  dateTimeRange: h.dateTimeRange,
                  date: h.date,
                  now: h.now,
                  thread: h.thread!.copyWith(todo: updatedThread.todo),
                  text: h.text,
                  scheduleAt: h.scheduleAt,
                );
              },
              activity: (a) {
                if (a.thread.id != updatedThread.id) return item;
                if (exactMatch(a.thread)) {
                  return AgendaThreadItem(updatedThread, now: a.now);
                }
                // Sibling occurrence: propagate todo state only
                return AgendaThreadItem(
                  a.thread.copyWith(todo: updatedThread.todo),
                  now: a.now,
                  isNext: a.isNext,
                );
              },
            );
          }).toList();

          // When a link schedule instance becomes a todo, also insert the
          // base todo duplicate in today's section so it appears instantly.
          if (updatedThread.isLinkScheduleInstance &&
              updatedThread.todo &&
              !state.agendaItems.any(
                (item) => item.when(
                  header: (_) => false,
                  activity: (a) =>
                      a.thread.id == updatedThread.id &&
                      !a.thread.isLinkScheduleInstance,
                ),
              )) {
            final baseTodo = updatedThread.toBaseTodo();
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
                  break;
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
              insertIndex = updatedAgendaItems.isNotEmpty ? 1 : 0;
            }
            updatedAgendaItems.insert(insertIndex, AgendaThreadItem(baseTodo));
          }
        }
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
      updatedAgendaItems.insert(insertIndex, AgendaThreadItem(updatedThread));
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

    emit(
      state.copyWith(
        thread: state.thread?.id == updatedThread.id
            ? Value(updatedThread)
            : const Value.absent(),
        agendaItems: updatedAgendaItems,
        activityFeedItems: updatedFeedItems,
      ),
    );
  }

  /// Force the agenda to rebuild from fresh stream data. Call after an
  /// optimistic update + save when the number of agenda items may have changed
  /// (e.g. starting a link schedule thread creates a base todo duplicate).
  void refreshAgenda() {
    _loadAgenda(triggerSync: false);
  }

  Future<void> setPriority(Priority newPriority) async {
    if (state.context.id == newPriority.id) return;
    // Track previous non-root context for new-thread priority chips
    if (!state.context.root) {
      _previousContextPriority = state.context;
    }
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
    log.info(
      '[setPriority] Switching to priority: ${newPriority.id} (${newPriority.title})',
    );
    final drafts = await Thread.get(
      priorityId: newPriority.id,
      draft: true,
      archived: false, // Only get active (non-archived) drafts
    );
    // Sort by updatedAt descending to get the latest
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final existingDraft = drafts.firstOrNull;

    // Enrich the priority so computed fields are populated
    final enrichedList = await Priority.get(id: newPriority.id, archived: null);
    final contextPriority = enrichedList.isNotEmpty
        ? enrichedList.first
        : newPriority;

    Thread newDraft;
    if (existingDraft != null) {
      newDraft = existingDraft.copyWith(priority: contextPriority);
      log.info(
        '[setPriority] Loaded existing draft: id=${existingDraft.id}, priority=${existingDraft.priority.id} (${existingDraft.priority.title}), archived=${existingDraft.archivedAt != null}',
      );
    } else {
      newDraft = Thread(priority: contextPriority, draft: true);
      log.info(
        '[setPriority] Creating new draft for priority: id=${newDraft.id}, priority=${contextPriority.id} (${contextPriority.title})',
      );
    }

    // Clean up orphaned drafts (keep only the latest)
    if (drafts.length > 1) {
      log.info(
        '[setPriority] Cleaning up ${drafts.length - 1} extra drafts for priority ${newPriority.id}',
      );
      for (final stale in drafts.skip(1)) {
        await stale.delete();
      }
    }

    // Load the latest active draft note for the draft thread
    final draftNotes =
        await (Store.get.select(Store.get.notes)
              ..where((tbl) => tbl.threadId.equalsValue(newDraft.id))
              ..where((tbl) => tbl.draft.equals(true))
              ..where((tbl) => tbl.archivedAt.isNull())
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
            accessContacts: draftNotes.first.accessContacts,
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

    // Reset scroll offsets for the new priority
    agendaScrollOffset = 0.0;
    activityFeedScrollOffset = 0.0;

    // Update context immediately for responsive switching
    emit(
      state.copyWith(
        context: contextPriority,
        draft: newDraft,
        draftNote: draftNote,
        agendaItems: const [],
        activityFeedItems: const [],
        agendaDoneEnd: false,
        agendaLoaded: false,
        activityFeedDoneEnd: false,
        activityFeedLoaded: false,
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
      // Reset header visibility before emitting so the header rebuild
      // sees isThreadVisible = false immediately
      headerNotifier?.isThreadVisible = false;
    }

    // Sticky unread tracking: when navigating away from a thread, remove it
    // from sticky set so it moves to the read section. When selecting an
    // unread thread, add it so it stays in place while being read.
    final oldThread = state.thread;
    if (oldThread != null && thread?.id != oldThread.id) {
      final wasSticky = _stickyUnreadIds.remove(oldThread.id) != null;
      if (wasSticky) {
        oldThread.copyWith(bumpedAt: Value(DateTime.now())).save();
      }
    }
    if (thread != null && thread.unread) {
      _stickyUnreadIds[thread.id] = (
        urgencyRank: thread.urgencyRank,
        importance: thread.importance,
        activityAt: thread.activityAt,
        thread: thread,
      );
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

  /// Updates the draft thread in state only (no DB save).
  /// Use for default type toggles and other UI-only state that
  /// will be persisted when the user adds real content.
  void updateDraftLocal(Thread thread) {
    if (thread.id != state.draft.id) return;
    _draftModified = true;
    emit(state.copyWith(draft: thread));
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

    final noteChanged =
        note != null &&
        note.id == state.draftNote.id &&
        note != state.draftNote;
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
    if (note != null && noteChanged) {
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
        // "no thread" behavior: start from the "Now" header if present,
        // otherwise stay at -1 (before list) so offset=1 finds the first item
        for (int i = 0; i < state.agendaItems.length; i++) {
          final item = state.agendaItems[i];
          if (item is AgendaHeaderItem && item.now) {
            currentIndex = i;
          }
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
      // No thread selected: start before the list so offset=1 finds first thread
      currentIndex = -1;
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
        // Thread not in filtered list (e.g. search active) - keep at -1
        // so offset=1 finds the first thread in the list
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
      final inAgenda = state.agendaItems.any(
        (item) => item.when(
          header: (_) => false,
          activity: (a) => a.thread.id == state.thread!.id,
        ),
      );
      if (inAgenda) return ThreadListSource.agenda;
    }
    return ThreadListSource.activityFeed;
  }

  void _loadPriority() {
    final priorityToLoad = state.context;

    _loadDraft(priorityToLoad);

    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _subscriptions.add(
      Priority.watchOne(priorityToLoad.id).listen((priority) {
        log.fine('Priority updated');
        emit(state.copyWith(context: priority));
      }),
    );
    if (state.thread != null) {
      _loadThread(state.thread!);
    }

    // Watch thread associations for agenda display.
    // The associations map is used by _makeAgenda to inject associated threads
    // under their parent events. The associated threads themselves are loaded
    // via watchAssociatedThreads() combined into the agenda stream.
    _associationsSubscription?.cancel();
    _associationsSubscription = Thread.watchAssociationsByParent().listen((
      associations,
    ) {
      _associations = associations;
    });

    // Watch tags for the priority
    _tagsSubscription?.cancel();
    _tagsSubscription = Thread.watchTagsForPriority(priorityToLoad.path).listen(
      (tags) {
        // Common tags (excluding action tags)
        final commonTagsFiltered = tags
            .where(
              (tagData) => tagData.$1.type != .compute && tagData.$1.addable,
            )
            .map((tagData) => tagData.$1)
            .toList();

        // All tags excluding action tags and common tags
        final commonTagSet = commonTagsFiltered.toSet();
        final otherTags = Tag.getAll(onlyAddable: true)
            .where((tag) => tag.type != .compute && !commonTagSet.contains(tag))
            .toList();

        // Combine: common tags first, then other tags
        final tagSuggestions = [...commonTagsFiltered, ...otherTags];

        emit(state.copyWith(tags: tags, tagSuggestions: tagSuggestions));
      },
    );

    // Watch icon counts for the priority
    _iconCountsSubscription?.cancel();
    _iconCountsSubscription =
        Thread.watchIconCountsForPriority(priorityToLoad.path).listen((counts) {
          final iconCounts = counts
              .map((c) {
                final subType = ThreadSubType.fromIcon(c.$1);
                return subType != null ? (subType, c.$2) : null;
              })
              .whereType<(ThreadSubType, int)>()
              .toList();
          emit(state.copyWith(iconCounts: iconCounts));
        });

    // Watch all active user twists (workspace-level, no longer per-priority)
    _subscriptions.add(
      TwistInstance.watch().listen((twists) {
        log.fine('Twists updated: ${twists.length} twists');
        emit(state.copyWith(twists: twists));
      }),
    );

    // Watch actors (users and contacts for mentions)
    _subscriptions.add(
      Actor.watch(
        types: [ActorType.user, ActorType.contact],
        inviteable: true,
      ).listen((actors) {
        log.fine('Priority actors updated: ${actors.length} actors');
        emit(state.copyWith(actors: actors));
      }),
    );

    _agendaLimit = 50;
    _agendaHorizonDays = 90;
    _agendaSyncNoMore = false;
    _loadAgenda();

    _activityFeedLimit = 50;
    _activityFeedSyncNoMore = false;
    _activityFeedLastRawRowCount = 0;
    _activityFeedLimitIncreased = false;
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
    _threadSubscription = Thread.watchOne(thread.id).listen((watchedThread) {
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

      // Load the corresponding draft note for this thread
      final draftNote = await Note.getDraftByActivity(existingDraft.id);

      // Use state.context (enriched in setPriority)
      emit(
        state.copyWith(
          draft: existingDraft.copyWith(priority: state.context),
          draftNote: draftNote,
        ),
      );
    }
  }

  /// Adds a thread by converting the current draft to a non-draft.
  /// Creates a fresh draft for the priority afterward.
  /// If note is provided, converts it from draft to published.
  /// AI title generation is handled by Thread.save().
  /// Returns the saved thread.
  Future<Thread> add(
    Thread thread, {
    Note? note,
    bool assignNote = true,
  }) async {
    // Convert the draft to a non-draft
    final savedThread = thread.copyWith(draft: false);
    await savedThread.save();

    // Convert draft note to published if provided
    if (note != null &&
        note.content != null &&
        note.content!.trim().isNotEmpty) {
      var publishedNote = note.copyWith(threadId: savedThread.id, draft: false);

      // If the thread is a task and note assignment is requested, assign the
      // note to the current user — but only if no one is already assigned
      // (e.g. the user explicitly assigned someone else on the new thread page).
      if (savedThread.todo && assignNote && !publishedNote.isAssigned()) {
        publishedNote = publishedNote.assignTo(Base.actorId);
      }

      await publishedNote.save();
    }

    // Create fresh draft for the priority (use remembered default if set)
    final newDraft = Thread(
      priority: _newThreadDefaultPriority ?? thread.priority,
      draft: true,
    );
    emit(
      state.copyWith(
        draft: newDraft,
        draftNote: Note.draft(threadId: newDraft.id),
      ),
    );

    return savedThread;
  }

  void _loadAgenda({bool triggerSync = true}) {
    final priorityToLoad = state.context;

    log.fine('Loading agenda for priority ${priorityToLoad.id}');
    _agendaSubscription?.cancel();
    _pendingRemovedIds.clear();

    // Three streams are combined:
    // 1. Main agenda: threads in the current priority (filtered by path)
    // 2. Associated threads: children of active thread associations
    // 3. Cross-priority link events: link-scheduled threads from all priorities
    //    (shown dimmed when outside the current priority)
    final dateRange = CustomBoundedDateRange(
      Date.today(),
      Date.today().addDays(_agendaHorizonDays),
    );
    final agendaStream = Thread.watch(
      priorityPath: priorityToLoad.path,
      archived: state.showArchived,
      filter: state.filter.isNotEmpty ? state.filter : null,
      iconFilter: state.iconFilter.isNotEmpty ? state.iconFilter : null,
      search: state.search.isNotEmpty ? state.search : null,
      order: ThreadOrder.sorted,
      limit: _agendaLimit,
      includeUnscheduled: false,
      range: dateRange,
    );
    final associatedStream = Thread.watchAssociatedThreads();

    // Only fetch cross-priority link events when no active filters/search
    // (filters are priority-scoped, cross-priority events don't match).
    final hasActiveFilters =
        state.filter.isNotEmpty ||
        state.iconFilter.isNotEmpty ||
        state.search.isNotEmpty;
    final crossPriorityStream = hasActiveFilters
        ? Stream.value(<Thread>[])
        : Thread.watch(
            linkScheduledOnly: true,
            archived: false,
            order: ThreadOrder.sorted,
            includeUnscheduled: false,
            range: dateRange,
          ).map((result) => result.threads);

    _agendaSubscription =
        Rx.combineLatest3<
              ThreadWatchResult,
              List<Thread>,
              List<Thread>,
              (ThreadWatchResult, Set<Uuid>)
            >(agendaStream, associatedStream, crossPriorityStream, (
              agendaResult,
              associatedThreads,
              crossPriorityThreads,
            ) {
              final agendaIds = agendaResult.threads.map((t) => t.id).toSet();

              // Merge associated threads that aren't already in the agenda.
              // Only include associated threads whose parent event is in the
              // current priority — prevents threads from other priorities
              // leaking into the agenda.
              final currentPriorityEventIds = agendaResult.threads
                  .where((t) => t.isLinkScheduleInstance || t.hasLinkSchedule)
                  .map((t) => t.id)
                  .toSet();
              final extra = associatedThreads.where((t) {
                if (agendaIds.contains(t.id)) return false;
                // Check if this thread is associated with an event in the
                // current priority (via _associations map)
                if (_associations != null) {
                  for (final entry in _associations!.entries) {
                    if (currentPriorityEventIds.contains(entry.key) &&
                        entry.value.any((a) => a.childThreadId == t.id)) {
                      return true;
                    }
                  }
                }
                return false;
              }).toList();

              // Merge cross-priority link events not already in agenda.
              // Track which thread IDs are outside the current priority.
              // Only include actual link schedule instances from the
              // cross-priority stream — base threads (e.g. todos that
              // happen to have a link) should not leak through.
              final outsidePriorityIds = <Uuid>{};
              final crossExtra = <Thread>[];
              for (final t in crossPriorityThreads) {
                if (!agendaIds.contains(t.id) && t.isLinkScheduleInstance) {
                  crossExtra.add(t);
                  outsidePriorityIds.add(t.id);
                }
              }

              final allThreads = [
                ...agendaResult.threads,
                ...extra,
                ...crossExtra,
              ];

              return (
                (threads: allThreads, rawRowCount: agendaResult.rawRowCount),
                outsidePriorityIds,
              );
            })
            .map((combined) {
              // Compute a cheap signature so identical re-emissions can be
              // dropped before we pay the _makeAgenda cost. Drift streams
              // re-fire on every table change, so repeated syncs of unrelated
              // tables produce many identical emissions.
              final (result, outsidePriorityIds) = combined;
              final threadSig =
                  (result.threads
                          .map(
                            (t) =>
                                '${t.id}:${t.updatedAt.microsecondsSinceEpoch}'
                                ':${t.occurrence ?? ''}'
                                ':${t.isLinkScheduleInstance ? 1 : 0}',
                          )
                          .toList()
                        ..sort())
                      .join(',');
              final outsideSig =
                  (outsidePriorityIds.map((u) => u.toString()).toList()..sort())
                      .join(',');
              final sig =
                  '${result.rawRowCount}|${result.threads.length}|'
                  '$threadSig|$outsideSig';
              return (sig, combined);
            })
            .distinct((a, b) => a.$1 == b.$1)
            .map((tagged) => tagged.$2)
            .transform(
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
            )
            .debounceTime(const Duration(milliseconds: 100))
            .listen((combined) {
              final (result, outsidePriorityIds) = combined;
              final (:threads, :rawRowCount) = result;

              // After a reorder or optimistic update, suppress agenda rebuilds
              // briefly so the optimistic state stays visible until all DB writes
              // (thread, schedule, tags) are complete and the stream settles.
              final now = DateTime.now();

              // Data-driven suppression for optimistic schedule changes: keep
              // suppressing until stream data confirms the expected schedule.
              final bool suppressOptimisticSchedule;
              if (_pendingOptimisticSchedule != null) {
                final (threadId, expectedAt) = _pendingOptimisticSchedule!;
                final settled = threads.any(
                  (t) => t.id == threadId && t.at == expectedAt,
                );
                suppressOptimisticSchedule = !settled;
                if (settled) {
                  _pendingOptimisticSchedule = null;
                }
              } else {
                suppressOptimisticSchedule = false;
              }

              // Data-driven suppression for optimistic removals: keep suppressing
              // until the stream confirms the removed thread is gone.
              final bool suppressOptimisticRemoval;
              if (_pendingRemovedIds.isNotEmpty) {
                final stillPresent = threads.any(
                  (t) => _pendingRemovedIds.contains(t.id),
                );
                suppressOptimisticRemoval = stillPresent;
                if (!stillPresent) {
                  _pendingRemovedIds.clear();
                }
              } else {
                suppressOptimisticRemoval = false;
              }

              // Time-based suppression for other optimistic thread updates (non-reorder).
              final suppressOptimistic =
                  suppressOptimisticSchedule ||
                  suppressOptimisticRemoval ||
                  (_optimisticTimestamp != null &&
                      now.difference(_optimisticTimestamp!) <
                          const Duration(milliseconds: 500));

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
                }
              } else {
                suppressReorder = false;
              }

              // Data-driven suppression for association: keep reorderViewItems
              // until _associations confirms the child→parent mapping AND the
              // thread is no longer a standalone todo (schedule archival done).
              final bool suppressAssociation;
              if (_pendingAssociation != null) {
                final (childId, parentId) = _pendingAssociation!;
                final children = _associations?[parentId];
                final assocExists =
                    children != null &&
                    children.any((a) => a.childThreadId == childId);
                final stillTodo = threads.any((t) => t.id == childId && t.todo);
                final settled = assocExists && !stillTodo;
                suppressAssociation = !settled;
                if (settled) {
                  _pendingAssociation = null;
                }
              } else {
                suppressAssociation = false;
              }

              // Data-driven suppression for disassociation: keep reorderViewItems
              // until _associations no longer contains the child AND the thread
              // has the expected order (schedule restore done).
              final bool suppressDisassociation;
              if (_pendingDisassociation != null) {
                final childId = _pendingDisassociation!;
                final stillAssociated =
                    _associations?.values.any(
                      (children) =>
                          children.any((a) => a.childThreadId == childId),
                    ) ??
                    false;
                // Also check that the thread has settled with its new order
                final orderSettled = _pendingReorderOrder == null;
                final settled = !stillAssociated && orderSettled;
                suppressDisassociation = !settled;
                if (settled) {
                  _pendingDisassociation = null;
                }
              } else {
                suppressDisassociation = false;
              }

              // Time-based minimum suppression for reorders: association and
              // disassociation involve multiple DB writes (association +
              // schedule). Keep reorderViewItems for at least 500ms so all
              // writes settle before _makeAgenda takes over.
              final suppressReorderTime =
                  _reorderTimestamp != null &&
                  now.difference(_reorderTimestamp!) <
                      const Duration(milliseconds: 500);

              // Clear reorder timestamp once all data-driven checks pass
              // AND the time window has elapsed.
              if (!suppressReorder &&
                  !suppressAssociation &&
                  !suppressDisassociation &&
                  !suppressReorderTime) {
                _reorderTimestamp = null;
              }

              final suppressRebuild =
                  suppressReorder ||
                  suppressAssociation ||
                  suppressDisassociation ||
                  suppressReorderTime ||
                  suppressOptimistic;

              log.fine(
                '[_loadAgenda] stream fired: suppress=$suppressRebuild '
                '(reorder=$suppressReorder assoc=$suppressAssociation '
                'disassoc=$suppressDisassociation time=$suppressReorderTime '
                'optimistic=$suppressOptimistic) '
                'reorderAge=${_reorderTimestamp != null ? now.difference(_reorderTimestamp!).inMilliseconds : "null"}ms '
                'hasReorderViewItems=${state.reorderViewItems != null} '
                'pendingOrder=${_pendingReorderOrder?.$2}',
              );

              final agendaItems = suppressRebuild
                  ? state.agendaItems
                  : PriorityState._makeAgenda(
                      threads,
                      context: priorityToLoad,
                      horizonDays: _agendaHorizonDays,
                      associationsByParentId: _associations,
                      outsidePriorityIds: outsidePriorityIds,
                    );

              emit(
                state.copyWith(
                  agendaItems: agendaItems,
                  agendaDoneEnd: false,
                  agendaLoaded: true,
                  // Keep reorderViewItems during suppress, clear when real data arrives
                  reorderViewItems: suppressRebuild
                      ? const Value.absent()
                      : const Value(null),
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
    final path = priorityToLoad.path.value;
    final suffix = archived ? '_archived' : '';
    final entityName = 'agenda:$path$suffix';

    // Fetch-more loop: pull pages until we have enough local items AND the
    // sync boundary covers the last visible item's date, or server has no more.
    for (var i = 0; i < 10; i++) {
      await Thread.pullAgenda(
        priorityToLoad.id,
        priorityToLoad.path,
        archived: archived,
      );

      final syncState = await (Store.get.select(
        Store.get.syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();
      _agendaSyncNoMore = syncState?.noMore ?? true;

      if (_agendaSyncNoMore) break;

      // Check local agenda to decide if we need more pages.
      final localThreads = await Thread.get(
        priorityPath: priorityToLoad.path,
        archived: archived,
        order: ThreadOrder.sorted,
        includeUnscheduled: false,
        limit: _agendaLimit,
        range: CustomBoundedDateRange(
          Date.today(),
          Date.today().addDays(_agendaHorizonDays),
        ),
      );

      final hasEnoughItems = localThreads.length >= _agendaLimit;

      // Compare sync boundary with the last visible item's date.
      final syncBoundary = syncState?.last != null
          ? DateTime.fromMicrosecondsSinceEpoch(syncState!.last!, isUtc: true)
          : null;
      final lastItemDate = localThreads.isNotEmpty
          ? localThreads.last.agendaAt
          : null;
      final syncedPastLastItem =
          syncBoundary != null &&
          lastItemDate != null &&
          !syncBoundary.isBefore(lastItemDate);

      // Stop when both conditions are met: page is full AND sync covers it.
      if (hasEnoughItems && syncedPastLastItem) break;
    }

    // Agenda is infinite — never mark it as done at the end.
    // fetchMoreAgendaItems will extend the horizon as the user scrolls.
  }

  void _loadActivityFeed({bool triggerSync = true}) {
    final priorityToLoad = state.context;
    _activityFeedSubscription?.cancel();
    _activityFeedSubscription =
        Thread.watch(
          order: ThreadOrder.reverse,
          priorityPath: priorityToLoad.path,
          archived: state.showArchived,
          filter: state.filter.isNotEmpty ? state.filter : null,
          iconFilter: state.iconFilter.isNotEmpty ? state.iconFilter : null,
          search: state.search.isNotEmpty ? state.search : null,
          limit: _activityFeedLimit,
        ).listen((result) {
          final (:threads, :rawRowCount) = result;
          _activityFeedLastRawRowCount = rawRowCount;

          // Suppress rebuilds briefly after optimistic updates so stale
          // intermediate stream events (e.g. thread saved but schedule not yet)
          // don't overwrite the optimistic state.
          final suppressOptimistic =
              _optimisticTimestamp != null &&
              DateTime.now().difference(_optimisticTimestamp!) <
                  const Duration(milliseconds: 500);
          if (suppressOptimistic) return;

          // doneEnd when sync is complete AND either:
          // - raw rows are below limit (no more data), OR
          // - thread count hasn't grown despite limit increase (JOIN multiplication)
          final threadCountStalled =
              _activityFeedLimitIncreased &&
              _activityFeedSyncNoMore &&
              rawRowCount >= _activityFeedLimit &&
              threads.length ==
                  state.activityFeedItems
                      .whereType<AgendaThreadItem>()
                      .length &&
              threads.length < _activityFeedLimit;
          final isSearching = state.search.isNotEmpty;
          final doneEnd =
              (rawRowCount < _activityFeedLimit &&
                  (isSearching || _activityFeedSyncNoMore)) ||
              threadCountStalled;
          _activityFeedLimitIncreased = false;
          // Inject sticky threads that fell outside the SQL LIMIT
          // after being marked as read (unreadSort dropped 1→0,
          // pushing them past the LIMIT boundary).
          final allThreads = List<Thread>.from(threads);
          final threadIds = threads.map((t) => t.id).toSet();
          for (final entry in _stickyUnreadIds.entries.toList()) {
            if (threadIds.contains(entry.key)) {
              // Refresh cached thread with latest stream data
              _stickyUnreadIds[entry.key] = (
                urgencyRank: entry.value.urgencyRank,
                importance: entry.value.importance,
                activityAt: entry.value.activityAt,
                thread: threads.firstWhere((t) => t.id == entry.key),
              );
            } else {
              // Thread fell outside LIMIT because it was marked read
              // (unreadSort dropped 1→0). Inject with unread: false so
              // the indicator updates while the position stays sticky.
              allThreads.add(entry.value.thread.copyWith(unread: false));
            }
          }

          final items = <AgendaItem>[];

          // Partition into unread and read
          final unreadThreads = <Thread>[];
          final readThreads = <Thread>[];
          for (final thread in allThreads) {
            if (thread.unread || _stickyUnreadIds.containsKey(thread.id)) {
              unreadThreads.add(thread);
            } else {
              readThreads.add(thread);
            }
          }

          // Sort unread by urgency rank (lower = higher priority), then importance desc,
          // with activityAt as stable tiebreaker.
          // For sticky threads (being viewed), use stored sort values so they
          // don't jump position when urgency is cleared by sync.
          unreadThreads.sort((a, b) {
            final aSticky = _stickyUnreadIds[a.id];
            final bSticky = _stickyUnreadIds[b.id];
            final aRank = aSticky?.urgencyRank ?? a.urgencyRank;
            final bRank = bSticky?.urgencyRank ?? b.urgencyRank;
            final urgencyCmp = aRank.compareTo(bRank);
            if (urgencyCmp != 0) return urgencyCmp;
            final aImp = aSticky?.importance ?? a.importance;
            final bImp = bSticky?.importance ?? b.importance;
            final importanceCmp = bImp.compareTo(aImp);
            if (importanceCmp != 0) return importanceCmp;
            final aAt = aSticky?.activityAt ?? a.activityAt;
            final bAt = bSticky?.activityAt ?? b.activityAt;
            return bAt.compareTo(aAt);
          });

          // Add unread threads (no section header - they're at the very top)
          for (final thread in unreadThreads) {
            items.add(AgendaThreadItem(thread));
          }

          // Add read threads with time-ago bucket headers
          String? currentBucket;
          for (final thread in readThreads) {
            final (label, bucketDate) = PriorityState._timeAgoBucket(
              thread.activityAt.toDate(),
            );
            if (label != currentBucket) {
              currentBucket = label;
              items.add(AgendaHeaderItem(text: label, date: bucketDate));
            }
            items.add(AgendaThreadItem(thread));
          }
          emit(
            state.copyWith(
              activityFeedItems: items,
              activityFeedDoneEnd: doneEnd,
              activityFeedLoaded: true,
            ),
          );
        });

    if (triggerSync) {
      _activityFeedSyncFuture = _triggerActivityFeedSync(priorityToLoad);
    }
  }

  Future<void> _triggerActivityFeedSync(Priority priorityToLoad) async {
    final archived = _effectiveShowArchived;
    final path = priorityToLoad.path.value;
    final suffix = archived ? '_archived' : '';
    final entityName = 'activity-feed:$path$suffix';

    // Fetch-more loop: pull pages until we have enough local items AND the
    // sync boundary covers the last visible item's date, or server has no more.
    for (var i = 0; i < 10; i++) {
      await Thread.pullActivityFeed(
        priorityToLoad.id,
        priorityToLoad.path,
        archived: archived,
      );

      final syncState = await (Store.get.select(
        Store.get.syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();
      _activityFeedSyncNoMore = syncState?.noMore ?? true;

      if (_activityFeedSyncNoMore) break;

      // Check local activity feed to decide if we need more pages.
      final localThreads = await Thread.get(
        priorityPath: priorityToLoad.path,
        archived: archived,
        order: ThreadOrder.reverse,
        limit: _activityFeedLimit,
      );

      final hasEnoughItems = localThreads.length >= _activityFeedLimit;

      // Compare sync boundary with the last visible item's date.
      // Activity feed is reverse-chronological, so sync boundary moves backward.
      final syncBoundary = syncState?.last != null
          ? DateTime.fromMicrosecondsSinceEpoch(syncState!.last!, isUtc: true)
          : null;
      final lastItemDate = localThreads.isNotEmpty
          ? localThreads.last.activityAt
          : null;
      final syncedPastLastItem =
          syncBoundary != null &&
          lastItemDate != null &&
          !syncBoundary.isAfter(lastItemDate);

      // Stop when both conditions are met: page is full AND sync covers it.
      if (hasEnoughItems && syncedPastLastItem) break;
    }

    if (_activityFeedSyncNoMore &&
        _activityFeedLastRawRowCount < _activityFeedLimit) {
      emit(state.copyWith(activityFeedDoneEnd: true));
    }
  }

  Future<void> fetchMoreActivityFeedItems(int first, int count) async {
    final needed = first + count;
    if (needed > _activityFeedLimit) {
      _activityFeedLimitIncreased = true;
      _activityFeedLimit = needed;
      _loadActivityFeed(
        triggerSync: !_activityFeedSyncNoMore && state.search.isEmpty,
      );
    } else if (!state.activityFeedDoneEnd) {
      // JOIN multiplication: need more raw rows to get enough unique threads
      _activityFeedLimitIncreased = true;
      _activityFeedLimit += 50;
      _loadActivityFeed(
        triggerSync: !_activityFeedSyncNoMore && state.search.isEmpty,
      );
    }
    // Wait for sync so InfiniteList's _fetching stays true until data arrives
    final future = _activityFeedSyncFuture;
    if (future != null) {
      try {
        await future;
      } catch (_) {}
    }
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _fullResyncSubscription;
  StreamSubscription<void>? _threadSubscription;
  StreamSubscription<void>? _agendaSubscription;
  StreamSubscription<void>? _activityFeedSubscription;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
  StreamSubscription<List<(String, int)>>? _iconCountsSubscription;
  int _agendaLimit = 50;
  int _agendaHorizonDays = 90;
  int _activityFeedLimit = 50;
  bool _agendaSyncNoMore = false;
  bool _activityFeedSyncNoMore = false;
  Future<void>? _agendaSyncFuture;
  Future<void>? _activityFeedSyncFuture;
  int _activityFeedLastRawRowCount = 0;
  bool _activityFeedLimitIncreased = false;
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
  bool updateShouldNotify(ThreadListSourceProvider old) => source != old.source;
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
    // PriorityState eagerly creates a Note.draft (which reads Base.actorId!),
    // so ensure identity is complete before constructing the bloc. An
    // incomplete identity (userId present but actorId missing) usually means
    // /activate hasn't completed yet (e.g. first run offline, or legacy
    // stored identity without contact ID). Try one more resolve here.
    if (Base.actorIdOrNull == null && Base.signedIn) {
      try {
        await Base.resolveIdentity();
      } catch (e, stackTrace) {
        log.warning(
          'Could not resolve identity before loading priority',
          e,
          stackTrace,
        );
      }
      if (Base.actorIdOrNull == null) {
        return _LoadResult.error(
          'Your account is still being set up. Please check your '
          'connection and try again.',
        );
      }
    }

    try {
      // Level 1: Try to load requested priority
      final priority = await (widget.priority != null
          ? Future.value(widget.priority!)
          : widget.priorityId != null
          ? Priority.getOne(widget.priorityId!)
          : widget.threadId != null
          ? Thread.getOne(widget.threadId!).then((thread) => thread.priority)
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
                  variant: FButtonVariant.secondary,
                  child: const Text('View Priorities'),
                ),
                FButton(
                  onPress: onRetry,
                  variant: FButtonVariant.primary,
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
