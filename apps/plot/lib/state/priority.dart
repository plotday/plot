import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/agenda_item.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority, Activity? activity})
    : _subscriptions = [],
      super(PriorityState(context: priority, activity: activity)) {
    _loadPriority(priority);
    if (activity != null) {
      _loadActivity(activity);
    }
  }

  void _reset() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions = [];
  }

  @override
  Future<void> close() {
    _reset();
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  void _loadPriority(Priority priority) {
    _reset();

    // Watch the current priority (context)
    _subscriptions.add(
      Priority.watchOne(priority.id).listen((priority) {
        emit(state.copyWith(context: priority));
      }),
    );

    // Watch pinned activities
    _subscriptions.add(
      Activity.watch(priorityId: priority.id, pinned: true).listen((
        activities,
      ) {
        emit(
          state.copyWith(
            pinned: activities.map((a) => ActivityAgendaItem(a)).toList(),
          ),
        );
      }),
    );
    // Watch upcoming, scheduled priorities and past activity using ScheduledDay.watch
    final today = Date.today();
    final oneMonthAgo = today
        .toDateTime()
        .subtract(const Duration(days: 30))
        .toDate();
    final oneMonthFromNow = today
        .toDateTime()
        .add(const Duration(days: 30))
        .toDate();
    final range = DateRangeCustom(oneMonthAgo, oneMonthFromNow);

    _subscriptions.add(
      Rx.combineLatest2(
        ScheduledDay.watch(range, context: priority),
        Priority.watch(order: PriorityOrder.sorted),
        (scheduleMap, priorities) => (scheduleMap, priorities),
      ).listen((data) {
        final (scheduleMap, priorities) = data;
        final priorityMap = Priority.asMap(priorities);

        final agenda = Agenda.fromScheduledDays(
          scheduleMap.values.toList(),
          today: today,
          priorities: priorityMap,
        );

        emit(
          state.copyWith(
            agendaItems: agenda.items.reversed.toList(),
            anchorIndex: agenda.items.length - agenda.anchorIndex - 1,
            moreAgendaItems: false,
          ),
        );
      }),
    );
  }

  void _loadActivity(Activity activity) {
    // Watch the activity
    _subscriptions.add(
      Activity.watchOne(activity.id).listen((watchedActivity) {
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
    emit(
      state.copyWith(
        draft: Activity(priorityId: state.context.id, draft: true),
      ),
    );
  }

  List<StreamSubscription<void>> _subscriptions;
}
