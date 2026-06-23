import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:drift/drift.dart' hide Column;

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/state/activity_feed_drop.dart';
import 'package:plot/state/activity_feed_layout.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_builder.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/feed_navigation.dart';
import 'package:plot/state/order_repair.dart';
// Hide store.dart's `PriorityBlock` (the order-timeline class) so it
// doesn't shadow the agenda_model.dart `PriorityBlock` UI type already
// re-exported from this file. The row + top-level helpers
// (PriorityBlockRow, streamPriorityBlocksGroupedByPriority,
// effectivePriorityOrderAt) remain accessible.
import 'package:plot/store/store.dart' hide PriorityBlock;
// Bring the timeline class in under an alias for the few places we
// need to construct/save one.
import 'package:plot/store/store.dart' as store show PriorityBlock, Link;

// Re-export the agenda atom types so existing consumers that import
// `package:plot/state/priority.dart` still see them after their move
// to `agenda_model.dart`.
export 'package:plot/state/agenda_model.dart'
    show AgendaItem, AgendaHeaderItem, AgendaThreadItem;
import 'package:plot/util/async.dart';
import 'package:plot/util/draft.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/pending_send.dart';
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
  order,
  active,
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
      case _OverrideField.order:
        return actual.order.value == expected.order.value;
      case _OverrideField.active:
        return actual.active == expected.active;
    }
  }
}

/// Per-thread overlay entry for the activity feed's active tab. Mirrors
/// [_OptimisticOverride]'s expected-vs-watched semantics but also carries
/// tab-specific positioning hints so the merger can re-position
/// substituted rows (reorder/reschedule) and inject overlay-only rows
/// (sticky-unread that fell past LIMIT) without losing the SQL-driven
/// display order for everything else.
///
/// Lifecycle: the overlay map is owned by the active tab's subscription.
/// It is cleared on tab switch, filter/search/scope/icon change, priority
/// switch, or auto-settled (non-sticky entries) when the stream matches
/// the expected state on every watched field.
class _Overlay {
  const _Overlay({
    required this.expected,
    this.watched = _OptimisticOverride._defaultWatched,
    this.catchUpSortKeys,
    this.sticky = false,
  });

  /// Expect the thread to drop out of the active tab. Settled when the
  /// stream no longer returns it.
  const _Overlay.drop({
    Set<_OverrideField> watched = _OptimisticOverride._defaultWatched,
  }) : this(expected: null, watched: watched);

  /// Sticky-unread: a Catch up thread the user just opened should remain
  /// visible at its pre-read sort position while it is open. The snapshot
  /// is frozen as *read* (`unread: false`) so the unread dot clears the
  /// moment the thread is opened, while the entry's presence (matched via
  /// [PriorityBloc._isStickyPinned]) keeps the row pinned in the unread
  /// cluster regardless of that flag. Never auto-settles — cleared the
  /// moment the user navigates away ([PriorityBloc._removeSticky]) or by
  /// explicit triggers (tab switch, archive, drop-to-Done).
  factory _Overlay.stickyUnread(
    Thread thread, {
    required ({int urgent, int importance, DateTime activityAt}) sortKeys,
  }) => _Overlay(
    expected: thread.copyWith(unread: false),
    watched: const <_OverrideField>{},
    catchUpSortKeys: sortKeys,
    sticky: true,
  );

  final Thread? expected;
  final Set<_OverrideField> watched;
  final ({int urgent, int importance, DateTime activityAt})? catchUpSortKeys;
  final bool sticky;

