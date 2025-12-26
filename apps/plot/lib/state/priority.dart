import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:drift/drift.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/async.dart';
import 'package:plot/util/list.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/state/now.dart';
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

    // Check if requested range is already within current loaded range
    final currentFirst = state.first;
    final currentLast = state.first + state.agendaItems.length;
    final requestedLast = first + count;

    if (first >= currentFirst && requestedLast <= currentLast) {
      log.fine(
        'Requested range [$first, $requestedLast) already within current range [$currentFirst, $currentLast). Skipping fetch.',
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

    log.fine(
      'Fetching more agenda items: expandedFirst=$expandedFirst, expandedCount=$expandedCount, moveStart=$moveStart, moveEnd=$moveEnd, doneStart=${state.doneStart}, doneEnd=${state.doneEnd}',
    );

    final currentRange = state.range!;
    final rangeDays = currentRange.duration.inDays;

    Date newStart = moveStart < 0 && state.previous != null
        ? state.previous!
        : currentRange.start;
    Date newEnd = moveEnd > 0 && state.next != null
        ? state.next!
        : currentRange.end;

    if (moveStart > 0 || !state.doneStart) {
      final moveDays = (rangeDays * (moveStart / state.agendaItems.length))
          .floor();
      newStart = newStart.addDays(moveDays);
    }

    if (moveEnd > 0 || !state.doneEnd) {
      final moveDays = (rangeDays * (moveEnd / state.agendaItems.length))
          .ceil();
      newEnd = newEnd.addDays(moveDays);
    }

    final newRange = CustomBoundedDateRange(newStart, newEnd);
    log.fine(
      'Expanding range from ${currentRange.start}-${currentRange.end} to ${newRange.start}-${newRange.end}',
    );
    await _loadSchedule(newRange);
  }

  @override
  Future<void> close() {
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
    final draftNote = draftNotes.isEmpty
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
            updatedAt: draftNotes.first.updatedAt,
            archivedAt: draftNotes.first.archivedAt,
          );

    if (draftNote != null) {
      log.info(
        '[setPriority] Loaded draft note: id=${draftNote.id}, activityId=${draftNote.activityId}, content="${draftNote.content?.substring(0, draftNote.content!.length > 50 ? 50 : draftNote.content!.length) ?? ''}", archived=${draftNote.archivedAt != null}',
      );
    } else {
      log.info('[setPriority] No draft note found for activity ${newDraft.id}');
    }

    // Set target priority without changing context (delay context update until data loads)
    emit(
      state.copyWith(
        targetPriority: Value(newPriority),
        draft: newDraft,
        draftNote: Value(draftNote),
      ),
    );

    // Reload with new priority
    _loadPriority();
  }

  void setActivity(Activity? activity) {
    if (state.activity == activity) {
      return;
    }
    emit(state.copyWith(activity: Value(activity)));

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
    if (activity.id == state.draft.id) {
      emit(state.copyWith(draft: activity));
    }
    // Update draft note in state if:
    // 1. The note ID matches the existing draft note ID (update case), OR
    // 2. There is no existing draft note and the note belongs to the current draft activity (new draft note case)
    if (note != null &&
        (note.id == state.draftNote?.id ||
         (state.draftNote == null && note.activityId == state.draft.id))) {
      emit(state.copyWith(draftNote: Value(note)));
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
  /// - Returns null if no current activity is set
  AgendaItem? getAgendaItem(
    int offset, {
    bool includeActivity = true,
    bool includePriority = false,
    bool includeDate = false,
  }) {
    if (state.activity == null) {
      return null;
    }

    // Find current activity index in agendaItems
    int currentIndex = -1;
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
          // Calculate tag suggestions: common tags first, then all other tags
          const actionTags = [Tag.now, Tag.done, Tag.later, Tag.archived];

          // Common tags (excluding action tags)
          final commonTagsFiltered = tags
              .where(
                (tagData) =>
                    !actionTags.contains(tagData.$1) && tagData.$1.addable,
              )
              .map((tagData) => tagData.$1)
              .toList();

          // All tags excluding action tags and common tags
          final commonTagSet = commonTagsFiltered.toSet();
          final otherTags = Tag.getAll(onlyAddable: true)
              .where(
                (tag) =>
                    !actionTags.contains(tag) && !commonTagSet.contains(tag),
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

    _loadSchedule(
      state.range ??
          CustomBoundedDateRange(
            Date.today()
                .toDateTime()
                .subtract(const Duration(days: 14))
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
      log.fine('Activity updated');
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

  Future<void> save(Activity activity) async {
    await activity.save();
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
    if (note != null && note.content != null && note.content!.trim().isNotEmpty) {
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
    final newDraft = Activity(priority: state.context, draft: true);
    await newDraft.save();

    emit(state.copyWith(draft: newDraft));

    return savedActivity;
  }

  Future<void> _loadSchedule(BoundedDateRange range, {Date? firstDate}) {
    final priorityToLoad = state.targetPriority ?? state.context;

    log.fine('Loading schedule (${range.start} to ${range.end})');
    _agendaSubscription?.cancel();

    // Ensure the new range overlaps with the previous one by at least one day
    // Find the first and last AgendaHeaderItem with date in the current agenda items
    var overlappingIndex =
        state.range == null || range.start == state.range?.start
        ? -1
        : state.agendaItems.indexWhere(
            (item) => item is AgendaHeaderItem && item.date != null,
          );
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
    // using DateTime.now() for "now" indicator placement and event transitions.
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
                final now = DateTime.now();
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
              if (overlappingIndex != -1) {
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
                log.fine(
                  'First was $first, overlappingIndex is $overlappingIndex, newIndex is $newIndex newFirst = ${first + overlappingIndex - newIndex}',
                );
                if (newIndex != -1) {
                  first += overlappingIndex - newIndex;
                }
                // The listener may trigger multiple times, but we only want to adjust first once
                overlappingIndex = -1;
              }

              log.fine(
                'Schedule updated (${range.start} to ${range.end}, first=$first, count=${schedule.days.length}, previous=${schedule.previous}, next=${schedule.next})',
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

class PriorityBlocProviderState extends State<PriorityBlocProvider> {
  late Future<PriorityBloc> _bloc;

  @override
  void initState() {
    super.initState();
    _bloc =
        (widget.priority != null
                ? Future.value(widget.priority!)
                : widget.priorityId != null
                ? Priority.getOne(widget.priorityId!)
                : widget.activityId != null
                ? Activity.getOne(
                    widget.activityId!,
                  ).then((activity) => activity.priority)
                : Future<Priority>.error(
                    'Either priorityId or activityId must be provided',
                  ))
            .then((priority) {
              // Update theme hue when priority is first loaded
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  context.read<NowBloc>().setContext(priority);
                }
              });
              return PriorityBloc(priority: priority);
            });
  }

  @override
  void didUpdateWidget(PriorityBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.priority != null && widget.priority != oldWidget.priority) {
      _bloc.then((bloc) {
        final priority = widget.priority;
        if (priority == null) return;
        bloc.setPriority(priority);
        // Theme will be updated when new agenda loads (in _loadSchedule)
      });
    } else if (widget.priorityId != null &&
        widget.priorityId != oldWidget.priorityId) {
      _bloc.then((bloc) async {
        final priority = await Priority.getOne(widget.priorityId!);
        bloc.setPriority(priority);
        // Theme will be updated when new agenda loads (in _loadSchedule)
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
