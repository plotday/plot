import 'dart:async';
import 'dart:math';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/store/store.dart';

part 'priorities_state.dart';

class PrioritiesBloc extends Cubit<PrioritiesState> {
  PrioritiesBloc()
      : super(PrioritiesState(
          week: Week.current(),
        )) {
    _loadBalances();
    _prioritySubscription = Priority.watchRoot().listen((priorities) {
      emit(state.copyWith(
        priorities: priorities,
      ));
      if (state.balances == null && state.defaultPriority != null) {
        _loadBalances();
      }
    });
  }

  void dispose() {
    _prioritySubscription.cancel();
    _balanceSubscription?.cancel();
  }

  Future<void> save(Priority priority) async {
    await priority.save();
  }

  void setWeek(Week week) async {
    if (state.week == week) return;
    emit(state.copyWith(week: week, balances: const Value(null)));
    _loadBalances();
  }

  void _loadBalances() async {
    _balanceSubscription?.cancel();
    // We can't listen to balances without a default priority, since it is
    // needed for default event priority.
    if (state.defaultPriority == null) return;
    _balanceSubscription = Balance.watch(state.week).listen(
      (balances) {
        emit(state.copyWith(balances: Value(balances)));
      },
    );
  }

  late final StreamSubscription<dynamic> _prioritySubscription;
  StreamSubscription<BalanceByPriorityType>? _balanceSubscription;
}
