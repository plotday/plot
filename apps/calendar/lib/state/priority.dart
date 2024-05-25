import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/util/time.dart';
import 'package:plot/model/context.dart';
import 'package:plot/model/priority.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc() : super(PriorityLoading(Week.current())) {
    setWeek(Week.current());
  }

  void setWeek(Week week) async {
    emit(PriorityLoading(week));
    final budgets = await Priority.list(week);
    emit(PriorityLoaded(week, budgets));
  }

  void updatePriority(Priority priority) async {
    await priority.save();
    final newList = await Priority.list(state.week);
    emit(PriorityLoaded(state.week, newList));
  }

  void addContext(Context context) async {
    await context.save();
    final newList = await Priority.list(state.week);
    emit(PriorityLoaded(state.week, newList));
  }
}
