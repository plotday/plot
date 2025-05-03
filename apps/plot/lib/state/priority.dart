import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority})
    : _subscriptions = [],
      super(PriorityState(current: priority)) {
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

  PriorityId get currentId => state.current.id;

  void _loadPriority(Priority priority) {
    _reset();

    _subscriptions.add(
      Priority.watchOne(priority.id).listen((priority) {
        emit(state.copyWith(current: priority));
      }),
    );
    _subscriptions.add(
      Priority.watch(
        path: priority.path,
        self: false,
        depth: 1,
        pinned: true,
      ).listen((priorities) {
        emit(state.copyWith(pinned: priorities));
      }),
    );
    _subscriptions.add(
      Priority.watch(path: priority.path, self: false, active: true).listen((
        priorities,
      ) {
        emit(state.copyWith(active: priorities, moreActive: false));
      }),
    );
    _subscriptions.add(
      Priority.watch(
        path: priority.path,
        self: false,
        active: false,
        pinned: false,
      ).listen((priorities) {
        emit(state.copyWith(inactive: priorities, moreInactive: false));
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
    emit(state.copyWith(draft: Priority(parent: state.current, draft: true)));
  }

  List<StreamSubscription<void>> _subscriptions;
}
