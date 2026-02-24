part of 'priority.dart';

@immutable
class PriorityState extends Equatable {
  factory PriorityState({
    required Priority context,
    Activity? activity,
    Activity? draft,
    Note? draftNote,
    Map<Date, ScheduledDay> schedule = const {},
    int first = 0,
    Date? firstDate,
    BoundedDateRange? range,
    Date? previous,
    Date? next,
    bool showArchived = false,
    List<AgendaItem>? agendaItems,
    List<Tag> filter = const [],
    String search = '',
    List<PriorityTwist> twists = const [],
    List<Actor> actors = const [],
    List<(Tag, int)> tags = const [],
    List<Tag> tagSuggestions = const [],
    Priority? targetPriority,
  }) {
    final agenda = agendaItems ?? _makeAgenda(schedule, context: context);

    // Calculate range from agenda items if not provided
    BoundedDateRange? calculatedRange = range;
    if (calculatedRange == null && schedule.isNotEmpty && agenda.isNotEmpty) {
      final dates = agenda
          .whereType<AgendaHeaderItem>()
          .where((header) => header.date != null)
          .map((header) => header.date!)
          .toList();

      if (dates.isNotEmpty) {
        dates.sort();
        calculatedRange = CustomBoundedDateRange(
          dates.first,
          dates.last.addDays(1),
        );
      }
    }

    draft ??= Activity(priority: context, draft: true);

    return PriorityState._(
      context: context,
      activity: activity,
      draft: draft,
      draftNote: draftNote ?? Note.draft(activityId: draft.id),
      schedule: schedule.isNotEmpty ? Map.unmodifiable(schedule) : schedule,
      agendaItems: agenda.isNotEmpty ? List.unmodifiable(agenda) : agenda,
      first: firstDate != null
          ? -_findDate(agenda, firstDate)
          : range != null
          ? first // Preserve first on updates (when range is set)
          : (first != 0
                ? first
                : -_findNow(agenda)), // Calculate first only on initial load
      range: calculatedRange,
      next: next,
      previous: previous,
      showArchived: showArchived,
      filter: filter.isNotEmpty ? List.unmodifiable(filter) : filter,
      search: search,
      twists: twists.isNotEmpty ? List.unmodifiable(twists) : twists,
      actors: actors.isNotEmpty ? List.unmodifiable(actors) : actors,
      tags: tags.isNotEmpty ? List.unmodifiable(tags) : tags,
      tagSuggestions: tagSuggestions.isNotEmpty
          ? List.unmodifiable(tagSuggestions)
          : tagSuggestions,
      targetPriority: targetPriority,
    );
  }

  const PriorityState._({
    required this.context,
    this.activity,
    required this.draft,
    required this.draftNote,
    required this.range,
    required this.previous,
    required this.next,
    required this.agendaItems,
    this.schedule = const {},
    this.first = 0,
    this.showArchived = false,
    this.filter = const [],
    this.search = '',
    this.twists = const [],
    this.actors = const [],
    this.tags = const [],
    this.tagSuggestions = const [],
    this.targetPriority,
  });

  final Priority context;
  final Activity? activity;
  final Activity draft;
  final Note draftNote;
  final Map<Date, ScheduledDay> schedule;
  final int first;
  final BoundedDateRange? range;
  final Date? previous;
  final Date? next;
  final bool showArchived;
  final List<AgendaItem> agendaItems;
  final List<Tag> filter;
  final String search;
  final List<PriorityTwist> twists;
  final List<Actor> actors;
  final List<(Tag, int)> tags;
  final List<Tag> tagSuggestions;
  final Priority? targetPriority;

  bool get doneStart =>
      range != null && (previous == null || range!.includes(previous!));
  bool get doneEnd {
    final range = this.range;
    final next = this.next;
    return range != null && (next == null || next < range.end);
  }

