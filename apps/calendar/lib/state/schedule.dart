import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/optional.dart';

part 'schedule_state.dart';

// Need to listen to route state, change selected, set error
class ScheduleBloc extends Cubit<ScheduleState> {
  ScheduleBloc() : super(SelectedEventLoadingState()) {
    _subscription = ScheduledDay.store.stream().listen((event) {
      emit(state.copyWith());
    });
    selectCurrent();
  }

  void select(Event event) {
    emit(state.copyWith(selected: Optional.of(event)));
  }

  Future<Event> selectById(EventID eventId) async {
    emit(SelectedEventLoadingState.copy(state));
    final event = await Event.getOrFetch(eventId);
    select(event);
    return event;
  }

  Future<Event> selectCurrent() async {
    emit(SelectedEventLoadingState.copy(state));
    await ScheduledDay.getOrFetchToday();
    final current = Event.current();
    assert(current.isNotEmpty);
    select(current.first);
    return current.first;
  }

  Future<Event> update(Event event) async {
    return await event.save();
  }

  Event? get selected {
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
