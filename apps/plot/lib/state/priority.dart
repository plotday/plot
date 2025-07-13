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
    _loadPriority();
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));

    // Reload pinned activities and agenda items with new archived filter
    _loadPriority();
    if (state.range != null) {
      _loadAgendaItems(state.range!);
    }
  }

  void moveAgendaItem(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;

    final items = List<AgendaItem>.from(state.agendaItems);
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);

    emit(state.copyWith(agendaItems: items));
  }

  void fetchMoreAgendaItems(int first, int count) async {
    if (state.range == null) return;

    // Determine if we need items before start, after end, or both
    final moveStart = first - state.first;
    final moveEnd = first - state.first + count - state.agendaItems.length;

    final needsBefore = moveStart < 0;
    final needsAfter = moveEnd > 0;

    log.info(
      'Fetching more agenda items: first=$first, count=$count, moveStart=$moveStart, moveEnd=$moveEnd, needsBefore=$needsBefore, needsAfter=$needsAfter',
    );

    Date newStart = state.range!.start;
    Date newEnd = state.range!.end;

    // Handle range expansion and internal range movement
    Date? prevDate, nextDate;
    if (needsBefore || needsAfter) {
      // Run both queries in parallel when both are needed
      final results = await Future.wait([
        if (needsBefore)
          ScheduledDay.previous(
            state.range!.start,
            context: state.context,
            deleted: state.showArchived,
            minimum: moveStart.abs(),
          ),
        if (needsAfter)
          ScheduledDay.next(
            state.range!.end,
            context: state.context,
            deleted: state.showArchived,
            minimum: moveEnd,
          ),
      ]);

      if (needsAfter) {
        nextDate = results.removeLast();
      }
      if (needsBefore) {
        prevDate = results.removeLast();
      }
    }

    // Handle expanding before the current range
    if (needsBefore) {
      if (prevDate != null) {
        newStart = prevDate;
      } else {
        // No more items before - go arbitrarily far back
        newStart = Date.earliest;
      }
    } else if (moveStart > 0) {
      for (int i = moveStart; i >= 0; i--) {
        final item = state.agendaItems[i];
        final date = item.when(
          activity: (activity) => null,
          event: (event) => null,
          header: (header) => header.date,
        );
        if (date != null) {
          newStart = date;
          break;
        }
      }
    }

    // Handle expanding after the current range
    if (needsAfter) {
      if (nextDate != null) {
        newEnd = nextDate.addDays(1); // Make end exclusive
      } else {
        // No more items after - go arbitrarily far ahead
        newEnd = Date.latest;
      }
    } else if (moveEnd < 0) {
      // Moving backward within the current range - find the date at the new last position
      for (
        int i = state.agendaItems.length - 1 + moveEnd;
        i < state.agendaItems.length;
        i++
      ) {
        final item = state.agendaItems[i];
        final date = item.when(
          activity: (_) => null,
          event: (_) => null,
          header: (header) => header.date,
        );
        if (date != null) {
          newEnd = date;
          break;
        }
      }
    }

    final newRange = DateRangeCustom(newStart, newEnd);
    log.info(
      'Expanding range from ${state.range!.start}-${state.range!.end} to ${newRange.start}-${newRange.end}',
    );
    _loadAgendaItems(newRange);
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

  void _loadPriority() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.add(
      Priority.watchOne(state.context.id).listen((priority) {
        log.info('Priority updated');
        emit(state.copyWith(context: priority));
      }),
    );
    _loadPinnedActivities();
    if (state.activity != null) {
      _loadActivity(state.activity!);
    }
    if (state.event != null) {
      _loadEvent(state.event!);
    }

    _loadAgendaItems(
      state.range ??
          DateRangeCustom(
            Date.today()
                .toDateTime()
                .subtract(const Duration(days: 14))
                .toDate(),
            Date.today().toDateTime().add(const Duration(days: 14)).toDate(),
          ),
    );
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

  void _loadPinnedActivities() {
    final stream = state.activity == null && state.event == null
        ? Activity.watch(
            priorityId: state.context.id,
            path: state.activity?.path ?? state.event?.path,
            pinned: true,
            deleted: state.showArchived,
          )
        : Rx.combineLatest2(
            Activity.watch(
              priorityId: state.context.id,
              path: state.activity?.path ?? state.event?.path,
              pinned: true,
              deleted: state.showArchived,
            ),
            Activity.watch(
              priorityId: state.context.id,
              path: state.activity?.path ?? state.event?.path,
              active: true,
              deleted: state.showArchived,
            ),
            (pinnedActivities, activeActivities) {
              final combined = {
                ...pinnedActivities,
                ...activeActivities,
              }.toList();
              combined.sort((a, b) => a.order.compareTo(b.order));
              return combined;
            },
          );

    _subscriptions.add(
      stream.listen((activities) {
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
        if (overlappingDate >= range.end) {
          log.info('Extending $range to include $overlappingDate');
          // If the new range ends before the old range, extend it to overlap by one day
          range = DateRangeCustom(range.start, overlappingDate.addDays(1));
        } else {
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
            log.info('Extending $range to include $overlappingDate');
            // If the new range starts after the old range, extend it to overlap by one day
            range = DateRangeCustom(overlappingDate, range.end);
          }
        }
      }
    }
    log.info(
      'Range: ${range.start} to ${range.end}, overlappingIndex: $overlappingIndex, overlappingDate: $overlappingDate',
    );

    // PriorityPage
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
            } else if (agenda.anchorIndex != null) {
              first = -agenda.anchorIndex!;
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
              'Agenda updated (${range.start} to ${range.end}, first=$first, count=${agenda.items.length}, totalRange=$totalRange, doneStart=$doneStart, doneEnd=$doneEnd), anchorIndex=${agenda.anchorIndex}',
            );
            emit(
              state.copyWith(
                range: range,
                agendaItems: agenda.items,
                first: first,
                moreAgendaItems: true,
                doneStart: doneStart,
                doneEnd: doneEnd,
              ),
            );
          });
    } else {
      // ActivityPage
      _agendaSubscription =
          Activity.watch(
            // range: range,
            priorityPath: state.context.path,
            path: state.activity?.path ?? state.event?.path,
            deleted: state.showArchived,
          ).listen((activities) {
            emit(
              state.copyWith(
                agendaItems: activities
                    .map((activity) => ActivityAgendaItem(activity))
                    .toList(),
                first: 0,
                moreAgendaItems: false,
                doneStart: true,
                doneEnd: true,
              ),
            );
          });
    }
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _agendaSubscription;
}
