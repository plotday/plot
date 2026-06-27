part of 'priority.dart';

/// Which list the user last selected a thread from.
/// Used by Previous/Next Thread commands to determine navigation list.
enum ThreadListSource { agenda, activityFeed }

@immutable
class PriorityState extends Equatable {
  factory PriorityState({
    required Priority? context,
    Priority? draftFallbackPriority,
    Thread? thread,
    Thread? draft,
    Note? draftNote,
    bool showArchived = false,
    bool muteOnly = false,
    AgendaModel agenda = AgendaModel.empty,
    List<AgendaItem>? agendaItems,
    bool agendaDoneEnd = false,
    bool agendaLoaded = false,
    List<Tag> filter = const [],
    List<Reaction> reactionFilter = const [],
    String search = '',
    List<TwistInstance> twists = const [],
    List<Actor> actors = const [],
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    List<(Reaction, int)> reactions = const [],
    Map<ActivityTab, ActivityFeedTabData> activityFeedByTab = const {},
    ActivityTab activeTab = ActivityTab.catchUp,
    bool activityFeedDoneEnd = false,
    bool activityFeedLoaded = false,
    List<AgendaItem>? reorderViewItems,
    List<String> iconFilter = const [],
    List<ActorId> assigneeFilter = const [],
    List<(String, int)> iconCounts = const [],
    List<Thread> remoteSearchExtras = const [],
    bool remoteSearchInProgress = false,
    bool remoteSearchOffline = false,
    bool hasArchivedMatches = false,
    bool showSubPriorities = true,
    bool everything = false,
    Priority? globalViewScope,
    Set<ThreadId> selected = const {},
    ThreadId? selectionAnchor,
    bool unreadFilterActive = false,
  }) {
    // Invariant: the synthetic "Everything" view is the one and only
    // context-less state. `everything == true` iff `context == null`, so
    // every reader can treat a null context as "Everything" without a
    // separate flag check.
    assert(
      (context == null) == everything,
      'PriorityState invariant: everything <=> context == null',
    );
    // Drafts must always file somewhere. In a focus view that is the focus
    // itself; in the context-less Everything view it is the supplied
    // fallback (the app's default Inbox). Only resolved when a draft must be
    // synthesized — callers that pass an explicit draft already chose where
    // it files.
    if (draft == null) {
      final draftPriority = context ?? draftFallbackPriority;
      assert(
        draftPriority != null,
        'a context-less state needs a draftFallbackPriority',
      );
      draft = Thread(priority: draftPriority!, draft: true);
    }

    return PriorityState._(
      context: context,
      thread: thread,
      draft: draft,
      draftNote: draftNote ?? Note.draft(threadId: draft.id),
      agenda: agenda,
      agendaItems: agendaItems != null && agendaItems.isNotEmpty
          ? List.unmodifiable(agendaItems)
          : agendaItems ?? const [],
      agendaDoneEnd: agendaDoneEnd,
      agendaLoaded: agendaLoaded,
      showArchived: showArchived,
      muteOnly: muteOnly,
      filter: filter.isNotEmpty ? List.unmodifiable(filter) : filter,
      reactionFilter: reactionFilter.isNotEmpty
          ? List.unmodifiable(reactionFilter)
          : reactionFilter,
      search: search,
      twists: twists.isNotEmpty ? List.unmodifiable(twists) : twists,
      actors: actors.isNotEmpty ? List.unmodifiable(actors) : actors,
      tags: tags.isNotEmpty ? List.unmodifiable(tags) : tags,
      tagSuggestions: tagSuggestions.isNotEmpty
          ? List.unmodifiable(tagSuggestions)
          : tagSuggestions,
      reactions: reactions.isNotEmpty ? List.unmodifiable(reactions) : reactions,
      activityFeedByTab: activityFeedByTab.isNotEmpty
          ? Map.unmodifiable(activityFeedByTab)
          : activityFeedByTab,
      activeTab: activeTab,
      activityFeedDoneEnd: activityFeedDoneEnd,
      activityFeedLoaded: activityFeedLoaded,
      reorderViewItems: reorderViewItems != null
          ? List.unmodifiable(reorderViewItems)
          : null,
      iconFilter: iconFilter.isNotEmpty
          ? List.unmodifiable(iconFilter)
          : iconFilter,
      assigneeFilter: assigneeFilter.isNotEmpty
          ? List.unmodifiable(assigneeFilter)
          : assigneeFilter,
      iconCounts: iconCounts.isNotEmpty
          ? List.unmodifiable(iconCounts)
          : iconCounts,
      remoteSearchExtras: remoteSearchExtras.isNotEmpty
          ? List.unmodifiable(remoteSearchExtras)
          : remoteSearchExtras,
      remoteSearchInProgress: remoteSearchInProgress,
      remoteSearchOffline: remoteSearchOffline,
      hasArchivedMatches: hasArchivedMatches,
      showSubPriorities: showSubPriorities,
      everything: everything,
      globalViewScope: globalViewScope,
      selected: selected.isNotEmpty ? Set.unmodifiable(selected) : selected,
      selectionAnchor: selectionAnchor,
      unreadFilterActive: unreadFilterActive,
    );
  }

