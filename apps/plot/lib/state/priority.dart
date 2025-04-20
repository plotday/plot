import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority})
    : super(PriorityState(current: priority)) {
    _loadPriority(priority);
  }

  void _reset() {
    _prioritySubscription?.cancel();
    _prioritySubscription = null;
    _activitiesSubscription?.cancel();
    _activitiesSubscription = null;
    _childActivitiesSubscription?.cancel();
    _childActivitiesSubscription = null;
    _balanceSubscription?.cancel();
    _balanceSubscription = null;
  }

  @override
  Future<void> close() {
    _reset();
    return super.close();
  }

  PriorityId get currentId => state.current.id;

  void _loadPriority(Priority priority) {
    _reset();

    _prioritySubscription = Priority.watchOne(priority.id, depth: 1).listen((
      priority,
    ) {
      emit(state.copyWith(current: priority));
    });

    _loadActivities();
    _loadBalances();
  }

  void _loadBalances() async {
    _balanceSubscription?.cancel();
    _balanceSubscription = Balance.watch(Week.current()).listen((balances) {
      emit(state.copyWith(balances: Value(balances)));
    });
  }

  Future<void> save(Priority priority) async {
    await priority.save();
  }

  Future<void> add(Activity activity) async {
    activity = activity.copyWith(draft: false);
    await activity.save();
  }

  /// Load activities for the current priority
  void _loadActivities() {
    _activitiesSubscription?.cancel();
    _activitiesSubscription = Activity.watchPriority(state.current.id).listen((
      activities,
    ) {
      emit(
        state.copyWith(
          activities: activities,
          moreActivities: Activity.hasMorePriority(state.current.path),
        ),
      );
    });

    _childActivitiesSubscription?.cancel();
    _childActivitiesSubscription = Activity.watchActivePriorityChildren(
      state.current.path,
    ).listen((childActivities) {
      emit(state.copyWith(childActivities: childActivities));
    });
  }

  StreamSubscription<Priority>? _prioritySubscription;
  StreamSubscription<List<Activity>>? _activitiesSubscription;
  StreamSubscription<Map<PriorityId, List<Activity>>>?
  _childActivitiesSubscription;
  StreamSubscription<BalanceByPriorityType>? _balanceSubscription;
}
