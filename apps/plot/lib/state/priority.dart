import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority})
    : _subscriptions = [],
      super(PriorityState(context: priority)) {
    _loadPriority(priority);
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
    // Watch pinned priorities
    _subscriptions.add(
      Priority.watch(
        path: priority.path,
        self: false,
        depth: 1,
        pinned: true,
      ).listen((priorities) {
        emit(state.copyWith(pinned: priorities.map((p) => PriorityAgendaItem(p)).toList()));
      }),
    );
    // Watch upcoming, scheduled priorities and past activity using ScheduledDay.watch
    final today = Date.today();
    final oneMonthAgo =
        today.toDateTime().subtract(const Duration(days: 30)).toDate();
    final oneMonthFromNow =
        today.toDateTime().add(const Duration(days: 30)).toDate();
    final range = DateRangeCustom(oneMonthAgo, oneMonthFromNow);

    _subscriptions.add(
      ScheduledDay.watch(range, context: priority).listen((scheduleMap) {
        final activity = <AgendaItem>[];
        final scheduled = <AgendaItem>[];
        for (final scheduledDay in scheduleMap.values) {
          if (scheduledDay.date < today) {
            activity.addAll(scheduledDay.priorities.map((p) => PriorityAgendaItem(p)));
          } else if (scheduledDay.date == today) {
            for (final priority in scheduledDay.priorities) {
              if (priority.doNow) {
                scheduled.add(PriorityAgendaItem(priority));
              } else {
                activity.add(PriorityAgendaItem(priority));
              }
            }
          } else {
            scheduled.addAll(scheduledDay.priorities.map((p) => PriorityAgendaItem(p)));
          }
        }
        emit(
          state.copyWith(
            activity: activity.reversed.toList(),
            moreActivity: false,
            scheduled: scheduled.reversed.toList(),
            moreScheduled: false,
          ),
        );
      }),
    );
  }

  Future<void> save(Priority priority) async {
    await priority.save();
  }

  Future<void> add(Priority priority) async {
    priority = priority.copyWith(draft: false);
    await priority.save();
    // Create a new draft
    emit(state.copyWith(draft: Priority(parent: state.context, draft: true)));
  }

  List<StreamSubscription<void>> _subscriptions;
}
