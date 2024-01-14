import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'activity.dart';
import 'budget.dart';
import '../util/time.dart';

part 'event.dart';
part 'state.dart';

class PrioritiesBloc extends Bloc<PriorityEvent, PrioritiesState> {
  PrioritiesBloc() : super(PrioritiesLoading(Time.week(DateTime.now()))) {
    on<PrioritiesWeekChanged>(_onWeekChanged);
    on<PriorityChanged>(_onPriorityChanged);
    on<PriorityAdded>(_onPriorityAdded);
    add(PrioritiesWeekChanged(Time.week(DateTime.now())));
  }

  void _onWeekChanged(
      PrioritiesWeekChanged event, Emitter<PrioritiesState> emit) async {
    emit(PrioritiesLoading(event.week));
    final budgets = await Budget.list(event.week);
    emit(PrioritiesLoaded(event.week, budgets));
  }

  void _onPriorityChanged(
      PriorityChanged event, Emitter<PrioritiesState> emit) async {
    await event.budget.save();
    final newList = await Budget.list(state.week);
    emit(PrioritiesLoaded(state.week, newList));
  }

  void _onPriorityAdded(
      PriorityAdded event, Emitter<PrioritiesState> emit) async {
    await Activity.add(event.name, event.parent);
    final newList = await Budget.list(state.week);
    emit(PrioritiesLoaded(state.week, newList));
  }
}