  const PriorityState._({
    required this.context,
    this.thread,
    required this.draft,
    required this.draftNote,
    required this.agenda,
    required this.agendaItems,
    this.agendaDoneEnd = false,
    this.agendaLoaded = false,
    this.showArchived = false,
    this.muteOnly = false,
    this.filter = const [],
    this.reactionFilter = const [],
    this.search = '',
    this.twists = const [],
    this.actors = const [],
    this.tags = const [],
    this.tagSuggestions = const [],
    this.reactions = const [],
    this.activityFeedByTab = const {},
    this.activeTab = ActivityTab.catchUp,
    this.activityFeedDoneEnd = false,
    this.activityFeedLoaded = false,
    this.reorderViewItems,
    this.iconFilter = const [],
    this.assigneeFilter = const [],
    this.iconCounts = const [],
    this.remoteSearchExtras = const [],
    this.remoteSearchInProgress = false,
    this.remoteSearchOffline = false,
    this.hasArchivedMatches = false,
    this.showSubPriorities = true,
    this.everything = false,
    this.globalViewScope,
    this.selected = const {},
    this.selectionAnchor,
    this.unreadFilterActive = false,
  });

  /// The focus (priority) this page is scoped to. `null` is the synthetic
  /// "Everything" view — see the [everything] invariant. Readers must treat
  /// null as "unscoped / Everything", never dereference it. The draft files
  /// under [draft]'s priority (the focus, or the default-Inbox fallback in
  /// the Everything view), not under this field.
  final Priority? context;
  final Thread? thread;
  final Thread draft;
  final Note draftNote;
  final bool showArchived;

  /// When true, the activity feed is filtered down to threads carrying a
  /// `mute_by_thread_id` flag — i.e. only threads swept up by a "Skip
  /// active for threads like this" rule. Lets users find and toggle the
  /// rule from the normal (non-archived) view since muted threads now
  /// land in Done, not Archive. In-memory only; resets to false on bloc
  /// rebuild.
  final bool muteOnly;

  /// Block-aware view of the agenda. Source of truth going forward; the
  /// flat [agendaItems] is held alongside during the migration so legacy
  /// rendering and reorder paths continue to work without rewrites.
  final AgendaModel agenda;
  final List<AgendaItem> agendaItems;
  final bool agendaDoneEnd;
  final bool agendaLoaded;
  final List<Tag> filter;
  final List<Reaction> reactionFilter;
  final String search;
  final List<TwistInstance> twists;
  final List<Actor> actors;
  final List<(Tag, int)> tags;
  final List<Tag> tagSuggestions;
  final List<(Reaction, int)> reactions;
  /// Per-tab build output for the activity feed. Each tab's data carries
  /// the flat `AgendaItem` list the widget renders for it, plus the
  /// pre-cascade native-by-date map used by Reschedule All (only
  /// populated for action tabs — Respond / Do / Read).
  final Map<ActivityTab, ActivityFeedTabData> activityFeedByTab;