  /// True when [actual] (the stream's copy, or null) makes this overlay
  /// safe to drop. Sticky entries never settle implicitly.
  bool settled(Thread? actual) {
    if (sticky) return false;
    if (expected == null) return actual == null;
    if (actual == null) return false;
    for (final field in watched) {
      if (!_OptimisticOverride._matches(field, actual, expected!)) return false;
    }
    return true;
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
  /// Live [PriorityBloc] instances. Multi-panel layout creates separate
  /// blocs for the priority page, the [LeftPanelAgendaView], and the
  /// thread page (`PriorityBlocProvider` per route + per panel). Each
  /// bloc has its own [_optimisticOverrides] and [_lastAgendaThreads],
  /// so without propagation only the originating bloc's agenda updates
  /// immediately on drag-to-Doing — peer blocs must wait for the Drift
  /// stream emission after save, which can be several seconds while
  /// the sync orchestrator is holding SQLite locks. Constructor adds,
  /// [close] removes; [applyActivityFeedThreadDrop] propagates its
  /// optimistic override to peers so every visible agenda updates in
  /// the same frame as the drop.
  static final Set<PriorityBloc> _allInstances = <PriorityBloc>{};

  ThreadHeaderNotifier? headerNotifier;

  /// Persisted scroll offsets for scroll restoration across route changes.
  double agendaScrollOffset = 0.0;
  double activityFeedScrollOffset = 0.0;

  /// Per-row [Thread.loadRepresentativeForFeed] cache. Without it, every
  /// `_ActivityFeedItem` reissues the schedule lookup in `initState`,
  /// producing N parallel Drift queries on first render and another batch
  /// each time an item rebuilds. Keyed by `(threadId, scheduleId,
  /// currentUserRsvp)` so a thread whose representative inputs change
  /// (recurring instance moved, RSVP changed) transparently re-resolves
  /// — these are the same fields the old `_ActivityFeedItem.didUpdateWidget`
  /// watched.
  final Map<(ThreadId, Uuid?, String?), Future<Thread?>> _representativeCache =
      {};

  /// Returns the cached `Thread.loadRepresentativeForFeed` Future for the
  /// given base thread, creating one on first access. Cache lifetime is
  /// the lifetime of the bloc — `close()` drops the map.
  Future<Thread?> loadRepresentativeForFeed(Thread base, {DateTime? now}) {
    final key = (base.id, base.scheduleId, base.currentUserRsvp);
    final existing = _representativeCache[key];
    if (existing != null) return existing;
    final future = Thread.loadRepresentativeForFeed(
      base,
      now: now ?? Time.now(),
    );
    _representativeCache[key] = future;
    return future;
  }

  PriorityBloc({
    required Priority priority,
    required NowBloc nowBloc,
    required LocalPreferencesBloc localPreferences,
    Thread? thread,
    bool everything = false,
  }) : _subscriptions = [],
       _threadSubscription = null,
       _agendaSubscription = null,
       _tagsSubscription = null,
       _reactionsSubscription = null,
       _draftModified = false,
       super(
         // Everything mode is the context-less view (invariant:
         // everything <=> context == null). The priority passed in becomes
         // the draft fallback so new threads still file under a real focus
         // (the app's default Inbox) even with no scoped context.
         PriorityState(
           context: everything ? null : priority,
           draftFallbackPriority: priority,
           thread: thread,
           everything: everything,
           // Seed from the single persisted archived-visibility flag so a
           // freshly opened focus honours a "Show archived items" toggle the
           // user already made elsewhere.
           showArchived: localPreferences.state.showAllPriorities,
         ),
       ) {
    _allInstances.add(this);
    _nowBloc = nowBloc;
    _loadPriority();
    _restartActiveTabSubscription();

    // React to the global archived-visibility flag so toggling it (via the
    // unified "Show archived items" command) flips this focus's archived
    // threads & notes too, regardless of where the toggle was triggered.
    _showArchivedFromPrefs = localPreferences.state.showAllPriorities;
    _localPreferencesSubscription = localPreferences.stream.listen((prefs) {
      if (prefs.showAllPriorities == _showArchivedFromPrefs) return;
      _showArchivedFromPrefs = prefs.showAllPriorities;
      _applyShowArchived(prefs.showAllPriorities);
    });

    // Seed pausedFocus from current NowBloc state immediately so the
    // first agenda build already has the sliding block if paused.
    final initialNow = nowBloc.state;
    if (initialNow is NowLoaded) {
      _pausedFocus = initialNow.pausedFocus;
      _lastNowForPaused = initialNow.now;
      // Seed the Event Agenda event too: PriorityPage only mirrors
      // currentEvent CHANGES, so a bloc freshly mounted for the event's
      // own focus would otherwise never learn about an already-selected
      // event. Ownership-gated — a foreign event stays out of this feed.
      _currentEventForFeed = eventAgendaEventFor(
        initialNow.currentEvent,
        priority.id,
      );
    }

    // Subscribe to NowBloc so the agenda re-builds when the paused-focus
    // state changes or when `now` advances while paused (sliding block).
    _nowSubscription = nowBloc.stream.listen((nowState) {
      if (nowState is! NowLoaded) return;
      final pausedChanged = nowState.pausedFocus != _pausedFocus;
      _pausedFocus = nowState.pausedFocus;
      // NowBloc ticks at 1-minute intervals while paused — rebuild so
      // the synthesized sliding block advances with `now`.
      final nowAdvanced = _pausedFocus != null &&
          nowState.now.difference(_lastNowForPaused).inSeconds >= 1;
      if (pausedChanged || nowAdvanced) {
        _lastNowForPaused = nowState.now;
        _rebuildAgendaModel();
      }
    });

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

  /// Mirror of [NowBloc.everything] for this bloc. The priority page calls
  /// this whenever the user switches between a scoped focus/Inbox view and
  /// the synthetic "Everything" feed, so the activity-feed query re-scopes
  /// (unscoped when true) and renders one unsectioned list. No-op when
  /// unchanged.
  void setEverything(bool everything) {
    if (state.everything == everything) return;
    log.info('Setting everything feed mode to $everything');
    // The default Inbox the draft falls back to with no scoped context. The
    // raw priorities watch ([_priorityById]) is the cheapest in-hand list;
    // fall back to the current context / existing draft priority before the
    // watch warms.
    final inbox = Priority.defaultInbox(_priorityById.values.toList()) ??
        state.context ??
        state.draft.priority;
    if (everything) {
      // Enter Everything: drop the scoped context (invariant) and re-aim the
      // draft at the Inbox fallback so a new thread started from Everything
      // files there rather than under the focus we just left.
      emit(
        state.copyWith(
          context: const Value(null),
          everything: true,
          draft: Thread(priority: inbox, draft: true),
        ),
      );
    } else {
      // Leave Everything: restore a non-null context to satisfy the
      // invariant. A following [setPriority] swaps in the actual focus the
      // user navigated to; the Inbox fallback covers the gap.
      emit(
        state.copyWith(
          context: Value(inbox),
          everything: false,
          draft: Thread(priority: inbox, draft: true),
        ),
      );
    }
    _restartActiveTabSubscription();
  }

  /// Narrow (or un-narrow) the active global view — search or filter — to a
  /// focus. `null` means "Everything" (the full global result set); the root
  /// scopes to the Inbox (unfiled matches); any other focus scopes to that
  /// focus. The global-view sidebar calls this when the user taps Everything /
  /// Inbox / a focus, so results narrow in place WITHOUT route navigation —
  /// the search text and filter chips stay active. This is a DISPLAY-only
  /// filter ([PriorityState.activityFeedViewItems] applies it); the global
  /// query is unchanged, so no subscription restart is needed and the sidebar
  /// keeps listing every focus with a match. No-op when unchanged.
  void setGlobalViewScope(Priority? scope) {
    if (state.globalViewScope?.id == scope?.id) return;
    log.info('Setting global-view scope to ${scope?.title ?? 'Everything'}');
    // Narrowing/widening the global view changes the visible rows — clear any
    // multi-selection so it can't carry across to a different result set.
    emit(state.copyWith(
      globalViewScope: Value(scope),
      selected: const {},
      selectionAnchor: const Value(null),
    ));
  }

  /// Applies a new archived-visibility value, driven by the global
  /// `showAllPriorities` flag on [LocalPreferencesBloc]. No-ops when the value
  /// is unchanged so unrelated preference emissions don't trigger reloads.
  void _applyShowArchived(bool showArchived) {
    if (state.showArchived == showArchived) return;
    log.info('Applying showArchived = $showArchived');
    emit(state.copyWith(showArchived: showArchived));

    // Reload agenda items with new archived filter
    _loadPriority();
    _restartActiveTabSubscription();

    // If a search is active, rerun the remote search so its archived
    // scope matches and the archived-match hint is re-evaluated.
    if (state.search.isNotEmpty) {
      _runRemoteSearch(state.search);
    }
  }

  /// Toggle the "Muted only" filter on the unified feed. When on, the
  /// activity feed shows only threads filed under a "Skip active for
  /// threads like this" rule, letting the user find and un-mute them.
  /// Available in the regular (non-archived) view since muted threads
  /// live in Done, not Archive.
  void toggleMuteOnly() {
    final next = !state.muteOnly;
    log.info('Toggling muteOnly to $next');
    // The muted-only filter changes which rows are visible — clear selection.
    emit(state.copyWith(
      muteOnly: next,
      selected: const {},
      selectionAnchor: const Value(null),
    ));
    _loadPriority();
    _restartActiveTabSubscription();
  }

  void updateUnreadFilter(bool active) {
    if (state.unreadFilterActive == active) return;
    log.info('Updating unread filter to $active');
    emit(state.copyWith(unreadFilterActive: active));
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    // Reset the global-view focus scope when this leaves no global view active
    // (no search and no other filter), so the next view starts at Everything.
    final willBeGlobal = filter.isNotEmpty ||
        state.search.isNotEmpty ||
        state.reactionFilter.isNotEmpty ||
        state.iconFilter.isNotEmpty;
    emit(state.copyWith(
      filter: filter,
      globalViewScope: willBeGlobal ? const Value.absent() : const Value(null),
    ));

    // When filtering, force navigation to use activityFeed (matches UI)
    if (filter.isNotEmpty) {
      threadListSource = ThreadListSource.activityFeed;
    } else {
      threadListSource = null;
    }

    // The agenda is universal and ignores filters; only the activity
    // feed needs to refresh.
    _loadPriority(reloadAgenda: false);
    _restartActiveTabSubscription();
  }

  void updateReactionFilter(List<Reaction> reactionFilter) {
    log.info('Updating reaction filter to $reactionFilter');
    final willBeGlobal = reactionFilter.isNotEmpty ||
        state.search.isNotEmpty ||
        state.filter.isNotEmpty ||
        state.iconFilter.isNotEmpty;
    emit(state.copyWith(
      reactionFilter: reactionFilter,
      globalViewScope: willBeGlobal ? const Value.absent() : const Value(null),
    ));

    if (reactionFilter.isNotEmpty) {
      threadListSource = ThreadListSource.activityFeed;
    } else if (state.filter.isEmpty) {
      threadListSource = null;
    }

    _loadPriority(reloadAgenda: false);
    _restartActiveTabSubscription();
  }

  void updateIconFilter(String iconValue) {
    final current = List<String>.from(state.iconFilter);
    if (current.contains(iconValue)) {
      current.remove(iconValue);
    } else {
      current.add(iconValue);
    }
    log.info('Updating icon filter to $current');
    final willBeGlobal = current.isNotEmpty ||
        state.search.isNotEmpty ||
        state.filter.isNotEmpty ||
        state.reactionFilter.isNotEmpty;
    emit(state.copyWith(
      iconFilter: current,
      globalViewScope: willBeGlobal ? const Value.absent() : const Value(null),
    ));

    // The agenda is universal and ignores filters; only the activity
    // feed needs to refresh.
    _loadPriority(reloadAgenda: false);
    _restartActiveTabSubscription();
  }

  void updateAssigneeFilter(List<ActorId> assigneeFilter) {
    log.info('Updating assignee filter to $assigneeFilter');
    final willBeGlobal = assigneeFilter.isNotEmpty ||
        state.search.isNotEmpty ||
        state.filter.isNotEmpty ||
        state.reactionFilter.isNotEmpty ||
        state.iconFilter.isNotEmpty;
    emit(state.copyWith(
      assigneeFilter: assigneeFilter,
      globalViewScope: willBeGlobal ? const Value.absent() : const Value(null),
    ));

    if (assigneeFilter.isNotEmpty) {
      threadListSource = ThreadListSource.activityFeed;
    } else if (state.filter.isEmpty &&
        state.reactionFilter.isEmpty &&
        state.iconFilter.isEmpty) {
      threadListSource = null;
    }

    // The agenda is universal and ignores filters; only the activity
    // feed needs to refresh.
    _loadPriority(reloadAgenda: false);
    _restartActiveTabSubscription();
  }

  /// Called immediately on every keystroke to update search text in state
  /// and cancel stale subscriptions so old results stop flowing.
  void prepareSearch(String search) {
    if (state.search == search) return;
    // Invalidate any in-flight remote search so its response is discarded.
    _searchGeneration++;
    // Drop the global-view focus scope when clearing search leaves no global
    // view active (no filter armed), so the next search starts at Everything.
    // Preserved across keystrokes within a search, and while a filter keeps
    // the global view alive.
    final willBeGlobal = search.isNotEmpty || _hasActiveFilter;
    emit(
      state.copyWith(
        search: search,
        remoteSearchExtras: const [],
        remoteSearchInProgress: false,
        remoteSearchOffline: false,
        hasArchivedMatches: false,
        globalViewScope: willBeGlobal ? const Value.absent() : const Value(null),
      ),
    );

    // When searching, force navigation to use activityFeed (matches UI)
    if (search.isNotEmpty) {
      threadListSource = ThreadListSource.activityFeed;
      // Cancel the active per-tab subscription so unfiltered results
      // don't flash. The agenda subscription is intentionally left
      // alone — the agenda is universal and search never narrows it.
      _activeTabSubscription?.cancel();
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

    // The agenda doesn't react to search — only the activity feed does.
    _restartActiveTabSubscription();

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

    // Header search is global for now — no priority scoping. We may
    // reintroduce a priority-specific search affordance later.

    // 1) Main search: hydrate matching threads into the local store and stash
    //    the ones that weren't already visible as "extras".
    unawaited(() async {
      try {
        final threads = await Thread.searchRemote(
          search,
          archived: showArchived,
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
          final count = await Thread.searchRemoteCount(search, archived: true);
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

  /// Monotonic counter incremented at the top of every [setPriority]. Post-await
  /// emits inside [setPriority] and [_finalizeDraftInBackground] check this so
  /// that a B→C switch in mid-flight cancels A→B's pending draft emit.
  int _priorityLoadGeneration = 0;

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

  /// Per-thread overlay for the active activity-feed tab. See [_Overlay].
  /// Cleared on tab/filter/search/scope/priority change — anything that
  /// re-fires the per-tab SQL query. The legacy [_optimisticOverrides]
  /// continues to serve the agenda; this map serves only the per-tab
  /// activity feed.
  final Map<ThreadId, _Overlay> _overlay = {};

  /// Whether [id] currently has a sticky-unread overlay entry — the open
  /// thread the user just read holds its position in the unread cluster
  /// (with the dot already cleared) until they navigate away.
  bool _isStickyPinned(ThreadId id) => _overlay[id]?.sticky ?? false;

  /// Whether two snapshots of a thread occupy the same feed position
  /// (section + slot): used to decide if an optimistic update may keep a
  /// sticky-unread pin alive.
  static bool _samePosition(Thread a, Thread b) =>
      a.todo == b.todo &&
      a.active == b.active &&
      a.on == b.on &&
      a.at == b.at &&
      a.order.compareTo(b.order) == 0 &&
      a.priority.id == b.priority.id &&
      a.archivedAt == b.archivedAt;

  /// Monotonic generation for explicit user state-change rebuilds of the
  /// sectioned feed. Stamped onto [ActivityFeedTabData.moveGen]; the page
  /// animates the items diff (collapse at source / expand at destination)
  /// when it advances. Stream-driven rebuilds never advance it.
  int _feedMoveGen = 0;

  /// The thread ids that produced [_feedMoveGen]'s generation. Kept (not
  /// recomputed) so a follow-up rebuild in the same frame — e.g. the
  /// sticky-unread pin written by [setThread] right after a state change
  /// navigates — re-emits the SAME gen+ids pair. Emitting the gen with an
  /// empty id set would make the page's diff treat the moved row as
  /// stable-but-reordered and bail out of the animation.
  Set<ThreadId> _feedMovedIds = const {};

  /// Threads whose state the user explicitly changed since the last
  /// sectioned-feed rebuild; consumed (and cleared) by
  /// [_rebuildActiveTabSection].
  final Set<ThreadId> _pendingMoveIds = {};

  /// Flag [id] as explicitly state-changed by the user so the next
  /// sectioned-feed rebuild animates its repositioning. Flat feeds
  /// (Everything / search / filter) never reposition on state changes, so
  /// this is a no-op there. Drag-and-drop deliberately does NOT mark —
  /// the drag's own visuals already animate the move.
  void markFeedMove(ThreadId id) {
    if (_activeTabFlatMode) return;
    _pendingMoveIds.add(id);
  }

  /// Live subscription for the currently-active activity-feed tab's
  /// per-tab query. Started in [_restartActiveTabSubscription], cancelled
  /// and re-started on tab / filter / scope / priority changes. `null`
  /// when the active tab is still on the legacy dual-stream path
  /// (transitional state during the per-tab migration).
  StreamSubscription<void>? _activeTabSubscription;

  /// Which tab the [_activeTabSubscription] is currently feeding. `null`
  /// when the active tab still routes through the legacy build.
  ActivityTab? _activeTabSubscriptionTab;

  /// Head emission for the active per-tab subscription. Replaced wholesale
  /// on every stream fire.
  List<Thread> _activeTabHead = const [];
  bool _activeTabHeadSaturated = false;

  /// Set to false in [_restartActiveTabSubscription] and flipped to true on
  /// the first emission from a per-tab head subscription. Gates
  /// [_rebuildActiveTabSection] so that adjacent subscriptions (notably
  /// [_associationsSubscription], which fires on any priority reload) can't
  /// publish an empty "loaded" state during the race window before the new
  /// tab-head query yields. Without this, opening then immediately closing
  /// search would briefly flash the activity feed's empty-state text.
  bool _activeTabHeadReceived = false;

  /// Static append pages beyond the head for the active per-tab
  /// subscription. Filled by [fetchMoreActivityFeedItems] via the per-tab
  /// `fetch*Page` method that matches [_activeTabSubscriptionTab].
  List<Thread> _activeTabAppended = const [];
  bool _activeTabAppendsExhausted = false;
  Future<void>? _activeTabAppendInFlight;
  int _activeTabAppendGeneration = 0;

  /// True while the active feed is in flat (search / filter / icon) mode,
  /// which renders a single unsectioned list from one [Thread.watchAllTabHead]
  /// query. When false the feed is sectioned and fed by three merged section
  /// streams (Unread / Active+Scheduled / Done). Pagination dispatches on
  /// this: flat pages the all-tab query; sectioned pages the Done stream.
  bool _activeTabFlatMode = false;

  /// Flat-mode (Everything / search / filter / icon) head + append cursors
  /// for the single unified query, ordered purely by `activity_at` like the
  /// Done section. Unused in sectioned mode.
  ({String activityAt, ThreadId id})? _allTabHeadTailCursor;
  ({String activityAt, ThreadId id})? _allTabAppendCursor;

  /// Sectioned-mode Done head + append cursors. Only the Done section
  /// paginates on scroll; Unread and Active+Scheduled are loaded whole at a
  /// generous limit (they're bounded), so they carry no cursor.
  ({String activityAt, ThreadId id})? _doneHeadTailCursor;
  ({String activityAt, ThreadId id})? _doneAppendCursor;

  /// Latest threads list emitted by the agenda subscription (after
  /// optimistic overrides). Optimistic mutation handlers transform
  /// this list and call [_rebuildAgendaModel] to derive a fresh
  /// [AgendaModel] without re-running the agenda DB query.
  List<Thread> _lastAgendaThreads = const [];

  /// Latest todos/associated emissions captured by the agenda
  /// subscription's `combineLatest3` callback. When `_loadAgenda`
  /// re-subscribes (e.g. on `fetchMoreAgendaItems` to widen the LIMIT
  /// or horizon), the new `todosStream` and `associatedStream` use
  /// these as their `startWith` seeds. Without them the leading
  /// throttle emission would briefly contain events-only data —
  /// dropping todos and associated children — and the agenda would
  /// collapse from N items to a handful for ~100ms. On cold start
  /// they're the empty defaults, matching the original cold-start
  /// behavior (let combineLatest fire on eventsStream alone).
  ThreadWatchResult _seedTodosResult = const (
    threads: <Thread>[],
    rawRowCount: 0,
    feedTailCursor: null,
  );
  List<Thread> _seedAssociatedThreads = const <Thread>[];

  /// Rebuild the agenda model from the cached threads list and emit
  /// it. Optional [extra] state-shape changes (e.g. updated activity
  /// feed, cleared selected thread) are layered onto the same emit.
  ///
  /// Also re-emits the active tab's items via [_rebuildActiveTabSection]
  /// when a per-tab subscription is feeding the active tab. Callers that
  /// just wrote to [_overlay] don't need a separate trigger.
  void _rebuildAgendaModel({
    Value<Thread?> thread = const Value.absent(),
    Map<ActivityTab, ActivityFeedTabData>? activityFeedByTab,
  }) {
    final agenda = AgendaBuilder.build(
      threads: _lastAgendaThreads,
      // The agenda needs a real priority for its [isOutside] dimming; with no
      // scoped context (Everything) use the draft's Inbox fallback, matching
      // the focus the Everything feed files into.
      context: state.context ?? state.draft.priority,
      horizonDays: _agendaHorizonDays,
      minFillDays: _agendaFillDays,
      associationsByParentId: _associations,
      priorityBlocksByPriority: _priorityBlocksByPriority,
      priorityById: _priorityById,
      pausedFocus: _pausedFocus == null
          ? null
          : (
              priority: _pausedFocus!.priority,
              remaining: _pausedFocus!.remaining,
            ),
    );
    emit(
      state.copyWith(
        thread: thread,
        agenda: agenda,
        agendaItems: agenda.flatItems(),
        activityFeedByTab: activityFeedByTab,
      ),
    );
    if (_activeTabSubscriptionTab != null) {
      _rebuildActiveTabSection();
    }
  }

  /// Finds a thread from the current state so callers that only have an id
  /// can build an expected-state override. Searches the activity feed first
  /// (where todo changes originate for the bug this fixes) then the agenda.
  Thread? _findThreadInState(ThreadId id) {
    for (final item in state.activityFeedItems) {
      final thread = item.when(header: (_) => null, activity: (a) => a.thread);
      if (thread != null && thread.id == id) return thread;
    }
    for (final section in state.agenda.sections) {
      for (final block in section.blocks) {
        for (final thread in block.threads) {
          if (thread.id == id) return thread;
        }
      }
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

  /// Cancel any running per-tab subscription and reset per-tab state, then
  /// start the subscription for the now-active tab if it has been migrated.
  /// Call on every event that changes what the per-tab SQL query would
  /// return: tab switch, filter/icon/search/scope change, priority switch.
  void _restartActiveTabSubscription() {
    _activeTabSubscription?.cancel();
    _activeTabSubscription = null;
    _activeTabSubscriptionTab = null;
    _activeTabHead = const [];
    _activeTabAppended = const [];
    _activeTabHeadSaturated = false;
    _activeTabAppendsExhausted = false;
    _activeTabAppendGeneration++;
    _activeTabHeadReceived = false;
    _allTabHeadTailCursor = null;
    _allTabAppendCursor = null;
    _doneHeadTailCursor = null;
    _doneAppendCursor = null;
    _overlay.clear();
    _pendingMoveIds.clear();

    // Unified feed: a single subscription returns every visible thread.
    // The section structure (Updates / Doing / Scheduled / Activity) is
    // applied client-side in _rebuildActiveTabSection.
    _subscribeAllTabHead();
  }

  /// True when any header filter chip (tag, reaction, or thread type) is
  /// armed. Filters query globally — like search — so an armed filter both
  /// unscopes the feed ([_feedScope]) and renders it as one flat list.
  bool get _hasActiveFilter =>
      state.filter.isNotEmpty ||
      state.reactionFilter.isNotEmpty ||
      state.iconFilter.isNotEmpty ||
      state.assigneeFilter.isNotEmpty;

  /// Resolve the `priorityId` scope for the activity-feed queries. The scope
  /// is path-independent: the server filters by `priority_id` and the local
  /// Drift filter scopes on the thread's filed `priority_id`. Flat-focus
  /// rules:
  ///   • Everything → null: every thread, unscoped.
  ///   • Root (Inbox) → exact `priorityId` so only unfiled threads show; the
  ///     synthetic Everything view is the way to see all of them at once.
  ///     Searching from the root still goes global (null).
  ///   • A focus → exact `priorityId`. Focuses are leaves in the flat model,
  ///     so the former path scope (`showSubPriorities` / event agenda) was an
  ///     exact filed-priority match too — id is the same scope.
  ///   • A global view (active search or any active filter) → null, so results
  ///     are global no matter which focus was selected. Narrowing to a focus
  ///     is a display-only concern driven by [globalViewScope] (see
  ///     [PriorityState.activityFeedViewItems]); the underlying query stays
  ///     global so the focus-as-filter sidebar can keep listing every focus
  ///     with a match and the user can switch the narrow without re-querying.
  PriorityId? _feedScope() {
    if (state.search.isNotEmpty || _hasActiveFilter) {
      return null;
    }
    // The dedicated (non-search) Everything feed is also global. Past this
    // guard the invariant guarantees a non-null context, but read it
    // null-safely regardless.
    if (state.everything) {
      return null;
    }
    return state.context?.id;
  }

  void _subscribeAllTabHead() {
    final isSearching = state.search.isNotEmpty;
    final priorityId = _feedScope();
    // "Show archived items" is a superset toggle: when on, show active AND
    // archived (null = no archived filter); when off, active only.
    final bool? archived = state.showArchived ? null : false;
    final filter = state.filter.isNotEmpty ? state.filter : null;
    final reactionFilter =
        state.reactionFilter.isNotEmpty ? state.reactionFilter : null;
    final iconFilter = state.iconFilter.isNotEmpty ? state.iconFilter : null;
    final assigneeFilter =
        state.assigneeFilter.isNotEmpty ? state.assigneeFilter : null;
    final search = isSearching ? state.search : null;

    // Flat mode (Everything / search / filter / icon) renders one unsectioned
    // list ordered purely by `activity_at` (like the Done section), so a
    // single query is both correct and cheaper. Sectioned mode runs three
    // independently-sorted streams so the bounded Unread / Active+Scheduled
    // sets always surface regardless of how deep the Done tail is — the bug
    // this fixes was active threads being buried past the LIMIT of a single
    // `activity_at`-ordered page at rolled-up priorities.
    final flatMode =
        state.everything || state.search.isNotEmpty || _hasActiveFilter;

    _activeTabSubscriptionTab = ActivityTab.all;
    _activeTabFlatMode = flatMode;

    if (flatMode) {
      _activeTabSubscription = Thread.watchAllTabHead(
        priorityId: priorityId,
        archived: archived,
        filter: filter,
        reactionFilter: reactionFilter,
        iconFilter: iconFilter,
        assigneeFilter: assigneeFilter,
        search: search,
        limit: _activityFeedLimit,
      ).listen((result) async {
        if (isClosed) return;
        _activeTabHead = result.threads;
        _activeTabHeadSaturated = result.saturated;
        _allTabHeadTailCursor = result.tailCursor;
        // Warm the channel-breadcrumb links for these threads before the feed
        // swaps in, so rows don't render headerless for a frame mid-switch.
        // Mark `received` only after priming (gating adjacent rebuilds off the
        // cold cache); a prime failure must not wedge the feed, so proceed.
        try {
          await store.Link.primeForThreads(result.threads.map((t) => t.id));
        } catch (e, st) {
          Tracker.captureException(e, st);
        }
        if (isClosed) return;
        _activeTabHeadReceived = true;
        _rebuildActiveTabSection();
        _firePendingFeedSync();
      });
      return;
    }

    // Sectioned mode: merge the three section streams into a single head
    // list, deduped by id (streams are mutually exclusive on the stored
    // unread/active booleans, so a dupe only appears for a single frame
    // mid-transition — keeping the first occurrence pins it stably). Only
    // the Done stream paginates; its tail cursor drives [_fetchMoreDone].
    _activeTabSubscription = Rx.combineLatest3<
        ({
          List<Thread> threads,
          ({int urgent, int importance, double order, ThreadId id})? tailCursor,
          bool saturated,
        }),
        ({
          List<Thread> threads,
          ({int isActiveInv, String bucketKey, double order, ThreadId id})?
              tailCursor,
          bool saturated,
        }),
        ({
          List<Thread> threads,
          ({String activityAt, ThreadId id})? tailCursor,
          bool saturated,
        }),
        ({
          List<Thread> threads,
          ({String activityAt, ThreadId id})? doneCursor,
          bool doneSaturated,
        })>(
      Thread.watchUnreadHead(
        priorityId: priorityId,
        archived: archived,
        reactionFilter: reactionFilter,
        limit: _boundedSectionLimit,
      ),
      Thread.watchActionTabHead(
        action: 'active',
        sectionScope: 'active',
        priorityId: priorityId,
        archived: archived,
        reactionFilter: reactionFilter,
        limit: _boundedSectionLimit,
      ),
      Thread.watchDoneHead(
        priorityId: priorityId,
        archived: archived,
        reactionFilter: reactionFilter,
        limit: _activityFeedLimit,
      ),
      (unread, active, done) {
        final seen = <ThreadId>{};
        final merged = <Thread>[];
        for (final t in unread.threads) {
          if (seen.add(t.id)) merged.add(t);
        }
        for (final t in active.threads) {
          if (seen.add(t.id)) merged.add(t);
        }
        for (final t in done.threads) {
          if (seen.add(t.id)) merged.add(t);
        }
        return (
          threads: merged,
          doneCursor: done.tailCursor,
          doneSaturated: done.saturated,
        );
      },
    ).listen((result) async {
      if (isClosed) return;
      _activeTabHead = result.threads;
      _activeTabHeadSaturated = result.doneSaturated;
      _doneHeadTailCursor = result.doneCursor;
      // Warm the channel-breadcrumb links for these threads before the feed
      // swaps in, so rows don't render headerless for a frame mid-switch.
      // Mark `received` only after priming (gating adjacent rebuilds off the
      // cold cache); a prime failure must not wedge the feed, so proceed.
      try {
        await store.Link.primeForThreads(result.threads.map((t) => t.id));
      } catch (e, st) {
        Tracker.captureException(e, st);
      }
      if (isClosed) return;
      _activeTabHeadReceived = true;
      _rebuildActiveTabSection();
      _firePendingFeedSync();
    });
  }

  /// Recompose the active tab's items list from the per-tab subscription's
  /// head + appended pages, applying the overlay (substitute / drop /
  /// sticky-unread injection). Emits a state update that overrides
  /// `activityFeedByTab[activeTab]` while leaving the legacy data for
  /// other tabs intact.
  void _rebuildActiveTabSection() {
    final tab = _activeTabSubscriptionTab;
    if (tab == null) return;
    // The tab-head subscription owns the ground-truth `_activeTabHead` for
    // the active filter set; until it emits, any rebuild kicked off by an
    // adjacent stream (associations, event-agenda updates, etc.) would
    // publish stale or empty data labeled as `activityFeedLoaded: true`.
    // Skip those — the tab-head listener will call us once data is in.
    if (!_activeTabHeadReceived) return;

    final combined = <Thread>[..._activeTabHead, ..._activeTabAppended];
    final merged = _applyOverlay(combined, tab);

    final eventPrefix = _buildEventAgendaItems();

    // Search / filter mode: flat list, no sections (per spec).
    final flatMode =
        state.everything || state.search.isNotEmpty || _hasActiveFilter;

    final List<AgendaItem> items;
    Set<ThreadId> unreadClusterIds = const {};
    if (flatMode) {
      items = <AgendaItem>[
        ...eventPrefix,
        for (final t in merged) AgendaThreadItem(t),
      ];
    } else {
      final built = _buildUnifiedFeedItems(merged, eventPrefix);
      items = built.items;
      unreadClusterIds = built.unreadClusterIds;
    }

    final byTab = Map<ActivityTab, ActivityFeedTabData>.from(
      state.activityFeedByTab,
    );
    // Tag the data with whether it's the dedicated Everything feed (everything
    // mode, no search/filter). The page leads with the "Everything" header
    // based on THIS flag, not the live `state.everything`, so the header and
    // the items flip together — never an "Everything" header over the old
    // sectioned focus list during the frame between the flag changing and the
    // feed rebuilding.
    final everythingFeed =
        state.everything && state.search.isEmpty && !_hasActiveFilter;
    // Consume pending explicit-state-change marks: advance the move
    // generation so the page animates this rebuild's diff. Flat feeds
    // never reposition on state changes, so marks are dropped there.
    if (_pendingMoveIds.isNotEmpty) {
      if (!_activeTabFlatMode) {
        _feedMoveGen++;
        _feedMovedIds = Set.unmodifiable(Set.of(_pendingMoveIds));
      }
      _pendingMoveIds.clear();
    }
    byTab[tab] = ActivityFeedTabData(
      items: items,
      everythingFeed: everythingFeed,
      context: state.context,
      moveGen: _feedMoveGen,
      movedIds: _feedMovedIds,
      unreadClusterIds: unreadClusterIds,
    );
    emit(
      state.copyWith(
        activityFeedByTab: byTab,
        activityFeedDoneEnd: _computeActiveTabDoneEnd(),
        activityFeedLoaded: true,
      ),
    );
    // Auto-off: if the filter is on but nothing is unread any more (e.g. the
    // last unread was read on another device and synced in), release it so we
    // never show an empty filtered feed behind a disabled toggle.
    if (state.unreadFilterActive && !state.hasUnread) {
      emit(state.copyWith(unreadFilterActive: false));
    }
  }

  /// Build the unified feed: Doing → Scheduled (per-day) → Activity.
  /// Active to-dos hold their `order` position (read and unread intermixed).
  /// Non-active unread threads cluster at the BOTTOM of Doing (urgent,
  /// importance, order) and drain to Activity (Done) once read and navigated
  /// away from. Scheduled unread threads stay in their date slot.
  ///
  /// Returns both the item list and the set of thread ids that make up the
  /// non-active unread cluster (for source-aware drop boundaries).
  ({List<AgendaItem> items, Set<ThreadId> unreadClusterIds})
  _buildUnifiedFeedItems(
    List<Thread> merged,
    List<AgendaItem> eventPrefix,
  ) {
    final doingEligible = <Thread>[];   // active to-dos + bottom unread cluster
    final scheduled = <Thread>[];
    final activity = <Thread>[];

    for (final t in merged) {
      if (t.isActiveThread) {
        doingEligible.add(t);            // active to-dos stay in place (incl. unread)
        continue;
      }
      if (t.isScheduledThread) {
        scheduled.add(t);                // scheduled stays in place (incl. unread)
        continue;
      }
      if (t.unread || _isStickyPinned(t.id)) {
        doingEligible.add(t);            // non-active unread → bottom cluster
        continue;
      }
      activity.add(t);                   // read, non-active → Done
    }

    final split = splitDoingSection(doingEligible);

    // Scheduled: bucket date ASC, then state_order, then id.
    scheduled.sort((a, b) {
      final aDate = a.on?.start ?? a.at?.start?.toDate() ?? Date.today();
      final bDate = b.on?.start ?? b.at?.start?.toDate() ?? Date.today();
      final dateCmp = aDate.compareTo(bDate);
      if (dateCmp != 0) return dateCmp;
      final orderCmp = a.order.compareTo(b.order);
      if (orderCmp != 0) return orderCmp;
      return a.id.toString().compareTo(b.id.toString());
    });

    // Activity: activity_at DESC, id DESC. Matches the Phase-1 SQL's
    // `MAX(lastNoteSourceCreatedAt, linkSourceCreatedAt, bumpedAt,
    // pastScheduleEnd)` (see [Thread.activityAt]) so threads bumped via
    // read / done transitions land at the top, then stay in stable
    // order as new entries arrive above them. The in-memory sort is
    // load-bearing only for overlay-substituted rows whose live
    // `activityAt` differs from the SQL snapshot.
    activity.sort((a, b) {
      final at = b.activityAt.compareTo(a.activityAt);
      if (at != 0) return at;
      return b.id.toString().compareTo(a.id.toString());
    });

    final items = <AgendaItem>[...eventPrefix];

    // Doing header is emitted only when the section has threads, so an
    // empty Active section doesn't render a floating header (e.g. when the
    // feed contains only Done threads).
    if (split.active.isNotEmpty || split.unreadCluster.isNotEmpty) {
      items.add(
        AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
      );
      for (final t in split.active) {
        items.add(AgendaThreadItem(t));
      }
      for (final t in split.unreadCluster) {
        items.add(AgendaThreadItem(t));
      }
    }

    // Scheduled: per-day headers.
    Date? lastBucket;
    for (final t in scheduled) {
      final date = t.on?.start ?? t.at?.start?.toDate() ?? Date.today();
      if (lastBucket == null || lastBucket != date) {
        items.add(
          AgendaHeaderItem(
            date: date,
            text: ActivitySectionMarker.encode(
              ActivitySection.scheduled,
              label: relativeDateLabel(date),
            ),
          ),
        );
        lastBucket = date;
      }
      items.add(AgendaThreadItem(t));
    }

    if (activity.isNotEmpty) {
      items.add(
        AgendaHeaderItem(
          text: ActivitySectionMarker.encode(ActivitySection.activity),
        ),
      );
      for (final t in activity) {
        items.add(AgendaThreadItem(t));
      }
    }

    final clusterIds = {for (final t in split.unreadCluster) t.id};
    return (items: items, unreadClusterIds: clusterIds);
  }

  /// Apply the activity-feed overlay to a per-tab SQL result. Substitutes
  /// or drops rows that have overlay entries; for Catch up, also injects
  /// overlay entries whose expected thread is missing from the SQL result
  /// (sticky-unread rows that fell past the LIMIT after being marked read)
  /// and re-sorts via the catch-up comparator so cached pre-read sort
  /// keys keep the row pinned at its original position.
  List<Thread> _applyOverlay(List<Thread> sqlThreads, ActivityTab tab) {
    if (_overlay.isEmpty) return sqlThreads;

    final byId = <ThreadId, Thread>{};
    for (final t in sqlThreads) {
      byId[t.id] = t;
    }

    _overlay.removeWhere((id, o) => o.settled(byId[id]));
    if (_overlay.isEmpty) return sqlThreads;

    final patched = <Thread>[];
    for (final thread in sqlThreads) {
      final o = _overlay[thread.id];
      if (o == null) {
        patched.add(thread);
      } else if (o.expected == null) {
        continue;
      } else {
        patched.add(o.expected!);
      }
    }

    // `tab` is always [ActivityTab.unified] (the enum collapsed to one value;
    // `catchUp`/`all`/… are aliases), so this branch always runs. Re-inject
    // sticky overlay entries whose live row fell past the SQL LIMIT, then
    // re-sort. The flat feed (Everything / search / filter / icon) must keep
    // the pure-recency order its SQL produces; sectioned mode re-buckets
    // afterward, so its within-bucket order follows the catch-up keys.
    for (final entry in _overlay.entries) {
      if (entry.value.expected != null && !byId.containsKey(entry.key)) {
        patched.add(entry.value.expected!);
      }
    }
    patched.sort(_activeTabFlatMode ? _flatFeedCompare : _catchUpCompare);

    return patched;
  }

  /// Mirror of the flat feed's SQL `ORDER BY activity_at DESC, id DESC`
  /// ([Thread.watchAllTabHead]). Used to re-place overlay substitutions and
  /// injections in the Everything / search / filter / icon feed so an
  /// optimistic mutation keeps the pure-recency order the SQL produced —
  /// importance and read state never reorder this feed. Sorts by
  /// [Thread.contentActivityAt] (NOT [Thread.activityAt]) so `bumped_at`
  /// never lifts a row here, matching the bump-free SQL in
  /// [Thread._watchAllTabIds].
  int _flatFeedCompare(Thread a, Thread b) {
    final atCmp = b.contentActivityAt.compareTo(a.contentActivityAt);
    if (atCmp != 0) return atCmp;
    return b.id.toString().compareTo(a.id.toString());
  }

  /// Mirror of the SQL `ORDER BY urgent DESC, importance DESC,
  /// activity_at DESC, id DESC` used by [Thread.watchCatchUpHead], with a
  /// leading `unread-or-sticky DESC` key for the sticky behavior below. Used
  /// in **sectioned mode only** (see [_applyOverlay]) to position sticky-unread
  /// injections (overlay entries whose live row fell past the SQL LIMIT) in
  /// the merged list before it is re-bucketed into sections. The merger
  /// substitutes the live thread with the overlay's `expected` snapshot, which
  /// is frozen as *read* at sticky-creation time so the unread dot clears the
  /// moment the thread is opened. The leading key keys off [_isStickyPinned]
  /// (not the row's `unread` flag) so the just-read row keeps its pre-read
  /// position in the unread cluster until its sticky entry is dropped. The
  /// flat "Everything" feed sorts purely by `activity_at` via
  /// [_flatFeedCompare] instead.
  int _catchUpCompare(Thread a, Thread b) {
    final aUn = (a.unread || _isStickyPinned(a.id)) ? 1 : 0;
    final bUn = (b.unread || _isStickyPinned(b.id)) ? 1 : 0;
    if (aUn != bUn) return bUn.compareTo(aUn);

    final aUrg = a.urgent ? 1 : 0;
    final bUrg = b.urgent ? 1 : 0;
    if (aUrg != bUrg) return bUrg.compareTo(aUrg);

    if (a.importance != b.importance) {
      return b.importance.compareTo(a.importance);
    }

    final atCmp = b.activityAt.compareTo(a.activityAt);
    if (atCmp != 0) return atCmp;

    return b.id.toString().compareTo(a.id.toString());
  }

  /// doneEnd flag for the active per-tab subscription's pagination, used
  /// in place of the legacy [_computeActivityFeedDoneEnd] while the
  /// active tab's data comes from a per-tab query.
  bool _computeActiveTabDoneEnd() {
    final tab = _activeTabSubscriptionTab;
    if (tab == null) return false;
    final isSearching = state.search.isNotEmpty;
    final exhaustedRemote = isSearching || _activityFeedSyncNoMore;
    final appendCursorNull =
        _activeTabFlatMode ? _allTabAppendCursor == null : _doneAppendCursor == null;
    final localExhausted = _activeTabAppended.isEmpty
        ? (!_activeTabHeadSaturated || _activeTabAppendsExhausted)
        : appendCursorNull;
    return localExhausted && exhaustedRemote;
  }

  /// Fetch additional **Done** pages beyond the head when InfiniteList
  /// scrolls past what's loaded (sectioned mode). Mirrors [_fetchMoreAllTab]
  /// but uses [Thread.fetchDonePage] and the Done `(activity_at, id)` cursor.
  /// Unread and Active+Scheduled are fully loaded by the head streams, so
  /// only the Done tail grows here.
  Future<void> _fetchMoreDone(int first, int count) async {
    final needed = first + count;
    bool needsProbeBeyondHead() =>
        _activeTabHeadSaturated &&
        _activeTabAppended.isEmpty &&
        !_activeTabAppendsExhausted;

    if (_activeTabHead.length + _activeTabAppended.length >= needed &&
        !needsProbeBeyondHead()) {
      return;
    }

    while (_activeTabAppendInFlight != null) {
      try {
        await _activeTabAppendInFlight;
      } catch (_) {}
      if (isClosed) return;
      if (_activeTabHead.length + _activeTabAppended.length >= needed &&
          !needsProbeBeyondHead()) {
        return;
      }
    }

    while (!_computeActiveTabDoneEnd() &&
        (_activeTabHead.length + _activeTabAppended.length < needed ||
            needsProbeBeyondHead())) {
      final cursor = _doneAppendCursor ?? _doneHeadTailCursor;
      if (cursor == null) {
        if (needsProbeBeyondHead()) {
          _activeTabAppendsExhausted = true;
          _rebuildActiveTabSection();
        }
        break;
      }

      final gen = _activeTabAppendGeneration;
      final scopeId = _feedScope();

      final completer = Completer<void>();
      _activeTabAppendInFlight = completer.future;
      ({
        List<Thread> threads,
        ({String activityAt, ThreadId id})? nextCursor,
        bool saturated,
      })?
      page;
      try {
        page = await Thread.fetchDonePage(
          priorityId: scopeId,
          archived: state.showArchived ? null : false,
          reactionFilter:
              state.reactionFilter.isNotEmpty ? state.reactionFilter : null,
          limit: _activityFeedLimit,
          after: cursor,
        );
      } finally {
        completer.complete();
        _activeTabAppendInFlight = null;
      }

      if (isClosed) return;
      if (gen != _activeTabAppendGeneration) return;

      final headIds = {for (final t in _activeTabHead) t.id};
      final dedupedNew = page.threads
          .where((t) => !headIds.contains(t.id))
          .toList();
      _activeTabAppended = [..._activeTabAppended, ...dedupedNew];
      _doneAppendCursor = page.saturated ? page.nextCursor : null;
      if (!page.saturated) {
        _activeTabAppendsExhausted = true;
      }
      _rebuildActiveTabSection();

      if (!page.saturated) break;
    }
  }

  /// Fetch additional All-tab pages beyond the head. Same shape as
  /// [_fetchMoreCatchUp] but uses [Thread.fetchAllTabPage] and the All
  /// tab's `(activityAt, id)` cursor.
  Future<void> _fetchMoreAllTab(int first, int count) async {
    final needed = first + count;
    bool needsProbeBeyondHead() =>
        _activeTabHeadSaturated &&
        _activeTabAppended.isEmpty &&
        !_activeTabAppendsExhausted;

    if (_activeTabHead.length + _activeTabAppended.length >= needed &&
        !needsProbeBeyondHead()) {
      return;
    }

    while (_activeTabAppendInFlight != null) {
      try {
        await _activeTabAppendInFlight;
      } catch (_) {}
      if (isClosed) return;
      if (_activeTabHead.length + _activeTabAppended.length >= needed &&
          !needsProbeBeyondHead()) {
        return;
      }
    }

    while (!_computeActiveTabDoneEnd() &&
        (_activeTabHead.length + _activeTabAppended.length < needed ||
            needsProbeBeyondHead())) {
      final cursor = _allTabAppendCursor ?? _allTabHeadTailCursor;
      if (cursor == null) {
        if (needsProbeBeyondHead()) {
          _activeTabAppendsExhausted = true;
          _rebuildActiveTabSection();
        }
        break;
      }

      final gen = _activeTabAppendGeneration;
      final scopeId = _feedScope();

      final completer = Completer<void>();
      _activeTabAppendInFlight = completer.future;
      ({
        List<Thread> threads,
        ({String activityAt, ThreadId id})? nextCursor,
        bool saturated,
      })?
      page;
      try {
        page = await Thread.fetchAllTabPage(
          priorityId: scopeId,
          archived: state.showArchived ? null : false,
          filter: state.filter.isNotEmpty ? state.filter : null,
          reactionFilter:
              state.reactionFilter.isNotEmpty ? state.reactionFilter : null,
          iconFilter: state.iconFilter.isNotEmpty ? state.iconFilter : null,
          search: state.search.isNotEmpty ? state.search : null,
          limit: _activityFeedLimit,
          after: cursor,
        );
      } finally {
        completer.complete();
        _activeTabAppendInFlight = null;
      }

      if (isClosed) return;
      if (gen != _activeTabAppendGeneration) return;

      final headIds = {for (final t in _activeTabHead) t.id};
      final dedupedNew = page.threads
          .where((t) => !headIds.contains(t.id))
          .toList();
      _activeTabAppended = [..._activeTabAppended, ...dedupedNew];
      _allTabAppendCursor = page.saturated ? page.nextCursor : null;
      if (!page.saturated) {
        _activeTabAppendsExhausted = true;
      }
      _rebuildActiveTabSection();

      if (!page.saturated) break;
    }
  }

  /// Current thread associations, keyed by parent thread ID.
  /// Updated via a separate stream subscription.
  Map<Uuid, List<ThreadAssociationRow>>? _associations;
  StreamSubscription<Map<Uuid, List<ThreadAssociationRow>>>?
  _associationsSubscription;

  /// Mirrors [NowBloc]'s `currentEvent` for the PriorityPage activity
  /// feed. Set via [setCurrentEventForFeed]; null when no event is
  /// selected. Drives the "Event Agenda" section in
  /// [_rebuildActivityFeedSections].
  ///
  /// Invariant: this always holds what the RENDERED feed should show for
  /// its current context. During a cross-focus transition the latest
  /// mirror is withheld in [_pendingEventForFeed] instead, so incidental
  /// rebuilds (associations stream, agenda updates) can't flip the
  /// Event Agenda prefix ahead of the thread rows.
  Thread? _currentEventForFeed;

  /// Latest mirrored event withheld while a cross-focus transition is in
  /// flight (see [setCurrentEventForFeed]). Applied by [setPriority] so
  /// the prefix and the new focus's rows flip in the same emission.
  /// [_hasPendingEventForFeed] distinguishes "pending null" (clear the
  /// prefix at the swap) from "nothing pending".
  Thread? _pendingEventForFeed;
  bool _hasPendingEventForFeed = false;

  /// Replace the event that drives the "Event Agenda" section and
  /// rebuild the activity feed. Called by PriorityPage when the
  /// NowBloc.currentEvent changes.
  ///
  /// In the flat priority model the scope-by-path and scope-by-id branches
  /// both resolve to the same priority, so this only re-runs the
  /// subscriptions when the event-selected transition flips the prefix.
  void setCurrentEventForFeed(Thread? event) {
    final latest = _hasPendingEventForFeed
        ? _pendingEventForFeed
        : _currentEventForFeed;
    if (latest?.id == event?.id && latest?.occurrence == event?.occurrence) {
      return;
    }
    // During a cross-focus switch the event mirror arrives before the
    // setPriority that swaps the rows: ChangeCurrentPriority and
    // NowBloc.setCurrentEvent update NowBloc's context synchronously at
    // tap time, while this feed swaps atomically on the restarted
    // subscription's first emission. Applying the mirror now would render
    // the new event over the previous focus's rows — or drop the old
    // event a frame before the rows swap. Stash it; [setPriority] applies
    // it so the Event Agenda prefix and the rows flip in the same frame.
    final nowState = _nowBloc.state;
    if (shouldDeferEventMirror(
      nowContextId: nowState is NowLoaded ? nowState.context?.id : null,
      feedContextId: state.context?.id,
    )) {
      _pendingEventForFeed = event;
      _hasPendingEventForFeed = true;
      return;
    }
    _pendingEventForFeed = null;
    _hasPendingEventForFeed = false;
    final scopeChanged = (_currentEventForFeed == null) != (event == null);
    _currentEventForFeed = event;
    if (scopeChanged && !state.showSubPriorities && state.search.isEmpty) {
      // Only reload when the effective scope actually flips. When the
      // user already has descendants visible (showSubPriorities=true) or
      // is searching (already global), nothing changes.
      _restartActiveTabSubscription();
    } else if (_activeTabSubscriptionTab != null) {
      // Re-render the active tab so the new Event Agenda prefix takes
      // effect without re-fetching SQL.
      _rebuildActiveTabSection();
    }
  }

  /// Per-priority order timeline (`priority_block` rows). Populated by
  /// [_priorityBlocksSubscription] and fed to [AgendaBuilder.build] so
  /// that block ordering reflects user-driven reorders. Empty until the
  /// first stream emission; AgendaBuilder falls back to
  /// `priority.order` when a priority has no rows here.
  Map<PriorityId, List<PriorityBlockRow>> _priorityBlocksByPriority = const {};
  StreamSubscription<
    (Map<PriorityId, List<PriorityBlockRow>>, Map<PriorityId, Priority>)
  >?
  _priorityBlocksSubscription;

  /// Priorities keyed by id, sourced from a priorities watch (NOT from the
  /// agenda's threads). Passed to [AgendaBuilder.build] as `priorityById`
  /// so explicit focus blocks resolve their [Priority] even when the
  /// priority has no threads in the agenda — most notably the root
  /// priority, whose agenda shows only descendants' events. Mirrors the
  /// block-priority resolution in [NowBloc].
  Map<PriorityId, Priority> _priorityById = const {};

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
      // No scoped context (Everything) → dim against the draft's Inbox
      // fallback (see [_rebuildAgendaModel]).
      context: state.context ?? state.draft.priority,
      horizonDays: _agendaHorizonDays,
      minFillDays: _agendaFillDays,
      associationsByParentId: _associations,
      priorityBlocksByPriority: _priorityBlocksByPriority,
      priorityById: _priorityById,
      pausedFocus: _pausedFocus == null
          ? null
          : (
              priority: _pausedFocus!.priority,
              remaining: _pausedFocus!.remaining,
            ),
    );
    final flat = agenda.flatItems();
    emit(
      state.copyWith(
        agenda: agenda,
        agendaItems: flat,
        reorderViewItems: Value(flat),
      ),
    );
  }


  /// Reschedule an existing focus block (`priority_block` row with
  /// positive `duration`) to [targetAnchor]. Soft-archives [source] and
  /// writes a new row at the resolved time so the block always carries
  /// an explicit, non-midnight time-of-day.
  ///
  /// Time-of-day resolution:
  ///   1. If [targetAnchor] has a non-midnight time (gap start after an
  ///      event, scheduled focus block slot, etc.), the row lands there.
  ///   2. If [targetAnchor] is at midnight (the section anchor for a
  ///      no-event day), the row inherits the source row's existing
  ///      time-of-day on the target's calendar date.
  ///   3. If both are at midnight, the row lands at 9:00 on the target
  ///      date — a sensible default since the modal also defaults to 9am
  ///      on future days.
  Future<void> moveFocusBlock({
    required PriorityBlockRow source,
    required DateTime targetAnchor,
    bool anchorIsExact = false,
  }) async {
    final now = DateTime.now();
    // An [anchorIsExact] target was derived from a neighbor block's
    // start/end by the drag dispatch, so it carries the precise drop time
    // and is used verbatim. The midnight/source-time-of-day heuristic
    // only applies to the date-anchored fallback, where the anchor
    // carries no meaningful time-of-day.
    final targetTime = anchorIsExact
        ? targetAnchor
        : _resolveFocusBlockTargetTime(
            source: source,
            targetAnchor: targetAnchor,
          );

    // Optimistic update: archive the source in the cache so the agenda
    // immediately stops rendering the block at its old time, and inject
    // the new row.
    final archivedSource = source.copyWith(
      archivedAt: Value(now),
      updatedAt: now,
    );
    final newRow = PriorityBlockRow(
      id: Uuid.generate(),
      priorityId: source.priorityId,
      createdBy: Base.userId,
      orderValue: source.orderValue,
      effectiveAt: targetTime,
      duration: source.duration,
      archivedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    final updated = <PriorityId, List<PriorityBlockRow>>{
      for (final entry in _priorityBlocksByPriority.entries)
        entry.key: List.of(entry.value),
    };
    final list =
        updated.putIfAbsent(source.priorityId, () => <PriorityBlockRow>[]);
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == source.id) list[i] = archivedSource;
    }
    list.add(newRow);
    _priorityBlocksByPriority = updated;
    _rebuildAgendaModel();

    // Authoritative write: archive the existing row, then upsert the new
    // one. Reuses [store.PriorityBlock.save]'s `(priority_id, effective_at)`
    // conflict policy so a re-drag onto an existing slot updates in place.
    //
    // Both writes run in a single transaction so the
    // `streamPriorityBlocksGroupedByPriority` watch fires exactly once —
    // with the final, consistent state ({old archived, new present}). Two
    // separate writes each notify the watch, and the intermediate emit
    // (old archived but new not yet saved) momentarily overwrites the
    // correct optimistic state above, flashing the block at its old
    // position for a frame before it settles.
    await Store.get.transaction(() async {
      await Store.get.save(
        store.PriorityBlock.table,
        archivedSource.toCompanion(false),
        PriorityBlocksBase(),
      );
      final saver = store.PriorityBlock(
        priorityId: source.priorityId,
        orderValue: source.orderValue,
        effectiveAt: targetTime,
        duration: source.duration,
      );
      await saver.save();
    });

    // Session routing: align the running timer with the new window.
    final newDuration = source.duration ?? Duration.zero;
    final newEnd = targetTime.add(newDuration);
    final coversNow = !targetTime.isAfter(now) && newEnd.isAfter(now);
    final isCurrentFocus =
        _nowBloc.state is NowLoaded &&
        (_nowBloc.state as NowLoaded).context?.id == source.priorityId;
    if (coversNow && isCurrentFocus && newDuration > Duration.zero) {
      // Drop covers now and the focus is current — start (or resume) the
      // session matched to the remaining window.
      await _nowBloc.startSession(override: newEnd.difference(now));
    } else if (!coversNow) {
      // Drop is wholly in the past or wholly in the future. If a session
      // was active for this priority, stop it.
      final s = _nowBloc.state;
      if (s is NowLoaded &&
          s.session?.priority?.id == source.priorityId &&
          s.session?.at.isNow() == true &&
          s.session?.source == 'active') {
        await _nowBloc.stopSession();
      }
    }
  }

  static DateTime _resolveFocusBlockTargetTime({
    required PriorityBlockRow source,
    required DateTime targetAnchor,
  }) {
    final anchorIsMidnight = targetAnchor.hour == 0 &&
        targetAnchor.minute == 0 &&
        targetAnchor.second == 0 &&
        targetAnchor.millisecond == 0 &&
        targetAnchor.microsecond == 0;
    if (!anchorIsMidnight) return targetAnchor;
    final src = source.effectiveAt;
    final sourceIsMidnight = src.hour == 0 &&
        src.minute == 0 &&
        src.second == 0 &&
        src.millisecond == 0 &&
        src.microsecond == 0;
    if (sourceIsMidnight) {
      return DateTime(
        targetAnchor.year,
        targetAnchor.month,
        targetAnchor.day,
        9,
      );
    }
    return DateTime(
      targetAnchor.year,
      targetAnchor.month,
      targetAnchor.day,
      src.hour,
      src.minute,
      src.second,
      src.millisecond,
      src.microsecond,
    );
  }

  /// Apply an optimistic duration change for a block, then schedule the
  /// underlying `priority_block` write. Mirrors the reorder optimistic
  /// pattern above so the agenda gutter updates in the same frame as
  /// the button press, with the watch-driven rebuild confirming the
  /// state once the DB write settles.
  ///
  /// Caller is responsible for routing session-anchored bumps through
  /// [NowBloc.applyBlockBump] separately — this method only updates the
  /// per-block row state. If the eventual DB write goes to a session
  /// row instead, the next subscription emission will revert this
  /// optimistic mutation harmlessly.
  void optimisticBlockDuration({
    required PriorityId priorityId,
    required DateTime blockStart,
    required Duration? newDuration,
  }) {
    final normalized = (newDuration == null || newDuration <= Duration.zero)
        ? null
        : newDuration;
    final now = DateTime.now();

    final updated = <PriorityId, List<PriorityBlockRow>>{
      for (final entry in _priorityBlocksByPriority.entries)
        entry.key: List.of(entry.value),
    };
    final list = updated.putIfAbsent(priorityId, () => <PriorityBlockRow>[]);
    PriorityBlockRow? slotRow;
    var slotIndex = -1;
    for (var i = 0; i < list.length; i++) {
      if (list[i].effectiveAt.isAtSameMomentAs(blockStart)) {
        slotRow = list[i];
        slotIndex = i;
        break;
      }
    }

    if (normalized == null) {
      if (slotRow != null && slotRow.archivedAt == null) {
        list[slotIndex] = slotRow.copyWith(
          archivedAt: Value(now),
          updatedAt: now,
        );
      }
    } else {
      final inheritedOrder = effectivePriorityOrderAt(
        moment: blockStart,
        blocksForPriority: list,
        fallback: 0,
      );
      if (slotRow != null) {
        list[slotIndex] = slotRow.copyWith(
          orderValue: Order(inheritedOrder),
          duration: Value(normalized),
          archivedAt: const Value(null),
          updatedAt: now,
        );
      } else {
        list.add(
          PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: priorityId,
            createdBy: Base.userId,
            orderValue: Order(inheritedOrder),
            effectiveAt: blockStart,
            duration: normalized,
            archivedAt: null,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }

    _priorityBlocksByPriority = updated;
    _rebuildAgendaModel();
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

  /// Apply an Activity-feed drag-and-drop. Decodes the target's section
  /// and applies the appropriate state transition (todo / unread /
  /// schedule date) plus an intra-section order rewrite.
  ///
  /// Section transitions:
  ///   * Today      → todo=true, schedule = `Thread.todoNowDate` sentinel
  ///   * Scheduled  → todo=true, schedule.startOn = `targetScheduledDate`
  ///   * New        → unread=true, archive any user schedule
  ///   * Done       → unread=false, archive any user schedule, bump
  ///                  `bumpedAt` so it surfaces at the top of Done
  ///
  /// Intra-section order is computed from the prev/next thread's
  /// `userSchedule.order` (fractional indexing). For New/Done where
  /// threads have no `userSchedule.order`, the resulting display order
  /// is governed by the bloc's existing sort.
  Future<void> applyActivityFeedThreadDrop({
    required ThreadId draggedId,
    required ActivitySection targetSection,
    required Date? targetScheduledDate,
    required ThreadId? prevId,
    required ThreadId? nextId,
  }) async {
    Thread? dragged = _findThreadInState(draggedId);
    if (dragged == null) {
      // Fall back to the active per-tab subscription's caches if the item
      // hasn't propagated into state yet.
      for (final t in [..._activeTabHead, ..._activeTabAppended]) {
        if (t.id == draggedId) {
          dragged = t;
          break;
        }
      }
    }
    if (dragged == null) return;

    // Dropping into the Event Agenda section creates an association
    // without changing the thread's own section membership — the user
    // wants the thread to appear in both places (duplicate).
    if (targetSection == ActivitySection.eventAgenda) {
      // Same ownership gate as _buildEventAgendaItems — the section is only
      // rendered (and so only a drop target) for an event this context owns.
      final parent = eventAgendaEventFor(
        _currentEventForFeed,
        state.context?.id,
      );
      if (parent == null) return;
      // Resolve neighbouring association orders (if any) to compute a
      // fractional order between them.
      final assocs = _associations?[parent.id] ?? const [];
      Order? above;
      Order? below;
      for (final a in assocs) {
        if (a.childThreadId == prevId) above = a.order;
        if (a.childThreadId == nextId) below = a.order;
      }
      final assocOrder = Order.between(above, below);
      await dragged.associateWith(parentThreadId: parent.id, order: assocOrder);
      // No state change to `dragged` itself — the source row stays in
      // whichever section it was in. The activity feed rebuild fires
      // from the associations stream.
      return;
    }

    // Resolve neighbouring thread refs from the rendered feed. Used
    // both to compute the drop order and (for Doing) to absorb the
    // neighbour's bucket (unread / urgent / importance) so the dropped
    // thread lands exactly where the user released it.
    Thread? prevThread;
    Thread? nextThread;
    if (targetSection == ActivitySection.doing ||
        targetSection == ActivitySection.scheduled) {
      for (final item in state.activityFeedItems) {
        if (item is! AgendaThreadItem) continue;
        if (item.thread.id == prevId) prevThread = item.thread;
        if (item.thread.id == nextId) nextThread = item.thread;
      }
    }
    Thread updated;
    switch (targetSection) {
      case ActivitySection.eventAgenda:
        return; // handled above
      case ActivitySection.doing:
        // The Doing section is sub-clustered by sort key: the unread
        // cluster sorts urgent DESC, importance DESC, order ASC, so
        // unread threads only share an order space with siblings of
        // the same (urgent, importance) tuple; the read cluster is one
        // order space. resolveDoingDrop picks the destination cluster
        // (preserving the dragged row's own bucket at a boundary slot)
        // and tells us which neighbours' orders we can use as bounds.
        final resolution = resolveDoingDrop(
          prev: prevThread == null ? null : doingClusterFor(prevThread),
          next: nextThread == null ? null : doingClusterFor(nextThread),
          dragged: doingClusterFor(dragged),
        );
        // Guard: an active thread must never resolve to the unread cluster,
        // regardless of which slot triggered the drop (handles both the
        // backwards-clamp case and the tail-escape case where
        // resolveDoingDrop sees prev=unread, next=null and returns unread).
        final destination = clampDraggedActiveDestination(
          draggedActive: dragged.isActiveThread,
          destination: resolution.destination,
        );
        final clamped =
            dragged.isActiveThread && resolution.destination.unread;
        // Legacy data contains runs of identical persisted orders (seeded
        // constants; NULL state_order rows all sharing the lowerBound
        // fallback). A plain Order.between inside such a run lands the
        // drop at the bottom of the run instead of in the gap, so resolve
        // against the destination cluster's visual rows and repair the
        // tied run when needed (see [resolveDropOrderWithRepair]).
        final doingBucket = [
          for (final t in feedSectionBucket(
            state.activityFeedItems,
            section: ActivitySection.doing,
            exclude: draggedId,
          ))
            if (doingClusterFor(t) == destination) t,
        ];
        // When the clamp fired the original neighbours are in the unread
        // cluster and their orders belong to a different order-space.
        // Place the thread at the END of the active (read) sub-cluster by
        // setting prevId to the last active thread's id and nextId to null.
        final ThreadId? effectivePrevId;
        final ThreadId? effectiveNextId;
        if (clamped) {
          effectivePrevId = doingBucket.isEmpty ? null : doingBucket.last.id;
          effectiveNextId = null;
        } else {
          effectivePrevId = resolution.usePrev ? prevId : null;
          effectiveNextId = resolution.useNext ? nextId : null;
        }
        final doingResolved = resolveDropOrderWithRepair(
          bucket: doingBucket,
          gapIndex: feedDropGapIndex(
            doingBucket,
            prevId: effectivePrevId,
            nextId: effectiveNextId,
          ),
        );
        _persistOrderRepairs(doingResolved.rewrites);
        final doingNewOrder = doingResolved.dropOrder;
        if (destination.unread) {
          // Land in an unread sub-cluster: mark/keep unread, set the
          // sub-cluster fields (urgent, importance), and place via
          // stateOrder. Schedule state is preserved.
          updated = dragged.asUnreadInDoing(
            order: doingNewOrder,
            urgent: destination.urgent,
            importance: destination.importance,
          );
        } else {
          // Land in the active order-space: become/stay an active to-do, set
          // order, but DON'T mark read — reordering or promoting up must not
          // clear the unread dot. Clear any sticky pin.
          updated = dragged.asActiveToday(order: doingNewOrder, markRead: false);
          _overlay.remove(draggedId);
        }
        break;
      case ActivitySection.scheduled:
        if (targetScheduledDate == null) return;
        // Scheduled lives in a single order space per day; repair tied
        // legacy orders around the gap the same way as Doing above.
        final dayBucket = feedSectionBucket(
          state.activityFeedItems,
          section: ActivitySection.scheduled,
          date: targetScheduledDate,
          exclude: draggedId,
        );
        final dayResolved = resolveDropOrderWithRepair(
          bucket: dayBucket,
          gapIndex: feedDropGapIndex(
            dayBucket,
            prevId: prevId,
            nextId: nextId,
          ),
        );
        _persistOrderRepairs(dayResolved.rewrites);
        updated = dragged.asScheduled(
          targetScheduledDate,
          order: dayResolved.dropOrder,
        );
        // Dropping to a future day is a deliberate move out of the
        // unread cluster — clear any sticky pin.
        _overlay.remove(draggedId);
        break;
      case ActivitySection.activity:
        updated = dragged.asInactive();
        // Sticky-unread keeps a thread pinned to the unread cluster
        // even after its `unread` flag flips to false (so opening an
        // unread thread doesn't make it disappear from the top of
        // Doing mid-read). An explicit drop on Activity is a
        // deliberate move — clear the sticky overlay entry so the
        // merger routes the thread to Activity, not back to the
        // unread cluster.
        _overlay.remove(draggedId);
        break;
    }

    // Watch order — within Today/Scheduled the only thing changing on a
    // reorder is the user-schedule order, and the watched-fields default
    // (todo/at/on/...) is unchanged from the start. Without `order` in
    // the watched set, the override settles on the first stream emission
    // (before the schedule write completes) and the row snaps back to
    // its pre-drop position. The optimistic update writes to `_overlay`,
    // which the per-tab subscription's merger consults to reflect the
    // new section / order on the next rebuild.
    optimisticallyUpdateThread(updated, watchOrder: true);

    // Propagate the optimistic override to peer bloc instances so the
    // LeftPanelAgendaView (keyed to defaultPriority) and the thread-page
    // bloc reflect the drop in the same frame. Without this, those views
    // wait for the Drift stream to emit after [updated.save()] commits,
    // which can be several seconds when the sync orchestrator holds
    // SQLite locks. The activity feed in each peer is priority-scoped,
    // so we only patch the agenda — see [_applyPeerOptimisticOverride].
    for (final peer in _allInstances) {
      if (peer == this || peer.isClosed) continue;
      peer._applyPeerOptimisticOverride(updated, watchOrder: true);
    }

    // optimisticallyUpdateThread already wrote to `_overlay` and
    // triggered `_rebuildActiveTabSection` (via _rebuildAgendaModel),
    // so the dragged row already shows in its target section/order.
    await updated.save();
  }

  /// Persist the order rewrites produced by [resolveDropOrderWithRepair].
  /// The rewrites preserve the rows' visual positions exactly, so no
  /// optimistic overlay is needed — they only make the persisted orders
  /// match what is already displayed, repairing legacy identical-order
  /// data (seeded constants, NULL-state lowerBound fallbacks) so this and
  /// future drops bracket correctly.
  void _persistOrderRepairs(List<(Thread, Order)> rewrites) {
    if (rewrites.isEmpty) return;
    log.info('[orderRepair] rewriting ${rewrites.length} tied order(s)');
    unawaited(() async {
      try {
        await Future.wait([
          for (final (thread, order) in rewrites)
            thread.copyWith(order: order).save(),
        ]);
      } catch (e, stackTrace) {
        log.warning('[orderRepair] failed to persist rewrites', e, stackTrace);
        Tracker.captureException(e, stackTrace);
      }
    }());
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

    _optimisticOverrides[threadId] = _OptimisticOverride.expect(
      expected: anchored,
    );
    _lastAgendaThreads = _lastAgendaThreads
        .map((t) => t.id == threadId ? anchored : t)
        .toList();
    _pendingReorderOrder = (threadId, newOrder.value);

    _rebuildAgendaModel();

    unawaited(anchored.save());
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
    // Pagination is by date range only: extend the horizon when the
    // InfiniteList asks for more rows than we currently render.
    if (!state.agendaDoneEnd && currentItems < needed) {
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
    _allInstances.remove(this);
    // Unregister time change callback
    Time.setOnTimeChanged(null);

    _nowSubscription?.cancel();
    _localPreferencesSubscription?.cancel();
    _fullResyncSubscription?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _threadSubscription?.cancel();
    _agendaSubscription?.cancel();
    _associationsSubscription?.cancel();
    _priorityBlocksSubscription?.cancel();
    _tagsSubscription?.cancel();
    _reactionsSubscription?.cancel();
    _iconCountsSubscription?.cancel();
    _activeTabSubscription?.cancel();
    _pendingFeedSyncFallback?.cancel();
    _pendingFeedSync = null;
    _pendingMoveIds.clear();
    return super.close();
  }

  /// The scoped focus id, or `null` in the unscoped Everything view.
  PriorityId? get currentId => state.context?.id;

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
    // When finishing, mirror FinishThread's save: flip todo and bump
    // activity_at to now so the optimistic state already has the thread at
    // the top of Done before the Drift write / stream emission arrive.
    final finished = (finishTodo && existing != null)
        ? existing.copyWith(todo: false, bump: true)
        : null;
    if (existing != null) {
      if (finishTodo) {
        _optimisticOverrides[id] = _OptimisticOverride.expect(
          expected: finished!,
          fields: const {_OverrideField.todo},
        );
        // Action tabs (Respond / Do / Read) filter out finished rows via
        // `read_at IS NULL`, so substituting an `expected` overlay would
        // re-render the thread under a fresh "Today" scheduled bucket for
        // one frame before the SQL update arrives. Drop so the per-tab
        // feed matches the post-write reality.
        _overlay[id] = _activeTabSubscriptionTab?.isActionTab == true
            ? const _Overlay.drop()
            : _Overlay(
                expected: finished,
                watched: const {_OverrideField.todo},
              );
      } else {
        _optimisticOverrides[id] = _OptimisticOverride.absent();
        _overlay[id] = const _Overlay.drop();
      }
    }
    // Drop non-link-instance copies of the thread from the cached
    // source list; finishing a todo keeps any link-schedule instance
    // alive (it remains as an event) but flips its todo flag so the
    // builder treats it as the user's scheduled completion.
    // Associated threads are also kept so they continue to render
    // nested under their parent event — "Finish" must
    // not strip the event nesting (that's "Remove from event"'s job).
    final isAssociated =
        _associations?.values.any(
          (children) => children.any((a) => a.childThreadId == id),
        ) ??
        false;
    _lastAgendaThreads = _lastAgendaThreads
        .where((t) => t.id != id || t.isLinkScheduleInstance || isAssociated)
        .map((t) {
          if (!finishTodo || t.id != id) return t;
          return finished ?? t.copyWith(todo: false);
        })
        .toList();

    // The overlay write above is what the per-tab subscription consults
    // to re-bin the visible feed; _rebuildAgendaModel re-emits the
    // active tab's section.
    _rebuildAgendaModel();
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
  ///
  /// [watchOrder] adds [_OverrideField.order] to the watched set so the
  /// override won't settle until the stream's `userSchedule.order` matches
  /// the expected value. Required for reorders within a section (Activity
  /// feed Today/Scheduled drop, todo reorder) — the visible-state fields
  /// (todo/at/on/...) are unchanged from the start, so without watching
  /// `order` the override settles on the very first stream emission while
  /// the schedule write is still pending, and the row visibly snaps back
  /// to its old position before the saved order arrives.
  ///
  /// [watchScheduleAction] adds [_OverrideField.scheduleAction] for the
  /// same reason as [watchOrder] but for action-tab moves (To respond /
  /// To do / To read). Without it the override settles before the
  /// schedule write applies and the row briefly disappears from the
  /// destination tab.
  void optimisticallyUpdateThread(
    Thread updatedThread, {
    bool watchOrder = false,
    bool watchScheduleAction = false,
  }) {
    if (updatedThread.draft) return;
    // Record the expected post-update state. The default watched set covers
    // the visible-state fields any save() could flip (todo, archived,
    // priority, schedule, unread) while ignoring fields the server may
    // rewrite on its own (e.g. AI-generated title). When [watchOrder] /
    // [watchScheduleAction] are set, also require those fields to match
    // before settling.
    final fields = (watchOrder || watchScheduleAction)
        ? <_OverrideField>{
            _OverrideField.todo,
            _OverrideField.archived,
            _OverrideField.priorityId,
            _OverrideField.unread,
            _OverrideField.at,
            _OverrideField.on,
            if (watchOrder) _OverrideField.order,
            if (watchScheduleAction) _OverrideField.active,
          }
        : null;
    _optimisticOverrides[updatedThread.id] = _OptimisticOverride.expect(
      expected: updatedThread,
      fields: fields,
    );
    // Mirror in the per-tab activity-feed overlay so the active tab shows
    // the optimistic state in the same frame as the edit. A sticky-unread
    // pin (the open thread the user just read) survives position-neutral
    // updates — the row must hold its cluster spot while open — but an
    // update that changes positioning state (to-do/done, schedule, move)
    // replaces the pin so the row relocates immediately.
    final existingOverlay = _overlay[updatedThread.id];
    final keepSticky =
        existingOverlay != null &&
        existingOverlay.sticky &&
        existingOverlay.expected != null &&
        _samePosition(existingOverlay.expected!, updatedThread);
    _overlay[updatedThread.id] = keepSticky
        ? _Overlay(
            expected: updatedThread.copyWith(unread: false),
            watched: const <_OverrideField>{},
            catchUpSortKeys: existingOverlay.catchUpSortKeys,
            sticky: true,
          )
        : _Overlay(
            expected: updatedThread,
            watched: fields ?? _OptimisticOverride._defaultWatched,
          );

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

    // The overlay write above is consumed by the per-tab subscription's
    // merger to render the new section / order in the same frame as
    // the click. _rebuildAgendaModel re-emits the active tab's section.
    _rebuildAgendaModel(
      thread: state.thread?.id == updatedThread.id
          ? Value(updatedThread)
          : const Value.absent(),
    );
  }

  /// Apply an optimistic override propagated from a peer bloc that ran
  /// its own optimistic update (e.g. the priority page's bloc handled a
  /// drag-to-Doing). Only patches the agenda model — the activity-feed
  /// overlay is bloc-local (each bloc has its own active per-tab
  /// subscription) so we don't propagate overlay writes here. The
  /// per-thread agenda override is
  /// still recorded so the subsequent Drift stream emission is patched
  /// the same way as the originating bloc's — keeping the agenda in
  /// sync until the saved row settles the override.
  void _applyPeerOptimisticOverride(
    Thread updatedThread, {
    bool watchOrder = false,
  }) {
    if (updatedThread.draft) return;
    final fields = watchOrder
        ? <_OverrideField>{
            _OverrideField.todo,
            _OverrideField.archived,
            _OverrideField.priorityId,
            _OverrideField.unread,
            _OverrideField.at,
            _OverrideField.on,
            _OverrideField.order,
          }
        : null;
    _optimisticOverrides[updatedThread.id] = _OptimisticOverride.expect(
      expected: updatedThread,
      fields: fields,
    );

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
      return t.copyWith(todo: updatedThread.todo);
    }).toList();

    if (shouldRemove) {
      rebuilt = rebuilt.where((t) => t.id != updatedThread.id).toList();
    } else if (!foundInAgenda) {
      if (updatedThread.todo) rebuilt.add(updatedThread);
    }

    _lastAgendaThreads = rebuilt;
    _rebuildAgendaModel();
  }

  /// Force the agenda to rebuild from fresh stream data. Call after an
  /// optimistic update + save when the number of agenda items may have changed
  /// (e.g. starting a link schedule thread creates a base todo duplicate).
  void refreshAgenda() {
    _loadAgenda(triggerSync: false);
  }

  Future<void> setPriority(Priority newPriority) async {
    // No-op when already on this focus. A null context (Everything) is never
    // equal to a real focus id, so a switch out of Everything proceeds.
    if (state.context?.id == newPriority.id) return;

    // Leaving the current focus invalidates any multi-selection (the new
    // focus shows a different set of rows).
    clearSelection();

    // Bump the generation so any in-flight chain-draft lookup or background
    // finalization from a previous setPriority is fenced off — they check
    // this counter before emitting and bail if a newer switch is underway.
    final myGen = ++_priorityLoadGeneration;

    // Apply any event mirror withheld during the transition (see
    // [setCurrentEventForFeed]) so the restarted subscription's first
    // emission renders the Event Agenda prefix together with the new
    // focus's rows — never one ahead of the other.
    if (_hasPendingEventForFeed) {
      _currentEventForFeed = _pendingEventForFeed;
      _pendingEventForFeed = null;
      _hasPendingEventForFeed = false;
    }

    // Profile the priority switch end-to-end. The same stopwatch is passed
    // into _loadPriority/_loadAgenda so timestamps share an origin and the
    // user can see exactly how each phase contributes to time-to-threads.
    final profile = _PriorityLoadProfile('switch:${newPriority.id}');
    profile.mark(
      'setPriority start: ${state.context?.title ?? 'Everything'} -> '
      '${newPriority.title}',
    );

    // Track the previous non-Inbox context for new-thread priority chips.
    // Everything (null context) leaves the previous chip untouched.
    final prev = state.context;
    if (prev != null && !prev.isInbox) {
      _previousContextPriority = prev;
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
    // NOTE: the tags / reactions / icon-count filter subscriptions are
    // deliberately NOT cancelled here. They're global (focus-independent) and
    // loaded once via [ensureFilterData]; tearing them down per switch only to
    // re-run identical global scans was the largest switch-burst cost.

    // Drop optimistic overrides — they apply to the old priority's streams
    // and won't naturally settle in the new one. The per-tab overlay is
    // cleared below in `_restartActiveTabSubscription`.
    _optimisticOverrides.clear();

    // Cancel any in-flight remote search so its result doesn't land in B
    // after the user switched away from A.
    _searchGeneration++;

    // Reset only the activity-feed scroll. Agenda scroll is preserved so
    // the user lands on the same visible block region after the switch.
    activityFeedScrollOffset = 0.0;

    // Reset the "which list was last navigated from" hint. The new priority
    // starts in its default navigation source until the user picks again.
    threadListSource = null;

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
      priorityById: _priorityById,
      pausedFocus: _pausedFocus == null
          ? null
          : (
              priority: _pausedFocus!.priority,
              remaining: _pausedFocus!.remaining,
            ),
    );
    emit(
      state.copyWith(
        // Navigating to a real focus always leaves the Everything view, so
        // clear `everything` alongside the context to keep the invariant
        // (everything <=> context == null) intact even when this switch
        // originates from Everything.
        context: Value(newPriority),
        everything: false,
        agenda: newAgenda,
        agendaItems: newAgenda.flatItems(),
        // Deliberately KEEP the previous focus's `activityFeedByTab` /
        // `activityFeedDoneEnd` / `activityFeedLoaded` here. Clearing them
        // dropped the feed to a blank LoadingPage for the few frames until the
        // new subscription's first emission, so the shared "Active" header (and
        // everything else) visibly disappeared and reappeared across the
        // switch. Holding the prior list — exactly as `setEverything` does —
        // lets `_rebuildActiveTabSection` swap it for the new focus's data in a
        // single frame, with no intervening blank. The restarted subscription
        // below overwrites both the items and `activityFeedLoaded` on its first
        // emission. (First app load still shows LoadingPage: the bloc starts
        // with `activityFeedLoaded == false` and no items.)
        // Reset to the default rolled-up feed (priority + descendants) on
        // every priority switch, including navigation from the agenda.
        showSubPriorities: true,
        // Match the pre-persistence behavior: a fresh PriorityBloc started
        // with empty filters / search. Carrying them across switches makes
        // users hit "filtered to nothing" without realizing why.
        filter: const [],
        iconFilter: const [],
        search: '',
        // A navigation ends any global view, so clear its focus scope too.
        globalViewScope: const Value(null),
        remoteSearchExtras: const [],
        remoteSearchInProgress: false,
        remoteSearchOffline: false,
        hasArchivedMatches: false,
      ),
    );
    profile.mark('emitted context-switched state');

    // Reset the activity-feed sync state — the per-tab subscription will
    // be restarted below for the new priority, and a fresh sync is owed.
    _activityFeedSyncNoMore = false;

    // Re-init priority-scoped subscriptions (drafts, tags, icons,
    // activity feed). reloadAgenda: false skips the global agenda
    // subscription — it's still alive from the initial load. loadDraft:
    // false because the chain-draft lookup below owns the draft emit.
    _loadPriority(profile: profile, reloadAgenda: false, loadDraft: false);
    profile.mark('_loadPriority returned (subscriptions started)');
    // Per-tab subscription is priority-scoped — restart so the active
    // tab reloads for the new priority.
    _restartActiveTabSubscription();

    // Look up the chain draft so the new-thread input shows the right
    // content. We deliberately DO NOT call `Priority.get(archived: null)` to
    // re-enrich the priority — the profile data showed it cost ~1100ms
    // (including a `pullArchived` call) and the only fields it adds
    // (`active`/`unreadComputed`) are recomputed elsewhere by PrioritiesBloc;
    // nothing in this bloc reads them off `state.context`. Priority.watchOne
    // (registered inside _loadPriority) keeps state.context in sync with the
    // raw row, which is enough.
    final existingDraft = await Thread.getDraftInChain(newPriority);
    profile.mark('chain draft lookup done (found=${existingDraft != null})');

    Thread newDraft;
    if (existingDraft != null) {
      // Preserve the draft's filed priority — don't reassign to context.
      newDraft = existingDraft;

      // Auto-organize is only meaningful in an Inbox. If the chain draft was
      // auto-filed in an Inbox and we're entering a non-Inbox context, drop
      // the auto flag and re-file to the new context priority so the chip
      // reflects "where the user is working" instead of "Auto".
      if (!newPriority.isInbox &&
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
    // A later setPriority(C) has fenced us off — don't emit B's chain draft
    // into C's state.
    if (myGen != _priorityLoadGeneration) {
      profile.mark('draft emit skipped (newer setPriority in flight)');
      return;
    }

    // Emit the chosen draft right away so the new-thread input shows the
    // right priority chip. The actual draft note (and the legacy duplicate
    // cleanup) finish in the background — neither blocks typing because the
    // editor mounts with the in-memory draft and patches in the saved note
    // when it arrives.
    emit(state.copyWith(draft: newDraft));
    profile.mark('draft emitted');

    unawaited(_finalizeDraftInBackground(newDraft, profile, myGen));
  }

  /// Background completion for [setPriority]'s draft work. Runs the legacy
  /// duplicate-draft cleanup and loads the saved draft note, then emits the
  /// note when ready. Runs after the agenda has had a chance to render so
  /// it doesn't compete with the agenda's Drift query for the SQLite
  /// connection during the user-visible spinner phase.
  Future<void> _finalizeDraftInBackground(
    Thread newDraft,
    _PriorityLoadProfile profile,
    int myGen,
  ) async {
    try {
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
      // Also keep an existing empty in-memory note when its threadId already
      // matches the new draft. Constructing a fresh Note.draft generates a
      // new note id which forces the NoteEditor to reset its SuperEditor —
      // visible as a flicker even when the content is unchanged.
      final draftNote =
          loadedNote ??
          (state.draftNote.threadId == newDraft.id
              ? state.draftNote
              : Note.draft(threadId: newDraft.id));
      profile.mark('draft note loaded (background)');

      if (isClosed) return;
      // A newer setPriority has started — don't clobber the new priority's
      // draft note with this stale one.
      if (myGen != _priorityLoadGeneration) {
        profile.mark('draft note emit skipped (newer setPriority in flight)');
        return;
      }

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

    // Sticky-unread tracking: when navigating away from a thread, drop its
    // overlay entry immediately so the just-read thread settles into its
    // natural section right away (the page animates the move). When
    // selecting an unread thread, pin it via the overlay so the per-tab
    // Catch up subscription keeps it visible at its pre-read position; the
    // snapshot is frozen as read so the unread dot clears immediately on
    // open. The thread's own unread → read DB write happens in
    // `page/thread.dart`.
    final oldThread = state.thread;
    if (oldThread != null && thread?.id != oldThread.id) {
      _removeSticky(oldThread.id);
    }
    if (thread != null &&
        thread.unread &&
        _activeTabSubscriptionTab == ActivityTab.catchUp) {
      _overlay[thread.id] = _Overlay.stickyUnread(
        thread,
        sortKeys: (
          urgent: thread.urgent ? 1 : 0,
          importance: thread.importance,
          activityAt: thread.activityAt,
        ),
      );
      _rebuildActiveTabSection();
    }

    // Clear the unread filter when the user opens the last remaining unread.
    // The sticky-pin above keeps the just-opened thread visible while the
    // full feed reappears behind it, so it's safe to drop the filter here.
    if (thread != null && thread.unread && state.unreadFilterActive) {
      final otherUnread = state.activityFeedItems.any((item) =>
          item is AgendaThreadItem &&
          item.thread.unread &&
          item.thread.id != thread.id);
      if (!otherUnread) {
        updateUnreadFilter(false); // opening the last unread reveals the full feed
      }
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

  /// Drop a sticky-unread overlay the moment the user navigates away so
  /// the just-read thread settles into its natural section immediately
  /// (animated via [markFeedMove]). No-op when the thread has no live
  /// sticky entry — e.g. its overlay was already replaced by an explicit
  /// state change, which manages its own move.
  void _removeSticky(ThreadId id) {
    final overlay = _overlay[id];
    if (overlay == null || !overlay.sticky) return;
    _overlay.remove(id);
    markFeedMove(id);
    if (_activeTabSubscriptionTab == ActivityTab.catchUp) {
      _rebuildActiveTabSection();
    }
  }

  // --- Multi-select (bulk operations) ---

  /// Toggle a thread's membership in the multi-select set (Cmd/Ctrl+click).
  /// When multi-select is starting and a thread is open, the open thread joins
  /// the selection first so it's included per the bulk-select rules. The
  /// toggled row becomes the new anchor for a subsequent shift-click range.
  void toggleSelected(Thread thread) {
    final next = Set<ThreadId>.of(state.selected);
    if (next.isEmpty && state.thread != null) {
      next.add(state.thread!.id);
    }
    if (!next.remove(thread.id)) {
      next.add(thread.id);
    }
    emit(state.copyWith(
      selected: next,
      selectionAnchor: Value<ThreadId?>(thread.id),
    ));
  }

  /// Select the contiguous range of feed rows from the current anchor to
  /// [thread] (Shift+click), replacing the prior range. The anchor is the last
  /// toggled row, or — when shift-click starts the multi-select — the open
  /// thread, or the clicked row itself. The anchor is left in place so
  /// successive shift-clicks re-pivot from the same origin.
  void selectRange(Thread thread) {
    final ids = state.orderedFeedThreadIds;
    final targetIdx = ids.indexOf(thread.id);
    if (targetIdx < 0) {
      // Clicked row isn't in the visible feed (shouldn't happen) — fall back
      // to a single-row selection anchored on it.
      emit(state.copyWith(
        selected: {thread.id},
        selectionAnchor: Value<ThreadId?>(thread.id),
      ));
      return;
    }
    final anchorId = state.selectionAnchor ?? state.thread?.id ?? thread.id;
    var anchorIdx = ids.indexOf(anchorId);
    if (anchorIdx < 0) anchorIdx = targetIdx;
    final lo = anchorIdx < targetIdx ? anchorIdx : targetIdx;
    final hi = anchorIdx < targetIdx ? targetIdx : anchorIdx;
    emit(state.copyWith(
      selected: ids.sublist(lo, hi + 1).toSet(),
      selectionAnchor: Value<ThreadId?>(anchorId),
    ));
  }

  /// Exit multi-select mode, clearing the selection and anchor. No-op (no
  /// emit) when nothing is selected so ordinary thread opens don't churn
  /// state on every click.
  void clearSelection() {
    if (state.selected.isEmpty && state.selectionAnchor == null) return;
    emit(state.copyWith(
      selected: const {},
      selectionAnchor: const Value(null),
    ));
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

  /// Whether the current working draft holds user content worth keeping.
  bool isWorkingDraftSubstantive() {
    final t = state.draft;
    final n = state.draftNote;
    return isSubstantiveDraftFields(
      title: t.title,
      hasRecipients:
          t.contacts.isNotEmpty || t.groups.isNotEmpty || t.inviteEmails.isNotEmpty,
      hasSchedule: t.at != null || t.on != null,
      body: n.content,
      hasActions: n.actions?.isNotEmpty ?? false,
    );
  }

  /// Starts a brand-new empty working draft on the same priority.
  ///
  /// If the current working draft is substantive it is left intact (it was
  /// autosaved by [updateDraft], so it remains in the Drafts list) and a fresh
  /// draft thread + note replace it in state. If the current draft is an empty
  /// skeleton it is reused and cleared, so abandoned empties never accumulate.
  void startFreshDraft() {
    // Fence any in-flight setPriority background draft-note emit so it can't
    // land on top of this fresh draft (it checks _priorityLoadGeneration).
    ++_priorityLoadGeneration;
    final current = state.draft;
    if (isWorkingDraftSubstantive()) {
      final fresh = Thread(priority: current.priority, draft: true);
      emit(state.copyWith(
        draft: fresh,
        draftNote: Note.draft(threadId: fresh.id),
      ));
    } else {
      final cleared = current.copyWith(
        title: const Value(null),
        at: const Value(null),
        on: const Value(null),
        duration: const Value(null),
        preview: const Value(null),
        contacts: const Value(null),
        groups: const Value(null),
        inviteEmails: const Value(null),
        teamId: const Value(null),
        icon: const Value(null),
        topicId: const Value(null),
      );
      emit(state.copyWith(
        draft: cleared,
        draftNote: Note.draft(threadId: cleared.id),
      ));
    }
    _draftModified = false;
  }

  /// Loads an existing draft thread + note as the working draft (resume). The
  /// previously-active substantive draft is already autosaved and stays in the
  /// list; an empty skeleton is simply abandoned.
  void resumeDraft(Thread thread, Note note) {
    emit(state.copyWith(draft: thread, draftNote: note));
    _draftModified = true;
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
      // Never let a draft-save downgrade a thread that has already been
      // published. A late _saveDraft from a NewThreadPage NoteEditor being
      // torn down during the publish route-replace can fire while
      // state.draft still points at the thread add() just published
      // (draft=0). Persisting it back as a draft would exclude it from
      // sync, stranding any published note on it in a permanent
      // /sync/notes 403 loop. See Store._buildDraftFilter and the v364
      // recovery migration.
      if (await _isThreadPublished(thread.id)) {
        log.warning(
          '[updateDraft] Skipped draft-save that would downgrade published '
          'thread ${thread.id} back to draft',
        );
      } else {
        await thread.save();
      }
    } else if (note != null && noteChanged) {
      // Note is changing but no thread-level fields are. The thread row
      // may still be in-memory only (Thread() constructs but updateDraft
      // skips save() unless thread fields change). Persist it so chain /
      // priority draft lookups can find this draft after navigation.
      await thread.ensurePersisted();
    }
    if (note != null && noteChanged) {
      // Symmetric guard: don't downgrade a published note back to draft
      // either (same race as the thread above).
      if (await _isNotePublished(note.id)) {
        log.warning(
          '[updateDraft] Skipped draft-save that would downgrade published '
          'note ${note.id} back to draft',
        );
      } else {
        log.info(
          '[updateDraft] Saving note: id=${note.id}, threadId=${note.threadId}, content length=${note.content?.length ?? 0}',
        );
        await note.save(pushToRemote: false);
      }
    }
  }

  /// Whether the thread row [id] exists on disk already published
  /// (draft = false). Used to stop a late draft-save from downgrading a
  /// just-published thread (see [updateDraft]).
  Future<bool> _isThreadPublished(Uuid id) async {
    if (!Store.isAvailable) return false;
    final row = await (Store.get.select(Store.get.threads)
          ..where((t) => t.id.equalsValue(id))
          ..limit(1))
        .getSingleOrNull();
    return row != null && !row.draft;
  }

  /// Whether the note row [id] exists on disk already published
  /// (draft = false). Used to stop a late draft-save from downgrading a
  /// just-published note (see [updateDraft]).
  Future<bool> _isNotePublished(Uuid id) async {
    if (!Store.isAvailable) return false;
    final row = await (Store.get.select(Store.get.notes)
          ..where((t) => t.id.equalsValue(id))
          ..limit(1))
        .getSingleOrNull();
    return row != null && !row.draft;
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
      // Thread selected: post-Task-3 agendaItems contains only header
      // items (one per block), so locate which block contains the
      // thread and use that block's header index. The header carries
      // the block id via [parentBlockId]; fall back to the
      // event-block case where the header itself references the
      // event thread directly.
      String? blockId;
      for (final section in state.agenda.sections) {
        for (final block in section.blocks) {
          if (block.threads.any((t) => t.id == state.thread!.id)) {
            blockId = block.id;
            break;
          }
        }
        if (blockId != null) break;
      }
      if (blockId != null) {
        for (int i = 0; i < state.agendaItems.length; i++) {
          final item = state.agendaItems[i];
          if (item is AgendaHeaderItem && item.parentBlockId == blockId) {
            currentIndex = i;
            break;
          }
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

    // Helper to check if an item matches the filter criteria.
    // Post-Task-3, agendaItems contains only header items: per-block
    // headers (date == null) and date/text section headers
    // (date != null or pure text). [includeThread] is retained for
    // backwards compatibility but, since there are no AgendaThreadItem
    // rows on the agenda, it now controls whether per-block headers
    // (which represent the threads) participate in navigation.
    bool matchesFilter(AgendaItem item) {
      return item.when<bool>(
        activity: (agendaItem) => includeThread,
        header: (header) =>
            (header.date != null && includeDate) ||
            (header.date == null &&
                (includePriority || (includeThread && header.text == null))),
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

  /// True when the active feed renders as a flat list (Everything, search,
  /// or filters) — state changes never reposition rows there.
  bool get activeFeedIsFlat => _activeTabFlatMode;

  /// Rule 2/3 navigation decision for an explicit state change on the
  /// open thread. Computed against the CURRENT feed items — call BEFORE
  /// applying the optimistic update.
  ///
  /// [multiPanel] gates the advance-to-next behaviour: in single panel the
  /// changed thread always stays open (the user pops back to the list when
  /// ready), so callers pass `context.isMultiPanel`.
  StateChangeNav threadAfterStateChange(
    ThreadId changedId, {
    required bool multiPanel,
  }) {
    if (_activeTabFlatMode) return (open: null, stay: true);
    // Advance through the VISIBLE feed so Done moves to the next visible thread
    // and never jumps to one the active filter hides. activityFeedViewItems
    // narrows by the unread-only, mute-only and focus-scope filters; it returns
    // the full feed unchanged when none is active. (Search and tag / icon /
    // assignee filters render as a flat list and already stay put via the
    // flat-mode early-return above.) In a filtered subset "nothing left to
    // open" doesn't mean the whole list is clear, so keep the just-finished
    // thread open instead of the compose-page fallback — for the unread filter
    // it also auto-clears, revealing the full feed. The unfiltered feed keeps
    // its compose-on-empty behavior.
    final filtered = state.unreadFilterActive ||
        state.muteOnly ||
        state.globalViewScope != null;
    return nextThreadAfterStateChange(
      state.activityFeedViewItems,
      changedId,
      multiPanel: multiPanel,
      stayWhenNothingToOpen: filtered,
    );
  }

  /// Determines which list to navigate based on prior context.
  /// If the user previously selected from a list, use that.
  /// Otherwise, prefer agenda if the current thread is in it.
  ThreadListSource resolveThreadListSource() {
    if (threadListSource != null) return threadListSource!;
    // Check if current thread is in the agenda
    if (state.thread != null) {
      final inAgenda = state.agenda.sections
          .expand((s) => s.blocks)
          .expand((b) => b.threads)
          .any((t) => t.id == state.thread!.id);
      if (inAgenda) return ThreadListSource.agenda;
    }
    return ThreadListSource.activityFeed;
  }

  /// Lazily subscribe the global filter-data streams (tags, reactions, icon
  /// counts) that populate the header filter dropdown. These are global
  /// (`priorityId=null`) and feed only the filter UI, so their results are
  /// identical for every focus. They're loaded once — on first search-open —
  /// instead of being recomputed on every focus switch, where the three
  /// global threads scans were the largest switch-burst cost.
  ///
  /// Idempotent: a no-op once subscribed. The subscriptions live for the
  /// bloc's lifetime and are cancelled in [close]; they are never torn down on
  /// a focus switch because the data does not change with focus.
  void ensureFilterData() {
    if (_tagsSubscription != null) return;

    _tagsSubscription = Thread.watchTagsForPriority().listen((tags) {
      // Common tags (excluding action/compute tags)
      final commonTagsFiltered = tags
          .where((tagData) => tagData.$1.type != .compute && tagData.$1.addable)
          .map((tagData) => tagData.$1)
          .toList();
      final commonTagSet = commonTagsFiltered.toSet();
      final otherTags = Tag.getAll(onlyAddable: true)
          .where((tag) => tag.type != .compute && !commonTagSet.contains(tag))
          .toList();
      final tagSuggestions = [...commonTagsFiltered, ...otherTags];
      emit(state.copyWith(tags: tags, tagSuggestions: tagSuggestions));
    });

    _reactionsSubscription = Thread.watchReactionsForPriority().listen((
      reactions,
    ) {
      emit(state.copyWith(reactions: reactions));
    });

    _iconCountsSubscription = Thread.watchIconCountsForPriority().listen((
      counts,
    ) {
      final iconCounts = [...counts]..sort((a, b) => b.$2.compareTo(a.$2));
      emit(state.copyWith(iconCounts: iconCounts));
    });
  }

  /// Whether a [Priority.watchOne] emission for [watched] should be written
  /// back into the current [state]'s context.
  ///
  /// The per-focus watch registered in [_loadPriority] keeps `state.context`
  /// in sync with edits to the focus the user is viewing. That subscription is
  /// NOT torn down when the view switches to the synthetic Everything feed
  /// ([setEverything] only emits a new state), so a late emission for the
  /// focus we just left would otherwise stamp a non-null context onto an
  /// `everything == true` state — violating the PriorityState invariant
  /// (everything <=> context == null) and throwing. It also guards against a
  /// queued emission for a focus the view has already switched away from.
  ///
  /// Only apply the emission while the bloc is still scoped to that focus.
  @visibleForTesting
  static bool shouldApplyWatchedContext(
    PriorityState state,
    Priority watched,
  ) =>
      state.context?.id == watched.id;

  void _loadPriority({
    _PriorityLoadProfile? profile,
    bool reloadAgenda = true,
    bool loadDraft = true,
  }) {
    // Null in the unscoped Everything view. The per-focus chain-draft load
    // and the focus watch below are both scoped to a real focus, so they are
    // skipped — the Everything feed's draft already files into the Inbox
    // fallback (set when entering Everything) and the unscoped feed query
    // needs no focus watch.
    final Priority? priorityToLoad = state.context;

    // [setPriority] passes loadDraft: false — it owns the chain-draft lookup
    // itself (including the auto-file re-file and fresh-draft fallback that
    // [_loadDraft] doesn't do), so running both would issue the same
    // chain-draft and draft-note queries twice per switch and race the two
    // draft emits against each other.
    if (loadDraft && priorityToLoad != null) _loadDraft(priorityToLoad);

    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    if (priorityToLoad != null) {
      _subscriptions.add(
        Priority.watchOne(priorityToLoad.id).listen((priority) {
          log.fine('Priority updated');
          // Drop stale emissions after the view left this focus (e.g. entered
          // the Everything feed, where context must stay null). Stamping a
          // non-null context onto an `everything` state violates the
          // PriorityState invariant. See [shouldApplyWatchedContext].
          if (!shouldApplyWatchedContext(state, priority)) return;
          emit(state.copyWith(context: Value(priority)));
        }),
      );
    }
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
      // Refresh the active per-tab section so the "Event Agenda" prefix
      // picks up newly created / archived associations. Without this,
      // a drop that calls `associateWith` would write to the DB and
      // update the stream but the feed wouldn't re-render — the source
      // row would be hidden by the drag system while the association
      // never surfaced in the section, so the thread visibly
      // disappears until a manual reload.
      if (_activeTabSubscriptionTab != null) {
        _rebuildActiveTabSection();
      }
    });

    // Watch the per-priority order timeline. Each emission updates the
    // cache AND triggers an agenda rebuild so per-block durations
    // resolved by `_attachBlockDurations` reflect the new rows.
    // Without the rebuild, a row write (e.g. from `applyBlockBump`)
    // updates `_priorityBlocksByPriority` but the displayed
    // `cascadeDuration` stays stale until some other event happens to
    // rebuild the agenda.
    _priorityBlocksSubscription?.cancel();
    _priorityBlocksSubscription = Rx.combineLatest2(
      streamPriorityBlocksGroupedByPriority(),
      // Raw watch: this subscription only needs the id→Priority lookup map
      // for the agenda model. The enriched [Priority.watch] additionally
      // computes active/unread/non-empty id sets via three thread-table
      // scans that re-run on every thread write — needless load on the
      // single SQLite connection during a focus switch (the sidebar gets its
      // enriched state from PrioritiesBloc, not from here).
      Priority.watchRaw(archived: false),
      (
        Map<PriorityId, List<PriorityBlockRow>> grouped,
        List<Priority> priorities,
      ) => (grouped, {for (final p in priorities) p.id: p}),
    ).listen((data) {
      _priorityBlocksByPriority = data.$1;
      _priorityById = data.$2;
      _rebuildAgendaModel();
    });

    // Tags / reactions / icon-count filter data is GLOBAL (priorityId=null)
    // and feeds only the header filter dropdown, so it is byte-identical
    // across focuses. It is loaded lazily and exactly once via
    // [ensureFilterData] when the user first opens search — NOT here, where it
    // would re-run three global threads scans on every focus switch (the
    // single biggest switch-burst cost). The subscriptions then live for the
    // bloc's lifetime; do not re-subscribe or cancel them on switch.

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
      // Initial 30-day horizon. [fetchMoreAgendaItems] extends this
      // as the user scrolls forward.
      _agendaHorizonDays = 30;
      _agendaFillDays = 0;
      _agendaSyncNoMore = false;
      _loadAgenda(profile: profile);
    }

    _activityFeedSyncNoMore = false;
    // Defer the server-side feed sync (still needed to populate the local DB
    // that per-tab queries read from) until the feed's first emission has
    // rendered. Firing it at switch start made the pull's network decode and
    // row writes race the very queries the user is waiting on — the cold
    // switch (where the accumulated pull is largest) was gated on it. The
    // feed renders from local data first; the sync lands moments later and
    // the live streams pick its rows up. The fallback timer covers any path
    // where the tab-head stream doesn't emit promptly.
    _pendingFeedSync = state.context;
    _pendingFeedSyncFallback?.cancel();
    _pendingFeedSyncFallback = Timer(
      const Duration(milliseconds: 1500),
      _firePendingFeedSync,
    );
  }

  /// Focus whose activity-feed sync is owed once the feed has rendered (or
  /// the fallback timer fires). Overwritten by a newer [_loadPriority] —
  /// only the most recent focus is synced.
  Priority? _pendingFeedSync;
  Timer? _pendingFeedSyncFallback;

  void _firePendingFeedSync() {
    final priority = _pendingFeedSync;
    if (priority == null) return;
    _pendingFeedSync = null;
    _pendingFeedSyncFallback?.cancel();
    _pendingFeedSyncFallback = null;
    if (isClosed) return;
    unawaited(_triggerActivityFeedSync(priority));
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
      emit(state.copyWith(draft: existingDraft, draftNote: draftNote));
    }
  }

  /// Adds a thread by converting the current draft to a non-draft.
  /// Creates a fresh draft for the priority afterward.
  /// If note is provided, converts it from draft to published.
  /// AI title generation is handled by Thread.save().
  /// Returns the saved thread.
  Future<Thread> add(Thread thread, {Note? note}) async {
    // Convert the draft to a non-draft. When the first note is one the author
    // flagged as their own task (Tag.todo via the editor's "To do" toggle),
    // activate the whole thread ATOMICALLY here — the same copyWith(todo: true)
    // path the thread-level toggle uses — so the new thread is born in Active at
    // the BOTTOM (Order.last) with durable per-user state. Otherwise the thread
    // is published inactive (briefly visible under Done) and only flipped to
    // Active afterward by Note.save() -> Note.ensureTodoForUser, which appended
    // at the TOP and left the order unpushed. With this, that propagation
    // becomes a no-op (its guard sees the thread already active).
    final isSelfTodo = note?.hasTag(Tag.todo, Base.actorId) ?? false;
    final savedThread =
        thread.copyWith(draft: false, todo: isSelfTodo ? true : null);

    // If the draft note carries a CreateLinkUserAction, stash a pending
    // create_link payload so ThreadsBase.toBase spreads it into the thread
    // push body. The server dispatches to the connector's onCreateLink once
    // the thread is titled and persisted. (savedThread.id == thread.id since
    // copyWith only flips draft/todo.)
    _stashPendingCreateLink(savedThread.id, note);

    await savedThread.save();

    // Convert draft note to published if provided. Tags on the note (including
    // self-assignment via Tag.todo) come from explicit user toggles in the
    // editor — never auto-applied here.
    // Publish the draft note when it has body content OR carries an external
    // link action (an empty-body "thread about a link" keeps the link on the
    // note — it is no longer promoted to a thread-level LinkRow). Mirrors the
    // new-thread send-button predicate and the finalizeThreadDraft guard.
    final hasNoteContent =
        note?.content != null && note!.content!.trim().isNotEmpty;
    final hasNoteLink =
        note?.actions?.whereType<ExternalUserAction>().isNotEmpty ?? false;
    if (note != null && (hasNoteContent || hasNoteLink)) {
      final publishedNote = note.copyWith(
        threadId: savedThread.id,
        draft: false,
      );
      await publishedNote.save();
    }

    // Create fresh draft for the priority (use remembered default if set)
    resetDraftAfterSend(thread.priority);

    return savedThread;
  }

  /// Emits a fresh draft thread + draft note for the priority so the compose
  /// surface is clean for the next new thread. Extracted from [add] so the
  /// deferred (undoable) new-thread path can reuse it without publishing.
  void resetDraftAfterSend(Priority priority) {
    final newDraft = Thread(
      priority: _newThreadDefaultPriority ?? priority,
      draft: true,
    );
    emit(
      state.copyWith(
        draft: newDraft,
        draftNote: Note.draft(threadId: newDraft.id),
      ),
    );
  }

  /// Stashes a pending create_link payload keyed by thread id so
  /// [ThreadsBase.toBase] spreads it into the thread push body when the
  /// thread is saved. Mirrors the inline block in [add] lines 3920–3937.
  void _stashPendingCreateLink(ThreadId threadId, Note? note) {
    final createAction = note?.actions
        ?.whereType<CreateLinkUserAction>()
        .firstOrNull;
    if (createAction != null) {
      ThreadsBase.pendingCreateLinks[threadId.toString()] = {
        'create_link': {
          'twist_instance_id': createAction.twistInstanceId,
          'channel_id': createAction.channelId,
          'type': createAction.linkType,
          'status': createAction.status,
        },
        if (note?.content != null) 'note_content': note!.content,
      };
    }
  }

  /// Defers publishing a brand-new thread so the 5-second undo window can
  /// fire. The draft thread row stays `draft=true` in the DB; [PendingSend]
  /// holds the promote-ready thread + publish-ready note. When the window
  /// elapses (or the app closes), [PendingSend.commit] promotes the thread
  /// and publishes the note atomically.
  ///
  /// Falls back to the immediate [add] path when [note] is null (nothing
  /// to undo — an empty-body thread with no link action).
  Future<Thread> sendThreadWithUndo(Thread draftThread, {Note? note}) async {
    // No note → nothing to undo; use the existing immediate publish path.
    if (note == null) {
      return add(draftThread, note: null);
    }

    _stashPendingCreateLink(draftThread.id, note);

    final isSelfTodo = note.hasTag(Tag.todo, Base.actorId);
    final promoteThread =
        draftThread.copyWith(draft: false, todo: isSelfTodo ? true : null);
    final publishNote = note.copyWith(threadId: draftThread.id, draft: false);

    // Reset the compose surface WITHOUT publishing — the draft thread row
    // stays `draft=true` in the DB until PendingSend.commit() fires.
    resetDraftAfterSend(draftThread.priority);

    PendingSend.instance.start(note: publishNote, newThread: promoteThread);

    return draftThread;
  }

  void _loadAgenda({bool triggerSync = true, _PriorityLoadProfile? profile}) {
    // Null in the unscoped Everything view. The agenda streams are global
    // (search/filter/focus never narrow them), so [priorityToLoad] only
    // selects the [AgendaBuilder] dimming context and the per-focus sync.
    final Priority? priorityToLoad = state.context;
    // The agenda always needs a real priority for [isOutside] dimming; with
    // no scoped context use the draft's Inbox fallback.
    final agendaContext = priorityToLoad ?? state.draft.priority;

    profile?.mark('_loadAgenda subscribe start');
    log.fine('Loading agenda for priority ${agendaContext.id}');
    _agendaSubscription?.cancel();
    var firstEmissionLogged = false;

    // Three streams are combined:
    // 1. Events: paginated, hard-scheduled rows (shared or link schedule)
    //    within the date window. LIMIT governs the event horizon, grown
    //    as the user scrolls via [fetchMoreAgendaItems].
    // 2. Todos: all active user-only todos. NO LIMIT — constraint 1
    //    from the agenda spec ("we only care about the existence of at
    //    least one active thread per priority") means a flood of overdue
    //    or sentinel-dated todos must not crowd events out of the events
    //    stream. Keeping todos in their own stream sidesteps the LIMIT.
    // 3. Associated threads: children of active thread associations,
    //    surfaced under their parent event in the agenda block.
    final dateRange = CustomBoundedDateRange(
      Date.today(),
      Date.today().addDays(_agendaHorizonDays),
    );
    // The agenda is universal — search, filter, and icon filters are
    // priority-page concepts and never narrow the agenda. Only
    // [showArchived] gates which threads appear here, mirroring the
    // user's archived-view toggle.
    final eventsStream = Thread.watch(
      archived: state.showArchived ? null : false,
      order: ThreadOrder.sorted,
      includeUnscheduled: false,
      range: dateRange,
      // Restrict the datetime-based event branches to "in progress at
      // now and forward" — `AgendaBuilder` drops past link schedule
      // instances anyway, so fetching them only wastes work. Uses
      // [Time.now] so the agenda matches the user's frozen time when
      // time travel is enabled (otherwise events on dates between
      // frozen-now and real-now silently disappear).
      eventsActiveAt: Time.now(),
      // Drop the user-schedule branches; the todosStream below is the
      // sole source for those rows.
      eventsOnly: true,
    );
    // Todos query: every active user-only todo, no LIMIT and no date
    // range. Surfacing one row per todo is intentional — `AgendaBuilder`
    // collapses past-dated todos to today via `agendaAt`, and future-dated
    // todos to their actual date, so the stream's full output naturally
    // covers the "current day + future days with at least one todo"
    // contract the agenda needs. If todo volume ever becomes a perf
    // concern we can switch to a GROUP BY priority + date-bucket
    // existence query, but at present even calendar-heavy users land
    // in the low-hundreds range.
    final todosStream = Thread.watch(
      archived: state.showArchived ? null : false,
      order: ThreadOrder.sorted,
      todoOnly: true,
    ).startWith(_seedTodosResult);
    // Seed the associations stream so [combineLatest] can fire on the
    // FIRST emission of [eventsStream] alone. Without this, cold-start
    // agenda render is gated on the 6-join associations SQL completing —
    // which on a fresh app open is often empty anyway. When the real
    // associations emission arrives moments later it will re-fire
    // combineLatest and the throttleTime/distinct downstream collapses
    // the burst.
    //
    // On cold start [_seedAssociatedThreads]/[_seedTodosResult] are the
    // empty defaults (matching the original behavior). On re-subscribe
    // — fetchMoreAgendaItems, setPriority, time changes, full resync —
    // they hold the most recent values from the previous subscription,
    // so the leading throttle emission contains real todos/associations
    // instead of empties. Without this, the agenda would briefly drop to
    // events-only during every resubscribe; an in-flight ballistic
    // scroll would then clamp against a near-zero `maxScrollExtent` and
    // jump to the top by the time real data returned.
    final associatedStream = Thread.watchAssociatedThreads().startWith(
      _seedAssociatedThreads,
    );

    _agendaSubscription =
        Rx.combineLatest3<
              ThreadWatchResult,
              ThreadWatchResult,
              List<Thread>,
              ThreadWatchResult
            >(eventsStream, todosStream, associatedStream, (
              eventsResult,
              todosResult,
              associatedThreads,
            ) {
              // Capture the latest per-stream values so a future
              // re-subscription (fetchMoreAgendaItems, setPriority,
              // time change, full resync) can seed its todos/associated
              // startWith() with real data instead of empties. See the
              // declaration of [_seedTodosResult] above.
              _seedTodosResult = todosResult;
              _seedAssociatedThreads = associatedThreads;
              // Merge events + todos, deduplicating by (id, occurrence,
              // isLinkScheduleInstance) since a thread with both a
              // user-only todo and a calendar event surfaces in both
              // streams and `_mapResultsToThreads` may emit multiple
              // Thread instances per id (one per occurrence).
              final seen = <String>{};
              final merged = <Thread>[];
              String key(Thread t) =>
                  '${t.id}:${t.occurrence ?? ''}:${t.isLinkScheduleInstance ? 1 : 0}';
              for (final t in eventsResult.threads) {
                if (seen.add(key(t))) merged.add(t);
              }
              for (final t in todosResult.threads) {
                if (seen.add(key(t))) merged.add(t);
              }

              final mergedIds = merged.map((t) => t.id).toSet();

              // Merge associated threads that aren't already in the agenda.
              // Include any associated child whose parent event is visible
              // in the (now global) agenda.
              final visibleEventIds = merged
                  .where((t) => t.isLinkScheduleInstance || t.hasLinkSchedule)
                  .map((t) => t.id)
                  .toSet();
              final extra = associatedThreads.where((t) {
                if (mergedIds.contains(t.id)) return false;
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

              // `rawRowCount` still drives the pagination grow logic in
              // [fetchMoreAgendaItems]; it should reflect the events
              // stream alone since that's where pagination is anchored.
              return (
                threads: [...merged, ...extra],
                rawRowCount: eventsResult.rawRowCount,
                feedTailCursor: null,
              );
            })
            .map((result) {
              // Compute a cheap signature so identical re-emissions can be
              // dropped before we pay the _makeAgenda cost. Drift streams
              // re-fire on every table change, so repeated syncs of unrelated
              // tables produce many identical emissions.
              //
              // The signature includes schedule-derived fields
              // (`todo`, `agendaAt`, `order`, `archivedAt`) in addition
              // to the thread row's `updatedAt`. `Thread.save()` writes
              // the thread row and the `user_schedule` row separately,
              // so Drift can emit a snapshot in between — at that
              // moment `t.updatedAt` has been bumped (sig differs from
              // the pre-save state and passes [.distinct]) but
              // `_userSchedule` still reflects the old startOn/order.
              // The next emission, after the user_schedule write, leaves
              // `t.updatedAt` unchanged, so without schedule fields in
              // the sig that final emission would match the intermediate
              // sig and be dropped — leaving the agenda stuck on the
              // stale snapshot. Including the schedule-derived fields
              // forces the post-userschedule emission through.
              final threadSig =
                  (result.threads
                          .map(
                            (t) =>
                                '${t.id}:${t.updatedAt.microsecondsSinceEpoch}'
                                ':${t.occurrence ?? ''}'
                                ':${t.isLinkScheduleInstance ? 1 : 0}'
                                ':${t.priority.id}'
                                // Include the priority's display colour so a
                                // focus colour edit (which doesn't bump the
                                // thread row's `updatedAt` or change its id)
                                // produces a distinct signature and isn't
                                // dropped by [.distinct] below — otherwise the
                                // agenda's event blocks keep their stale colour.
                                ':${t.priority.displayColor.index}'
                                ':${t.todo ? 1 : 0}'
                                ':${t.archivedAt?.microsecondsSinceEpoch ?? 0}'
                                ':${t.agendaAt.microsecondsSinceEpoch}'
                                ':${t.order.value}',
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
                emit(state.copyWith(agendaDoneEnd: false, agendaLoaded: true));
                return;
              }
              _lastAgendaThreads = patchedThreads;
              final buildStart = profile == null
                  ? null
                  : (Stopwatch()..start());
              final agenda = AgendaBuilder.build(
                threads: patchedThreads,
                context: agendaContext,
                horizonDays: _agendaHorizonDays,
                minFillDays: _agendaFillDays,
                associationsByParentId: _associations,
                priorityBlocksByPriority: _priorityBlocksByPriority,
                priorityById: _priorityById,
                pausedFocus: _pausedFocus == null
                    ? null
                    : (
                        priority: _pausedFocus!.priority,
                        remaining: _pausedFocus!.remaining,
                      ),
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
                  agendaItems: agenda.flatItems(),
                  agendaDoneEnd: false,
                  agendaLoaded: true,
                  reorderViewItems: const Value(null),
                ),
              );
              profile?.mark('agenda state emitted');
            });

    // The per-focus agenda sync is scoped to a real focus; the unscoped
    // Everything view has no focus to anchor it, and its activity-feed sync
    // already populates the local DB the global agenda streams read from.
    if (triggerSync && priorityToLoad != null) {
      _agendaSyncFuture = _triggerAgendaSync(priorityToLoad);
    }
  }

  bool get _effectiveShowArchived => state.showArchived;

  Future<void> _triggerAgendaSync(Priority priorityToLoad) async {
    final archived = _effectiveShowArchived;
    // The sync cursor anchor keys on the priority id string (path-independent),
    // matching [ThreadsBase.filterName].
    final scopeKey = priorityToLoad.id.toString();
    final suffix = archived ? '_archived' : '';
    final entityName = 'agenda:$scopeKey$suffix';

    // Fetch-more loop: pull pages until we have enough local items AND the
    // sync boundary covers the last visible item's date, or server has no more.
    for (var i = 0; i < 10; i++) {
      await Thread.pullAgenda(
        priorityToLoad.id,
        archived: archived,
      );

      final syncState = await (Store.get.select(
        Store.get.syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();
      _agendaSyncNoMore = syncState?.noMore ?? true;

      if (_agendaSyncNoMore) break;

      // Stop when the sync boundary covers the visible horizon — we've
      // fetched every event up to today + _agendaHorizonDays. Pagination
      // is by date range, not row count.
      final horizonEnd = Date.today().addDays(_agendaHorizonDays).toDateTime();
      final syncBoundary = syncState?.last != null
          ? DateTime.fromMicrosecondsSinceEpoch(syncState!.last!, isUtc: true)
          : null;
      final syncedToHorizon =
          syncBoundary != null && !syncBoundary.isBefore(horizonEnd);

      if (syncedToHorizon) break;
    }

    // Agenda is infinite — never mark it as done at the end.
    // fetchMoreAgendaItems will extend the horizon as the user scrolls.
  }

  /// Switch which activity-feed tab the user is viewing. Tears down the
  /// previous tab's per-tab subscription and starts the new tab's, also
  /// clearing the overlay so the new tab's first emission is canonical.
  void selectActivityTab(ActivityTab tab) {
    if (state.activeTab == tab) return;
    // Switching tabs shows a different set of rows — drop any multi-selection.
    emit(state.copyWith(
      activeTab: tab,
      selected: const {},
      selectionAnchor: const Value(null),
    ));
    _restartActiveTabSubscription();
  }

  /// Build the Event Agenda prefix items — pinned event thread plus its
  /// associated threads. Returns an empty list when no event is selected
  /// or when the selected event belongs to another focus — the prefix
  /// must never render over rows from a context that doesn't own it
  /// (defense in depth behind [setCurrentEventForFeed]'s deferral).
  List<AgendaItem> _buildEventAgendaItems() {
    final currentEvent = eventAgendaEventFor(
      _currentEventForFeed,
      state.context?.id,
    );
    if (currentEvent == null) return const <AgendaItem>[];
    final items = <AgendaItem>[
      AgendaHeaderItem(
        text: ActivitySectionMarker.encode(ActivitySection.eventAgenda),
      ),
      AgendaThreadItem(currentEvent, pinned: true),
    ];
    final eventAssocs = _associations?[currentEvent.id] ?? const [];
    if (eventAssocs.isEmpty) return items;
    final lookup = <ThreadId, Thread>{};
    for (final t in _activeTabHead) {
      lookup.putIfAbsent(t.id, () => t);
    }
    for (final t in _activeTabAppended) {
      lookup.putIfAbsent(t.id, () => t);
    }
    for (final t in _lastAgendaThreads) {
      lookup.putIfAbsent(t.id, () => t);
    }
    final ordered = List<ThreadAssociationRow>.from(eventAssocs)
      ..sort((a, b) => a.order.compareTo(b.order));
    final parentKey =
        '${currentEvent.id}${currentEvent.occurrence != null ? '_${currentEvent.occurrence}' : ''}';
    for (final assoc in ordered) {
      final child = lookup[assoc.childThreadId];
      if (child == null) continue;
      items.add(
        AgendaThreadItem(
          child,
          isAssociated: true,
          associationParentId: parentKey,
          associationOrder: assoc.order,
        ),
      );
    }
    return items;
  }

  Future<void> _triggerActivityFeedSync(Priority priorityToLoad) async {
    final archived = _effectiveShowArchived;
    // The sync cursor anchor keys on the priority id string (path-independent),
    // matching [ThreadsBase.filterName].
    final scopeKey = priorityToLoad.id.toString();
    final suffix = archived ? '_archived' : '';
    final entityName = 'activity-feed:$scopeKey$suffix';

    // True when the loop exits because the sync boundary now covers the
    // last locally-visible item — i.e. we've pulled everything the feed
    // can show, even though the server may still have more older items.
    // Tracked across iterations so the post-loop guard can use it.
    var syncedPastLastItem = false;

    // Fetch-more loop: pull pages until we have enough local items AND the
    // sync boundary covers the last visible item's date, or server has no more.
    for (var i = 0; i < 10; i++) {
      await Thread.pullActivityFeed(
        priorityToLoad.id,
        archived: archived,
      );

      final syncState = await (Store.get.select(
        Store.get.syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();
      _activityFeedSyncNoMore = syncState?.noMore ?? true;

      if (_activityFeedSyncNoMore) break;

      // Check local activity feed to decide if we need more pages.
      final localThreads = await Thread.get(
        priorityId: priorityToLoad.id,
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
      syncedPastLastItem =
          syncBoundary != null &&
          lastItemDate != null &&
          !syncBoundary.isAfter(lastItemDate);

      // Stop when both conditions are met: page is full AND sync covers it.
      if (hasEnoughItems && syncedPastLastItem) break;
    }

    if (isClosed) return;
    // Caught up: server says no more, OR the sync boundary now covers
    // our last visible item (anything still unpulled is outside the
    // active tab's LIMIT window). Re-emit the active per-tab section so
    // `activityFeedDoneEnd` recomputes from the new sync state — the
    // trailing spinner stops once syncNoMore is observed.
    final caughtUp = _activityFeedSyncNoMore || syncedPastLastItem;
    if (caughtUp && _activeTabSubscriptionTab != null) {
      _rebuildActiveTabSection();
    }
  }

  Future<void> fetchMoreActivityFeedItems(int first, int count) async {
    // No active head subscription yet — defensive guard so InfiniteList
    // doesn't hang before the feed has loaded.
    if (_activeTabSubscriptionTab == null) return;
    // Flat (search/filter) mode pages the single unified query; sectioned
    // mode pages only the Done tail (Unread + Active+Scheduled are fully
    // loaded by their head streams).
    if (_activeTabFlatMode) {
      return _fetchMoreAllTab(first, count);
    }
    return _fetchMoreDone(first, count);
  }

  /// Latest [PausedFocus] observed from [NowBloc]. Passed to every
  /// [AgendaBuilder.build] call so the agenda renders the sliding block
  /// while a focus session is paused.
  PausedFocus? _pausedFocus;

  /// The `now` value at the last agenda rebuild triggered by a NowBloc tick
  /// while paused. Used to gate 1-second-advance rebuilds and avoid
  /// redundant emits.
  DateTime _lastNowForPaused = DateTime.fromMillisecondsSinceEpoch(0);

  /// Reference to [NowBloc] for session routing in [moveFocusBlock].
  late final NowBloc _nowBloc;

  /// Subscription to [NowBloc.stream] for [_pausedFocus] updates.
  StreamSubscription<NowState>? _nowSubscription;

  /// Subscription to [LocalPreferencesBloc.stream] so the global
  /// archived-visibility flag drives this focus's `showArchived`.
  StreamSubscription<LocalPreferencesState>? _localPreferencesSubscription;

  /// Last `showAllPriorities` value seen from [LocalPreferencesBloc], used to
  /// ignore preference emissions that don't change archived visibility.
  bool _showArchivedFromPrefs = false;

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _fullResyncSubscription;
  StreamSubscription<void>? _threadSubscription;
  StreamSubscription<void>? _agendaSubscription;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
  StreamSubscription<List<(Reaction, int)>>? _reactionsSubscription;
  StreamSubscription<List<(String, int)>>? _iconCountsSubscription;

  // Initial cold-start window kept small for fast first paint; grows via
  // [fetchMoreAgendaItems] as the user scrolls.
  int _agendaHorizonDays = 30;
  // Minimum days from today to populate with empty headers. Starts at 0
  // so [AgendaBuilder.build]'s 14-day buffer past the last-content date
  // dominates on the initial render. Grows in [fetchMoreAgendaItems] as
  // the user scrolls past the buffer so more empty days appear instead
  // of leaving the user on a stuck spinner.
  int _agendaFillDays = 0;

  /// Fixed page size for every activity-feed per-tab query. The watcher
  /// always covers the head (top [_activityFeedLimit] threads); scrolling
  /// past appends static pages via cursor pagination in
  /// [fetchMoreActivityFeedItems], so watcher cost stays constant
  /// regardless of scroll depth.
  static const int _activityFeedLimit = 50;

  /// Head limit for the bounded sectioned streams (Unread, Active+Scheduled).
  /// These sets are a user's curated Updates / Doing / Scheduled lists, so
  /// they're small in practice (tens, occasionally low hundreds) — well under
  /// this cap — and are loaded whole so they always surface regardless of the
  /// Done tail's volume. Only the Done section paginates past its head.
  static const int _boundedSectionLimit = 1000;
  bool _agendaSyncNoMore = false;
  bool _activityFeedSyncNoMore = false;
  Future<void>? _agendaSyncFuture;
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
    this.useDefault = false,
    this.setContext = true,
    required this.child,
    super.key,
  });

  final PriorityId? priorityId;
  final ThreadId? threadId;
  final Priority? priority;

  /// When true, load the user's default (root) priority directly instead of a
  /// specific priority/thread. This is an intentional, warning-free path for
  /// universal views like the global Search tab that span every focus and have
  /// no single priority to target. Distinct from the error-fallback default:
  /// supplying none of [priorityId]/[threadId]/[priority] without this flag is
  /// a misuse and is surfaced as an error.
  final bool useDefault;

  /// When true (default), the loaded priority is published to [NowBloc] as
  /// the user's current context. Universal views like the agenda — which
  /// are keyed to the default priority but are not "the user navigated
  /// here" — should pass `false` so they don't clobber the context the
  /// user actually chose.
  final bool setContext;

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

  /// Monotonic counter incremented every time [didUpdateWidget] sees a new
  /// priorityId or priority prop. Pairs with the bloc-side
  /// `_priorityLoadGeneration` to drop stale `setPriority` calls when the
  /// user toggles A→B→A faster than `Priority.getOne` resolves.
  int _switchGen = 0;

  @override
  void initState() {
    super.initState();
    _bloc = _loadPriorityWithFallback();
  }

  Future<_LoadResult> _loadPriorityWithFallback() async {
    // Capture the NowBloc and current Everything-feed flag before any await
    // so a fresh PriorityBloc (e.g. navigating from a focus straight to
    // Everything) starts in the right feed mode. The priority page keeps
    // it in sync afterwards via setEverything.
    final nowBloc = context.read<NowBloc>();
    // Capture before any await — used to seed the bloc's archived visibility
    // and keep it reacting to the global flag.
    final localPreferences = context.read<LocalPreferencesBloc>();
    final everything = nowBloc.everything;
    // Snapshot the switch generation at load-initiation. If a newer switch
    // arrives via didUpdateWidget while Priority.getOne is in flight,
    // `_switchGen` advances past this value and the deferred setContext
    // calls below must bail — otherwise this stale initial priority
    // clobbers NowBloc.context after the newer switch already set it,
    // reverting the sidebar to the previous focus. Mirrors the `_switchGen`
    // guard in didUpdateWidget.
    final myGen = _switchGen;
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
          // Intentional default-priority path (e.g. global Search). Load the
          // default directly so universal views don't trip the error fallback
          // (which would log a WARNING on every mount).
          : widget.useDefault
          ? Priority.getDefault()
          : Future<Priority>.error(
              'Either priorityId or threadId must be provided',
            ));

      // Success - update theme and create bloc
      if (widget.setContext) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Drop this initial-load context publish if a newer switch
          // superseded it while getOne was in flight (see `myGen` above).
          if (myGen != _switchGen || !mounted) return;
          context.read<NowBloc>().setContext(priority);
        });
      }

      return _LoadResult.success(
        PriorityBloc(
          priority: priority,
          nowBloc: nowBloc,
          localPreferences: localPreferences,
          everything: everything,
        ),
      );
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
        if (widget.setContext) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Same stale-switch guard as the success path above.
            if (myGen != _switchGen || !mounted) return;
            context.read<NowBloc>().setContext(defaultPriority);
          });
        }

        return _LoadResult.success(
          PriorityBloc(
            priority: defaultPriority,
            nowBloc: nowBloc,
            localPreferences: localPreferences,
            everything: everything,
          ),
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
      final myGen = ++_switchGen;
      _bloc.then((result) {
        final priority = widget.priority;
        if (priority == null || result.bloc == null) return;
        // A newer switch arrived while waiting on the bloc Future — let it
        // win to avoid a stale priority emit clobbering the current one.
        if (myGen != _switchGen || !mounted) return;
        result.bloc!.setPriority(priority);
        // Theme will be updated when new agenda loads (in _loadAgenda)
      });
    } else if (widget.priorityId != null &&
        widget.priorityId != oldWidget.priorityId) {
      final myGen = ++_switchGen;
      // Stopwatch starts at the user-visible click time. Logs how long
      // didUpdateWidget's pre-setPriority work takes so the [PriorityProfile]
      // timeline covers the full click-to-threads window.
      final didUpdateSw = Stopwatch()..start();
      log.info('[PriorityProfile][didUpdate:${widget.priorityId}] start');
      _bloc.then((result) async {
        if (result.bloc == null) return;
        final priority = await Priority.getOne(widget.priorityId!);
        log.info(
          '[PriorityProfile][didUpdate:${widget.priorityId}] '
          'Priority.getOne done @ ${didUpdateSw.elapsedMilliseconds}ms',
        );
        // Drop this switch if a newer one has been requested since.
        if (myGen != _switchGen || !mounted) return;
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
                  child: const Text('View Focuses'),
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

/// True when a [NowBloc.currentEvent] mirror must NOT be applied to the
/// feed yet because a cross-focus transition is in flight.
///
/// [ChangeCurrentPriority] and [NowBloc.setCurrentEvent] move NowBloc's
/// context synchronously at tap time, while the activity feed swaps
/// atomically on the first emission after [PriorityBloc.setPriority] —
/// so whenever the two contexts disagree, the mirror is ahead of the
/// rendered rows and applying it would flip the Event Agenda prefix one
/// frame early (new event over the old focus's threads on the way in;
/// prefix vanishing before the rows on the way out). A null
/// [nowContextId] (NowBloc not loaded) applies immediately.
bool shouldDeferEventMirror({
  required PriorityId? nowContextId,
  required PriorityId? feedContextId,
}) {
  // A null [feedContextId] is the unscoped Everything feed — there is no
  // per-focus row swap to wait for, so apply the mirror immediately.
  if (feedContextId == null) return false;
  return nowContextId != null && nowContextId != feedContextId;
}

/// The event allowed to drive the "Event Agenda" prefix for a feed whose
/// context is [feedContextId]: [event] when that context owns it, null
/// otherwise. Keeps an event filed in another focus from ever rendering
/// over rows it doesn't belong with.
Thread? eventAgendaEventFor(Thread? event, PriorityId? feedContextId) {
  if (event == null) return null;
  // No scoped context (Everything) → no focus owns the event, so the
  // ownership-gated Event Agenda prefix is empty (the flat Everything feed
  // leads with rows, not an event section).
  if (feedContextId == null) return null;
  return event.priority.id == feedContextId ? event : null;
}
