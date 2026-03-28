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
    List<AgendaItem>? agendaItems,
    bool agendaDoneEnd = false,
    List<Tag> filter = const [],
    String search = '',
    List<PriorityTwist> twists = const [],
    List<Actor> actors = const [],
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    List<AgendaItem> activityFeedItems = const [],
    bool activityFeedDoneEnd = false,
    bool activityFeedLoaded = false,
    List<AgendaItem>? reorderViewItems,
    List<String> iconFilter = const [],
    List<(ThreadSubType, int)> iconCounts = const [],
  }) {
    draft ??= Thread(priority: context, draft: true);

    return PriorityState._(
      context: context,
      thread: thread,
      draft: draft,
      draftNote: draftNote ?? Note.draft(threadId: draft.id),
      agendaItems: agendaItems != null && agendaItems.isNotEmpty
          ? List.unmodifiable(agendaItems)
          : agendaItems ?? const [],
      agendaDoneEnd: agendaDoneEnd,
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
    );
  }

  const PriorityState._({
    required this.context,
    this.thread,
    required this.draft,
    required this.draftNote,
    required this.agendaItems,
    this.agendaDoneEnd = false,
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
  });

  final Priority context;
  final Thread? thread;
  final Thread draft;
  final Note draftNote;
  final bool showArchived;
  final List<AgendaItem> agendaItems;
  final bool agendaDoneEnd;
  final List<Tag> filter;
  final String search;
  final List<PriorityTwist> twists;
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
  final List<(ThreadSubType, int)> iconCounts;

  bool get doneStart => true;
  bool get doneEnd => agendaDoneEnd;

  /// "Agenda": items starting from today, moving forward.
  /// Strips sub-priority-only headers and event timing headers
  /// (timing info shown inside ThreadWidget), keeping only current-event
  /// headers. Synthesizes a "Now" header at the top when needed.
  List<AgendaItem> get agendaViewItems {
    if (reorderViewItems != null) return reorderViewItems!;
    final now = Time.now();

    final result = agendaItems.where((item) {
      // Strip today's date header (replaced by synthesized "Now" header)
      if (item is AgendaHeaderItem &&
          item.date != null &&
          item.date == Date.today()) {
        return false;
      }
      // Strip event headers (timing info now shown inside ThreadWidget).
      // Keep only current event headers (event happening now) since they
      // replace the "Now" text header.
      if (item is AgendaHeaderItem &&
          item.thread != null &&
          item.dateTimeRange != null &&
          (!item.now || !item.dateTimeRange!.includes(now))) {
        return false;
      }
      return true;
    }).toList();

    // If there's a current event header (event happening now), use it
    // as the starting point (it replaces the "Now" text header).
    final nowEventIdx = result.indexWhere(
      (item) =>
          item is AgendaHeaderItem &&
          item.thread != null &&
          item.dateTimeRange != null &&
          item.now &&
          item.dateTimeRange!.includes(now),
    );
    if (nowEventIdx > 0) {
      result.removeRange(0, nowEventIdx);
    }

    // If _makeAgenda already created a "Now" text header (e.g. between past
    // threads and todos), strip it — we no longer show standalone "Now" headers.
    if (nowEventIdx <= 0) {
      final nowTextIdx = result.indexWhere(
        (item) =>
            item is AgendaHeaderItem &&
            item.now &&
            item.text == 'Now' &&
            item.thread == null,
      );
      if (nowTextIdx > 0) {
        result.removeRange(0, nowTextIdx);
        // Remove the "Now" text header itself
        result.removeAt(0);
      }
    }

    // Mark the first future event as isNext for countdown display.
    for (int i = 0; i < result.length; i++) {
      final item = result[i];
      if (item is AgendaThreadItem &&
          !item.now &&
          item.thread.at?.start != null &&
          item.thread.at!.start!.isAfter(now)) {
        result[i] = AgendaThreadItem(item.thread, isNext: true);
        break;
      }
    }

    return result;
  }

  /// Returns a coarse time bucket label and representative date for grouping.
  static (String, Date) _timeAgoBucket(Date date) {
    final today = Date.today();
    final days = today.difference(date).inDays;

    if (days <= 0) return ('Today', today);
    if (days == 1) return ('Yesterday', today.addDays(-1));
    if (days <= 6) return ('$days days ago', date);
    if (days <= 13) return ('A week ago', date);
    if (days <= 20) return ('2 weeks ago', date);
    if (days <= 29) return ('3 weeks ago', date);

    // Month-based buckets
    final months = (days / 30).floor();
    if (months <= 1) return ('A month ago', date);
    if (months < 12) return ('$months months ago', date);

    // Year-based buckets
    final years = (days / 365).floor();
    if (years <= 1) return ('A year ago', date);
    return ('$years years ago', date);
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
  static List<AgendaItem> _makeAgenda(
    List<Thread> threads, {
    required Priority context,
    required int horizonDays,
    Map<Uuid, List<ThreadAssociationRow>>? associationsByParentId,
  }) {
    log.fine('[_makeAgenda] rebuilding agenda (${threads.length} threads)');
    final items = <AgendaItem>[];
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

          if (entry.key.id != skipHeaderFor?.id ||
              prioritizedThreads.length > 1) {
            items.add(AgendaHeaderItem(scheduleAt: scheduleAt));
          }
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
      final startOfDay =
          event.draft && event.at?.start == event.at?.start?.startOfDay;
      if (startOfDay) {
        // Add date header
        items.add(
          AgendaHeaderItem(date: event.at?.start?.toDate(), now: current),
        );
      } else {
        // Add header for the event (with time and duration)
        items.add(
          AgendaHeaderItem(
            dateTimeRange: event.at,
            now: current,
            thread: event,
          ),
        );
        // Add the event as a thread widget below the header
        items.add(AgendaThreadItem(event, now: current));
      }

      // Insert associated threads below the event
      if (associationsByParentId != null) {
        final associations = associationsByParentId[event.id];
        if (associations != null) {
          // Use event occurrence (or 'base') as disambiguator so the same
          // child thread under different recurring instances gets unique keys.
          final parentKey = event.occurrence ?? 'base';
          for (final assoc in associations) {
            final child = threadById[assoc.childThreadId];
            if (child != null) {
              items.add(AgendaThreadItem(
                child,
                isAssociated: true,
                associationParentId: parentKey,
              ));
            }
          }
        }
      }

      // Pinned-to-event-start todos are handled by the time-match
      // condition in the priority filter below, so they sort by order
      // alongside other todos under the event.
      // (Pinned to event end time = gap start → handled in gap section.)

      // Split threads into todos vs notes/done.
      // Exclude threads that are associated with this event — they are
      // already shown via the association injection above.
      final eventAssocChildIds = associationsByParentId?[event.id]
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
      final (matchingTodos, remainingTodos) = todos.partition(
        (Thread a) =>
            !a.hasLinkSchedule &&
            (// Priority match: same or descendant priority
            ((event.priority.id == a.priority.id ||
                    event.priority.isParent(a.priority)) &&
                !(a.at?.start != null &&
                    event.at?.start != null &&
                    event.at?.end != null &&
                    a.at!.start!.isSameOrAfter(event.at!.end!))) ||
            // Time match: todo explicitly pinned to this event's start
            (event.at?.start != null &&
                (a.pinnedAfterTime ?? a.at?.start) != null &&
                (a.pinnedAfterTime ?? a.at!.start!).isAtSameMomentAs(event.at!.start!))),
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
                    (a.pinnedAfterTime ?? a.at!.start!).isAtSameMomentAs(event.at!.start!)),
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
            // Pinned todos stay in remainingUnscheduled for makeBlock.
            // Skip when the upcoming event is the current one — todos will
            // be placed after it via makeBlock / the next gap instead.
            if (!nextIsNow) {
              final todosForStart = remainingUnscheduled
                  .where(
                    (a) =>
                        a.todo && !a.isLinkScheduleInstance && !a.isPinnedTodo,
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

    // Fill in date headers for every day from today through the horizon
    final horizon = today.addDays(horizonDays);
    final existingDates = <Date>{};
    for (final item in items) {
      if (item is AgendaHeaderItem && item.date != null) {
        existingDates.add(item.date!);
      }
    }

    final missingHeaders = <AgendaHeaderItem>[];
    for (var date = today; date <= horizon; date = date.addDays(1)) {
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
    List<AgendaItem>? agendaItems,
    bool? agendaDoneEnd,
    List<Tag>? filter,
    String? search,
    List<PriorityTwist>? twists,
    List<Actor>? actors,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
    List<AgendaItem>? activityFeedItems,
    bool? activityFeedDoneEnd,
    bool? activityFeedLoaded,
    Value<List<AgendaItem>?> reorderViewItems = const Value.absent(),
    List<String>? iconFilter,
    List<(ThreadSubType, int)>? iconCounts,
  }) {
    return PriorityState(
      context: context ?? this.context,
      thread: thread.or(this.thread),
      draft: draft ?? this.draft,
      draftNote: draftNote ?? this.draftNote,
      showArchived: showArchived ?? this.showArchived,
      agendaItems: agendaItems ?? this.agendaItems,
      agendaDoneEnd: agendaDoneEnd ?? this.agendaDoneEnd,
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
    );
  }

  @override
  List<Object?> get props => [
    context,
    thread,
    draft,
    draftNote,
    showArchived,
    agendaItems,
    agendaDoneEnd,
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
  ];

  @override
  String toString() {
    return 'PriorityState(context: ${context.title}, thread: ${thread?.title}, draft: $draft, showArchived: $showArchived, filter: $filter, search: $search, twists: ${twists.length}, tags: ${tags.length})';
  }
}

sealed class AgendaItem extends Equatable {
  const AgendaItem();

  T when<T>({
    required T Function(AgendaHeaderItem) header,
    required T Function(AgendaThreadItem) activity,
  }) {
    return switch (this) {
      AgendaHeaderItem h => header(h),
      AgendaThreadItem a => activity(a),
    };
  }

  /// Stable identity key for this item, used for scroll anchor correction
  /// and widget keys.
  String get stableKey => when(
    header: (h) => h.date != null
        ? 'header_date_${h.date}'
        : h.dateTimeRange != null
        ? 'header_event_${h.dateTimeRange}'
        : 'header_other',
    activity: (a) =>
        'activity_${a.thread.id}${a.thread.occurrence != null ? '_${a.thread.occurrence}' : ''}${a.thread.isLinkScheduleInstance ? '_link' : ''}${a.isAssociated ? '_assoc${a.associationParentId != null ? '_${a.associationParentId}' : ''}' : ''}',
  );
}

class AgendaHeaderItem extends AgendaItem {
  const AgendaHeaderItem({
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.thread,
    this.text,
    this.scheduleAt,
  });

  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final Thread? thread;
  final String? text;
  final DateTime? scheduleAt;

  @override
  List<Object?> get props => [
    dateTimeRange,
    date,
    now,
    thread,
    text,
    scheduleAt,
  ];

  @override
  String toString() =>
      'AgendaHeaderItem(dateTimeRange: $dateTimeRange, date: $date, now: $now, text: $text, scheduleAt: $scheduleAt)';
}

class AgendaThreadItem extends AgendaItem {
  const AgendaThreadItem(
    this.thread, {
    this.now = false,
    this.isNext = false,
    this.isAssociated = false,
    this.associationParentId,
  });

  final Thread thread;
  final bool now;
  final bool isNext;
  final bool isAssociated;

  /// Disambiguator for the same child thread appearing under multiple
  /// parent events (e.g. recurring event instances). Used in widget keys
  /// to prevent GlobalKey collisions.
  final String? associationParentId;

  @override
  List<Object?> get props =>
      [thread, now, isNext, isAssociated, associationParentId];

  @override
  String toString() =>
      'AgendaThreadItem(thread: ${thread.title}, now: $now, isAssociated: $isAssociated)';
}