  /// Which of the activity-feed tabs the user is currently viewing.
  /// Changing this is purely a view operation — the bloc rebuilds every
  /// tab's items together on each underlying thread change, so switching
  /// tabs is just a re-render.
  final ActivityTab activeTab;

  /// The flat `AgendaItem` list for the active tab. Backwards-compatible
  /// shim over [activityFeedByTab] so widgets can keep reading
  /// `state.activityFeedItems` without knowing about tabs.
  List<AgendaItem> get activityFeedItems =>
      activityFeedByTab[activeTab]?.items ?? const [];

  /// Move-animation generation of the active feed (see
  /// [ActivityFeedTabData.moveGen]).
  int get feedMoveGen => activityFeedByTab[activeTab]?.moveGen ?? 0;

  /// Threads whose explicit state change produced [feedMoveGen].
  Set<ThreadId> get feedMovedIds =>
      activityFeedByTab[activeTab]?.movedIds ?? const {};

  /// True when the active tab's items were built for the dedicated
  /// "Everything" feed (see [ActivityFeedTabData.everythingFeed]). The page
  /// uses this — not the live [everything] flag — to decide whether to lead
  /// the feed with the "Everything" header, so the header tracks the items'
  /// generation and never renders over a stale sectioned focus list mid-switch.
  bool get activeTabEverythingFeed =>
      activityFeedByTab[activeTab]?.everythingFeed ?? false;

  /// The priority context the active tab's currently-displayed items were
  /// built for. Used for the per-row sub-priority (focus) label so it never
  /// disagrees with the items during a focus switch (the previous focus's
  /// rows are kept until the new feed rebuilds). Null until the first feed
  /// build — callers fall back to the live [context].
  Priority? get activeTabContext => activityFeedByTab[activeTab]?.context;

  /// Thread ids of the non-active unread cluster at the bottom of the Doing
  /// section (see [ActivityFeedTabData.unreadClusterIds]). Empty outside
  /// sectioned mode or when there is no cluster.
  Set<ThreadId> get unreadClusterIds =>
      activityFeedByTab[activeTab]?.unreadClusterIds ?? const {};

  final bool activityFeedDoneEnd;
  final bool activityFeedLoaded;

  /// [activityFeedDoneEnd] as the *filtered* view ([activityFeedViewItems])
  /// sees it. The unread-only filter ([unreadFilterActive]) shows a complete
  /// set: every unread thread is already loaded by the bounded head streams
  /// (only the read/Done tail paginates), so paging further can never surface
  /// a row the filter keeps. Without this, [InfiniteList] sees a short
  /// filtered list with `doneEnd: false` and renders a trailing spinner that
  /// auto-pages the read tail forever — visible as a spinner stuck at the end
  /// of the list the moment the unread filter is turned on.
  bool get activityFeedViewDoneEnd => activityFeedDoneEnd || unreadFilterActive;

  /// Cached agendaViewItems from an optimistic reorder. When set,
  /// [agendaViewItems] returns this directly instead of re-deriving.
  /// Cleared when new agenda data arrives.
  final List<AgendaItem>? reorderViewItems;

  final List<String> iconFilter;

  /// Active assignee filter — narrows the thread feed to threads whose
  /// `thread.assignee_id` is one of these actors. Parallel to [iconFilter];
  /// like the other filter dimensions it forces the feed global + flat.
  final List<ActorId> assigneeFilter;

  final List<(String, int)> iconCounts;

  /// Threads returned by the remote search endpoint that are not already
  /// visible in [activityFeedItems]. Empty when search is empty or offline.
  final List<Thread> remoteSearchExtras;

