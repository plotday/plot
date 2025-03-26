import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({PriorityId? id}) : super(const NoPriorityState()) {
    if (id != null) {
      setCurrentId(id);
    }
  }

  void _reset() {
    _prioritySubscription?.cancel();
    _prioritySubscription = null;
    _activitiesSubscription?.cancel();
    _activitiesSubscription = null;
  }

  @override
  Future<void> close() {
    _reset();
    return super.close();
  }

  PrioritySelectedState get selectedState => state as PrioritySelectedState;

  PriorityId? get currentId {
    return switch (state) {
      PrioritySelectedState state => state.current.id,
      NoPriorityState _ => null,
    };
  }

  void setCurrent(Priority? current) {
    if (switch (state) {
      PrioritySelectedState state => state.current.id == current?.id,
      NoPriorityState _ => current == null,
    }) {
      return;
    }

    _reset();

    if (current == null) {
      emit(const NoPriorityState());
      return;
    }

    emit(PrioritySelectedState(
      current: current,
    ));
    _prioritySubscription = Priority.watchOne(
      current.id,
    ).listen((priority) {
      emit(selectedState.copyWith(current: priority));
    });
    _loadActivites();
  }

  Future<void> setCurrentId(PriorityId? id) async {
    if (switch (state) {
      PrioritySelectedState state => state.current.id == id,
      NoPriorityState _ => id == null,
    }) {
      return;
    }
    _reset();
    if (id == null) {
      setCurrent(null);
    } else {
      final priority = await Priority.get(id);
      setCurrent(priority);
    }
  }

  Future<void> save(Priority priority) async {
    await priority.save();
  }

  void _loadActivites() {
    _activitiesSubscription?.cancel();
    _activitiesSubscription =
        Activity.watchPriority(selectedState.current.id).listen((activities) {
      emit(selectedState.copyWith(
        activities: activities,
        moreActivities: Activity.hasMorePriority(selectedState.current.path),
      ));
    });
  }

  StreamSubscription<Priority>? _prioritySubscription;
  StreamSubscription<List<Activity>>? _activitiesSubscription;
}