  /// "Now + Next": items from the "Now" header onward,
  /// with date headers and sub-priority-only headers stripped.
  /// The split point is the first incomplete action marked now=true,
  /// backed up to include the preceding "Now" header (but not date headers).
  List<AgendaItem> get upNextItems {
    final nowActivityIndex = _findNowActivity(agendaItems);

    // Look backward for the "Now" header (now=true, not a date header).
    // We skip over activities (not just headers) because reordering can
    // place a now=false activity between the Now header and the first
    // now=true activity.
    var startIndex = nowActivityIndex;
    for (int i = nowActivityIndex - 1; i >= 0; i--) {
      final item = agendaItems[i];
      if (item is AgendaHeaderItem) {
        if (item.now && item.date == null) {
          startIndex = i;
          break;
        }
        // Stop at non-now headers (e.g. date or priority headers from
        // an earlier section) to avoid pulling in unrelated items.
        break;
      }
      // Continue past activities — reorder may place them here.
    }

    final result = agendaItems.sublist(startIndex).where((item) {
      // Strip today's date header (replaced by synthesized "Now" header)
      if (item is AgendaHeaderItem &&
          item.date != null &&
          item.date == Date.today()) {
        return false;
      }
      // Strip sub-priority-only headers (priority set, but no date or dateTimeRange)
      if (item is AgendaHeaderItem &&
          item.priority != null &&
          item.date == null &&
          item.dateTimeRange == null) {
        return false;
      }
      return true;
    }).toList();

    // If no "Now" header at the top, synthesize one.
    // This happens when there are no past activities, so _makeAgenda only
    // creates a date header (no separate "Now" header).
    if (result.isEmpty ||
        result.first is! AgendaHeaderItem ||
        !(result.first as AgendaHeaderItem).now) {
      // Find countdown info: look for the next event in remaining items
      DateTimeRange? dateTimeRange;
      for (int i = nowActivityIndex; i < agendaItems.length; i++) {
        final item = agendaItems[i];
        if (item is AgendaHeaderItem &&
            item.dateTimeRange != null &&
            item.activity != null) {
          final eventStart = item.dateTimeRange!.start;
          if (eventStart != null && eventStart.isAfter(Time.now())) {
            dateTimeRange = DateTimeRange(Time.now(), eventStart);
          }
          break;
        }
      }
      result.insert(
        0,
        AgendaHeaderItem(now: true, text: 'Now', dateTimeRange: dateTimeRange),
      );
    }

    return result;
  }

