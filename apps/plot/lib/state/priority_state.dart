part of 'priority.dart';

/// Which list the user last selected a thread from.
/// Used by Previous/Next Thread commands to determine navigation list.
enum ThreadListSource { agenda, activityFeed }

@immutable
class PriorityState extends Equatable {
  factory PriorityState({
    required Priority context,
    Thread? thread,
    Thread? draft,
    Note? draftNote,
    bool showArchived = false,
    AgendaModel agenda = AgendaModel.empty,
    List<AgendaItem>? agendaItems,
    bool agendaDoneEnd = false,
    bool agendaLoaded = false,
    List<Tag> filter = const [],
    String search = '',
    List<TwistInstance> twists = const [],
    List<Actor> actors = const [],
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    List<AgendaItem> activityFeedItems = const [],
    bool activityFeedDoneEnd = false,
    bool activityFeedLoaded = false,
    List<AgendaItem>? reorderViewItems,
    List<String> iconFilter = const [],
    List<(String, int)> iconCounts = const [],
    List<Thread> remoteSearchExtras = const [],
    bool remoteSearchInProgress = false,
    bool remoteSearchOffline = false,
    bool hasArchivedMatches = false,
  }) {
    draft ??= Thread(priority: context, draft: true);

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
      filter: filter.isNotEmpty ? List.unmodifiable(filter) : filter,
      search: search,
      twists: twists.isNotEmpty ? List.unmodifiable(twists) : twists,
      actors: actors.isNotEmpty ? List.unmodifiable(actors) : actors,
      tags: tags.isNotEmpty ? List.unmodifiable(tags) : tags,
      tagSuggestions: tagSuggestions.isNotEmpty
          ? List.unmodifiable(tagSuggestions)
          : tagSuggestions,
      activityFeedItems: activityFeedItems.isNotEmpty
          ? List.unmodifiable(activityFeedItems)
          : activityFeedItems,
      activityFeedDoneEnd: activityFeedDoneEnd,
      activityFeedLoaded: activityFeedLoaded,
      reorderViewItems: reorderViewItems != null
          ? List.unmodifiable(reorderViewItems)
          : null,
      iconFilter: iconFilter.isNotEmpty
          ? List.unmodifiable(iconFilter)
          : iconFilter,
      iconCounts: iconCounts.isNotEmpty
          ? List.unmodifiable(iconCounts)
          : iconCounts,
      remoteSearchExtras: remoteSearchExtras.isNotEmpty
          ? List.unmodifiable(remoteSearchExtras)
          : remoteSearchExtras,
      remoteSearchInProgress: remoteSearchInProgress,
      remoteSearchOffline: remoteSearchOffline,
      hasArchivedMatches: hasArchivedMatches,
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
    this.filter = const [],
    this.search = '',
    this.twists = const [],
    this.actors = const [],
    this.tags = const [],
    this.tagSuggestions = const [],
    this.activityFeedItems = const [],
    this.activityFeedDoneEnd = false,
    this.activityFeedLoaded = false,
    this.reorderViewItems,
    this.iconFilter = const [],
    this.iconCounts = const [],
    this.remoteSearchExtras = const [],
    this.remoteSearchInProgress = false,
    this.remoteSearchOffline = false,
    this.hasArchivedMatches = false,
  });

  final Priority context;
  final Thread? thread;
  final Thread draft;
  final Note draftNote;
  final bool showArchived;

  /// Block-aware view of the agenda. Source of truth going forward; the
  /// flat [agendaItems] is held alongside during the migration so legacy
  /// rendering and reorder paths continue to work without rewrites.
  final AgendaModel agenda;
  final List<AgendaItem> agendaItems;
  final bool agendaDoneEnd;
  final bool agendaLoaded;
  final List<Tag> filter;
  final String search;
  final List<TwistInstance> twists;
  final List<Actor> actors;
  final List<(Tag, int)> tags;
  final List<Tag> tagSuggestions;
  final List<AgendaItem> activityFeedItems;
  final bool activityFeedDoneEnd;
  final bool activityFeedLoaded;

  /// Cached agendaViewItems from an optimistic reorder. When set,
  /// [agendaViewItems] returns this directly instead of re-deriving.
  /// Cleared when new agenda data arrives.
  final List<AgendaItem>? reorderViewItems;

  final List<String> iconFilter;
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

  bool get doneStart => true;
  bool get doneEnd => agendaDoneEnd;

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
        parentBlockId: h.parentBlockId,
        sourceDate: h.sourceDate,
        sourcePeriodStart: h.sourcePeriodStart,
        parentBlockVisibleCount: h.parentBlockVisibleCount,
      );
    }

    return result;
  }

  /// Finds the first gap of at least 1 hour in a day's schedule.
  ///
  /// Returns the start time of the first hour-long gap, or null if no such gap exists.
  /// [dayStart] is the earliest time to consider (e.g., 9 AM or current time for today).
  /// [dayEnd] is the latest time to consider (end of day).
  /// [events] is the list of scheduled events on that day.
  static DateTime? _findFirstHourGap(
    DateTime dayStart,
    DateTime dayEnd,
    List<Thread> events,
  ) {
    const oneHour = Duration(hours: 1);

    // Filter events to only those that have valid time ranges
    final scheduledEvents =
        events.where((e) => e.at?.start != null && e.at?.end != null).toList()
          ..sort((a, b) => a.at!.start!.compareTo(b.at!.start!));

    if (scheduledEvents.isEmpty) {
      // No events scheduled, so the entire day starting from dayStart is a gap
      if (dayEnd.difference(dayStart) >= oneHour) {
        return dayStart;
      }
      return null;
    }

    // Check gap before first event
    final firstEventStart = scheduledEvents.first.at!.start!;
    if (firstEventStart.difference(dayStart) >= oneHour) {
      return dayStart;
    }

    // Check gaps between events
    for (var i = 0; i < scheduledEvents.length - 1; i++) {
      final currentEventEnd = scheduledEvents[i].at!.end!;
      final nextEventStart = scheduledEvents[i + 1].at!.start!;

      final gapStart = currentEventEnd.isAfter(dayStart)
          ? currentEventEnd
          : dayStart;
      if (nextEventStart.difference(gapStart) >= oneHour) {
        return gapStart;
      }
    }

    // Check gap after last event
    final lastEventEnd = scheduledEvents.last.at!.end!;
    final gapStart = lastEventEnd.isAfter(dayStart) ? lastEventEnd : dayStart;
    if (dayEnd.difference(gapStart) >= oneHour) {
      return gapStart;
    }

    return null;
  }

  /// Builds the agenda UI items from a flat list of threads (sorted by agendaAt).
  ///
  /// Groups threads by date, places "now" indicators, handles events and gaps.
  /// Time-dependent calculations use Time.now() for "now" indicator placement.
  /// Builds the flat agenda items list from a thread set.
  ///
  /// Public so [AgendaBuilder.build] can delegate to it during the
  /// transitional period; once the agenda is fully block-aware this
  /// can be moved into the builder.
  static List<AgendaItem> makeAgendaItems(
    List<Thread> threads, {
    required Priority context,
    required int horizonDays,
    int minFillDays = 0,
    Map<Uuid, List<ThreadAssociationRow>>? associationsByParentId,
  }) {
    // A thread is "outside" the current view when its priority is neither
    // the current context nor a descendant of it. Link-scheduled events
    // from outside priorities are shown dimmed; associations and other
    // groupings treat them as external.
    bool isOutside(Thread t) =>
        t.priority.path != context.path &&
        !context.path.isParent(t.priority.path);
    log.fine('[makeAgendaItems] rebuilding agenda (${threads.length} threads)');
    final items = <AgendaItem>[];
    final addedAssociations = <String>{};
    final now = Time.now();
    final today = Date.today();

    // Build a set of child thread IDs that are associated with events.
    // These will be shown under their parent events instead of in the normal
    // unscheduled pool. Threads that also have an active user schedule still
    // appear in both places.
    final associatedChildIds = <Uuid>{};
    if (associationsByParentId != null) {
      for (final children in associationsByParentId.values) {
        for (final assoc in children) {
          associatedChildIds.add(assoc.childThreadId);
        }
      }
    }

    // Build a lookup from child thread ID to Thread for association rendering.
    final threadById = <Uuid, Thread>{};
    for (final thread in threads) {
      threadById[thread.id] = thread;
    }

    // Deduplicate threads by (id, isLinkScheduleInstance) before grouping.
    // The combineLatest merge may produce duplicates when a thread appears
    // in both the main agenda query and the associated-threads query.
    final seen = <String>{};
    final deduped = <Thread>[];
    for (final thread in threads) {
      final key =
          '${thread.id}${thread.isLinkScheduleInstance ? '_link' : ''}${thread.occurrence ?? ''}';
      if (seen.add(key)) {
        deduped.add(thread);
      }
    }

    // Group threads by date
    final threadsByDate = <Date, List<Thread>>{};
    for (final thread in deduped) {
      // Skip threads that are associated (will be shown under their event)
      // UNLESS they also have an active (non-archived) user schedule
      // (dual appearance).
      if (associatedChildIds.contains(thread.id) && !thread.todo) {
        continue;
      }
      final date = thread.agendaAt.toDate();
      threadsByDate.putIfAbsent(date, () => []).add(thread);
    }

    // Determine sort key: (order, timestamp)
    // Order 0: Future scheduled activities
    // Order 1: Past threads (sorted by timestamp)
    // Order 2: Incomplete actions (todos)
    (int, DateTime?) getSortKey(Thread thread) {
      if (thread.at?.start?.isAfter(now) == true) {
        return (0, thread.at!.start);
      }
      return (thread.todo ? 2 : 1, thread.agendaAt);
    }

    // Helper function to add threads grouped by priority.
    // Todos are extracted from all groups and added as a flat sorted list
    // at the end so cross-priority reordering works correctly.
    void addThreadsGrouped(
      List<Thread> threads, {
      DateTime? scheduleAt,
      Priority? skipHeaderFor,
    }) {
      if (threads.isEmpty) return;

      // Separate todos from non-todos so todos can be sorted as a flat list.
      // Link schedule instances are always treated as non-todo (scheduled events).
      final allTodos = <Thread>[];
      final nonTodoThreads = <Thread>[];
      for (final thread in threads) {
        if (thread.todo && !thread.isLinkScheduleInstance) {
          allTodos.add(thread);
        } else {
          nonTodoThreads.add(thread);
        }
      }

      // Add all todos first as a flat list sorted by user-defined order
      if (allTodos.isNotEmpty) {
        allTodos.sort((a, b) => a.todoCompareTo(b));
        items.addAll(allTodos.map((Thread a) => AgendaThreadItem(a)));
      }

      // Add non-todo threads grouped by priority
      if (nonTodoThreads.isNotEmpty) {
        final prioritizedThreads = Thread.prioritize(
          nonTodoThreads,
          context: context,
        );
        for (final entry in prioritizedThreads.entries) {
          final sortedThreads = entry.value.toList()
            ..sort((a, b) {
              final (orderA, timestampA) = getSortKey(a);
              final (orderB, timestampB) = getSortKey(b);

              final orderComparison = orderA.compareTo(orderB);
              if (orderComparison != 0) return orderComparison;

              if (timestampA != null && timestampB != null) {
                return timestampA.compareTo(timestampB);
              }

              return a.compareTo(b);
            });

          items.addAll(sortedThreads.map((Thread a) => AgendaThreadItem(a)));
        }
      }
    }

    // Add event header and thread, then return remaining threads
    List<Thread> makeBlock({
      required Thread event,
      required List<Thread> threads,
      bool current = false,
      DateTime? scheduleAt,
    }) {
      final eventIsOutside = isOutside(event);

      final startOfDay =
          event.draft && event.at?.start == event.at?.start?.startOfDay;
      if (startOfDay) {
        // Add date header
        items.add(
          AgendaHeaderItem(
            date: event.at?.start?.toDate(),
            now: current,
            isOutsidePriority: eventIsOutside,
          ),
        );
      } else {
        // Add header for the event (with time and duration)
        items.add(
          AgendaHeaderItem(
            dateTimeRange: event.at,
            now: current,
            thread: event,
            isOutsidePriority: eventIsOutside,
          ),
        );
        // Add the event as a thread widget below the header
        items.add(
          AgendaThreadItem(event, now: current, isOutsidePriority: eventIsOutside),
        );
      }

      // Insert associated threads below the event.
      // For outside-priority events, skip associations (they are from
      // another priority context). For in-priority events, show all
      // associations even if the child is from another priority.
      // Track which (child, parentKey) pairs have been added to avoid
      // duplicates when the same event appears multiple times (e.g.
      // multiple link schedule instances for the same recurring event).
      if (!eventIsOutside && associationsByParentId != null) {
        final associations = associationsByParentId[event.id];
        if (associations != null) {
          final parentKey =
              '${event.id}${event.occurrence != null ? '_${event.occurrence}' : ''}';
          for (final assoc in associations) {
            final dedupeKey = '${assoc.childThreadId}_$parentKey';
            if (!addedAssociations.add(dedupeKey)) continue;
            final child = threadById[assoc.childThreadId];
            if (child != null) {
              items.add(
                AgendaThreadItem(
                  child,
                  isAssociated: true,
                  associationParentId: parentKey,
                  associationOrder: assoc.order,
                ),
              );
            }
          }
        }
      }

      // Outside-priority events only show the event itself — no todos or
      // notes are grouped under them.
      if (eventIsOutside) return threads;

      // Pinned-to-event-start todos are handled by the time-match
      // condition in the priority filter below, so they sort by order
      // alongside other todos under the event.
      // (Pinned to event end time = gap start → handled in gap section.)

      // Split threads into todos vs notes/done.
      // Exclude threads that are associated with this event — they are
      // already shown via the association injection above.
      final eventAssocChildIds =
          associationsByParentId?[event.id]
              ?.map((a) => a.childThreadId)
              .toSet() ??
          const <Uuid>{};
      final todos = threads
          .where((a) => a.todo && !eventAssocChildIds.contains(a.id))
          .toList();
      final notesAndDone = threads
          .where((a) => !a.todo && !eventAssocChildIds.contains(a.id))
          .toList();

      // Filter todos by priority or explicit time match (user pinned
      // a todo from an unrelated priority to this event's time).
      // Exclude threads that have their own link schedule — they appear
      // as their own event elsewhere and shouldn't be pulled under
      // a different event by priority matching alone.
      // For link-scheduled events, skip priority matching — the
      // association mechanism replaces implicit priority grouping.
      // For link-scheduled events, only associations control which threads
      // appear under them — skip both priority and time-based matching.
      // For non-link events, use priority match and time match as before.
      final isLinkEvent = event.isLinkScheduleInstance || event.hasLinkSchedule;
      final (matchingTodos, remainingTodos) = isLinkEvent
          ? (<Thread>[], todos) // All todos remain for the gap
          : todos.partition(
              (Thread a) =>
                  !a.hasLinkSchedule &&
                  ( // Priority match: same or descendant priority
                  ((event.priority.id == a.priority.id ||
                              event.priority.isParent(a.priority)) &&
                          !(a.at?.start != null &&
                              event.at?.start != null &&
                              event.at?.end != null &&
                              a.at!.start!.isSameOrAfter(event.at!.end!))) ||
                      // Time match: todo explicitly pinned to this event's start
                      (event.at?.start != null &&
                          (a.pinnedAfterTime ?? a.at?.start) != null &&
                          (a.pinnedAfterTime ?? a.at!.start!).isAtSameMomentAs(
                            event.at!.start!,
                          ))),
            );

      // Filter notes/done by time (agendaAt within event's time range)
      final (matchingNotesAndDone, remainingNotesAndDone) = notesAndDone
          .partition((Thread a) {
            if (event.at?.start == null || event.at?.end == null) return false;
            final agendaAt = a.agendaAt;
            return !agendaAt.isBefore(event.at!.start!) &&
                agendaAt.isBefore(event.at!.end!);
          });

      final inPriorityThreads = [...matchingTodos, ...matchingNotesAndDone]
          .where(
            (a) =>
                event.priority.id == a.priority.id ||
                event.priority.isParent(a.priority) ||
                // Include todos pinned to this event's time regardless of
                // priority (user explicitly dragged them here).
                (a.todo &&
                    event.at?.start != null &&
                    (a.pinnedAfterTime ?? a.at?.start) != null &&
                    (a.pinnedAfterTime ?? a.at!.start!).isAtSameMomentAs(
                      event.at!.start!,
                    )),
          )
          .toList();

      final outOfPriorityNotes = matchingNotesAndDone
          .where(
            (a) =>
                !(event.priority.id == a.priority.id ||
                    event.priority.isParent(a.priority)),
          )
          .toList();

      addThreadsGrouped(
        inPriorityThreads,
        scheduleAt: scheduleAt,
        skipHeaderFor: event.priority,
      );
      addThreadsGrouped(outOfPriorityNotes, scheduleAt: scheduleAt);

      return [...remainingTodos, ...remainingNotesAndDone];
    }

    // Sort dates for iteration
    final sortedDates =
        threadsByDate.keys.where((date) => !date.isBefore(today)).toList()
          ..sort();

    bool processedToday = false;
    for (final date in sortedDates) {
      final dayThreads = threadsByDate[date]!;
      final isToday = date == today;
      final todayStartIndex = isToday ? items.length : -1;

      // Separate scheduled (timed events) from unscheduled
      final scheduled =
          dayThreads
              .where(
                (a) => (a.at != null && !a.todo) || a.isLinkScheduleInstance,
              )
              .toList()
            ..sort(
              (a, b) => (a.at?.start ?? DateTime(0)).compareTo(
                b.at?.start ?? DateTime(0),
              ),
            );
      final unscheduled = dayThreads
          .where((a) => (a.at == null || a.todo) && !a.isLinkScheduleInstance)
          .toList();

      // Insert today header before any future day if today has no threads
      if (!date.isBefore(today) && !isToday && !processedToday) {
        final nineAM = today.toStart().add(const Duration(hours: 9));
        final dayScheduleStart = now.isAfter(nineAM) ? now : nineAM;
        items.add(
          AgendaHeaderItem(
            date: today,
            now: true,
            scheduleAt: dayScheduleStart,
          ),
        );
        processedToday = true;
      }

      var remainingScheduled = scheduled;
      var remainingUnscheduled = unscheduled;

      bool dateHeaderIsNow = false;
      bool nextIsNow = false;
      bool createdDateHeader = false;

      // Calculate scheduleAt for day headers
      final nineAM = date.toStart().add(const Duration(hours: 9));
      final dayScheduleStart = isToday && now.isAfter(nineAM) ? now : nineAM;
      final dayScheduleEnd = date.toEnd();
      final dayScheduleAt =
          _findFirstHourGap(dayScheduleStart, dayScheduleEnd, scheduled) ??
          dayScheduleStart;

      if (isToday) {
        processedToday = true;
        // Find current event and collect remaining events
        Thread? currentEvent;
        final afterNowScheduled = <Thread>[];
        final beforeNowScheduled = <Thread>[];
        for (final event in scheduled) {
          if (event.at?.includes(now) == true &&
              (currentEvent == null ||
                  currentEvent.agendaAt < event.agendaAt)) {
            currentEvent = event;
          }
          if (event.at?.start != null && event.at!.start!.isAfter(now)) {
            afterNowScheduled.add(event);
          }
          if (event.at?.end != null && event.at!.end!.isBefore(now)) {
            // Past link schedule instances are read-only external events
            // that don't need attention once passed; exclude them.
            if (!event.isLinkScheduleInstance) {
              beforeNowScheduled.add(event);
            }
          }
        }
        remainingScheduled = [
          if (currentEvent != null) currentEvent,
          ...afterNowScheduled,
        ];

        final firstRemainingEvent = remainingScheduled.firstOrNull;
        if (firstRemainingEvent == null ||
            now.isBefore(firstRemainingEvent.at?.start ?? now)) {
          dateHeaderIsNow = true;
        } else {
          nextIsNow = true;
        }

        final (
          allBeforeNowUnscheduled,
          afterNowUnscheduled,
        ) = remainingUnscheduled.partition(
          (thread) =>
              currentEvent == null ||
              thread.agendaAt.isBefore(currentEvent.agendaAt),
        );

        // Keep pinned todos out of today's grouped sections so they flow
        // through to the event loop's makeBlock for placement after their
        // target events.
        final pinnedTodos = allBeforeNowUnscheduled
            .where((a) => a.isPinnedTodo)
            .toList();
        final beforeNowUnscheduled = allBeforeNowUnscheduled
            .where((a) => !a.isPinnedTodo)
            .toList();

        if (currentEvent == null && beforeNowUnscheduled.isNotEmpty) {
          final (pastThreads, otherBeforeNowThreads) = beforeNowUnscheduled
              .partition(
                (thread) => !thread.todo || thread.isLinkScheduleInstance,
              );

          if (pastThreads.isNotEmpty) {
            if (!createdDateHeader) {
              items.add(
                AgendaHeaderItem(
                  date: date,
                  now: dateHeaderIsNow,
                  scheduleAt: dayScheduleAt,
                ),
              );
              createdDateHeader = true;
            }

            addThreadsGrouped(
              [...pastThreads, ...beforeNowScheduled],
              scheduleAt: dayScheduleAt,
              skipHeaderFor: context,
            );

            if (otherBeforeNowThreads.isNotEmpty) {
              final sortedTodos = otherBeforeNowThreads.toList()
                ..sort((a, b) => a.todoCompareTo(b));
              items.addAll(sortedTodos.map((Thread a) => AgendaThreadItem(a)));
            }

            remainingUnscheduled = [...afterNowUnscheduled, ...pinnedTodos];
          } else {
            if (beforeNowUnscheduled.isNotEmpty ||
                beforeNowScheduled.isNotEmpty) {
              items.add(
                AgendaHeaderItem(
                  date: date,
                  now: dateHeaderIsNow,
                  scheduleAt: dayScheduleAt,
                ),
              );
              createdDateHeader = true;
              addThreadsGrouped(
                [...beforeNowUnscheduled, ...beforeNowScheduled],
                scheduleAt: dayScheduleAt,
                skipHeaderFor: context,
              );
            }
            remainingUnscheduled = [...afterNowUnscheduled, ...pinnedTodos];
          }
        } else {
          // When an event is active, push todos to the next gap so they
          // stay visible after agendaViewItems truncates to the current
          // event. Non-todo items (past notes) can stay before the event.
          final beforeNowNonTodos = beforeNowUnscheduled
              .where((a) => !a.todo || a.isLinkScheduleInstance)
              .toList();
          final beforeNowTodos = beforeNowUnscheduled
              .where((a) => a.todo && !a.isLinkScheduleInstance)
              .toList();
          if (beforeNowNonTodos.isNotEmpty || beforeNowScheduled.isNotEmpty) {
            items.add(
              AgendaHeaderItem(
                date: date,
                now: dateHeaderIsNow,
                scheduleAt: dayScheduleAt,
              ),
            );
            createdDateHeader = true;
            addThreadsGrouped(
              [...beforeNowNonTodos, ...beforeNowScheduled],
              scheduleAt: dayScheduleAt,
              skipHeaderFor: context,
            );
          }
          remainingUnscheduled = [
            ...beforeNowTodos,
            ...afterNowUnscheduled,
            ...pinnedTodos,
          ];
        }
      }

      DateTime? previousEnd;
      for (final event in remainingScheduled) {
        final gapStart = previousEnd ?? date.toStart();
        final gapEnd = event.at?.start;

        if (gapEnd != null && gapEnd.isAfter(gapStart)) {
          final gapRange = DateTimeRange(gapStart, gapEnd);
          final startOfDay = gapStart == date.toStart();

          if (startOfDay && !createdDateHeader) {
            items.add(
              AgendaHeaderItem(
                date: date,
                now: dateHeaderIsNow,
                scheduleAt: dayScheduleAt,
              ),
            );
            createdDateHeader = true;

            // Add unpinned todos at start of day, before the first event.
            // Pinned todos stay in remainingUnscheduled for makeBlock —
            // EXCEPT those whose pinnedAfterTime equals the day's start.
            // Those have no preceding event to land after (a block-move
            // dispatch can write `pinnedAfterTime = midnight of future
            // date` when the drop target has no gap anchor), so without
            // this catchall they'd be dropped entirely: `makeBlock`
            // requires either a priority match or a time-match against
            // the event's start, and subsequent gaps only claim pinned
            // todos whose pinnedAfterTime equals the gap start. Treat
            // "pinned to midnight" as "first thing in the day" so the
            // threads remain visible.
            // Skip when the upcoming event is the current one — todos will
            // be placed after it via makeBlock / the next gap instead.
            if (!nextIsNow) {
              final dayStart = date.toStart();
              final todosForStart = remainingUnscheduled
                  .where(
                    (a) =>
                        a.todo &&
                        !a.isLinkScheduleInstance &&
                        (!a.isPinnedTodo ||
                            (a.pinnedAfterTime != null &&
                                a.pinnedAfterTime!.isAtSameMomentAs(dayStart))),
                  )
                  .toList();
              if (todosForStart.isNotEmpty) {
                todosForStart.sort((a, b) => a.todoCompareTo(b));
                items.addAll(
                  todosForStart.map((Thread a) => AgendaThreadItem(a)),
                );
                remainingUnscheduled = remainingUnscheduled
                    .where((a) => !todosForStart.contains(a))
                    .toList();
              }
            }
          } else if (!startOfDay) {
            items.add(
              AgendaHeaderItem(
                dateTimeRange: gapRange,
                now: nextIsNow,
                scheduleAt: gapStart,
              ),
            );
            nextIsNow = false;
            {
              // Extract pinned todos whose pinnedAfterTime matches this
              // gap's start time (= preceding event's end time).
              final (pinnedHere, rest) = remainingUnscheduled.partition(
                (a) =>
                    a.isPinnedTodo &&
                    a.pinnedAfterTime!.isAtSameMomentAs(gapStart),
              );
              // Keep remaining pinned todos for later gaps/events.
              final pinned = rest.where((a) => a.isPinnedTodo).toList();
              final nonPinned = rest.where((a) => !a.isPinnedTodo).toList();
              // Add non-pinned items first via addThreadsGrouped.
              final gapItemsStart = items.length;
              addThreadsGrouped(
                nonPinned,
                scheduleAt: gapStart,
                skipHeaderFor: context,
              );
              // Insert pinned todos at order-based positions among
              // gap items so they interleave correctly with existing
              // items (e.g. link schedule instances).
              if (pinnedHere.isNotEmpty) {
                pinnedHere.sort((a, b) => a.todoCompareTo(b));
                for (final pinnedTodo in pinnedHere) {
                  var insertAt = items.length;
                  for (var j = gapItemsStart; j < items.length; j++) {
                    final item = items[j];
                    if (item is AgendaThreadItem &&
                        pinnedTodo.todoCompareTo(item.thread) < 0) {
                      insertAt = j;
                      break;
                    }
                  }
                  items.insert(insertAt, AgendaThreadItem(pinnedTodo));
                }
              }
              remainingUnscheduled = pinned;
            }
          }
        }

        remainingUnscheduled = makeBlock(
          event: event,
          threads: remainingUnscheduled,
          current: nextIsNow,
          scheduleAt: dayScheduleAt,
        );
        nextIsNow = false;
        previousEnd = event.at?.end;
      }

      // Add gap to end of day if needed
      final gapStart = previousEnd ?? date.toStart();
      final gapEnd = date.toEnd();

      if (gapEnd.isAfter(gapStart)) {
        final gapRange = DateTimeRange(gapStart, gapEnd);
        final startOfDay = gapStart == date.toStart();

        if (startOfDay && !createdDateHeader) {
          items.add(
            AgendaHeaderItem(
              date: date,
              now: dateHeaderIsNow,
              scheduleAt: dayScheduleAt,
            ),
          );
          addThreadsGrouped(
            remainingUnscheduled,
            scheduleAt: dayScheduleAt,
            skipHeaderFor: context,
          );
        } else if (startOfDay && remainingUnscheduled.isNotEmpty) {
          // Date header already created but remaining items (e.g. pinned
          // todos) still need to be added after the earlier section.
          addThreadsGrouped(
            remainingUnscheduled,
            scheduleAt: dayScheduleAt,
            skipHeaderFor: context,
          );
        } else if (!startOfDay) {
          items.add(
            AgendaHeaderItem(
              dateTimeRange: gapRange,
              now: nextIsNow,
              scheduleAt: gapStart,
            ),
          );
          // Extract pinned todos matching this gap's start time.
          final (pinnedHere, rest) = remainingUnscheduled.partition(
            (a) =>
                a.isPinnedTodo && a.pinnedAfterTime!.isAtSameMomentAs(gapStart),
          );
          // Add non-pinned items first via addThreadsGrouped.
          final gapItemsStart = items.length;
          addThreadsGrouped(
            rest.where((a) => !a.isPinnedTodo).toList(),
            scheduleAt: gapStart,
            skipHeaderFor: context,
          );
          // Insert pinned todos at order-based positions among
          // gap items so they interleave correctly.
          if (pinnedHere.isNotEmpty) {
            log.info(
              '[agenda:endGap] ${pinnedHere.length} pinned todo(s) '
              'in end-of-day gap starting $gapStart: '
              '${pinnedHere.map((t) => '"${t.title}"').join(', ')}',
            );
            pinnedHere.sort((a, b) => a.order.compareTo(b.order));
            for (final pinnedTodo in pinnedHere) {
              var insertAt = items.length;
              for (var j = gapItemsStart; j < items.length; j++) {
                final item = items[j];
                if (item is AgendaThreadItem &&
                    pinnedTodo.order.compareTo(item.thread.order) < 0) {
                  insertAt = j;
                  break;
                }
              }
              items.insert(insertAt, AgendaThreadItem(pinnedTodo));
            }
          }
        }
      }

      // Post-process today's items to add action-based "now" indicator
      if (isToday && todayStartIndex >= 0) {
        int? firstTodoIndex;
        for (int i = todayStartIndex; i < items.length; i++) {
          final item = items[i];
          if (item is AgendaThreadItem && item.thread.todo) {
            firstTodoIndex = i;
            break;
          }
        }

        if (firstTodoIndex != null) {
          final firstTodoItem = items[firstTodoIndex] as AgendaThreadItem;

          bool hasPrecedingThread = false;
          if (firstTodoIndex > todayStartIndex) {
            final precedingItem = items[firstTodoIndex - 1];
            if (precedingItem is AgendaThreadItem) {
              hasPrecedingThread = true;
            }
          }

          items[firstTodoIndex] = AgendaThreadItem(firstTodoItem.thread);

          if (!hasPrecedingThread) {
            for (int i = firstTodoIndex - 1; i >= todayStartIndex; i--) {
              final item = items[i];
              if (item is AgendaHeaderItem) {
                if (item.date != null || item.dateTimeRange != null) {
                  items[i] = AgendaHeaderItem(
                    dateTimeRange: item.dateTimeRange,
                    date: item.date,
                    now: true,
                    thread: item.thread,
                    text: item.text,
                  );
                }
                break;
              }
            }
          }
        }
      }
    }

    // Ensure today always has a date header, even if empty
    if (!processedToday) {
      final nineAM = today.toStart().add(const Duration(hours: 9));
      final dayScheduleStart = now.isAfter(nineAM) ? now : nineAM;

      items.add(
        AgendaHeaderItem(date: today, now: true, scheduleAt: dayScheduleStart),
      );
    }

    // Fill in date headers so users see contiguous days they can schedule
    // into. Cap the fill to the last date with real content (plus a small
    // buffer) rather than the full query horizon — there is no value in
    // materializing ~90 empty-day headers when the user only has content in
    // the next two weeks.
    final existingDates = <Date>{};
    Date? lastContentDate;
    for (final item in items) {
      if (item is AgendaHeaderItem && item.date != null) {
        existingDates.add(item.date!);
        if (lastContentDate == null || item.date! > lastContentDate) {
          lastContentDate = item.date!;
        }
      }
    }

    const emptyDayBufferDays = 14;
    final horizon = today.addDays(horizonDays);
    final contentEnd = lastContentDate ?? today;
    var fillUntil = contentEnd.addDays(emptyDayBufferDays);
    // Once the user scrolls past the buffer, [minFillDays] grows so the
    // agenda keeps producing more empty-day headers instead of stranding
    // them on a stuck "loading more" spinner.
    final minFillEnd = today.addDays(minFillDays);
    if (minFillEnd > fillUntil) fillUntil = minFillEnd;
    if (fillUntil > horizon) fillUntil = horizon;

    final missingHeaders = <AgendaHeaderItem>[];
    for (var date = today; date <= fillUntil; date = date.addDays(1)) {
      if (!existingDates.contains(date)) {
        final nineAM = date.toStart().add(const Duration(hours: 9));
        missingHeaders.add(AgendaHeaderItem(date: date, scheduleAt: nineAM));
      }
    }

    // Merge missing date headers into items in chronological order
    if (missingHeaders.isNotEmpty) {
      final merged = <AgendaItem>[];
      var missingIndex = 0;

      for (final item in items) {
        // Insert any missing headers that come before this item's date
        if (item is AgendaHeaderItem && item.date != null) {
          while (missingIndex < missingHeaders.length &&
              missingHeaders[missingIndex].date! < item.date!) {
            merged.add(missingHeaders[missingIndex]);
            missingIndex++;
          }
        }
        merged.add(item);
      }

      // Append any remaining missing headers after all existing items
      while (missingIndex < missingHeaders.length) {
        merged.add(missingHeaders[missingIndex]);
        missingIndex++;
      }

      items
        ..clear()
        ..addAll(merged);
    }

    return items;
  }

  PriorityState copyWith({
    Priority? context,
    Value<Thread?> thread = const Value.absent(),
    Thread? draft,
    Note? draftNote,
    bool? showArchived,
    AgendaModel? agenda,
    List<AgendaItem>? agendaItems,
    bool? agendaDoneEnd,
    bool? agendaLoaded,
    List<Tag>? filter,
    String? search,
    List<TwistInstance>? twists,
    List<Actor>? actors,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
    List<AgendaItem>? activityFeedItems,
    bool? activityFeedDoneEnd,
    bool? activityFeedLoaded,
    Value<List<AgendaItem>?> reorderViewItems = const Value.absent(),
    List<String>? iconFilter,
    List<(String, int)>? iconCounts,
    List<Thread>? remoteSearchExtras,
    bool? remoteSearchInProgress,
    bool? remoteSearchOffline,
    bool? hasArchivedMatches,
  }) {
    return PriorityState(
      context: context ?? this.context,
      thread: thread.or(this.thread),
      draft: draft ?? this.draft,
      draftNote: draftNote ?? this.draftNote,
      showArchived: showArchived ?? this.showArchived,
      agenda: agenda ?? this.agenda,
      agendaItems: agendaItems ?? this.agendaItems,
      agendaDoneEnd: agendaDoneEnd ?? this.agendaDoneEnd,
      agendaLoaded: agendaLoaded ?? this.agendaLoaded,
      reorderViewItems: reorderViewItems.or(this.reorderViewItems),
      filter: filter != null
          ? (filter.isNotEmpty ? List.unmodifiable(filter) : filter)
          : this.filter,
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
      activityFeedItems: activityFeedItems != null
          ? (activityFeedItems.isNotEmpty
                ? List.unmodifiable(activityFeedItems)
                : activityFeedItems)
          : this.activityFeedItems,
      activityFeedDoneEnd: activityFeedDoneEnd ?? this.activityFeedDoneEnd,
      activityFeedLoaded: activityFeedLoaded ?? this.activityFeedLoaded,
      iconFilter: iconFilter != null
          ? (iconFilter.isNotEmpty ? List.unmodifiable(iconFilter) : iconFilter)
          : this.iconFilter,
      iconCounts: iconCounts != null
          ? (iconCounts.isNotEmpty ? List.unmodifiable(iconCounts) : iconCounts)
          : this.iconCounts,
      remoteSearchExtras: remoteSearchExtras ?? this.remoteSearchExtras,
      remoteSearchInProgress:
          remoteSearchInProgress ?? this.remoteSearchInProgress,
      remoteSearchOffline: remoteSearchOffline ?? this.remoteSearchOffline,
      hasArchivedMatches: hasArchivedMatches ?? this.hasArchivedMatches,
    );
  }

  @override
  List<Object?> get props => [
    context,
    thread,
    draft,
    draftNote,
    showArchived,
    agenda,
    agendaItems,
    agendaDoneEnd,
    agendaLoaded,
    filter,
    search,
    twists,
    actors,
    tags,
    tagSuggestions,
    activityFeedItems,
    activityFeedDoneEnd,
    activityFeedLoaded,
    reorderViewItems,
    iconFilter,
    iconCounts,
    remoteSearchExtras,
    remoteSearchInProgress,
    remoteSearchOffline,
    hasArchivedMatches,
  ];

  @override
  String toString() {
    return 'PriorityState(context: ${context.title}, thread: ${thread?.title}, draft: $draft, showArchived: $showArchived, filter: $filter, search: $search, twists: ${twists.length}, tags: ${tags.length})';
  }
}

// AgendaItem, AgendaHeaderItem, AgendaThreadItem moved to
// `apps/plot/lib/state/agenda_model.dart` so that `AgendaModel.flatItems`
// can produce them without an import cycle with `priority.dart`.
// They remain re-exported through this library because `priority.dart`
// imports `agenda_model.dart`.
