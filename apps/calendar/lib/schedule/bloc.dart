import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'scheduled_event.dart';
import '../util/time.dart';
import '../priority/activity.dart';

part 'event.dart';
part 'state.dart';

class ScheduleBloc extends Bloc<ScheduleEvent, ScheduleState> {
  ScheduleBloc({this.horizon = TimeHorizon.day, this.initialActivity})
      : super(ScheduleState()) {
    on<ScheduleFetch>(_onFetch);
    on<ScheduleUpdated>(_onUpdated);
  }

  final TimeHorizon horizon;
  final Activity? initialActivity;

  Future<void> _onFetch(
      ScheduleFetch event, Emitter<ScheduleState> emit) async {
    final events = await ScheduledEvent.list(event.anchor,
        direction: event.direction,
        horizon: horizon,
        activity: initialActivity);
    if (event.direction == TimeDirection.descending) {
      emit(ScheduleState(lists: {
        TimeDirection.descending: EventList(
            {}
              ..addAll(state.lists[TimeDirection.descending]!.events)
              ..addAll(events),
            horizon.sub(events.keys.last)),
        TimeDirection.ascending: state.lists[TimeDirection.ascending]!
      }));
    } else {
      emit(ScheduleState(lists: {
        TimeDirection.descending: state.lists[TimeDirection.descending]!,
        TimeDirection.ascending: EventList(
            {}
              ..addAll(state.lists[TimeDirection.ascending]!.events)
              ..addAll(events),
            horizon.add(events.keys.last)),
      }));
    }
  }

  Future<void> _onUpdated(
      ScheduleUpdated event, Emitter<ScheduleState> emit) async {
    emit(state.copyWith(event.event));
    emit(state.copyWith(await event.event.save()));
  }
}