  /// True while the remote search request is in flight.
  final bool remoteSearchInProgress;

  /// True if the most recent remote search attempt failed because the
  /// device is offline (or the request otherwise threw a network error).
  final bool remoteSearchOffline;

  /// True if the server reports that toggling [showArchived] would surface
  /// additional matches. Drives the "View archived items matching this
  /// search" ghost button. Only meaningful when [showArchived] is false.
  final bool hasArchivedMatches;

  /// When true (default), the activity feed and todo list include threads
  /// filed under descendant priorities as well as the current priority —
  /// matching the long-standing "roll up sub-priorities" behavior. When
  /// false, only threads filed directly on [context] are shown.
  final bool showSubPriorities;

  /// When true, this bloc renders the synthetic "Everything" feed: every
  /// thread across the Inbox and all focuses, unscoped and unsectioned.
  /// Mirrored from [NowBloc.everything] by the priority page. In this mode
  /// [context] is `null` (the invariant `everything == (context == null)`),
  /// and drafts file under [draft]'s priority — the default Inbox supplied as
  /// `draftFallbackPriority`.
  final bool everything;

  /// While a global view is open (an active [search] or any active filter),
  /// the focus the user has narrowed results to. `null` means "Everything" —
  /// the full, unscoped global result set. A non-null value scopes the feed to
  /// that focus (the root scopes to the Inbox / unfiled threads). This drives
  /// focus-filtering entirely within the bloc, decoupled from route navigation
  /// and [context], so global views stay global regardless of which focus was
  /// selected when the view opened. Always `null` outside a global view.
  final Priority? globalViewScope;

  /// Ids of threads the user has multi-selected in the activity feed for a
  /// bulk operation. Empty means not in multi-select mode (see
  /// [multiSelecting]). Desktop-only — populated by modifier-click. The
  /// display-ordered, resolved view is [selectedThreads]; this raw set is
  /// membership-only.
  final Set<ThreadId> selected;

  /// Pivot row for shift-click range selection — the last row toggled (or the
  /// open thread when multi-select began on it). Null outside multi-select.
  final ThreadId? selectionAnchor;

  /// When true, the activity feed is filtered to unread threads only.
  /// In-memory only; resets to false on bloc rebuild.
  final bool unreadFilterActive;

  /// True when the active tab's feed currently contains at least one unread
  /// thread. Drives the unread-filter toggle visibility.
  bool get hasUnread {
    for (final item in activityFeedItems) {
      if (item is AgendaThreadItem && item.thread.unread) return true;
    }
    return false;
  }

  /// True when a multi-select is in progress (any thread is [selected]).
  bool get multiSelecting => selected.isNotEmpty;

  bool get doneStart => true;
  bool get doneEnd => agendaDoneEnd;

  /// The activity feed items as the user should see them — equal to
  /// [activityFeedItems] except when [muteOnly] is on (filtered to threads
  /// carrying a `mute_by_thread_id` flag) and/or when a global view is
  /// narrowed to a focus via [globalViewScope] (filtered to that focus, or
  /// the Inbox / unfiled threads when the scope is the root). Empty section
  /// headers are suppressed. The global query itself stays unscoped, so this
  /// display filter is what makes a focus pick narrow the visible results.
  List<AgendaItem> get activityFeedViewItems {
    final scope = globalViewScope;
    if (!muteOnly && scope == null && !unreadFilterActive) return activityFeedItems;
    final openId = thread?.id;
    bool keep(Thread t) {
      if (muteOnly && t.muteByThreadId == null) return false;
      if (scope != null && t.priority.id != scope.id) return false;
      if (unreadFilterActive && !t.unread && t.id != openId) return false;
      return true;
    }

    final result = <AgendaItem>[];
    final pendingHeaders = <AgendaHeaderItem>[];
    for (final item in activityFeedItems) {
      if (item is AgendaHeaderItem) {
        final isSectionHeader = item.text != null &&
            ActivitySectionMarker.tryDecode(item.text!) != null;
        if (isSectionHeader) pendingHeaders.clear();
        pendingHeaders.add(item);
      } else if (item is AgendaThreadItem && keep(item.thread)) {
        result.addAll(pendingHeaders);
        pendingHeaders.clear();
        result.add(item);
      }
    }
    return result;
  }

