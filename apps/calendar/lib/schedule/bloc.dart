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
      : super(const ScheduleState()) {
    on<ScheduleFetch>(_onFetch);
  }

  final TimeHorizon horizon;
  final Activity? initialActivity;

  Future<void> _onFetch(
      ScheduleFetch event, Emitter<ScheduleState> emit) async {
    print("FETCH: ${event.anchor} ${event.direction}");
    final events = await ScheduledEvent.list(event.anchor,
        direction: event.direction,
        horizon: horizon,
        activity: initialActivity);
    print("  GOT: ${events.length}");
    if (event.direction == TimeDirection.descending) {
      emit(ScheduleState(lists: {
        TimeDirection.descending: EventList(
            {}
              ..addAll(state.lists[TimeDirection.descending]!.events)
              ..addAll({event.anchor: events}),
            event.anchor - horizon.duration),
        TimeDirection.ascending: state.lists[TimeDirection.ascending]!
      }));
    } else {
      emit(ScheduleState(lists: {
        TimeDirection.descending: state.lists[TimeDirection.descending]!,
        TimeDirection.ascending: EventList(
            {}
              ..addAll(state.lists[TimeDirection.ascending]!.events)
              ..addAll({event.anchor: events}),
            event.anchor + horizon.duration),
      }));
    }
  }
}
