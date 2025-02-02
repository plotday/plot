import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

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
    _balanceSubscription = Balance.watch(state.week).listen(
      (balances) {
        emit(state.copyWith(balances: Value(balances)));
      },
    );
  }

  late final StreamSubscription<dynamic> _prioritySubscription;
  StreamSubscription<BalanceByPriorityType>? _balanceSubscription;
}
