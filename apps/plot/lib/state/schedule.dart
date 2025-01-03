import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'schedule_state.dart';

class ScheduleBloc extends Cubit<ScheduleState> {
  ScheduleBloc() : super(ScheduleState()) {
    selectCurrent();
  }

  void select(Event event) {
    if (state.selected?.id == event.id) {
      return;
    }
    emit(state.copyWith(selected: Value(event), day: event.start.toDate()));
    if (event.unsaved) return;
    _watchEvent(event.id);
  }

  Future<Event> selectById(EventId id) {
    if (state.selected?.id == id) {
      return Future.value(state.selected!);
    }
    emit(state.copyWith(selected: const Value(null)));
    return _watchEvent(id);
  }

  Future<Event> _watchEvent(EventId id) {
    _eventSubscription?.cancel();
    final stream = Event.watchOne(id).asBroadcastStream();
    _eventSubscription = stream.listen((event) {
      emit(state.copyWith(selected: Value(event), day: event.start.toDate()));
    });
    return stream.first;
  }

  Future<Event?> selectCurrent() async {
    final now = DateTime.now();
    final today = now.toDate();

    var schedule = state.schedule;
    if (!state.range.includes(today)) {
      emit(ScheduleState.copy(state.copyWith(day: now.toDate())));
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

  Future<void> update(Event event) async {
    if (event.isBlank && event.unsaved) {
      emit(state.copyWith(selected: Value(event)));
    } else {
      await event.save();
      if (event.unsaved && event.id == state.selected?.id) {
        await _watchEvent(event.id);
      }
    }
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
