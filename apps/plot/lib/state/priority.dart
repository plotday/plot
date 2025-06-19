import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/agenda_item.dart';
import 'logging.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority, Activity? activity})
    : _subscriptions = [],
      _agendaSubscription = null,
      super(PriorityState(context: priority, activity: activity)) {
    _loadPriority(priority);
    if (activity != null) {
      _loadActivity(activity);
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

      // Watch pinned activities
      _subscriptions.add(
        Activity.watch(priorityId: priority.id, pinned: true).listen((
          activities,
        ) {
          log.info('Pinned activities updated');
          emit(
            state.copyWith(
              pinned: activities.map((a) => ActivityAgendaItem(a)).toList(),
            ),
          );
        }),
      );
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
        draft: Activity(priorityId: state.context.id, draft: true),
      ),
    );
  }

  void _loadAgendaItems(DateRange range) {
    log.info('Loading agenda items (${range.start} to ${range.end})');

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
      if (range.end.isBefore(overlappingDate)) {
        // If the new range ends before the old range, extend it to overlap by one day
        range = DateRangeCustom(range.start, overlappingDate);
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
        if (range.start.isAfter(overlappingDate)) {
          // If the new range starts after the old range, extend it to overlap by one day
          range = DateRangeCustom(overlappingDate, range.end);
        }
      }
    }

    _agendaSubscription?.cancel();
    _agendaSubscription =
        Rx.combineLatest2(
          ScheduledDay.watch(range, context: state.context),
          Priority.watch(order: PriorityOrder.sorted),
          (scheduleMap, priorities) => (scheduleMap, priorities),
        ).listen((data) {
          final (scheduleMap, priorities) = data;
          final priorityMap = Priority.asMap(priorities);
          final today = Date.today();

          final agenda = Agenda.fromScheduledDays(
            scheduleMap.values.toList(),
            today: today,
            priorities: priorityMap,
          );

          final newAgendaItems = agenda.items.reversed.toList();

          // Calculate the new first index based on header overlap
          int? first;
          if (state.range != null && overlappingIndex != -1) {
            first =
                newAgendaItems.indexWhere(
                  (item) => item.when(
                    activity: (_) => false,
                    event: (_) => false,
                    header: (header) => header.date == overlappingDate,
                  ),
                ) -
                overlappingIndex;
          }

          log.info(
            'Agenda updated (${range.start} to ${range.end}, first=$first, count=${newAgendaItems.length})',
          );
          emit(
            state.copyWith(
              range: range,
              agendaItems: newAgendaItems,
              first: first,
              anchorIndex: agenda.items.length - agenda.anchorIndex - 1,
              moreAgendaItems: true,
              doneStart: false,
              doneEnd: false,
            ),
          );
        });
  }

  void fetchMoreAgendaItems(int first, int count) {
    if (state.range == null) return;
    log.info('Fetching more agenda items: first=$first, count=$count');
    final itemsPerDay = state.range!.duration.inDays / state.agendaItems.length;
    // Calculate how many days to move backwards from current first
    final move = state.first - first;
    final newStart = state.range!.start.subDays((move / itemsPerDay).ceil());
    final newRange = DateRangeCustom(
      newStart,
      newStart.addDays((count / itemsPerDay).ceil()),
    );
    _loadAgendaItems(newRange);
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _agendaSubscription;
}