  /// [remoteSearchExtras] with any thread already present in the live local
  /// feed ([activityFeedViewItems]) removed.
  ///
  /// The bloc computes [remoteSearchExtras] once, by subtracting a point-in-time
  /// snapshot of the local feed taken the instant the remote request resolves.
  /// But the local feed keeps changing afterward — matching notes/threads stream
  /// in via sync, and [Thread.searchRemote] itself hydrates matching rows into
  /// the store — so a thread can enter the local feed *after* the snapshot was
  /// taken. The frozen extras list then overlaps the updated feed, and since the
  /// search views simply concatenate (local feed) + (extras) with no further
  /// dedup, that thread renders twice. Re-deriving the exclusion here, against
  /// the current feed at render time, keeps a thread from appearing in both the
  /// local list and the extras regardless of when it synced in.
  List<Thread> get remoteSearchExtrasDeduped {
    if (remoteSearchExtras.isEmpty) return remoteSearchExtras;
    final localIds = <String>{
      for (final item in activityFeedViewItems)
        if (item is AgendaThreadItem) item.thread.id.toString(),
    };
    if (localIds.isEmpty) return remoteSearchExtras;
    return remoteSearchExtras
        .where((t) => !localIds.contains(t.id.toString()))
        .toList();
  }

  /// Thread ids of the currently visible feed rows, in display order. Drives
  /// shift-click range selection. Derived from [activityFeedViewItems] so it
  /// already respects the muteOnly / global-scope filters and skips section
  /// headers (which aren't [AgendaThreadItem]s).
  List<ThreadId> get orderedFeedThreadIds => activityFeedViewItems
      .whereType<AgendaThreadItem>()
      .map((i) => i.thread.id)
      .toList();

  /// The [selected] threads resolved to [Thread] objects in feed order. Walks
  /// the visible feed first, then appends the open [thread] if it is selected
  /// but scrolled/filtered out of the feed (it still counts as selected per
  /// the "open thread joins the selection" rule). Used by the header to show
  /// the count and to construct the bulk commands.
  List<Thread> get selectedThreads {
    if (selected.isEmpty) return const [];
    final result = <Thread>[];
    final seen = <ThreadId>{};
    for (final item in activityFeedViewItems) {
      if (item is AgendaThreadItem && selected.contains(item.thread.id)) {
        if (seen.add(item.thread.id)) result.add(item.thread);
      }
    }
    final open = thread;
    if (open != null && selected.contains(open.id) && !seen.contains(open.id)) {
      result.add(open);
    }
    return result;
  }

