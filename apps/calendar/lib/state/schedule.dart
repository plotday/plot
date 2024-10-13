import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/optional.dart';

part 'schedule_state.dart';

class ScheduleBloc extends Cubit<ScheduleState> {
  ScheduleBloc() : super(SelectedEventLoadingState()) {
    selectCurrent();
  }

  void select(Event event) {
    emit(state.copyWith(
        selected: Optional.of(event), day: event.start.toDate()));
    // TODO watch for event changes
    // _watchEvent(event.id);
  }

  Future<Event> selectById(EventId id) {
    emit(SelectedEventLoadingState.copy(state));
    return _watchEvent(id);
  }

  Future<Event> _watchEvent(EventId id) {
    _eventSubscription?.cancel();
    final stream = Event.watchOne(id).asBroadcastStream();
    _eventSubscription = stream.listen((event) {
      emit(state.copyWith(
          selected: Optional.of(event), day: event.start.toDate()));
    });
    return stream.first;
  }

  Future<Event?> selectCurrent() async {
    final now = DateTime.now();
    final today = now.toDate();

    var schedule = state.schedule;
    if (!state.range.includes(today)) {
      emit(SelectedEventLoadingState.copy(state.copyWith(day: now.toDate())));
      schedule = await watch(Day.today());
    }

    final current = schedule[today]?.getAt(now);
    if (current != null) {
      select(current);
    }
    return current;
  }

  void setDay(Date day) {
    emit(state.copyWith(day: day));
  }

  Future<Map<Date, ScheduledDay>> watch(DateRange range) {
    _subscription?.cancel();

    final stream = ScheduledDay.watch(range).asBroadcastStream();
    _subscription = stream.listen((schedule) {
      emit(state.copyWith(schedule: schedule));
    });
    return stream.first;
  }

  void update(Event event) async {
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
    _eventSubscription?.cancel();
    await super.close();
  }

  StreamSubscription<void>? _eventSubscription;
  StreamSubscription<void>? _subscription;
}
