import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:drift/drift.dart' hide Column;

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/state/agenda_builder.dart';
import 'package:plot/state/agenda_model.dart';
// Hide store.dart's `PriorityBlock` (the order-timeline class) so it
// doesn't shadow the agenda_model.dart `PriorityBlock` UI type already
// re-exported from this file. The row + top-level helpers
// (PriorityBlockRow, streamPriorityBlocksGroupedByPriority,
// effectivePriorityOrderAt) remain accessible.
import 'package:plot/store/store.dart' hide PriorityBlock;
// Bring the timeline class in under an alias for the few places we
// need to construct/save one.
import 'package:plot/store/store.dart' as store show PriorityBlock;

// Re-export the agenda atom types so existing consumers that import
// `package:plot/state/priority.dart` still see them after their move
// to `agenda_model.dart`.
export 'package:plot/state/agenda_model.dart'
    show AgendaItem, AgendaHeaderItem, AgendaThreadItem;
import 'package:plot/util/async.dart';
import 'package:plot/util/list.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/state/now.dart';
import 'package:plot/router.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

part 'priority_state.dart';

/// Fields that can be watched on an optimistic thread override.
/// An override "settles" (and is cleared) once the stream's copy of the
/// thread matches the expected thread on every watched field.
enum _OverrideField {
  todo,
  archived,
  priorityId,
  title,
  unread,
  at,
  on,
}

/// A per-thread optimistic override applied to stream results until the
/// stream confirms the expected state.
///
/// When [expected] is non-null, stream listeners replace the stream's copy
/// of the thread with [expected] until every [watched] field on the stream
/// copy matches. This keeps the optimistic state visible across the many
/// intermediate emissions produced by multi-row saves (thread row, user
/// schedule, tags, notes, links) without dropping unrelated updates.
///
/// When [expected] is null, the thread is filtered out of stream results
/// (e.g. archived while not viewing archived, moved to a different
/// priority) until the stream stops returning it.
class _OptimisticOverride {
  const _OptimisticOverride._(this.expected, this.watched);

  factory _OptimisticOverride.expect({
    required Thread expected,
    Set<_OverrideField>? fields,
  }) => _OptimisticOverride._(expected, fields ?? _defaultWatched);

  factory _OptimisticOverride.absent() =>
      const _OptimisticOverride._(null, <_OverrideField>{});

  final Thread? expected;
  final Set<_OverrideField> watched;

  /// Default set used when the caller passes the whole updated thread
  /// without specifying which fields it changed. Covers the visible-state
  /// fields that optimistic commands actually flip; intentionally excludes
  /// fields the server may rewrite (e.g. AI-generated title) to avoid
  /// overrides that never settle.
  static const _defaultWatched = <_OverrideField>{
    _OverrideField.todo,
    _OverrideField.archived,
    _OverrideField.priorityId,
    _OverrideField.unread,
    _OverrideField.at,
    _OverrideField.on,
  };

  /// True when [actual] (the stream's copy, or null if absent) matches
  /// what this override expects. Settled overrides are safe to drop.
  bool settled(Thread? actual) {
    if (expected == null) return actual == null;
    if (actual == null) return false;
    for (final field in watched) {
      if (!_matches(field, actual, expected!)) return false;
    }
    return true;
  }

  static bool _matches(_OverrideField field, Thread actual, Thread expected) {
    switch (field) {
      case _OverrideField.todo:
        return actual.todo == expected.todo;
      case _OverrideField.archived:
        return (actual.archivedAt != null) == (expected.archivedAt != null);
      case _OverrideField.priorityId:
        return actual.priority.id == expected.priority.id;
      case _OverrideField.title:
        return actual.title == expected.title;
      case _OverrideField.unread:
        return actual.unread == expected.unread;
      case _OverrideField.at:
        return actual.at == expected.at;
      case _OverrideField.on:
        return actual.on == expected.on;
    }
  }
}

/// Stopwatch-based instrumentation for priority loading. Logs each phase
/// of the switch-priority/load-agenda pipeline at info level so the user
/// can see exactly where time goes when threads are slow to render. The
/// label encodes the trigger (e.g. `switch:<priorityId>`) so events from
/// concurrent loads are easy to disambiguate.
class _PriorityLoadProfile {
  _PriorityLoadProfile(this.label) : _stopwatch = Stopwatch()..start();

  final String label;
  final Stopwatch _stopwatch;

