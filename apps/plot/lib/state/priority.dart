import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority, this.activityId})
    : _subscriptions = [],
      super(PriorityState(context: priority)) {
    _loadPriority(priority);
  }

  final ActivityId? activityId;

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
      Activity.watch(
        priorityId: priority.id,
        pinned: true,
      ).listen((activities) {
        emit(
          state.copyWith(
            pinned: activities.map((a) => ActivityAgendaItem(a)).toList(),
          ),
        );
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
            activity.addAll(
              scheduledDay.activities.map((a) => ActivityAgendaItem(a)),
            );
            activity.addAll(scheduledDay.events.map((e) => EventAgendaItem(e)));
          } else if (scheduledDay.date == today) {
            for (final activityItem in scheduledDay.activities) {
              if (activityItem.doNow) {
                scheduled.add(ActivityAgendaItem(activityItem));
              } else {
                activity.add(ActivityAgendaItem(activityItem));
              }
            }
            // Add events for today
            scheduled.addAll(
              scheduledDay.events.map((e) => EventAgendaItem(e)),
            );
          } else {
            scheduled.addAll(
              scheduledDay.activities.map((a) => ActivityAgendaItem(a)),
            );
            scheduled.addAll(
              scheduledDay.events.map((e) => EventAgendaItem(e)),
            );
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

  Future<void> save(Activity activity) async {
    await activity.save();
  }

  Future<void> add(Activity activity) async {
    activity = activity.copyWith(draft: false);
    await activity.save();
    // Create a new draft
    emit(state.copyWith(draft: Activity(priorityId: state.context.id, draft: true)));
  }

  List<StreamSubscription<void>> _subscriptions;
}
