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
  PriorityBloc({required Priority priority, Activity? activity})
    : _subscriptions = [],
      _activitySubscription = null,
      _agendaSubscription = null,
      _tagsSubscription = null,
      super(PriorityState(context: priority, activity: activity)) {
    _loadPriority();

    // Register callback to reload schedule when time changes (e.g., via TimeTravel)
    Time.setOnTimeChanged(() {
      if (state.range != null) {
        log.fine(
          'Time changed, reloading schedule to update time-dependent UI',
        );
        _loadSchedule(state.range!);
      }
    });
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));

    // Reload agenda items with new archived filter
    _loadPriority();
  }

  void setReorderMode(bool enabled) {
    emit(state.copyWith(isReorderMode: enabled));
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

    // Reload agenda items with new search
    _loadPriority();
  }

  void moveAgendaItem(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;

    final items = List<AgendaItem>.from(state.agendaItems);
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);

    emit(state.copyWith(agendaItems: items));
  }

  Future<void> fetchMoreAgendaItems(int first, int count) async {
    if (state.range == null) return;

    // Check if requested range is already within current loaded range with tolerance
    // Only fetch if we're missing significant buffer (> 20% of a page)
    final currentFirst = state.first;
    final currentLast = state.first + state.agendaItems.length;
    final requestedLast = first + count;

    final missingBefore = currentFirst - first;
    final missingAfter = requestedLast - currentLast;
    final pageSize = count / 3; // Rough estimate of page size
    final significantMissing = pageSize * 0.2; // 20% of page threshold

    if (missingBefore <= significantMissing &&
        missingAfter <= significantMissing) {
      log.fine(
        'Requested range [$first, $requestedLast) close enough to current range [$currentFirst, $currentLast). '
        'Skipping fetch (missingBefore=$missingBefore, missingAfter=$missingAfter, threshold=$significantMissing).',
      );
      return;
    }

    // Expand requested range by 15% in both directions
    final buffer = (count * 0.15).ceil();
    final expandedFirst = first - buffer;
    final expandedCount = count + (2 * buffer);

    log.fine(
      'Expanding requested range [$first, ${first + count}) by 15% to [$expandedFirst, ${expandedFirst + expandedCount})',
    );

    final moveStart = state.doneStart
        ? 0
        : expandedFirst - state.first; // negative = need before
    final moveEnd = state.doneEnd
        ? 0
        : expandedFirst -
              state.first +
              expandedCount -
              state.agendaItems.length; // positive = need after

    log.info(
      '[fetchMoreAgendaItems] expandedFirst=$expandedFirst, expandedCount=$expandedCount, '
      'moveStart=$moveStart, moveEnd=$moveEnd, doneStart=${state.doneStart}, doneEnd=${state.doneEnd}, '
      'previous=${state.previous}, next=${state.next}, range=${state.range}',
    );

    final currentRange = state.range!;

    // Calculate new start and end dates
    // Strategy: Use previous/next boundaries when available, otherwise keep current boundary
    // This prevents oscillation from proportion-based calculations

    Date newStart = currentRange.start;
    Date newEnd = currentRange.end;

    // Calculate density-based expansion to satisfy BidirectionalList in fewer rounds
    final rangeDays = currentRange.end
        .toDateTime()
        .difference(currentRange.start.toDateTime())
        .inDays;
    final itemsPerDay = rangeDays > 0
        ? state.agendaItems.length / rangeDays
        : 1.0;

    // Expand backward if needed
    if (moveStart < 0 && !state.doneStart) {
      final itemsNeeded = -moveStart;
      final daysNeeded = itemsPerDay > 0
          ? (itemsNeeded / itemsPerDay).ceil()
          : 7;
      final daysToExpand = daysNeeded.clamp(7, 90);
      newStart = currentRange.start.addDays(-daysToExpand);
      log.fine(
        'Expanding start by $daysToExpand days (need ~$itemsNeeded items, '
        'density=${itemsPerDay.toStringAsFixed(1)}/day): $newStart',
      );
    }

    // Expand forward if needed
    if (moveEnd > 0 && !state.doneEnd) {
      final itemsNeeded = moveEnd;
      final daysNeeded = itemsPerDay > 0
          ? (itemsNeeded / itemsPerDay).ceil()
          : 7;
      final daysToExpand = daysNeeded.clamp(7, 90);
      newEnd = currentRange.end.addDays(daysToExpand);
      log.fine(
        'Expanding end by $daysToExpand days (need ~$itemsNeeded items, '
        'density=${itemsPerDay.toStringAsFixed(1)}/day): $newEnd',
      );
    }

    final newRange = CustomBoundedDateRange(newStart, newEnd);
    log.fine(
      'Expanding range from ${currentRange.start}-${currentRange.end} to ${newRange.start}-${newRange.end}',
    );
    await _loadSchedule(newRange);
  }

  @override
  Future<void> close() {
    // Unregister time change callback
    Time.setOnTimeChanged(null);

    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _activitySubscription?.cancel();
    _agendaSubscription?.cancel();
    _tagsSubscription?.cancel();
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  Future<void> setPriority(Priority newPriority) async {
    if (state.context.id == newPriority.id) return;

    log.info(
      'Updating priority from ${state.context.title} to ${newPriority.title}',
    );

    // Cancel existing subscriptions
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _activitySubscription?.cancel();
    _agendaSubscription?.cancel();
    _tagsSubscription?.cancel();

    // Load or create draft for new priority
    // Load the latest draft regardless of archived status, so we can reuse it
    log.info(
      '[setPriority] Switching to priority: ${newPriority.id} (${newPriority.title})',
    );
    final drafts = await Activity.get(
      priorityId: newPriority.id,
      draft: true,
      archived: null, // Get both archived and non-archived
    );
    // Sort by updatedAt descending to get the latest
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final existingDraft = drafts.firstOrNull;

    Activity newDraft;
    if (existingDraft != null) {
      newDraft = existingDraft;
      log.info(
        '[setPriority] Loaded existing draft: id=${existingDraft.id}, priority=${existingDraft.priority.id} (${existingDraft.priority.title}), archived=${existingDraft.archivedAt != null}',
      );
    } else {
      newDraft = Activity(priority: newPriority, draft: true);
      log.info(
        '[setPriority] Creating new draft for priority: id=${newDraft.id}, priority=${newPriority.id} (${newPriority.title})',
      );
    }

    // Load draft note for the draft activity (also load archived notes)
    // We get all draft notes (archived or not) and take the latest one
    final draftNotes =
        await (Store.get.select(Store.get.notes)
              ..where((tbl) => tbl.activityId.equalsValue(newDraft.id))
              ..where((tbl) => tbl.draft.equals(true))
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
              ..limit(1))
            .get();
    Note? draftNote = draftNotes.isEmpty
        ? null
        : Note(
            id: draftNotes.first.id,
            activityId: draftNotes.first.activityId,
            authorId: draftNotes.first.authorId,
            draft: draftNotes.first.draft,
            private: draftNotes.first.private,
            content: draftNotes.first.content,
            links: draftNotes.first.links,
            mentions: draftNotes.first.mentions,
            createdAt: draftNotes.first.createdAt,
            sourceCreatedAt: draftNotes.first.sourceCreatedAt,
            updatedAt: draftNotes.first.updatedAt,
            archivedAt: draftNotes.first.archivedAt,
          );

    if (draftNote != null) {
      log.info(
        '[setPriority] Loaded draft note: id=${draftNote.id}, activityId=${draftNote.activityId}, content="${draftNote.content?.substring(0, draftNote.content!.length > 50 ? 50 : draftNote.content!.length) ?? ''}", archived=${draftNote.archivedAt != null}',
      );
    } else {
      // Create draft note in memory (will be saved when content is added)
      draftNote = Note.draft(activityId: newDraft.id);
      log.info(
        '[setPriority] Created draft note in state: id=${draftNote.id}, activityId=${newDraft.id}',
      );
    }

    // Set target priority without changing context (delay context update until data loads)
    emit(
      state.copyWith(
        targetPriority: Value(newPriority),
        draft: newDraft,
        draftNote: draftNote,
        isReorderMode: false,
      ),
    );

    // Reload with new priority
    _loadPriority();
  }

  void setActivity(Activity? activity) {
    if (state.activity == activity) {
      return;
    }
    // Clear reorder mode when opening an activity
    emit(
      state.copyWith(
        activity: Value(activity),
        isReorderMode: activity != null ? false : null,
      ),
    );

    // Manage activity subscription
    if (activity != null) {
      _loadActivity(activity);
    } else {
      _activitySubscription?.cancel();
      _activitySubscription = null;
    }
  }

  /// Resets the draft to a new empty activity for the current priority.
  /// This should be called when navigating to create a new activity.
  /// Reuses the existing draft ID to minimize archived drafts.
  void resetDraft() {
    final clearedDraft = state.draft.copyWith(
      type: ActivityType
          .note, // Default to note type (doesn't require scheduling)
      title: const Value(null),
      at: const Value(null),
      on: const Value(null),
      duration: const Value(null),
      assigneeId: null,
      preview: const Value(null),
    );
    emit(state.copyWith(draft: clearedDraft));
  }

  /// Updates the draft activity and optionally the note, saving both to the database.
  /// This provides instant UI updates while persisting changes.
  ///
  /// [activity] - Required activity to update
  /// [note] - Optional note to save (must be a draft note for this activity)
  Future<void> updateDraft(Activity activity, {Note? note}) async {
    if (activity.id != state.draft.id) {
      log.warning(
        '[updateDraft] Attempted to update draft with mismatched activity ID: ${activity.id} (expected ${state.draft.id})',
      );
      return;
    }

    emit(state.copyWith(draft: activity));

    if (note?.id == state.draftNote.id) {
      emit(state.copyWith(draftNote: note));
    } else {
      log.warning(
        "[updateDraft] Note ID does not match draft note ID: ${note?.id} (expected ${state.draftNote.id})",
      );
    }

    await activity.save();
    if (note != null) {
      log.info(
        '[updateDraft] Saving note: id=${note.id}, activityId=${note.activityId}, content length=${note.content?.length ?? 0}',
      );
      await note.save();
    }
  }

  /// Gets an agenda item relative to the current activity by offset.
  ///
  /// [offset] - Positive for forward, negative for backward (e.g., +1 = next, -1 = previous)
  /// [includeActivity] - Include ActivityAgendaItem in navigation (default: true)
  /// [includePriority] - Include PriorityAgendaItem in navigation (default: false)
  /// [includeDate] - Include DateAgendaItem in navigation (default: false)
  ///
  /// Returns the agenda item at the offset position. Boundary behavior:
  /// - If offset would go out of bounds but items exist in that direction, returns the furthest item
  /// - If already at the furthest item and trying to move further, returns null
  /// - If no current activity is set, navigates relative to the "now" header position
  AgendaItem? getAgendaItem(
    int offset, {
    bool includeActivity = true,
    bool includePriority = false,
    bool includeDate = false,
  }) {
    int currentIndex = -1;

    if (state.activity == null) {
      // No activity selected: start from the "now" header.
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
      // Activity selected: find its index
      for (int i = 0; i < state.agendaItems.length; i++) {
        final activity = state.agendaItems[i].when<Activity?>(
          header: (header) => null,
          activity: (agendaActivity) => agendaActivity.activity,
        );
        if (activity?.id == state.activity!.id) {
          currentIndex = i;
          break;
        }
      }
      if (currentIndex == -1) {
        return null;
      }
    }

    // Helper to check if an item matches the filter criteria
    bool matchesFilter(AgendaItem item) {
      return item.when<bool>(
        activity: (agendaActivity) => includeActivity,
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
    if (state.activity != null) {
      _loadActivity(state.activity!);
    }

    // Watch tags for the priority
    _tagsSubscription?.cancel();
    _tagsSubscription = Activity.watchTagsForPriority(priorityToLoad.path)
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

    _loadSchedule(
      state.range ??
          CustomBoundedDateRange(
            Date.today()
                .toDateTime()
                .subtract(const Duration(days: 45))
                .toDate(),
            Date.today().toDateTime().add(const Duration(days: 14)).toDate(),
          ),
      firstDate: Date.today(),
    );
  }

  void _loadActivity(Activity activity) {
    // Cancel existing activity subscription
    _activitySubscription?.cancel();

    // Watch the activity
    _activitySubscription = Activity.watchOne(activity.id).listen((
      watchedActivity,
    ) {
      emit(state.copyWith(activity: Value(watchedActivity)));
    });
  }

  /// Loads draft from database for the given priority
  Future<void> _loadDraft(Priority priority) async {
    final existingDraft = await Activity.getDraftByPriority(priority.id);
    if (existingDraft != null) {
      emit(state.copyWith(draft: existingDraft));
    }
  }

  /// Adds an activity by converting the current draft to a non-draft.
  /// Creates a fresh draft for the priority afterward.
  /// If note is provided, converts it from draft to published and asynchronously generates a title.
  /// Returns the saved activity.
  Future<Activity> add(Activity activity, {Note? note}) async {
    // Convert the draft to a non-draft
    final savedActivity = activity.copyWith(draft: false);
    await savedActivity.save();

    // Convert draft note to published if provided
    if (note != null &&
        note.content != null &&
        note.content!.trim().isNotEmpty) {
      final publishedNote = note.copyWith(
        activityId: savedActivity.id,
        draft: false,
      );
      await publishedNote.save();

      // Asynchronously generate a better title using AI (fire and forget)
      // The activity is already saved with a fallback title, so this update
      // will happen in the background without blocking the UI
      savedActivity
          .generateTitle(note.content!)
          .then((title) async {
            if (title != savedActivity.title) {
              await savedActivity.copyWith(title: Value(title)).save();
            }
          })
          .catchError((Object e) {
            // Error already logged by generateTitle(), just ignore here
          });
    }

    // Create fresh draft for the priority
    final newDraft = Activity(priority: activity.priority, draft: true);
    emit(
      state.copyWith(
        draft: newDraft,
        draftNote: Note.draft(activityId: newDraft.id),
      ),
    );

    return savedActivity;
  }

  Future<void> _loadSchedule(BoundedDateRange range, {Date? firstDate}) {
    final priorityToLoad = state.targetPriority ?? state.context;

    log.fine('Loading schedule (${range.start} to ${range.end})');
    _agendaSubscription?.cancel();

    // Ensure the new range overlaps with the previous one by at least one day
    // Find the header at the scroll anchor position (BidirectionalList index 0)
    var overlappingIndex = -1;
    if (state.range != null && range.start != state.range?.start) {
      // The scroll anchor is at agendaItems[0 - state.first]
      final anchorIndex = 0 - state.first;

      // Find the nearest header at or after the anchor position
      if (anchorIndex >= 0 && anchorIndex < state.agendaItems.length) {
        overlappingIndex = state.agendaItems.indexWhere(
          (item) => item is AgendaHeaderItem && item.date != null,
          anchorIndex, // Start search from anchor position
        );
      }

      // Fallback: if no header found at/after anchor, find the last header before it
      if (overlappingIndex == -1 && anchorIndex > 0) {
        for (var i = anchorIndex - 1; i >= 0; i--) {
          if (state.agendaItems[i] is AgendaHeaderItem &&
              (state.agendaItems[i] as AgendaHeaderItem).date != null) {
            overlappingIndex = i;
            break;
          }
        }
      }
    }
    Date? overlappingDate;
    if (overlappingIndex != -1) {
      overlappingDate = state.agendaItems[overlappingIndex].when<Date?>(
        header: (header) => header.date,
        activity: (activity) => null,
      );
      if (overlappingDate != null && !range.includes(overlappingDate)) {
        if (overlappingDate >= range.end) {
          log.fine('Extending $range to include $overlappingDate');
          // If the new range ends before the old range, extend it to overlap by one day
          range = CustomBoundedDateRange(
            range.start,
            overlappingDate.addDays(1),
          );
        } else {
          overlappingIndex = state.agendaItems.lastIndexWhere(
            (item) => item is AgendaHeaderItem && item.date != null,
          );
          overlappingDate = state.agendaItems[overlappingIndex].when<Date?>(
            header: (header) => header.date,
            activity: (activity) => null,
          );
          if (overlappingDate != null && !range.includes(overlappingDate)) {
            log.fine('Extending $range to include $overlappingDate');
            // If the new range starts after the old range, extend it to overlap by one day
            range = CustomBoundedDateRange(overlappingDate, range.end);
          }
        }
      }
    }
    log.fine(
      'Range: ${range.start} to ${range.end}, overlappingIndex: $overlappingIndex, overlappingDate: $overlappingDate',
    );

    log.fine(
      'Getting activities for priority ${priorityToLoad.id} in range $range',
    );

    // Create a completer to signal when the first result arrives
    final completer = Completer<void>();

    // Schedule.watch() uses distinct() to filter duplicate data emissions.
    // However, PriorityState._makeAgenda() performs time-dependent calculations
    // using Time.now() for "now" indicator placement and event transitions.
    // We need to re-evaluate every minute to ensure these calculations use
    // fresh time values, even when the underlying schedule data hasn't changed.
    _agendaSubscription =
        Schedule.watch(
              range,
              context: priorityToLoad,
              archived: state.showArchived,
              filter: state.filter.isNotEmpty ? state.filter : null,
              search: state.search.isNotEmpty ? state.search : null,
            )
            .transform(
              ExpiringStreamTransformer((schedule) {
                // Re-evaluate every minute on the minute to update time-dependent UI
                final now = Time.now();
                final expiry = now.add(
                  Duration(
                    seconds: 60 - now.second,
                    milliseconds: -now.millisecond,
                  ),
                );
                return ExpiringResult(value: schedule, expiry: expiry);
              }),
            )
            .debounceTime(const Duration(milliseconds: 100))
            .listen((schedule) {
              // Calculate the new first index based on date overlap
              int first = state.first;

              // If we have an overlapping date, find its new position in the agenda
              // and adjust first to keep it at the same visual position.
              // This needs to happen on EVERY emission since sync can insert new items.
              if (overlappingDate != null) {
                final newScheduleItems = PriorityState._makeAgenda(
                  schedule.days,
                  context: priorityToLoad,
                );
                final newIndex = newScheduleItems.indexWhere(
                  (item) => item.when<bool>(
                    header: (header) => header.date == overlappingDate,
                    activity: (activity) => false,
                  ),
                );
                if (newIndex != -1) {
                  final newFirst = -newIndex;
                  final firstDelta = (first - newFirst).abs();

                  // Only adjust if the change is significant (> 3 items)
                  // This prevents thrashing from small position changes
                  if (firstDelta > 3) {
                    log.fine(
                      'Adjusting first from $first to $newFirst to keep anchor at $overlappingDate '
                      '(delta=$firstDelta, now at index $newIndex)',
                    );
                    first = newFirst;
                  } else {
                    log.fine(
                      'Anchor shift small (delta=$firstDelta), keeping first=$first stable',
                    );
                  }
                } else {
                  // overlappingDate not found in new agenda - reset to 0 (start of list)
                  log.fine(
                    'overlappingDate $overlappingDate not found in new agenda, resetting first to 0',
                  );
                  first = 0;
                }
              }

              // Log anchor mapping and clamp first to valid bounds
              final newAgenda = PriorityState._makeAgenda(
                schedule.days,
                context: priorityToLoad,
              );
              if (newAgenda.isNotEmpty) {
                var anchorIndex = 0 - first;
                final anchorItem =
                    anchorIndex >= 0 && anchorIndex < newAgenda.length
                    ? newAgenda[anchorIndex]
                    : null;
                final anchorDescription =
                    anchorItem?.when(
                      header: (h) =>
                          'Header(date=${h.date}, priority=${h.priority?.title})',
                      activity: (a) =>
                          'Activity(id=${a.activity.id}, title=${a.activity.title})',
                    ) ??
                    'OUT OF BOUNDS';
                log.info(
                  '[_loadSchedule] Anchor mapping: first=$first, '
                  'anchorIndex=$anchorIndex, agendaItems[$anchorIndex]=$anchorDescription',
                );

                // Clamp first to valid bounds if agenda shrunk
                if (anchorIndex >= newAgenda.length) {
                  final oldFirst = first;
                  // Point anchor to the last valid item
                  first = -(newAgenda.length - 1);
                  anchorIndex = 0 - first;
                  log.info(
                    '[_loadSchedule] Clamped first from $oldFirst to $first '
                    '(agenda length=${newAgenda.length}, new anchorIndex=$anchorIndex)',
                  );
                } else if (anchorIndex < 0) {
                  final oldFirst = first;
                  first = 0;
                  log.info(
                    '[_loadSchedule] Clamped first from $oldFirst to $first '
                    '(anchorIndex was negative)',
                  );
                }
              } else {
                // Empty agenda - reset first to 0
                if (first != 0) {
                  log.info(
                    '[_loadSchedule] Empty agenda, resetting first from $first to 0',
                  );
                  first = 0;
                }
              }

              log.info(
                '[_loadSchedule] Schedule updated: range=${range.start} to ${range.end}, '
                'first=$first, dayCount=${schedule.days.length}, '
                'previous=${schedule.previous}, next=${schedule.next}, '
                'doneStart=${schedule.previous == null}, doneEnd=${schedule.next == null}',
              );

              emit(
                state.copyWith(
                  // If switching priorities, update context atomically with new agenda
                  context: state.targetPriority,
                  range: range,
                  schedule: schedule.days,
                  first: first,
                  firstDate: firstDate,
                  previous: Value(schedule.previous),
                  next: Value(schedule.next),
                  // Clear targetPriority after switching
                  targetPriority: state.targetPriority != null
                      ? const Value(null)
                      : const Value.absent(),
                ),
              );

              // Complete the future on first result
              if (!completer.isCompleted) {
                completer.complete();
              }
            });

    return completer.future;
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _activitySubscription;
  StreamSubscription<void>? _agendaSubscription;
  StreamSubscription<List<(Tag, int)>>? _tagsSubscription;
}

class PriorityBlocProvider extends StatefulWidget {
  const PriorityBlocProvider({
    this.priorityId,
    this.activityId,
    this.priority,
    required this.child,
    super.key,
  });

  final PriorityId? priorityId;
  final ActivityId? activityId;
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
          : widget.activityId != null
          ? Activity.getOne(
              widget.activityId!,
            ).then((activity) => activity.priority)
          : Future<Priority>.error(
              'Either priorityId or activityId must be provided',
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
        'Failed to load requested priority (${widget.priorityId ?? widget.activityId}): $e',
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
        // Theme will be updated when new agenda loads (in _loadSchedule)
      });
    } else if (widget.priorityId != null &&
        widget.priorityId != oldWidget.priorityId) {
      _bloc.then((result) async {
        if (result.bloc == null) return;
        final priority = await Priority.getOne(widget.priorityId!);
        result.bloc!.setPriority(priority);
        // Theme will be updated when new agenda loads (in _loadSchedule)
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
