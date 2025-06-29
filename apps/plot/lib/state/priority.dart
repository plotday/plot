import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/agenda_item.dart';
import 'logging.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority, Activity? activity, Event? event})
    : _subscriptions = [],
      _agendaSubscription = null,
      super(
        PriorityState(context: priority, activity: activity, event: event),
      ) {
    _loadPriority(priority);
    if (activity != null) {
      _loadActivity(activity);
    }
    if (event != null) {
      _loadEvent(event);
    }

    final today = Date.today();
    final initialStartDate = today
        .toDateTime()
        .subtract(const Duration(days: 14))
        .toDate();
    final initialEndDate = today
        .toDateTime()
        .add(const Duration(days: 14))
        .toDate();
    DateRange range = DateRangeCustom(initialStartDate, initialEndDate);
    _loadAgendaItems(range);
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _agendaSubscription?.cancel();
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  void _loadPriority(Priority priority) {
    // Watch the current priority (context) - only add if not already watching
    if (_subscriptions.isEmpty) {
      _subscriptions.add(
        Priority.watchOne(priority.id).listen((priority) {
          log.info('Priority updated');
          emit(state.copyWith(context: priority));
        }),
      );

      // Load pinned activities
      _loadPinnedActivities();
    }
  }

  void _loadActivity(Activity activity) {
    // Watch the activity
    _subscriptions.add(
      Activity.watchOne(activity.id).listen((watchedActivity) {
        log.info('Activity updated');
        emit(state.copyWith(activity: watchedActivity));
      }),
    );
  }

  void _loadEvent(Event event) {
    // Watch the event
    _subscriptions.add(
      Event.watchOne(event.id).listen((watchedEvent) {
        log.info('Event updated');
        emit(state.copyWith(event: watchedEvent));
      }),
    );
  }

  Future<void> save(Activity activity) async {
    await activity.save();
  }

  Future<void> add(Activity activity) async {
    activity = activity.copyWith(draft: false);
    await activity.save();
    // Create a new draft
    log.info('New draft');
    emit(
      state.copyWith(
        draft: Activity(
          priorityId: state.context.id,
          parent: state.activity,
          parentEvent: state.event,
          draft: true,
        ),
      ),
    );
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));

    // Reload pinned activities and agenda items with new archived filter
    _loadPinnedActivities();
    if (state.range != null) {
      _loadAgendaItems(state.range!);
    }
  }

  void _loadPinnedActivities() {
    // Cancel existing pinned subscription if it exists
    if (_subscriptions.length > 1) {
      _subscriptions[1].cancel();
      _subscriptions.removeAt(1);
    }

    // Watch pinned activities with current archived filter
    _subscriptions.add(
      Activity.watch(
        priorityId: state.context.id,
        pinned: true,
        deleted: state.showArchived,
      ).listen((activities) {
        log.info('Pinned activities updated');
        emit(
          state.copyWith(
            pinned: activities.map((a) => ActivityAgendaItem(a)).toList(),
          ),
        );
      }),
    );
  }

  void _loadAgendaItems(DateRange range) {
    log.info('Loading agenda items (${range.start} to ${range.end})');
    _agendaSubscription?.cancel();

    // Ensure the new range overlaps with the previous one by at least one day
    // Find the first and last HeaderAgendaItem in the current agenda items
    var overlappingIndex =
        state.range == null || range.start == state.range!.start
        ? -1
        : state.agendaItems.indexWhere(
            (item) => item.when(
              activity: (_) => false,
              event: (_) => false,
              header: (header) => header.date != null,
            ),
          );
    Date? overlappingDate;
    if (overlappingIndex != -1) {
      overlappingDate =
          (state.agendaItems[overlappingIndex] as HeaderAgendaItem).date!;
      if (!range.includes(overlappingDate)) {
        log.info('$overlappingDate is not in range $range');
        overlappingIndex = state.agendaItems.lastIndexWhere(
          (item) => item.when(
            activity: (_) => false,
            event: (_) => false,
            header: (header) => header.date != null,
          ),
        );
        overlappingDate =
            (state.agendaItems[overlappingIndex] as HeaderAgendaItem).date!;
        if (!range.includes(overlappingDate)) {
          log.info('$overlappingDate is not in range $range, adding it');
          // If the new range starts after the old range, extend it to overlap by one day
          range = DateRangeCustom(overlappingDate, range.end);
        }
      }
    }
    log.info(
      'Range: ${range.start} to ${range.end}, overlappingIndex: $overlappingIndex, overlappingDate: $overlappingDate',
    );

    if (state.activity == null && state.event == null) {
      _agendaSubscription =
          Rx.combineLatest3(
            ScheduledDay.watch(
              range,
              context: state.context,
              deleted: state.showArchived,
            ),
            Priority.watch(order: PriorityOrder.sorted),
            ScheduledDay.watchRange(
              context: state.context,
              deleted: state.showArchived,
            ),
            (scheduleMap, priorities, totalRange) =>
                (scheduleMap, priorities, totalRange),
          ).listen((data) {
            final (scheduleMap, priorities, totalRange) = data;
            final priorityMap = Priority.asMap(priorities);
            final today = Date.today();

            final agenda = Agenda.fromScheduledDays(
              scheduleMap.values.toList(),
              today: today,
              priorities: priorityMap,
              context: state.context,
            );

            // Calculate the new first index based on header overlap
            int first = state.first;
            if (overlappingIndex != -1) {
              final newIndex = agenda.items.indexWhere(
                (item) => item.when(
                  activity: (_) => false,
                  event: (_) => false,
                  header: (header) => header.date == overlappingDate,
                ),
              );
              log.info(
                'First was $first, overlappingIndex is $overlappingIndex, newIndex is $newIndex newFirst = ${first + overlappingIndex - newIndex}',
              );
              assert(
                newIndex != -1,
                'Overlapping date should be found in new agenda items',
              );
              first += overlappingIndex - newIndex;
              // The listener may trigger multiple times, but we only want to adjust first once
              overlappingIndex = -1;
            }

            // Determine done states based on comparison with total available range
            bool doneStart = true;
            bool doneEnd = true;

            if (totalRange != null) {
              final (totalEarliest, totalLatest) = totalRange;

              if (totalEarliest != null && totalLatest != null) {
                // We're done at start if our current range start is at or before the earliest available data
                doneStart = range.start <= totalEarliest;

                // We're done at end if our current range end is at or after the latest available data
                doneEnd =
                    range.end >=
                    totalLatest.addDays(
                      1,
                    ); // Add 1 day since range.end is exclusive
              }
            }

            log.info(
              'Agenda updated (${range.start} to ${range.end}, first=$first, count=${agenda.items.length}, totalRange=$totalRange, doneStart=$doneStart, doneEnd=$doneEnd)',
            );
            log.info(
              'Anchor ${agenda.anchorIndex == null ? null : first + agenda.anchorIndex!}: ${agenda.anchorIndex == null ? null : agenda.items[agenda.anchorIndex!]}',
            );
            emit(
              state.copyWith(
                range: range,
                agendaItems: agenda.items,
                first: first,
                anchorIndex:
                    agenda.anchorIndex ==
                        null //|| state.anchorIndex != 0
                    ? null
                    : first + agenda.anchorIndex!,
                moreAgendaItems: true,
                doneStart: doneStart,
                doneEnd: doneEnd,
              ),
            );
          });
    } else {
      _agendaSubscription =
          Activity.watch(
            // range: range,
            priorityPath: state.context.path,
            path: state.activity?.path ?? state.event?.path,
            deleted: state.showArchived,
          ).listen((activities) {
            emit(
              state.copyWith(
                // range: range,
                agendaItems: activities
                    .map((activity) => ActivityAgendaItem(activity))
                    .toList(),
                first: 0,
                anchorIndex: 0,
                moreAgendaItems: false,
                doneStart: true,
                doneEnd: true,
              ),
            );
          });
    }
  }

  void fetchMoreAgendaItems(int first, int count) {
    if (state.range == null) return;
    log.info('Fetching more agenda items: first=$first, count=$count');
    final itemsPerDay = state.agendaItems.length / state.range!.duration.inDays;
    // Calculate how many days to move backwards from current first
    final moveStart = first - state.first;
    final moveEnd = first - state.first + count - state.agendaItems.length;
    final newRange = DateRangeCustom(
      state.range!.start.addDays((moveStart / itemsPerDay).ceil()),
      state.range!.end.addDays((moveEnd / itemsPerDay).ceil()),
    );
    _loadAgendaItems(newRange);
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _agendaSubscription;
}