  void mark(String phase) {
    log.info(
      '[PriorityProfile][$label] $phase @ '
      '${_stopwatch.elapsedMilliseconds}ms',
    );
  }
}

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

    // If a search is active, rerun the remote search so its archived
    // scope matches and the archived-match hint is re-evaluated.
    if (state.search.isNotEmpty) {
      _runRemoteSearch(state.search);
    }
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
    // Invalidate any in-flight remote search so its response is discarded.
    _searchGeneration++;
    emit(
      state.copyWith(
        search: search,
        remoteSearchExtras: const [],
        remoteSearchInProgress: false,
        remoteSearchOffline: false,
        hasArchivedMatches: false,
      ),
    );

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

    _runRemoteSearch(search);
  }

  /// Remote search augmentation: fire a parallel API query to surface
  /// threads/notes not yet synced locally, and (when not already showing
  /// archived) a count-only query to decide whether to offer the
  /// "view archived matches" affordance.
  void _runRemoteSearch(String search) {
    _searchGeneration++;
    final gen = _searchGeneration;

    if (search.trim().isEmpty) {
      emit(
        state.copyWith(
          remoteSearchExtras: const [],
          remoteSearchInProgress: false,
          remoteSearchOffline: false,
          hasArchivedMatches: false,
        ),
      );
      return;
    }

    emit(
      state.copyWith(
        remoteSearchExtras: const [],
        remoteSearchInProgress: true,
        remoteSearchOffline: false,
        hasArchivedMatches: false,
      ),
    );

    final showArchived = state.showArchived;

    final scopePriorityId = state.context.id;

    // 1) Main search: hydrate matching threads into the local store and stash
    //    the ones that weren't already visible as "extras".
    unawaited(() async {
      try {
        final threads = await Thread.searchRemote(
          search,
          archived: showArchived,
          priorityId: scopePriorityId,
        );
        if (gen != _searchGeneration || isClosed) return;

        final visibleIds = <String>{
          for (final item in state.activityFeedItems)
            if (item is AgendaThreadItem) item.thread.id.toString(),
        };
        final extras = threads
            .where((t) => !visibleIds.contains(t.id.toString()))
            .toList();

        if (gen != _searchGeneration || isClosed) return;
        emit(state.copyWith(remoteSearchExtras: extras));
      } on NetworkException {
        if (gen != _searchGeneration || isClosed) return;
        emit(
          state.copyWith(
            remoteSearchOffline: true,
            remoteSearchExtras: const [],
          ),
        );
      } catch (e, st) {
        log.warning('Remote search failed', e, st);
      } finally {
        if (gen == _searchGeneration && !isClosed) {
          emit(state.copyWith(remoteSearchInProgress: false));
        }
      }
    }());

    // 2) Archived-hint: only relevant when we are NOT currently showing
    //    archived items. The answer flips the ghost button on/off.
    if (!showArchived) {
      unawaited(() async {
        try {
          final count = await Thread.searchRemoteCount(
            search,
            archived: true,
            priorityId: scopePriorityId,
          );
          if (gen != _searchGeneration || isClosed) return;
          emit(state.copyWith(hasArchivedMatches: count > 0));
        } on NetworkException {
          // Offline — no archived hint to show.
        } catch (e, st) {
          log.warning('Remote archived count failed', e, st);
        }
      }());
    }
  }

  /// Monotonic counter used to discard stale remote search responses.
  int _searchGeneration = 0;

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

  /// Per-thread optimistic overrides applied to stream results until the
  /// stream confirms the expected state. See [_OptimisticOverride]. Replaces
  /// the earlier `_optimisticTimestamp` (time-based), `_pendingRemovedIds`,
  /// and `_pendingOptimisticSchedule` mechanisms with one data-driven
  /// suppression that operates per thread and per field.
  final Map<ThreadId, _OptimisticOverride> _optimisticOverrides = {};

  /// Latest threads list emitted by the agenda subscription (after
  /// optimistic overrides). Optimistic mutation handlers transform
  /// this list and call [_rebuildAgendaModel] to derive a fresh
  /// [AgendaModel] without re-running the agenda DB query.
  List<Thread> _lastAgendaThreads = const [];

  /// Rebuild the agenda model from the cached threads list and emit
  /// it. Optional [extra] state-shape changes (e.g. updated activity
  /// feed, cleared selected thread) are layered onto the same emit.
  void _rebuildAgendaModel({
    Value<Thread?> thread = const Value.absent(),
    List<AgendaItem>? activityFeedItems,
  }) {
    final agenda = AgendaBuilder.build(
      threads: _lastAgendaThreads,
      context: state.context,
      horizonDays: _agendaHorizonDays,
      minFillDays: _agendaFillDays,
      associationsByParentId: _associations,
      priorityBlocksByPriority: _priorityBlocksByPriority,
    );
    emit(
      state.copyWith(
        thread: thread,
        agenda: agenda,
        agendaItems: agenda.flatItems(contextPriorityId: state.context.id),
        activityFeedItems: activityFeedItems,
      ),
    );
  }

  /// Finds a thread from the current state so callers that only have an id
  /// can build an expected-state override. Searches the activity feed first
  /// (where todo changes originate for the bug this fixes) then the agenda.
  Thread? _findThreadInState(ThreadId id) {
    for (final item in state.activityFeedItems) {
      final thread = item.when(
        header: (_) => null,
        activity: (a) => a.thread,
      );
      if (thread != null && thread.id == id) return thread;
    }
    for (final item in state.agendaItems) {
      final thread = item.when(
        header: (_) => null,
        activity: (a) => a.thread,
      );
      if (thread != null && thread.id == id) return thread;
    }
    return null;
  }

  /// Apply pending optimistic overrides to a stream's thread list and clear
  /// any overrides that have settled (the stream now matches the expected
  /// state on every watched field). Returns a new list with:
  ///   - expected-present overrides: the stream row replaced with
  ///     `override.expected` so downstream list builders render the
  ///     optimistic state (and if the stream hasn't caught up yet, the
  ///     expected thread is appended so it still appears).
  ///   - expected-absent overrides: the stream row filtered out.
  List<Thread> _applyOptimisticOverrides(List<Thread> streamThreads) {
    if (_optimisticOverrides.isEmpty) return streamThreads;

    final byId = <ThreadId, Thread>{};
    for (final t in streamThreads) {
      byId[t.id] = t;
    }

    _optimisticOverrides.removeWhere((id, o) => o.settled(byId[id]));

    if (_optimisticOverrides.isEmpty) return streamThreads;

    final patched = <Thread>[];
    for (final thread in streamThreads) {
      final override = _optimisticOverrides[thread.id];
      if (override == null) {
        patched.add(thread);
      } else if (override.expected == null) {
        // Expected absent — drop from the list until the stream agrees.
        continue;
      } else {
        patched.add(override.expected!);
      }
    }
    // Append expected threads the stream hasn't caught up with yet so
    // downstream list builders (e.g. _makeAgenda) still include them.
    for (final entry in _optimisticOverrides.entries) {
      final expected = entry.value.expected;
      if (expected != null && !byId.containsKey(entry.key)) {
        patched.add(expected);
      }
    }
    return patched;
  }

  /// Current thread associations, keyed by parent thread ID.
  /// Updated via a separate stream subscription.
  Map<Uuid, List<ThreadAssociationRow>>? _associations;
  StreamSubscription<Map<Uuid, List<ThreadAssociationRow>>>?
  _associationsSubscription;

  /// Per-priority order timeline (`priority_block` rows). Populated by
  /// [_priorityBlocksSubscription] and fed to [AgendaBuilder.build] so
  /// that block ordering reflects user-driven reorders. Empty until the
  /// first stream emission; AgendaBuilder falls back to
  /// `priority.order` when a priority has no rows here.
  Map<PriorityId, List<PriorityBlockRow>> _priorityBlocksByPriority =
      const {};
  StreamSubscription<Map<PriorityId, List<PriorityBlockRow>>>?
  _priorityBlocksSubscription;

  /// Data-driven suppression for association changes: keeps reorderViewItems
  /// until _associations confirms the child is under the expected parent.
  (ThreadId childId, Uuid parentId)? _pendingAssociation;

  /// Data-driven suppression for disassociation: keeps reorderViewItems
  /// until _associations no longer contains the child.
  ThreadId? _pendingDisassociation;

  /// Optimistic reorder. The caller has computed a new [Order] for the
  /// dragged thread and (in the association/disassociation cases) is
  /// also writing an associations row to the DB. This handler stitches
  /// the same change into [_lastAgendaThreads] and rebuilds the model
  /// so the UI reflects the move immediately. Suppression flags keep
  /// the optimistic state until the DB write settles.
  void moveAgendaItem({
    required Thread movedThread,
    Uuid? associatingWithParent,
    Order? associationOrder,
    bool disassociating = false,
  }) {
    _reorderTimestamp = DateTime.now();

    // Splice the moved thread into the cached source list.
    _lastAgendaThreads = _lastAgendaThreads.map((t) {
      if (t.id != movedThread.id) return t;
      if (t.occurrence == movedThread.occurrence &&
          t.isLinkScheduleInstance == movedThread.isLinkScheduleInstance) {
        return movedThread;
      }
      return t;
    }).toList();

    // Optimistically update the associations map so the rebuilt model
    // reflects the new parent → child mapping immediately.
    if (associatingWithParent != null) {
      // The new association row's order MUST match the order the DB
      // write (`associateWith`) is about to use — it determines where
      // the thread sorts among the parent's other associated children.
      // Falling back to `movedThread.order` here would use the (now
      // archived) user schedule's order, which is unrelated to
      // association order and would render the thread at an arbitrary
      // position until the DB sync caught up.
      final assoc = ThreadAssociationRow(
        id: Uuid.generate(),
        updatedAt: DateTime.now(),
        parentThreadId: associatingWithParent,
        childThreadId: movedThread.id,
        order: associationOrder ?? movedThread.order,
      );
      // First strip the moved thread out of every other parent — a
      // child can only be associated with one parent at a time, and
      // `associateWith` archives any prior association in the DB. If
      // we left the optimistic map showing both, the thread would
      // briefly appear under both events until the DB sync caught up.
      final updated = <Uuid, List<ThreadAssociationRow>>{};
      if (_associations != null) {
        for (final entry in _associations!.entries) {
          final filtered = entry.value
              .where((a) => a.childThreadId != movedThread.id)
              .toList();
          if (filtered.isNotEmpty) updated[entry.key] = filtered;
        }
      }
      final list = List<ThreadAssociationRow>.from(
        updated[associatingWithParent] ?? const [],
      )..add(assoc);
      updated[associatingWithParent] = list;
      _associations = updated;
      _pendingAssociation = (movedThread.id, associatingWithParent);
      _pendingReorderOrder = null;
    } else if (disassociating) {
      if (_associations != null) {
        final updated = <Uuid, List<ThreadAssociationRow>>{};
        for (final entry in _associations!.entries) {
          final filtered = entry.value
              .where((a) => a.childThreadId != movedThread.id)
              .toList();
          if (filtered.isNotEmpty) updated[entry.key] = filtered;
        }
        _associations = updated;
      }
      _pendingDisassociation = movedThread.id;
      _pendingReorderOrder = (movedThread.id, movedThread.order.value);
    } else {
      _pendingReorderOrder = (movedThread.id, movedThread.order.value);
    }

    log.info(
      '[moveAgendaItem] thread=${movedThread.id} '
      'order=${movedThread.order.value} '
      'assoc=${associatingWithParent ?? "-"} disassoc=$disassociating',
    );
    // Build the optimistic agenda from the mutated cache and pin it as
    // reorderViewItems so the renderer keeps showing this exact view
    // until the suppress window clears. Without the pin, mid-drag
    // background stream fires would emit subtly-different rebuilds
    // (e.g. updated_at deltas on unrelated threads) and ReorderableListView
    // would re-render the items list, snapping the just-dropped thread
    // back to its original position before the next frame settled.
    final agenda = AgendaBuilder.build(
      threads: _lastAgendaThreads,
      context: state.context,
      horizonDays: _agendaHorizonDays,
      minFillDays: _agendaFillDays,
      associationsByParentId: _associations,
      priorityBlocksByPriority: _priorityBlocksByPriority,
    );
    final flat = agenda.flatItems(contextPriorityId: state.context.id);
    emit(
      state.copyWith(
        agenda: agenda,
        agendaItems: flat,
        reorderViewItems: Value(flat),
      ),
    );
  }

  /// Move a single priority block to a different gap (and optionally a
  /// different day). Every contained thread's `_userSchedule.startAt` is
  /// rewritten to `targetGapAnchorAt` (the start of the destination gap)
  /// using the existing pinned-after-event encoding. The thread set is
  /// scoped to the source [blockId] — the agenda model already groups
  /// threads by `(date, period, priority)`, so using the block's own
  /// thread list is what isolates a drag of (say) Using Plot's *today*
  /// block from Using Plot's *tomorrow* block.
  ///
  /// Earlier this scope was just `priority.id`, which had the dragged
  /// block silently consuming every thread of that priority across the
  /// whole agenda — `reorderToAfterEvent` clears `startOn` and writes
  /// one common `startAt`, so other-day blocks of the same priority
  /// collapsed into the dragged target and disappeared from their
  /// original date.
  ///
  /// Implements rule 3 of the redesign (blocks can move into different
  /// time periods). Rejected drops over events should snap to the
  /// nearest gap before reaching this method.
  Future<void> moveBlock({
    required String blockId,
    required Iterable<ThreadId> threadIds,
    required DateTime targetGapAnchorAt,
  }) async {
    _reorderTimestamp = DateTime.now();
    // Resolve thread ids against `_lastAgendaThreads` — the canonical
    // cache. The dispatcher passes ids gathered from `listItems`, which
    // comes from the same agenda model. We don't read `state.agenda` to
    // find the block here because there's a narrow race where the bloc
    // has emitted a new state but the page hasn't yet rebuilt with
    // matching `listItems` — in that window `blockById` can miss while
    // `listItems` still references the prior model. Operating on thread
    // ids directly sidesteps the lookup.
    final threadIdSet = threadIds.toSet();
    if (threadIdSet.isEmpty) {
      log.warning('[moveBlock] block $blockId — empty thread id set');
      return;
    }
    final threadsToMove = _lastAgendaThreads
        .where((t) => threadIdSet.contains(t.id))
        .toList();
    if (threadsToMove.isEmpty) {
      log.warning(
        '[moveBlock] block $blockId — none of ${threadIdSet.length} '
        'thread ids present in cache (stale agenda?)',
      );
      return;
    }
    final priorityId = threadsToMove.first.priority.id;

    log.info(
      '[moveBlock] block=$blockId priority=$priorityId '
      'threads=${threadsToMove.length} target=$targetGapAnchorAt',
    );

    final updated = <Thread>[];
    for (final t in threadsToMove) {
      final moved = t.reorderToAfterEvent(t.order, eventEndTime: targetGapAnchorAt);
      updated.add(moved);
      _optimisticOverrides[t.id] = _OptimisticOverride.expect(expected: moved);
    }
    final movedById = {for (final t in updated) t.id: t};
    _lastAgendaThreads = _lastAgendaThreads
        .map((t) => movedById[t.id] ?? t)
        .toList();

    _rebuildAgendaModel();

    for (final t in updated) {
      // Fire-and-forget; the optimistic override survives until the
      // stream confirms.
      unawaited(t.save());
    }
  }

  /// Reorder a priority's block within a single time period.
  ///
  /// `periodReferenceTime` is the agenda moment from which the new
  /// ordering applies — typically the target gap's start. `above` and
  /// `below` identify the block's new neighbours (null = top / bottom).
  ///
  /// `effectiveAt` on the written `priority_block` row is purely an
  /// agenda coordinate (the gap's anchor). It has no relation to
  /// wall-clock `now`: a reorder of a past gap, the current gap, or a
  /// future gap all anchor at the gap itself, and time-traveled
  /// sessions behave the same as live ones. Earlier this used
  /// `now` for "do-now" reorders, which silently broke ordering for
  /// past gaps because `effectivePriorityOrderAt` filters out rows
  /// whose `effectiveAt > moment`.
  ///
  /// Re-reordering the *same* gap soft-archives the previous row at
  /// the same `effectiveAt` so the new one wins unambiguously. Rows
  /// at *different* `effectiveAt`s (older or newer reorders of other
  /// gaps) are preserved — they form a timeline where each gap has
  /// the ordering the user last set for it.
  Future<void> reorderBlockWithinPeriod({
    required PriorityId priorityId,
    required DateTime periodReferenceTime,
    required PriorityId? above,
    required PriorityId? below,
  }) async {
    _reorderTimestamp = DateTime.now();
    final now = DateTime.now();

    Order? aboveOrder;
    Order? belowOrder;
    if (above != null) {
      final aboveBlocks = _priorityBlocksByPriority[above] ?? const [];
      final fallback = _findPriorityFallback(above);
      aboveOrder = Order(effectivePriorityOrderAt(
        moment: periodReferenceTime,
        blocksForPriority: aboveBlocks,
        fallback: fallback,
      ));
    }
    if (below != null) {
      final belowBlocks = _priorityBlocksByPriority[below] ?? const [];
      final fallback = _findPriorityFallback(below);
      belowOrder = Order(effectivePriorityOrderAt(
        moment: periodReferenceTime,
        blocksForPriority: belowBlocks,
        fallback: fallback,
      ));
    }
    final newOrder = Order.between(aboveOrder, belowOrder);
    final effectiveAt = periodReferenceTime;

    log.info(
      '[reorderBlockWithinPeriod] priority=$priorityId '
      'order=${newOrder.value} effectiveAt=$effectiveAt',
    );

    // Optimistic: splice a synthetic row into the cache so the next
    // rebuild reflects the new ordering immediately.
    final optimisticRow = PriorityBlockRow(
      id: Uuid.generate(),
      priorityId: priorityId,
      createdBy: Base.userId,
      orderValue: newOrder,
      effectiveAt: effectiveAt,
      archivedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    final updated = <PriorityId, List<PriorityBlockRow>>{
      for (final entry in _priorityBlocksByPriority.entries)
        entry.key: List.of(entry.value),
    };
    final list = updated.putIfAbsent(priorityId, () => <PriorityBlockRow>[]);
    // Soft-archive any existing non-archived row at the same
    // effectiveAt for this priority — re-reorders of the same gap
    // replace the previous entry rather than accumulating duplicates
    // that effectivePriorityOrderAt would pick between
    // non-deterministically. Rows at *other* effectiveAts represent
    // orderings the user established for other gaps and stay intact.
    for (var i = 0; i < list.length; i++) {
      if (list[i].effectiveAt.isAtSameMomentAs(effectiveAt) &&
          list[i].archivedAt == null) {
        list[i] = list[i].copyWith(archivedAt: Value(now));
      }
    }
    list.add(optimisticRow);
    _priorityBlocksByPriority = updated;

    _rebuildAgendaModel();

    final block = store.PriorityBlock(
      priorityId: priorityId,
      orderValue: newOrder,
      effectiveAt: effectiveAt,
    );
    unawaited(block.save(archiveSameEffectiveAt: true));
  }

  /// Drop a thread inside another priority's block — reparents and
  /// reorders within that block. `above` / `below` are the dragged
  /// thread's new neighbours inside the target block.
  Future<void> dropThreadIntoBlock({
    required ThreadId threadId,
    required PriorityId targetPriorityId,
    required ThreadId? above,
    required ThreadId? below,
    DateTime? gapAnchorAt,
  }) async {
    return _dropThread(
      threadId: threadId,
      targetPriorityId: targetPriorityId,
      above: above,
      below: below,
      gapAnchorAt: gapAnchorAt,
      tag: 'dropThreadIntoBlock',
    );
  }

  /// Drop a thread outside any existing block. If the thread's target
  /// priority already has a block in this period the drop appends or
  /// prepends to it (based on which side of the existing block was
  /// dropped onto); otherwise a new block forms at the drop position.
  ///
  /// `above` / `below` are the threads of the *target priority* that
  /// would sit immediately above / below the drop in the consolidated
  /// view (they may be the same thread set as the existing block when a
  /// block exists, or null/null when the priority has no block yet).
  Future<void> dropThreadOutsideBlock({
    required ThreadId threadId,
    required PriorityId targetPriorityId,
    required ThreadId? above,
    required ThreadId? below,
    DateTime? gapAnchorAt,
  }) async {
    return _dropThread(
      threadId: threadId,
      targetPriorityId: targetPriorityId,
      above: above,
      below: below,
      gapAnchorAt: gapAnchorAt,
      tag: 'dropThreadOutsideBlock',
    );
  }

  /// Shared implementation for `dropThreadIntoBlock` /
  /// `dropThreadOutsideBlock`. Both end up doing the same thing on the
  /// thread side — only the page-level intent differs.
  Future<void> _dropThread({
    required ThreadId threadId,
    required PriorityId targetPriorityId,
    required ThreadId? above,
    required ThreadId? below,
    DateTime? gapAnchorAt,
    required String tag,
  }) async {
    _reorderTimestamp = DateTime.now();
    Thread? source;
    for (final t in _lastAgendaThreads) {
      if (t.id == threadId) {
        source = t;
        break;
      }
    }
    source ??= _findThreadInState(threadId);
    if (source == null) {
      log.warning('[$tag] thread $threadId not found in cache');
      return;
    }

    final aboveOrder = _findThreadOrder(above);
    final belowOrder = _findThreadOrder(below);
    final newOrder = Order.between(aboveOrder, belowOrder);

    final reparented = source.priority.id == targetPriorityId
        ? source
        : source.copyWith(
            priority: _findPriorityById(targetPriorityId) ?? source.priority,
          );

    final ordered = reparented.copyWith(order: newOrder);
    final anchored = gapAnchorAt != null
        ? ordered.reorderToAfterEvent(newOrder, eventEndTime: gapAnchorAt)
        : ordered;

    log.info(
      '[$tag] thread=$threadId target=$targetPriorityId '
      'order=${newOrder.value} above=$above below=$below '
      'anchor=$gapAnchorAt',
    );

    _optimisticOverrides[threadId] = _OptimisticOverride.expect(expected: anchored);
    _lastAgendaThreads = _lastAgendaThreads
        .map((t) => t.id == threadId ? anchored : t)
        .toList();
    _pendingReorderOrder = (threadId, newOrder.value);

    _rebuildAgendaModel();

    unawaited(anchored.save());
  }

  /// Look up a priority's fallback order value. Used by
  /// `reorderBlockWithinPeriod` when computing the order between two
  /// neighbours; matches the same fallback `AgendaBuilder` uses when no
  /// `priority_block` rows exist for a priority.
  double _findPriorityFallback(PriorityId id) {
    final priority = _findPriorityById(id);
    return priority?.order.value ?? 0.0;
  }

  Priority? _findPriorityById(PriorityId id) {
    for (final t in _lastAgendaThreads) {
      if (t.priority.id == id) return t.priority;
    }
    return null;
  }

  Order? _findThreadOrder(ThreadId? id) {
    if (id == null) return null;
    for (final t in _lastAgendaThreads) {
      if (t.id == id) return t.order;
    }
    return null;
  }

  Future<void> fetchMoreAgendaItems(int first, int count) async {
    final needed = first + count;
    final currentItems = state.agendaItems.length;
    var shouldReload = false;
    if (needed > _agendaLimit) {
      _agendaLimit = needed;
      _agendaHorizonDays += 90;
      shouldReload = true;
    } else if (!state.agendaDoneEnd && currentItems < needed) {
      // JOIN multiplication: need more raw rows to get enough unique threads.
      // Only bump when we actually don't have enough items — spurious fetcher
      // calls during first-frame layout (pageSize=1) should not inflate limits.
      _agendaLimit += 50;
      _agendaHorizonDays += 90;
      shouldReload = true;
    }
    // When the visible list is shorter than what the InfiniteList wants,
    // grow the empty-day fill so the rebuild produces more date headers.
    // Without this, agendas with sparse content stall at
    // last-content-date + 14 days no matter how far the horizon extends,
    // leaving the loading spinner stuck at the bottom.
    if (currentItems < needed && _agendaFillDays < _agendaHorizonDays) {
      _agendaFillDays = (_agendaFillDays + 90).clamp(0, _agendaHorizonDays);
      shouldReload = true;
    }
    if (shouldReload) {
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
    _priorityBlocksSubscription?.cancel();
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
    // Record an override so stream emissions between the thread-row write
    // and the user-schedule write (derived todo=true while the schedule
    // isn't yet archived) don't flip the icon back on.
    final existing = _findThreadInState(id);
    if (existing != null) {
      if (finishTodo) {
        _optimisticOverrides[id] = _OptimisticOverride.expect(
          expected: existing.copyWith(todo: false),
          fields: const {_OverrideField.todo},
        );
      } else {
        _optimisticOverrides[id] = _OptimisticOverride.absent();
      }
    }
    // Drop non-link-instance copies of the thread from the cached
    // source list; finishing a todo keeps any link-schedule instance
    // alive (it remains as an event) but flips its todo flag so the
    // builder treats it as the user's scheduled completion.
    // Associated threads are also kept so they continue to render
    // nested under their parent event — "Remove from agenda" must
    // not strip the event nesting (that's "Remove from event"'s job).
    final isAssociated =
        _associations?.values.any(
          (children) => children.any((a) => a.childThreadId == id),
        ) ??
        false;
    _lastAgendaThreads = _lastAgendaThreads
        .where(
          (t) => t.id != id || t.isLinkScheduleInstance || isAssociated,
        )
        .map((t) {
          if (!finishTodo || t.id != id) return t;
          return t.copyWith(todo: false);
        })
        .toList();

    // Activity feed isn't backed by _lastAgendaThreads — splice the
    // finishedTodo flag through directly so the icon updates instantly.
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

    _rebuildAgendaModel(activityFeedItems: updatedFeedItems);
  }

  /// Optimistically remove an archived thread from the agenda and the
  /// activity feed. When the user is viewing the archive (showArchived),
  /// the thread stays in the feed and is just updated in place via
  /// [optimisticallyUpdateThread].
  void optimisticallyArchiveThread(Thread archivedThread) {
    final id = archivedThread.id;
    // When viewing the archive, expect the thread to remain with
    // archivedAt set; otherwise expect it to disappear from the list.
    _optimisticOverrides[id] = state.showArchived
        ? _OptimisticOverride.expect(
            expected: archivedThread,
            fields: const {_OverrideField.archived},
          )
        : _OptimisticOverride.absent();
    _stickyUnreadIds.remove(id);

    // Drop the archived thread from the cached source list so the
    // rebuilt model omits it.
    _lastAgendaThreads = _lastAgendaThreads.where((t) => t.id != id).toList();

    final updatedFeed = state.showArchived
        ? state.activityFeedItems.map((item) {
            return item.when(
              header: (_) => item,
              activity: (a) => a.thread.id == id
                  ? AgendaThreadItem(archivedThread)
                  : item,
            );
          }).toList()
        : state.activityFeedItems
            .where(
              (item) => item.when(
                header: (_) => true,
                activity: (a) => a.thread.id != id,
              ),
            )
            .toList();

    _rebuildAgendaModel(
      thread: state.thread?.id == id
          ? Value(archivedThread)
          : const Value.absent(),
      activityFeedItems: updatedFeed,
    );
  }

  /// Optimistically remove associated copies of a thread from the agenda.
  /// Non-associated copies (user-scheduled) are preserved.
  void optimisticallyDisassociate(ThreadId id) {
    // No thread-level override: disassociation updates the _associations map
    // in place below, which _makeAgenda consults on every rebuild — so the
    // associated copy naturally stops rendering without needing to suppress
    // stream events.

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

    // _associations was pruned above, and _lastAgendaThreads still
    // contains the thread (its other appearances stay valid). Rebuilding
    // from the cache drops the associated copies as the builder no longer
    // sees the parent → child mapping for this id.
    _rebuildAgendaModel();
  }

  /// Optimistically update a thread in the agenda for instant UI feedback.
  /// The stream-based update will confirm the same state when it catches up.
  void optimisticallyUpdateThread(Thread updatedThread) {
    if (updatedThread.draft) return;
    // Record the expected post-update state. The default watched set covers
    // the visible-state fields any save() could flip (todo, archived,
    // priority, schedule, unread) while ignoring fields the server may
    // rewrite on its own (e.g. AI-generated title).
    _optimisticOverrides[updatedThread.id] = _OptimisticOverride.expect(
      expected: updatedThread,
    );

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

    // Mutate the cached threads list to reflect the update. Sibling
    // occurrences of recurring threads share an id but have different
    // `occurrence`/`isLinkScheduleInstance` — propagate only the
    // todo flag to siblings while replacing the exact match in full.
    bool exactMatch(Thread t) =>
        t.id == updatedThread.id &&
        t.occurrence == updatedThread.occurrence &&
        t.isLinkScheduleInstance == updatedThread.isLinkScheduleInstance;

    final foundInAgenda = _lastAgendaThreads.any(
      (t) => t.id == updatedThread.id,
    );

    final shouldRemove =
        !updatedThread.todo &&
        updatedThread.at == null &&
        updatedThread.on == null;

    var rebuilt = _lastAgendaThreads.map((t) {
      if (t.id != updatedThread.id) return t;
      if (exactMatch(t)) return updatedThread;
      // Sibling occurrence: propagate todo state only.
      return t.copyWith(todo: updatedThread.todo);
    }).toList();

    if (shouldRemove) {
      // Thread was only in agenda as a todo — remove every copy.
      rebuilt = rebuilt.where((t) => t.id != updatedThread.id).toList();
    } else if (!foundInAgenda) {
      if (updatedThread.todo) {
        // Becoming a todo but not in agenda yet — append; the builder
        // sorts todos by todoCompareTo, so position resolves automatically.
        rebuilt.add(updatedThread);
      }
      // Otherwise (e.g. archive transitioning, no longer todo): no
      // change — the thread stays absent from the agenda.
    }

    // When a link schedule instance becomes a todo, also surface the
    // base todo so it appears in today's section even before the DB
    // sync emits the user's user-schedule row. The builder dedups by
    // (id, isLinkScheduleInstance, occurrence), so adding the base
    // todo here doesn't conflict with the link instance.
    if (updatedThread.isLinkScheduleInstance &&
        updatedThread.todo &&
        !rebuilt.any(
          (t) => t.id == updatedThread.id && !t.isLinkScheduleInstance,
        )) {
      rebuilt.add(updatedThread.toBaseTodo());
    }

    _lastAgendaThreads = rebuilt;

    final updatedFeedItems = state.activityFeedItems.map((item) {
      return item.when(
        header: (_) => item,
        activity: (a) => a.thread.id == updatedThread.id
            ? AgendaThreadItem(updatedThread)
            : item,
      );
    }).toList();

    _rebuildAgendaModel(
      thread: state.thread?.id == updatedThread.id
          ? Value(updatedThread)
          : const Value.absent(),
      activityFeedItems: updatedFeedItems,
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

    // Profile the priority switch end-to-end. The same stopwatch is passed
    // into _loadPriority/_loadAgenda so timestamps share an origin and the
    // user can see exactly how each phase contributes to time-to-threads.
    final profile = _PriorityLoadProfile('switch:${newPriority.id}');
    profile.mark(
      'setPriority start: ${state.context.title} -> ${newPriority.title}',
    );

    // Track previous non-root context for new-thread priority chips
    if (!state.context.root) {
      _previousContextPriority = state.context;
    }
    _newThreadDefaultPriority = null;
    // We're switching priorities, so any in-progress edit on the old draft
    // is no longer relevant. Clearing the flag lets _loadDraft (called from
    // _loadPriority below) populate the new priority's chain draft instead
    // of bailing to preserve the old one.
    _draftModified = false;

    // Cancel priority-scoped subscriptions only. The agenda subscription
    // is global — it's not scoped to any priority — so leave it alone.
    // Re-subscribing it here would tear down and rebuild the SQLite query
    // for the same data, producing the visible reload the user is trying
    // to avoid. The activity feed, drafts, tags, and icon counts ARE
    // priority-scoped, so they get cancelled and re-initialized below.
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _threadSubscription?.cancel();
    _watchingThreadId = null;
    _activityFeedSubscription?.cancel();
    _tagsSubscription?.cancel();

    // Drop optimistic overrides — they apply to the old priority's streams
    // and won't naturally settle in the new one.
    _optimisticOverrides.clear();

    // Reset only the activity-feed scroll. Agenda scroll is preserved so
    // the user lands on the same visible block region after the switch.
    activityFeedScrollOffset = 0.0;

    // Switch context and rebuild the agenda model from cached threads
    // so the new context's blocks become the expanded ones (and
    // [isOutside] flags reflect the new context). agendaItems is NOT
    // cleared — the same threads are valid across all priorities (the
    // agenda query is global), only the blocks' presentation changes.
    final newAgenda = AgendaBuilder.build(
      threads: _lastAgendaThreads,
      context: newPriority,
      horizonDays: _agendaHorizonDays,
      minFillDays: _agendaFillDays,
      associationsByParentId: _associations,
      priorityBlocksByPriority: _priorityBlocksByPriority,
    );
    emit(
      state.copyWith(
        context: newPriority,
        agenda: newAgenda,
        agendaItems: newAgenda.flatItems(contextPriorityId: newPriority.id),
        activityFeedItems: const [],
        activityFeedDoneEnd: false,
        activityFeedLoaded: false,
      ),
    );
    profile.mark('emitted context-switched state');

    // Reset only the activity-feed pagination — the agenda's pagination
    // and sync state carry over because the data hasn't been re-fetched.
    _activityFeedLimit = 50;
    _activityFeedSyncNoMore = false;
    _activityFeedLastRawRowCount = 0;
    _activityFeedLimitIncreased = false;

    // Re-init priority-scoped subscriptions (drafts, tags, icons,
    // activity feed). reloadAgenda: false skips the global agenda
    // subscription — it's still alive from the initial load.
    _loadPriority(profile: profile, reloadAgenda: false);
    profile.mark('_loadPriority returned (subscriptions started)');

    // Look up the chain draft so the new-thread input shows the right
    // content. We deliberately DO NOT call `Priority.get(archived: null)` to
    // re-enrich the priority — the profile data showed it cost ~1100ms
    // (including a `pullArchived` call) and the only fields it adds
    // (`active`/`unreadComputed`) are recomputed elsewhere by PrioritiesBloc;
    // nothing in this bloc reads them off `state.context`. Priority.watchOne
    // (registered inside _loadPriority) keeps state.context in sync with the
    // raw row, which is enough.
    final existingDraft = await Thread.getDraftInChain(newPriority);
    profile.mark(
      'chain draft lookup done (found=${existingDraft != null})',
    );

    Thread newDraft;
    if (existingDraft != null) {
      // Preserve the draft's filed priority — don't reassign to context.
      newDraft = existingDraft;

      // Auto-organize is only meaningful in the root priority. If the chain
      // draft was auto-filed at root and we're entering a non-root context,
      // drop the auto flag and re-file to the new context priority so the
      // chip reflects "where the user is working" instead of "Auto".
      if (!newPriority.root &&
          ThreadsBase.autoFileIds.remove(newDraft.id.toString())) {
        newDraft = newDraft.copyWith(priority: newPriority);
        // Don't await — the save can finish in the background. The user only
        // needs the in-memory draft to start typing.
        unawaited(newDraft.save());
      }
    } else {
      newDraft = Thread(priority: newPriority, draft: true);
    }

    if (isClosed) return;

    // Emit the chosen draft right away so the new-thread input shows the
    // right priority chip. The actual draft note (and the legacy duplicate
    // cleanup) finish in the background — neither blocks typing because the
    // editor mounts with the in-memory draft and patches in the saved note
    // when it arrives.
    emit(state.copyWith(draft: newDraft));
    profile.mark('draft emitted');

    unawaited(_finalizeDraftInBackground(newDraft, profile));
  }

  /// Background completion for [setPriority]'s draft work. Runs the legacy
  /// duplicate-draft cleanup and loads the saved draft note, then emits the
  /// note when ready. Runs after the agenda has had a chance to render so
  /// it doesn't compete with the agenda's Drift query for the SQLite
  /// connection during the user-visible spinner phase.
  Future<void> _finalizeDraftInBackground(
    Thread newDraft,
    _PriorityLoadProfile profile,
  ) async {
    try {
      // Clean up duplicate drafts at the chosen draft's priority (legacy).
      // This used the heavy Thread._get JOIN, which the profile showed
      // could take >1.5s with a full thread table — pushing it off the
      // agenda's critical path makes the spinner phase the agenda query
      // alone.
      final sameIdDrafts = await Thread.get(
        priorityId: newDraft.priority.id,
        draft: true,
        archived: false,
      );
      if (sameIdDrafts.length > 1) {
        sameIdDrafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        log.info(
          '[setPriority] Cleaning up ${sameIdDrafts.length - 1} extra drafts for priority ${newDraft.priority.id}',
        );
        for (final stale in sameIdDrafts.skip(1)) {
          if (stale.id != newDraft.id) await stale.delete();
        }
      }
      profile.mark('drafts deduped (background)');

      // Load the latest active draft note for the draft thread
      final draftNotes =
          await (Store.get.select(Store.get.notes)
                ..where((tbl) => tbl.threadId.equalsValue(newDraft.id))
                ..where((tbl) => tbl.draft.equals(true))
                ..where((tbl) => tbl.archivedAt.isNull())
                ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
                ..limit(1))
              .get();
      final loadedNote = draftNotes.isEmpty
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

      // No saved note for this draft → create an empty in-memory note. Do
      // NOT clobber a note the user has already started typing — the
      // editor controller writes through to state.draftNote, so any
      // non-empty current note represents user input we should preserve.
      final draftNote =
          loadedNote ??
          (state.draftNote.threadId == newDraft.id &&
                  (state.draftNote.content?.isNotEmpty ?? false)
              ? state.draftNote
              : Note.draft(threadId: newDraft.id));
      profile.mark('draft note loaded (background)');

      if (isClosed) return;

      // Skip the emit if the user has already started editing — replacing
      // their note with a stale DB copy would lose keystrokes.
      if (_draftModified) {
        profile.mark('draft note emit skipped (user editing)');
        return;
      }

      emit(state.copyWith(draftNote: draftNote));
      profile.mark('setPriority done (background)');
    } catch (e, stackTrace) {
      log.warning(
        '[setPriority] Background draft finalization failed',
        e,
        stackTrace,
      );
      Tracker.captureException(e, stackTrace);
    }
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
    } else if (note != null && noteChanged) {
      // Note is changing but no thread-level fields are. The thread row
      // may still be in-memory only (Thread() constructs but updateDraft
      // skips save() unless thread fields change). Persist it so chain /
      // priority draft lookups can find this draft after navigation.
      await thread.ensurePersisted();
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

  void _loadPriority({
    _PriorityLoadProfile? profile,
    bool reloadAgenda = true,
  }) {
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

    // Watch the per-priority order timeline. Updates reflect immediately
    // in the next agenda rebuild; AgendaBuilder falls back to
    // priority.order for any priority that has no rows here.
    _priorityBlocksSubscription?.cancel();
    _priorityBlocksSubscription = streamPriorityBlocksGroupedByPriority().listen(
      (grouped) {
        _priorityBlocksByPriority = grouped;
      },
    );

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
          final iconCounts = [...counts]
            ..sort((a, b) => b.$2.compareTo(a.$2));
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
        primary: true,
      ).listen((actors) {
        log.fine('Priority actors updated: ${actors.length} actors');
        emit(state.copyWith(actors: actors));
      }),
    );

    if (reloadAgenda) {
      _agendaLimit = 50;
      _agendaHorizonDays = 90;
      _agendaFillDays = 0;
      _agendaSyncNoMore = false;
      _loadAgenda(profile: profile);
    }

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

  /// Loads draft from database for the given priority. Looks across the
  /// chain (ancestor / equal / descendant) so a draft started elsewhere in
  /// the branch follows the user as they navigate.
  /// Skips if the draft has already been modified by user actions to avoid
  /// overwriting user-initiated changes with stale DB state.
  Future<void> _loadDraft(Priority priority) async {
    final existingDraft = await Thread.getDraftInChain(priority);
    if (existingDraft != null) {
      if (_draftModified) return;

      // Load the corresponding draft note for this thread
      final draftNote = await Note.getDraftByActivity(existingDraft.id);

      if (isClosed) return;

      // Preserve the draft's filed priority — don't reassign to context.
      emit(
        state.copyWith(
          draft: existingDraft,
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
  }) async {
    // Convert the draft to a non-draft
    final savedThread = thread.copyWith(draft: false);

    // If the draft note carries a CreateLinkUserAction, stash a pending
    // create_link payload so ThreadsBase.toBase spreads it into the thread
    // push body. The server dispatches to the connector's onCreateLink once
    // the thread is titled and persisted.
    final createAction = note?.actions
        ?.whereType<CreateLinkUserAction>()
        .firstOrNull;
    if (createAction != null) {
      ThreadsBase.pendingCreateLinks[savedThread.id.toString()] = {
        'create_link': {
          'twist_instance_id': createAction.twistInstanceId,
          'channel_id': createAction.channelId,
          'type': createAction.linkType,
          'status': createAction.status,
        },
        if (note?.content != null) 'note_content': note!.content,
      };
    }

    await savedThread.save();

    // Convert draft note to published if provided. Tags on the note (including
    // self-assignment via Tag.todo) come from explicit user toggles in the
    // editor — never auto-applied here.
    if (note != null &&
        note.content != null &&
        note.content!.trim().isNotEmpty) {
      final publishedNote = note.copyWith(
        threadId: savedThread.id,
        draft: false,
      );
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

  void _loadAgenda({bool triggerSync = true, _PriorityLoadProfile? profile}) {
    final priorityToLoad = state.context;

    profile?.mark('_loadAgenda subscribe start');
    log.fine('Loading agenda for priority ${priorityToLoad.id}');
    _agendaSubscription?.cancel();
    var firstEmissionLogged = false;

    // Two streams are combined:
    // 1. Main agenda: threads across all priorities (no path filter), so
    //    every priority block is visible regardless of which priority
    //    page is active. The page [context] only determines which block
    //    is expanded by default, not which threads load.
    // 2. Associated threads: children of active thread associations.
    final dateRange = CustomBoundedDateRange(
      Date.today(),
      Date.today().addDays(_agendaHorizonDays),
    );
    final agendaStream = Thread.watch(
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

    _agendaSubscription =
        Rx.combineLatest2<
              ThreadWatchResult,
              List<Thread>,
              ThreadWatchResult
            >(agendaStream, associatedStream, (
              agendaResult,
              associatedThreads,
            ) {
              final agendaIds = agendaResult.threads.map((t) => t.id).toSet();

              // Merge associated threads that aren't already in the agenda.
              // Include any associated child whose parent event is visible
              // in the (now global) agenda.
              final visibleEventIds = agendaResult.threads
                  .where((t) => t.isLinkScheduleInstance || t.hasLinkSchedule)
                  .map((t) => t.id)
                  .toSet();
              final extra = associatedThreads.where((t) {
                if (agendaIds.contains(t.id)) return false;
                if (_associations != null) {
                  for (final entry in _associations!.entries) {
                    if (visibleEventIds.contains(entry.key) &&
                        entry.value.any((a) => a.childThreadId == t.id)) {
                      return true;
                    }
                  }
                }
                return false;
              }).toList();

              return (
                threads: [...agendaResult.threads, ...extra],
                rawRowCount: agendaResult.rawRowCount,
              );
            })
            .map((result) {
              // Compute a cheap signature so identical re-emissions can be
              // dropped before we pay the _makeAgenda cost. Drift streams
              // re-fire on every table change, so repeated syncs of unrelated
              // tables produce many identical emissions.
              final threadSig =
                  (result.threads
                          .map(
                            (t) =>
                                '${t.id}:${t.updatedAt.microsecondsSinceEpoch}'
                                ':${t.occurrence ?? ''}'
                                ':${t.isLinkScheduleInstance ? 1 : 0}'
                                ':${t.priority.path.value}',
                          )
                          .toList()
                        ..sort())
                      .join(',');
              final sig =
                  '${result.rawRowCount}|${result.threads.length}|$threadSig';
              return (sig, result);
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
            // throttleTime with leading: true emits the first event
            // immediately (no startup delay) while still coalescing the
            // burst of stream re-fires that follow a sync (each table
            // change re-fires the Drift stream). This was previously
            // debounceTime(100ms), which delayed the first agenda render
            // by ~100ms for no benefit on the initial emission.
            .throttleTime(
              const Duration(milliseconds: 100),
              leading: true,
              trailing: true,
            )
            .listen((result) {
              if (!firstEmissionLogged) {
                firstEmissionLogged = true;
                profile?.mark(
                  'first agenda stream emission (threads=${result.threads.length})',
                );
              }
              final threads = result.threads;

              final now = DateTime.now();

              // Per-thread optimistic overrides replace the earlier
              // time-based / pending-id suppressions: stream rows are patched
              // (or filtered) until the expected state is reflected, then the
              // override clears. Unrelated threads keep updating normally.
              final patchedThreads = _applyOptimisticOverrides(threads);

              // Data-driven suppression for reorders: keep reorderViewItems until
              // the stream data includes the reordered thread at its expected order.
              // Stale events are prevented by cancelling and restarting the
              // subscription in moveAgendaItem, so no time-based fallback is needed.
              final bool suppressReorder;
              if (_pendingReorderOrder != null) {
                final (threadId, expectedOrder) = _pendingReorderOrder!;
                final settled = patchedThreads.any(
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
                final stillTodo = patchedThreads.any(
                  (t) => t.id == childId && t.todo,
                );
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
                  suppressReorderTime;

              log.fine(
                '[_loadAgenda] stream fired: suppress=$suppressRebuild '
                '(reorder=$suppressReorder assoc=$suppressAssociation '
                'disassoc=$suppressDisassociation time=$suppressReorderTime) '
                'overrides=${_optimisticOverrides.length} '
                'reorderAge=${_reorderTimestamp != null ? now.difference(_reorderTimestamp!).inMilliseconds : "null"}ms '
                'pendingOrder=${_pendingReorderOrder?.$2} '
                'streamThreads=${threads.length} patched=${patchedThreads.length}',
              );

              if (suppressRebuild) {
                emit(
                  state.copyWith(
                    agendaDoneEnd: false,
                    agendaLoaded: true,
                  ),
                );
                return;
              }
              _lastAgendaThreads = patchedThreads;
              final buildStart = profile == null
                  ? null
                  : (Stopwatch()..start());
              final agenda = AgendaBuilder.build(
                threads: patchedThreads,
                context: priorityToLoad,
                horizonDays: _agendaHorizonDays,
                minFillDays: _agendaFillDays,
                associationsByParentId: _associations,
                priorityBlocksByPriority: _priorityBlocksByPriority,
              );
              if (buildStart != null) {
                profile?.mark(
                  'AgendaBuilder.build done in '
                  '${buildStart.elapsedMilliseconds}ms '
                  '(threads=${patchedThreads.length})',
                );
              }
              // Skip the emit when the rebuilt agenda matches what we
              // already have (e.g. background stream re-fires that don't
              // change visible content). bloc.emit's Equatable check
              // would handle this for us if `state.agenda` were the only
              // dirty field, but `agendaItems` references new Thread
              // instances on every patched-threads rebuild, so we
              // compare blocks structurally before paying the rebuild
              // cost downstream.
              if (agenda == state.agenda &&
                  state.agendaLoaded &&
                  state.reorderViewItems == null) {
                profile?.mark('agenda emit skipped (unchanged)');
                return;
              }
              emit(
                state.copyWith(
                  agenda: agenda,
                  agendaItems: agenda.flatItems(
                    contextPriorityId: state.context.id,
                  ),
                  agendaDoneEnd: false,
                  agendaLoaded: true,
                  reorderViewItems: const Value(null),
                ),
              );
              profile?.mark('agenda state emitted');
            });

    if (triggerSync) {
      _agendaSyncFuture = _triggerAgendaSync(priorityToLoad);
    }
  }

  bool get _effectiveShowArchived => state.showArchived;

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

          // Apply per-thread optimistic overrides so intermediate stream
          // snapshots (e.g. thread row written but user schedule not yet —
          // which derives todo=true even though the user just archived it)
          // don't flip the list back to a stale state. Unrelated threads
          // keep updating normally on every emission.
          final patchedThreads = _applyOptimisticOverrides(threads);

          // doneEnd when sync is complete AND either:
          // - raw rows are below limit (no more data), OR
          // - thread count hasn't grown despite limit increase (JOIN multiplication)
          final threadCountStalled =
              _activityFeedLimitIncreased &&
              _activityFeedSyncNoMore &&
              rawRowCount >= _activityFeedLimit &&
              patchedThreads.length ==
                  state.activityFeedItems
                      .whereType<AgendaThreadItem>()
                      .length &&
              patchedThreads.length < _activityFeedLimit;
          final isSearching = state.search.isNotEmpty;
          final doneEnd =
              (rawRowCount < _activityFeedLimit &&
                  (isSearching || _activityFeedSyncNoMore)) ||
              threadCountStalled;
          _activityFeedLimitIncreased = false;
          // Inject sticky threads that fell outside the SQL LIMIT
          // after being marked as read (unreadSort dropped 1→0,
          // pushing them past the LIMIT boundary).
          final allThreads = List<Thread>.from(patchedThreads);
          final threadIds = patchedThreads.map((t) => t.id).toSet();
          for (final entry in _stickyUnreadIds.entries.toList()) {
            if (threadIds.contains(entry.key)) {
              // Refresh cached thread with latest stream data
              _stickyUnreadIds[entry.key] = (
                urgencyRank: entry.value.urgencyRank,
                importance: entry.value.importance,
                activityAt: entry.value.activityAt,
                thread: patchedThreads.firstWhere((t) => t.id == entry.key),
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
  // Minimum days from today to populate with empty headers. Starts at 0
  // so [makeAgendaItems]'s 14-day buffer past the last-content date
  // dominates on the initial render. Grows in [fetchMoreAgendaItems] as
  // the user scrolls past the buffer so more empty days appear instead
  // of leaving the user on a stuck spinner.
  int _agendaFillDays = 0;
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
      // Stopwatch starts at the user-visible click time. Logs how long
      // didUpdateWidget's pre-setPriority work takes so the [PriorityProfile]
      // timeline covers the full click-to-threads window.
      final didUpdateSw = Stopwatch()..start();
      log.info(
        '[PriorityProfile][didUpdate:${widget.priorityId}] start',
      );
      _bloc.then((result) async {
        if (result.bloc == null) return;
        final priority = await Priority.getOne(widget.priorityId!);
        log.info(
          '[PriorityProfile][didUpdate:${widget.priorityId}] '
          'Priority.getOne done @ ${didUpdateSw.elapsedMilliseconds}ms',
        );
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
