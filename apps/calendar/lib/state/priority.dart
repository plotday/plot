import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/util/time.dart';
import 'package:plot/model/context.dart';
import 'package:plot/model/priority.dart';

part 'priority_event.dart';
part 'priority_state.dart';

class PriorityBloc extends Bloc<PriorityEvent, PriorityState> {
  PriorityBloc() : super(PriorityLoading(Week.current())) {
    on<PriorityWeekChanged>(_onWeekChanged);
    on<PriorityChanged>(_onPriorityChanged);
    on<ContextAdded>(_onContextyAdded);
  }

  void _onWeekChanged(
      PriorityWeekChanged event, Emitter<PriorityState> emit) async {
    emit(PriorityLoading(event.week));
    final budgets = await Priority.list(event.week);
    emit(PriorityLoaded(event.week, budgets));
  }

  void _onPriorityChanged(
      PriorityChanged event, Emitter<PriorityState> emit) async {
    await event.priority.save();
    final newList = await Priority.list(state.week);
    emit(PriorityLoaded(state.week, newList));
  }

  void _onContextyAdded(ContextAdded event, Emitter<PriorityState> emit) async {
    await event.context.save();
    final newList = await Priority.list(state.week);
    emit(PriorityLoaded(state.week, newList));
  }
}