  /// "Agenda": items starting from today, moving forward. Today's date
  /// header is preserved so the agenda always opens with a header above
  /// the first thread. When a current event is in progress, content
  /// before it is collapsed but today's date header is reinjected at the
  /// top so the section still leads with a header. Event headers are
  /// kept because they now carry the block's priority breadcrumb and
  /// accent borders — a separate row above the event's [ThreadWidget]
  /// with its own visual styling.
  List<AgendaItem> get agendaViewItems {
    if (reorderViewItems != null) return reorderViewItems!;
    final now = Time.now();

    final result = agendaItems.toList();

    // Strip the legacy standalone "Now" text header if `_makeAgenda`
    // emitted one — we no longer show it. Today's date header carries
    // the "we're here now" signal instead and is always rendered (no
    // fast-forward stripping of past content).
    final nowTextIdx = result.indexWhere(
      (item) =>
          item is AgendaHeaderItem &&
          item.now &&
          item.text == 'Now' &&
          item.thread == null,
    );
    if (nowTextIdx >= 0) {
      result.removeAt(nowTextIdx);
    }

    // Mark the next-upcoming scheduled block header as isNext so the
    // header's countdown ("in N min") renders. Post-Task-3, agendaItems
    // contains only header items (one per block); per-thread items are
    // gone, so we identify the next block directly from its header's
    // [dateTimeRange]. Gap and event blocks both carry a dateTimeRange.
    int? nextIdx;
    DateTime? nextStart;
    for (int i = 0; i < result.length; i++) {
      final item = result[i];
      if (item is! AgendaHeaderItem) continue;
      if (item.now) continue;
      final start = item.dateTimeRange?.start;
      if (start == null || !start.isAfter(now)) continue;
      if (nextStart == null || start.isBefore(nextStart)) {
        nextStart = start;
        nextIdx = i;
      }
    }
    if (nextIdx != null) {
      final h = result[nextIdx] as AgendaHeaderItem;
      result[nextIdx] = AgendaHeaderItem(
        dateTimeRange: h.dateTimeRange,
        date: h.date,
        now: h.now,
        isNext: true,
        thread: h.thread,
        text: h.text,
        scheduleAt: h.scheduleAt,
        isOutsidePriority: h.isOutsidePriority,
        blockPriority: h.blockPriority,
        block: h.block,
        parentBlockId: h.parentBlockId,
        sourceDate: h.sourceDate,
        sourcePeriodStart: h.sourcePeriodStart,
        parentBlockVisibleCount: h.parentBlockVisibleCount,
      );
    }

    return result;
  }