  /// "Activity": flat list of ALL activities sorted by activityFeedAt descending,
  /// with coarse time-based section headers (Today, Yesterday, X days ago, etc.).
  List<AgendaItem> get activityFeedItems {
    final activities =
        agendaItems
            .whereType<AgendaActivityItem>()
            .map((item) => item.activity)
            .toList()
          ..sort((a, b) => b.activityFeedAt.compareTo(a.activityFeedAt));

    final items = <AgendaItem>[];
    String? currentBucket;
    for (final activity in activities) {
      final (label, bucketDate) = _timeAgoBucket(
        activity.activityFeedAt.toDate(),
      );
      if (label != currentBucket) {
        currentBucket = label;
        items.add(AgendaHeaderItem(text: label, date: bucketDate));
      }
      items.add(AgendaActivityItem(activity));
    }
    return items;
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
    List<Activity> events,
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

  /// Builds the agenda UI items from schedule data.
  ///
  /// This method performs time-dependent calculations using Time.now():
  /// - Places the "now" indicator at the current time or event
  /// - Determines which events are "current" (happening right now)
  /// - Splits activities into past/future relative to current time
  /// - Calculates schedule gaps based on current time
  ///
  /// Because these calculations depend on the current time, this method
  /// must be re-run periodically (every minute) even when the underlying
  /// schedule data hasn't changed. This is handled by ExpiringStreamTransformer
  /// in PriorityBloc._loadSchedule().
  static List<AgendaItem> _makeAgenda(
    Map<Date, ScheduledDay> schedule, {
    required Priority context,
  }) {
    final items = <AgendaItem>[];
    final now = Time.now();
    final today = Date.today();

    // Determine sort key: (order, timestamp)
    // Order 0: Future events
    // Order 1: Past activities (sorted by timestamp)
    // Order 2: Incomplete actions
    (int, DateTime?) getSortKey(Activity activity) {
      // Future events (order 0)
      if (activity.type == ActivityType.event &&
          activity.at?.start?.isAfter(now) == true) {
        return (0, activity.at!.start);
      }
      return (activity.todo ? 2 : 1, activity.agendaAt);
    }

    // Helper function to add activities grouped by priority
    void addActivitiesGrouped(
      List<Activity> activities, {
      DateTime? scheduleAt,
      Priority? skipHeaderFor,
    }) {
      if (activities.isEmpty) return;

      final prioritizedActivities = Activity.prioritize(
        activities,
        context: context,
      );
      for (final entry in prioritizedActivities.entries) {
        // Sort activities: future events first, past activities interleaved chronologically, incomplete actions last
        final sortedActivities = entry.value.toList()
          ..sort((a, b) {
            final (orderA, timestampA) = getSortKey(a);
            final (orderB, timestampB) = getSortKey(b);

            // First compare by category order
            final orderComparison = orderA.compareTo(orderB);
            if (orderComparison != 0) {
              return orderComparison;
            }

            // For incomplete actions, sort by user-defined order
            if (a.todo && b.todo) {
              return a.order.compareTo(b.order);
            }

            // Within the same category, compare by timestamp
            if (timestampA != null && timestampB != null) {
              return timestampA.compareTo(timestampB);
            }

            // Fallback to existing comparison
            return a.compareTo(b);
          });

        // Add header only if there are multiple priorities or priority != skipHeaderFor
        if (entry.key.id != skipHeaderFor?.id ||
            prioritizedActivities.length > 1) {
          items.add(
            AgendaHeaderItem(priority: entry.key, scheduleAt: scheduleAt),
          );
        }
        items.addAll(
          sortedActivities.map((Activity a) => AgendaActivityItem(a)),
        );
      }
    }

    // Add event header and activity, then return remaining activities
    List<Activity> makeBlock({
      required Activity event,
      required List<Activity> activities,
      bool current = false,
      DateTime? scheduleAt,
    }) {
      final startOfDay =
          event.draft && event.at?.start == event.at?.start?.startOfDay;
      if (startOfDay) {
        // Add date header
        items.add(
          AgendaHeaderItem(
            priority: null,
            date: event.at?.start?.toDate(),
            now: current,
          ),
        );
      } else {
        // Add header for the event (with time and duration)
        items.add(
          AgendaHeaderItem(
            priority: event.priority,
            dateTimeRange: event.at,
            now: current,
            activity: event,
          ),
        );
        // Add the event as an activity widget below the header
        items.add(AgendaActivityItem(event, now: current));
      }

      // Split activities into todos vs notes/done
      final todos = activities.where((a) => a.todo).toList();
      final notesAndDone = activities.where((a) => !a.todo).toList();

      // Filter todos by priority (existing logic)
      final (matchingTodos, remainingTodos) = todos.partition(
        (Activity a) =>
            // Priority match
            (event.priority.id == a.priority.id ||
                event.priority.isParent(a.priority)) &&
            // Not after the event
            !(a.at?.start != null &&
                event.at?.start != null &&
                a.at!.start!.isSameOrAfter(event.at!.end!)),
      );

      // Filter notes/done by time (agendaAt within event's time range)
      final (matchingNotesAndDone, remainingNotesAndDone) = notesAndDone
          .partition((Activity a) {
            if (event.at?.start == null || event.at?.end == null) return false;
            final agendaAt = a.agendaAt;
            return !agendaAt.isBefore(event.at!.start!) &&
                agendaAt.isBefore(event.at!.end!);
          });

      // Split matching notes/done into in-priority vs out-of-priority
      final inPriorityActivities = [...matchingTodos, ...matchingNotesAndDone]
          .where(
            (a) =>
                event.priority.id == a.priority.id ||
                event.priority.isParent(a.priority),
          )
          .toList();

      final outOfPriorityNotes = matchingNotesAndDone
          .where(
            (a) =>
                !(event.priority.id == a.priority.id ||
                    event.priority.isParent(a.priority)),
          )
          .toList();

      // Add in-priority activities first
      addActivitiesGrouped(
        inPriorityActivities,
        scheduleAt: scheduleAt,
        skipHeaderFor: event.priority,
      );

      // Add out-of-priority notes after
      addActivitiesGrouped(outOfPriorityNotes, scheduleAt: scheduleAt);

      // Return remaining todos and notes/done that didn't match
      return [...remainingTodos, ...remainingNotesAndDone];
    }

    bool processedToday = false;
    for (final day in schedule.values) {
      final isToday = day.date == today;
      final isPast = day.date.isBefore(today);
      final todayStartIndex = isToday ? items.length : -1;

      // Insert today header before any future day if today has no activities
      if (!isPast && !isToday && !processedToday) {
        final nineAM = today.toStart().add(const Duration(hours: 9));
        final dayScheduleStart = now.isAfter(nineAM) ? now : nineAM;
        items.add(
          AgendaHeaderItem(
            priority: null,
            date: today,
            now: true,
            scheduleAt: dayScheduleStart,
          ),
        );
        processedToday = true;
      }

      if (isPast) {
        // All activities on past days are shown as-is
        makeBlock(
          event: Activity(priority: context, on: Day(day.date), draft: true),
          activities: day.activities,
          scheduleAt: null,
        );
      } else {
        var remainingScheduled = day.scheduled;
        var remainingUnscheduled = day.unscheduled;

        bool dateHeaderIsNow = false;
        bool nextIsNow = false;
        bool createdDateHeader = false;

        // Calculate scheduleAt for day headers
        final nineAM = day.date.toStart().add(const Duration(hours: 9));
        final dayScheduleStart = isToday && now.isAfter(nineAM) ? now : nineAM;
        final dayScheduleEnd = day.date.toEnd();
        final dayScheduleAt =
            _findFirstHourGap(
              dayScheduleStart,
              dayScheduleEnd,
              day.scheduled,
            ) ??
            dayScheduleStart;

        if (isToday) {
          processedToday = true;
          // Find current event and collect remaining events
          Activity? currentEvent;
          final afterNowScheduled = <Activity>[];
          final beforeNowScheduled = <Activity>[];
          for (final event in day.scheduled) {
            if (event.at?.includes(now) == true &&
                (currentEvent == null ||
                    currentEvent.agendaAt < event.agendaAt)) {
              currentEvent = event;
            }
            if (event.at?.start != null && event.at!.start!.isAfter(now)) {
              afterNowScheduled.add(event);
            }
            // Collect past events (ended before now)
            if (event.at?.end != null && event.at!.end!.isBefore(now)) {
              beforeNowScheduled.add(event);
            }
          }
          remainingScheduled = [
            if (currentEvent != null) currentEvent,
            ...afterNowScheduled,
          ];

          // Determine what should be marked as "now"
          final firstRemainingEvent = remainingScheduled.firstOrNull;
          if (firstRemainingEvent == null ||
              now.isBefore(firstRemainingEvent.at?.start ?? now)) {
            // Before first event or no events - date header is "now"
            dateHeaderIsNow = true;
          } else if (currentEvent != null) {
            // During an event - that event will be "now"
            nextIsNow = true;
          } else {
            // In a gap between/after events - that gap will be "now"
            nextIsNow = true;
          }

          final (
            beforeNowUnscheduled,
            afterNowUnscheduled,
          ) = remainingUnscheduled.partition(
            (activity) =>
                currentEvent == null ||
                activity.agendaAt.isBefore(currentEvent.agendaAt),
          );

          // Apply "Now" header when not in an event (covers: gaps, after events, no events)
          if (currentEvent == null && beforeNowUnscheduled.isNotEmpty) {
            // Split activities into past and future
            final (pastActivities, otherBeforeNowActivities) =
                beforeNowUnscheduled.partition((activity) => !activity.todo);

            if (pastActivities.isNotEmpty) {
              // Add date header if needed
              if (!createdDateHeader) {
                items.add(
                  AgendaHeaderItem(
                    priority: null,
                    date: day.date,
                    now: dateHeaderIsNow,
                    scheduleAt: dayScheduleAt,
                  ),
                );
                createdDateHeader = true;
              }

              // Add past activities grouped by priority (include past events)
              addActivitiesGrouped(
                [...pastActivities, ...beforeNowScheduled],
                scheduleAt: dayScheduleAt,
                skipHeaderFor: context,
              );

              // Add "Now" header
              items.add(
                AgendaHeaderItem(
                  priority: null,
                  dateTimeRange:
                      afterNowScheduled.firstOrNull?.at?.start != null
                      ? DateTimeRange(
                          now,
                          afterNowScheduled.firstOrNull!.at!.start!,
                        )
                      : null,
                  now: true,
                  text: currentEvent?.title ?? 'Now',
                ),
              );

              if (otherBeforeNowActivities.isNotEmpty) {
                // Sort all todos by user-defined order (no priority grouping)
                final sortedTodos = otherBeforeNowActivities.toList()
                  ..sort((a, b) => a.order.compareTo(b.order));
                items.addAll(
                  sortedTodos.map((Activity a) => AgendaActivityItem(a)),
                );
              }

              remainingUnscheduled = afterNowUnscheduled;
            } else {
              // No past activities, use existing logic
              if (beforeNowUnscheduled.isNotEmpty ||
                  beforeNowScheduled.isNotEmpty) {
                items.add(
                  AgendaHeaderItem(
                    priority: null,
                    date: day.date,
                    now: dateHeaderIsNow,
                    scheduleAt: dayScheduleAt,
                  ),
                );
                createdDateHeader = true;
                addActivitiesGrouped(
                  [...beforeNowUnscheduled, ...beforeNowScheduled],
                  scheduleAt: dayScheduleAt,
                  skipHeaderFor: context,
                );
              }
              remainingUnscheduled = afterNowUnscheduled;
            }
          } else {
            // Use existing logic when there are still scheduled events
            if (beforeNowUnscheduled.isNotEmpty ||
                beforeNowScheduled.isNotEmpty) {
              items.add(
                AgendaHeaderItem(
                  priority: null,
                  date: day.date,
                  now: dateHeaderIsNow,
                  scheduleAt: dayScheduleAt,
                ),
              );
              createdDateHeader = true;
              addActivitiesGrouped(
                [...beforeNowUnscheduled, ...beforeNowScheduled],
                scheduleAt: dayScheduleAt,
                skipHeaderFor: context,
              );
            }
            remainingUnscheduled = afterNowUnscheduled;
          }
        }

        DateTime? previousEnd;
        for (final event in remainingScheduled) {
          // Compute gap before this event
          final gapStart = previousEnd ?? day.date.toStart();
          final gapEnd = event.at?.start;

          if (gapEnd != null && gapEnd.isAfter(gapStart)) {
            // Create gap header
            final gapRange = DateTimeRange(gapStart, gapEnd);
            final startOfDay = gapStart == day.date.toStart();

            if (startOfDay && !createdDateHeader) {
              // Add date header for start-of-day gap
              items.add(
                AgendaHeaderItem(
                  priority: null,
                  date: day.date,
                  now: dateHeaderIsNow,
                  scheduleAt: dayScheduleAt,
                ),
              );
              createdDateHeader = true;
            } else if (!startOfDay) {
              // Add time header for mid-day gap
              items.add(
                AgendaHeaderItem(
                  priority: null,
                  dateTimeRange: gapRange,
                  now: nextIsNow,
                  scheduleAt: gapStart,
                ),
              );
              nextIsNow = false;
              // Add remaining activities to the gap
              addActivitiesGrouped(
                remainingUnscheduled,
                scheduleAt: gapStart,
                skipHeaderFor: context,
              );
              // Clear to prevent duplication in subsequent blocks
              remainingUnscheduled = [];
            }
          }

          remainingUnscheduled = makeBlock(
            event: event,
            activities: remainingUnscheduled,
            current: nextIsNow,
            scheduleAt: dayScheduleAt,
          );
          nextIsNow = false;
          previousEnd = event.at?.end;
        }

        // Add gap to end of day if needed
        final gapStart = previousEnd ?? day.date.toStart();
        final gapEnd = day.date.toEnd();

        if (gapEnd.isAfter(gapStart)) {
          final gapRange = DateTimeRange(gapStart, gapEnd);
          final startOfDay = gapStart == day.date.toStart();

          if (startOfDay && !createdDateHeader) {
            // Add date header if full day is empty
            items.add(
              AgendaHeaderItem(
                priority: null,
                date: day.date,
                now: dateHeaderIsNow,
                scheduleAt: dayScheduleAt,
              ),
            );
            // Add remaining activities to the full day
            addActivitiesGrouped(
              remainingUnscheduled,
              scheduleAt: dayScheduleAt,
              skipHeaderFor: context,
            );
          } else if (!startOfDay) {
            // Add time header for end-of-day gap
            items.add(
              AgendaHeaderItem(
                priority: null,
                dateTimeRange: gapRange,
                now: nextIsNow,
                scheduleAt: gapStart,
              ),
            );
            // Add remaining activities to the end-of-day gap
            addActivitiesGrouped(
              remainingUnscheduled,
              scheduleAt: gapStart,
              skipHeaderFor: context,
            );
          }
        }
      }

      // Post-process today's items to add action-based "now" indicator
      if (isToday && todayStartIndex >= 0) {
        // Find the first incomplete action
        int? firstIncompleteActionIndex;
        for (int i = todayStartIndex; i < items.length; i++) {
          final item = items[i];
          if (item is AgendaActivityItem &&
              item.activity.type == ActivityType.action &&
              item.activity.todo) {
            firstIncompleteActionIndex = i;
            break;
          }
        }

        if (firstIncompleteActionIndex != null) {
          final firstIncompleteActionItem =
              items[firstIncompleteActionIndex] as AgendaActivityItem;

          // Check what immediately precedes the first incomplete action
          bool hasPrecedingNoteOrDoneAction = false;

          if (firstIncompleteActionIndex > todayStartIndex) {
            final precedingItem = items[firstIncompleteActionIndex - 1];
            if (precedingItem is AgendaActivityItem) {
              final activity = precedingItem.activity;
              // Check if it's a note or a done action
              if (activity.type == ActivityType.note ||
                  (activity.type == ActivityType.action && activity.done)) {
                hasPrecedingNoteOrDoneAction = true;
              }
            }
          }

          // Mark the first incomplete action with now=true
          items[firstIncompleteActionIndex] = AgendaActivityItem(
            firstIncompleteActionItem.activity,
            now: true,
          );

          // If not preceded by note/done action, also mark the previous header
          // (but only if it's an event or day header, not a priority header)
          if (!hasPrecedingNoteOrDoneAction) {
            for (
              int i = firstIncompleteActionIndex - 1;
              i >= todayStartIndex;
              i--
            ) {
              final item = items[i];
              if (item is AgendaHeaderItem) {
                // Only mark event/day headers with now, not priority headers
                if (item.date != null || item.dateTimeRange != null) {
                  // Replace the header with a new one that has now=true
                  items[i] = AgendaHeaderItem(
                    priority: item.priority,
                    dateTimeRange: item.dateTimeRange,
                    date: item.date,
                    now: true,
                    activity: item.activity,
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
        AgendaHeaderItem(
          priority: null,
          date: today,
          now: true,
          scheduleAt: dayScheduleStart,
        ),
      );
    }

    return items;
  }

  PriorityState copyWith({
    Priority? context,
    Value<Activity?> activity = const Value.absent(),
    Activity? draft,
    Note? draftNote,
    Map<Date, ScheduledDay>? schedule,
    int? first,
    Date? firstDate,
    BoundedDateRange? range,
    Value<Date?> previous = const Value.absent(),
    Value<Date?> next = const Value.absent(),
    bool? showArchived,
    List<AgendaItem>? agendaItems,
    List<Tag>? filter,
    String? search,
    List<PriorityTwist>? twists,
    List<Actor>? actors,
    List<(Tag, int)>? tags,
    List<Tag>? tagSuggestions,
    Value<Priority?> targetPriority = const Value.absent(),
  }) {
    return PriorityState(
      context: context ?? this.context,
      activity: activity.or(this.activity),
      draft: draft ?? this.draft,
      draftNote: draftNote ?? this.draftNote,
      schedule: schedule != null
          ? (schedule.isNotEmpty ? Map.unmodifiable(schedule) : schedule)
          : this.schedule,
      first: first ?? this.first,
      firstDate: firstDate,
      range: range ?? this.range,
      next: next.or(this.next),
      previous: previous.or(this.previous),
      showArchived: showArchived ?? this.showArchived,
      agendaItems: agendaItems != null
          ? (agendaItems.isNotEmpty
                ? List.unmodifiable(agendaItems)
                : agendaItems)
          : (schedule == null ? this.agendaItems : null),
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
      targetPriority: targetPriority.or(this.targetPriority),
    );
  }

  @override
  List<Object?> get props => [
    context,
    activity,
    draft,
    draftNote,
    schedule,
    first,
    range,
    previous,
    next,
    showArchived,
    agendaItems,
    filter,
    search,
    twists,
    actors,
    tags,
    tagSuggestions,
    targetPriority,
  ];

  @override
  String toString() {
    return 'PriorityState(context: ${context.title}, activity: ${activity?.title}, draft: $draft, first: $first, range: $range, showArchived: $showArchived, filter: $filter, search: $search, twists: ${twists.length}, tags: ${tags.length})';
  }

  /// Returns the index of the first AgendaHeaderItem with a date on or after the given date.
  /// Returns 0 if no such AgendaHeaderItem is found.
  static int _findDate(List<AgendaItem> agendaItems, Date targetDate) {
    for (int i = 0; i < agendaItems.length; i++) {
      final item = agendaItems[i];
      if (item is AgendaHeaderItem &&
          item.date != null &&
          item.date! >= targetDate) {
        return i;
      }
    }
    return 0;
  }

  /// Returns the index of the AgendaHeaderItem with now=true.
  /// Prefers the "Now" divider header (no date) over date headers.
  /// Returns 0 if no such AgendaHeaderItem is found.
  static int _findNow(List<AgendaItem> agendaItems) {
    int? firstNow;
    for (int i = 0; i < agendaItems.length; i++) {
      final item = agendaItems[i];
      if (item is AgendaHeaderItem && item.now) {
        if (item.date == null) return i;
        firstNow ??= i;
      }
    }
    return firstNow ?? 0;
  }

  /// Returns the index of the first AgendaActivityItem with now=true.
  /// This is the first incomplete action, which is the true "up next" split point.
  /// Falls back to _findNow (the now header) if no activity has now=true.
  static int _findNowActivity(List<AgendaItem> agendaItems) {
    for (int i = 0; i < agendaItems.length; i++) {
      final item = agendaItems[i];
      if (item is AgendaActivityItem && item.now) {
        return i;
      }
    }
    return _findNow(agendaItems);
  }
}

sealed class AgendaItem {
  const AgendaItem();

  T when<T>({
    required T Function(AgendaHeaderItem) header,
    required T Function(AgendaActivityItem) activity,
  }) {
    return switch (this) {
      AgendaHeaderItem h => header(h),
      AgendaActivityItem a => activity(a),
    };
  }
}

class AgendaHeaderItem extends AgendaItem {
  const AgendaHeaderItem({
    this.priority,
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.activity,
    this.text,
    this.scheduleAt,
  });

  final Priority? priority;
  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final Activity? activity;
  final String? text;
  final DateTime? scheduleAt;

  @override
  String toString() =>
      'AgendaHeaderItem(priority: ${priority?.title}, dateTimeRange: $dateTimeRange, date: $date, now: $now, text: $text, scheduleAt: $scheduleAt)';
}

class AgendaActivityItem extends AgendaItem {
  const AgendaActivityItem(this.activity, {this.now = false});

  final Activity activity;
  final bool now;

  @override
  String toString() =>
      'AgendaActivityItem(activity: ${activity.title}, now: $now)';
}
