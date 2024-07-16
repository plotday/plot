import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/schedule.dart';
import 'package:plot/util/time.dart';

export 'package:plot/model/schedule.dart';

part 'schedule_state.dart';

// Need to listen to route state, change selected, set error
class ScheduleBloc extends Cubit<ScheduleState> {
  ScheduleBloc() : super(ScheduleState()) {
    _subscription = ScheduledDay.store.stream().listen((event) {
      emit(state.copyWith());
    });
  }

  void select(ScheduledEvent event) {
    emit(state.copyWith(selected: event));
  }

  Future<ScheduledEvent> selectById(int eventId) async {
    emit(SelectedEventLoadingState.copy(state));
    final event = await ScheduledEvent.getOrFetch(eventId);
    select(event);
    return event;
  }

  Future<ScheduledEvent?> selectCurrent() async {
    emit(SelectedEventLoadingState.copy(state));
    await ScheduledDay.getOrFetchToday();
    final current = ScheduledEvent.current();
    if (current.isEmpty) {
      emit(ScheduleState.copy(state));
      return null;
    } else {
      select(current.first);
      return current.first;
    }
  }

  Future<ScheduledEvent> update(ScheduledEvent event) async {
    return await event.save();
  }

  ScheduledEvent? get selected {
    if (state is SelectedEventState) {
      return (state as SelectedEventState).selected;
    }
    return null;
  }

  @override
  Future<void> close() async {
    _subscription?.cancel();
    await super.close();
  }

  StreamSubscription<void>? _subscription;
}