  PriorityState copyWith({
    Value<Priority?> context = const Value.absent(),
    Priority? draftFallbackPriority,
    Value<Thread?> thread = const Value.absent(),
    Thread? draft,
    Note? draftNote,
    bool? showArchived,
    bool? muteOnly,
    AgendaModel? agenda,
    List<AgendaItem>? agendaItems,
    bool? agendaDoneEnd,
    bool? agendaLoaded,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    String? search,
    List<TwistInstance>? twists,
    List<Actor>? actors,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
    List<(Reaction, int)>? reactions,
    Map<ActivityTab, ActivityFeedTabData>? activityFeedByTab,
    ActivityTab? activeTab,
    bool? activityFeedDoneEnd,
    bool? activityFeedLoaded,
    Value<List<AgendaItem>?> reorderViewItems = const Value.absent(),
    List<String>? iconFilter,
    List<ActorId>? assigneeFilter,
    List<(String, int)>? iconCounts,
    List<Thread>? remoteSearchExtras,
    bool? remoteSearchInProgress,
    bool? remoteSearchOffline,
    bool? hasArchivedMatches,
    bool? showSubPriorities,
    bool? everything,
    Value<Priority?> globalViewScope = const Value.absent(),
    Set<ThreadId>? selected,
    Value<ThreadId?> selectionAnchor = const Value.absent(),
    bool? unreadFilterActive,
  }) {
    return PriorityState(
      context: context.or(this.context),
      draftFallbackPriority: draftFallbackPriority,
      thread: thread.or(this.thread),
      draft: draft ?? this.draft,
      draftNote: draftNote ?? this.draftNote,
      showArchived: showArchived ?? this.showArchived,
      muteOnly: muteOnly ?? this.muteOnly,
      agenda: agenda ?? this.agenda,
      agendaItems: agendaItems ?? this.agendaItems,
      agendaDoneEnd: agendaDoneEnd ?? this.agendaDoneEnd,
      agendaLoaded: agendaLoaded ?? this.agendaLoaded,
      reorderViewItems: reorderViewItems.or(this.reorderViewItems),
      filter: filter != null
          ? (filter.isNotEmpty ? List.unmodifiable(filter) : filter)
          : this.filter,
      reactionFilter: reactionFilter != null
          ? (reactionFilter.isNotEmpty
                ? List.unmodifiable(reactionFilter)
                : reactionFilter)
          : this.reactionFilter,
      search: search ?? this.search,
      twists: twists != null
          ? (twists.isNotEmpty ? List.unmodifiable(twists) : twists)
          : this.twists,
      actors: actors != null
          ? (actors.isNotEmpty ? List.unmodifiable(actors) : actors)
          : this.actors,
      tags: tags != null
          ? (tags.isNotEmpty ? List.unmodifiable(tags) : tags)
          : this.tags,
      tagSuggestions: tagSuggestions != null
          ? (tagSuggestions.isNotEmpty
                ? List.unmodifiable(tagSuggestions)
                : tagSuggestions)
          : this.tagSuggestions,
      reactions: reactions != null
          ? (reactions.isNotEmpty ? List.unmodifiable(reactions) : reactions)
          : this.reactions,
      activityFeedByTab: activityFeedByTab != null
          ? (activityFeedByTab.isNotEmpty
                ? Map.unmodifiable(activityFeedByTab)
                : activityFeedByTab)
          : this.activityFeedByTab,
      activeTab: activeTab ?? this.activeTab,
      activityFeedDoneEnd: activityFeedDoneEnd ?? this.activityFeedDoneEnd,
      activityFeedLoaded: activityFeedLoaded ?? this.activityFeedLoaded,
      iconFilter: iconFilter != null
          ? (iconFilter.isNotEmpty ? List.unmodifiable(iconFilter) : iconFilter)
          : this.iconFilter,
      assigneeFilter: assigneeFilter != null
          ? (assigneeFilter.isNotEmpty
                ? List.unmodifiable(assigneeFilter)
                : assigneeFilter)
          : this.assigneeFilter,
      iconCounts: iconCounts != null
          ? (iconCounts.isNotEmpty ? List.unmodifiable(iconCounts) : iconCounts)
          : this.iconCounts,
      remoteSearchExtras: remoteSearchExtras ?? this.remoteSearchExtras,
      remoteSearchInProgress:
          remoteSearchInProgress ?? this.remoteSearchInProgress,
      remoteSearchOffline: remoteSearchOffline ?? this.remoteSearchOffline,
      hasArchivedMatches: hasArchivedMatches ?? this.hasArchivedMatches,
      showSubPriorities: showSubPriorities ?? this.showSubPriorities,
      everything: everything ?? this.everything,
      globalViewScope: globalViewScope.or(this.globalViewScope),
      selected: selected ?? this.selected,
      selectionAnchor: selectionAnchor.or(this.selectionAnchor),
      unreadFilterActive: unreadFilterActive ?? this.unreadFilterActive,
    );
  }

  @override
  List<Object?> get props => [
    context,
    thread,
    draft,
    draftNote,
    showArchived,
    muteOnly,
    agenda,
    agendaItems,
    agendaDoneEnd,
    agendaLoaded,
    filter,
    reactionFilter,
    search,
    twists,
    actors,
    tags,
    tagSuggestions,
    reactions,
    activityFeedByTab,
    activeTab,
    activityFeedDoneEnd,
    activityFeedLoaded,
    reorderViewItems,
    iconFilter,
    assigneeFilter,
    iconCounts,
    remoteSearchExtras,
    remoteSearchInProgress,
    remoteSearchOffline,
    hasArchivedMatches,
    showSubPriorities,
    everything,
    globalViewScope,
    selected,
    selectionAnchor,
    unreadFilterActive,
  ];

  @override
  String toString() {
    return 'PriorityState(context: ${context?.title ?? 'Everything'}, thread: ${thread?.title}, draft: $draft, showArchived: $showArchived, filter: $filter, search: $search, twists: ${twists.length}, tags: ${tags.length})';
  }
}

// AgendaItem, AgendaHeaderItem, AgendaThreadItem moved to
// `apps/plot/lib/state/agenda_model.dart` so that `AgendaModel.flatItems`
// can produce them without an import cycle with `priority.dart`.
// They remain re-exported through this library because `priority.dart`
// imports `agenda_model.dart`.
