import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'context.dart';
import 'activity.dart';
import 'priority.dart';
import '../util/time.dart';

part 'event.dart';
part 'state.dart';

class PrioritiesBloc extends Bloc<PriorityEvent, PrioritiesState> {
  PrioritiesBloc()
      : super(PrioritiesLoading(DateTimeRange.week(DateTime.now()))) {
    on<PrioritiesWeekChanged>(_onWeekChanged);
    on<PriorityChanged>(_onPriorityChanged);
    on<ContextAdded>(_onContextyAdded);
    on<ActivityAdded>(_onActivityAdded);
    add(PrioritiesWeekChanged(DateTimeRange.week(DateTime.now())));
  }

  void _onWeekChanged(
      PrioritiesWeekChanged event, Emitter<PrioritiesState> emit) async {
    emit(PrioritiesLoading(event.week));
    final budgets = await Priority.list(event.week);
    emit(PrioritiesLoaded(event.week, budgets));
  }

  void _onPriorityChanged(
      PriorityChanged event, Emitter<PrioritiesState> emit) async {
    await event.priority.save();
    final newList = await Priority.list(state.week);
    emit(PrioritiesLoaded(state.week, newList));
  }

  void _onContextyAdded(
      ContextAdded event, Emitter<PrioritiesState> emit) async {
    await event.context.save();
    final newList = await Priority.list(state.week);
    emit(PrioritiesLoaded(state.week, newList));
  }

  void _onActivityAdded(
      ActivityAdded event, Emitter<PrioritiesState> emit) async {
    await event.activity.save();
    final newList = await Priority.list(state.week);
    emit(PrioritiesLoaded(state.week, newList));
  }
}
