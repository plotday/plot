import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc()
      : super(PriorityState(
          week: Week.current(),
        )) {
    _loadBalances();
    _loadActivites();
    _prioritySubscription = Priority.watchRoot().listen((activities) {
      emit(state.copyWith(
        priorities: activities,
      ));
    });
  }

  void dispose() {
    _prioritySubscription.cancel();
    _balanceSubscription?.cancel();
    _noteSubscription?.cancel();
    _activitiesSubscription?.cancel();
  }

  void setCurrent(Priority? current) {
    if (current?.id == state.current?.id) {
      return;
    }

    emit(state.copyWith(
      current: Value(current),
      activity: const Value(null),
      activityNotes: [],
    ));
    _loadActivites();
  }

  void setCurrentId(PriorityId? id) async {
    if (id == state.current?.id) return;
    if (id == null) {
      setCurrent(null);
    } else {
      final activity = state.priorities[id];
      setCurrent(activity);
    }
  }

  void setActivityId(ActivityId? activityId) {
    if (activityId == state.activity.id) return;
    if (activityId == null) {
      setActivity(null);
    } else {
      Activity.get(activityId).then(setActivity);
    }
  }

  /// Change the current activity.
  ///
  /// If [activity] is null, the current draft activity (or a new one) is set.
  void setActivity(Activity? activity) {
    activity ??= state.draftActivity;
    if (activity.id == state.activity.id) {
      return;
    }
    emit(state.copyWith(activity: Value(activity), activityNotes: []));
    _loadActivityNotes();
  }

  Future<void> save(Priority activity) async {
    await activity.save();
  }

  void setWeek(Week week) async {
    if (state.week == week) return;
    emit(state.copyWith(week: week, balances: const Value(null)));
    _loadBalances();
  }

  void _loadBalances() async {
    _balanceSubscription?.cancel();
    _balanceSubscription = Balance.watch(state.week).listen(
      (balances) {
        emit(state.copyWith(balances: Value(balances)));
      },
    );
  }

  void _loadActivites() {
    _activitiesSubscription?.cancel();
    _activitiesSubscription =
        Activity.watchPriority(state.current).listen((activities) {
      emit(state.copyWith(
        activities: activities,
        moreActivities: Activity.hasMorePriority(state.current?.path),
      ));
    });
    _loadActivityNotes();
  }

  void _loadActivityNotes() {
    _noteSubscription?.cancel();
    final activityId = state.activity.id;
    if (activityId != null) {
      _noteSubscription = Note.watchActivity(activityId).listen((notes) {
        emit(state.copyWith(
          activityNotes: notes,
          moreActivityNotes: Note.hasMoreActivity(activityId),
        ));
      });
    }
  }

  Future<void> updateActivity(Activity activity) async {
    try {
      // TODO debounce save
      activity.save();
    } catch (e) {
      print(e);
      rethrow;
    }
  }

  Future<void> updateNote(Note note) async {
    final activityUpdate = !note.draft && note.activityId == state.activity.id
        ? state.activity.copyWith(order: Order.first())
        : null;
    try {
      // TODO debounce save
      await Future.wait([
        note.save(),
        if (activityUpdate != null) activityUpdate.save(),
      ]);
    } catch (e) {
      print(e);
      rethrow;
    }
  }

  late final StreamSubscription<dynamic> _prioritySubscription;
  StreamSubscription<BalanceByPriorityType>? _balanceSubscription;
  StreamSubscription<List<Note>>? _noteSubscription;
  StreamSubscription<List<Activity>>? _activitiesSubscription;
}
