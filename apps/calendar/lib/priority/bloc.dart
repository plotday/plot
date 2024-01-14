import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'budget.dart';
import 'activity.dart';
import '../util/time.dart';

part 'event.dart';
part 'state.dart';

class PrioritiesBloc extends Bloc<PriorityEvent, PrioritiesState> {
  PrioritiesBloc() : super(PrioritiesLoading(Time.week(DateTime.now()))) {
    on<PrioritiesWeekChanged>(_onWeekChanged);
    add(PrioritiesWeekChanged(Time.week(DateTime.now())));
  }

  void _onWeekChanged(
      PrioritiesWeekChanged event, Emitter<PrioritiesState> emit) async {
    emit(PrioritiesLoading(event.week));
    final budgets = await Budget.list(event.week);
    emit(PrioritiesLoaded(event.week, budgets));
  }
}
