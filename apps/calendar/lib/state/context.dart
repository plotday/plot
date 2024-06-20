import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/context.dart';
import 'package:plot/model/budget.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/list.dart';

part 'context_state.dart';

class ContextBloc extends Cubit<ContextState> {
  ContextBloc() : super(BudgetsLoadingState(contexts: Context.store.list())) {
    _subscription = Context.store.stream().listen((contexts) {
      emit(state.copyWith(contexts: contexts));
    });
  }

  void dispose() {
    _subscription.cancel();
  }

  void setCurrent(Context? current) {
    emit(state.copyWith(current: current));
  }

  void add(Context context) async {
    emit(state.copyWith(contexts: state.all + [context]));
    await context.save();
  }

  void update(Context context) async {
    emit(
      state.copyWith(
        contexts: state.all.replace(context, (c1, c2) => c1.id == c2.id),
      ),
    );
    await context.save();
  }

  void setWeek(Week week) async {
    emit(state.copyWith(week: week, budgets: null));
    final budgets = await Budget.list(week);
    emit(state.copyWith(budgets: budgets));
  }

  void setBudget(Budget budget) async {
    switch (state) {
      case BudgetsLoadedState loadedState when loadedState.week == budget.week:
        emit(
          loadedState.copyWith(
            budget: budget,
          ),
        );
      default:
    }
    await budget.save();
  }

  late StreamSubscription<List<Context>> _subscription;
}
