import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/list.dart';
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

    // Reload agenda items with new archived filter
    _loadPriority();
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    emit(state.copyWith(filter: filter));

    // Reload agenda items with new filter
    _loadPriority();
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
        final date = item.iff(date: (date) => date);
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
        final date = item.iff(date: (date) => date);
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
    _loadSchedule(newRange);
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
    if (state.activity != null) {
      _loadActivity(state.activity!);
    }
    if (state.event != null) {
      _loadEvent(state.event!);
    }

    _loadSchedule(
      state.range ??
          DateRangeCustom(
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
    emit(
      state.copyWith(
        // Create a new draft
        draft: Activity(
          priority: state.context,
          parent: state.activity,
          parentEvent: state.event,
          draft: true,
        ),
      ),
    );
    activity = activity.copyWith(draft: false);
    await activity.save();
  }

  void _loadSchedule(DateRange range, {Date? firstDate}) {
    log.info('Loading schedule (${range.start} to ${range.end})');
    _agendaSubscription?.cancel();

    // Ensure the new range overlaps with the previous one by at least one day
    // Find the first and last DateAgendaItem in the current agenda items
    var overlappingIndex =
        state.range == null || range.start == state.range!.start
        ? -1
        : state.agendaItems.indexWhere(
            (item) => item.iff(date: (date) => true) == true,
          );
    Date? overlappingDate;
    if (overlappingIndex != -1) {
      overlappingDate = state.agendaItems[overlappingIndex].iff(
        date: (date) => date,
      );
      if (overlappingDate != null && !range.includes(overlappingDate)) {
        if (overlappingDate >= range.end) {
          log.info('Extending $range to include $overlappingDate');
          // If the new range ends before the old range, extend it to overlap by one day
          range = DateRangeCustom(range.start, overlappingDate.addDays(1));
        } else {
          overlappingIndex = state.agendaItems.lastIndexWhere(
            (item) => item.iff(date: (date) => true) == true,
          );
          overlappingDate = state.agendaItems[overlappingIndex].iff(
            date: (date) => date,
          );
          if (overlappingDate != null && !range.includes(overlappingDate)) {
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

    log.info(
      'Getting activities for priprity ${state.context.id} in range $range',
    );
    _agendaSubscription =
        Rx.combineLatest2(
          ScheduledDay.watch(
            range,
            context: state.context,
            deleted: state.showArchived,
            filter: state.filter.isNotEmpty ? state.filter : null,
          ),
          ScheduledDay.watchRange(
            context: state.context,
            deleted: state.showArchived,
          ),
          (scheduleMap, totalRange) => (scheduleMap, totalRange),
        ).listen((data) {
          final (scheduleMap, totalRange) = data;

          // Calculate the new first index based on date overlap
          int first = state.first;
          if (overlappingIndex != -1) {
            final newScheduleItems = PriorityState._makeAgenda(
              scheduleMap,
              context: state.context,
            );
            final newIndex = newScheduleItems.indexWhere(
              (item) => item.when(
                date: (date) => date == overlappingDate,
                event: (event) => false,
                priority: (priority) => false,
                activity: (activity) => false,
              ),
            );
            log.info(
              'First was $first, overlappingIndex is $overlappingIndex, newIndex is $newIndex newFirst = ${first + overlappingIndex - newIndex}',
            );
            if (newIndex != -1) {
              first += overlappingIndex - newIndex;
            }
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
            'Schedule updated (${range.start} to ${range.end}, first=$first, count=${scheduleMap.length}, totalRange=$totalRange, doneStart=$doneStart, doneEnd=$doneEnd)',
          );
          emit(
            state.copyWith(
              range: range,
              schedule: scheduleMap,
              first: first,
              firstDate: firstDate,
              doneStart: doneStart,
              doneEnd: doneEnd,
            ),
          );
        });
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _agendaSubscription;
}
