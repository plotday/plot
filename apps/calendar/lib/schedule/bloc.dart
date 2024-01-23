import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'scheduled_event.dart';
import '../util/time.dart';
import '../priority/activity.dart';

part 'event.dart';
part 'state.dart';

class ScheduleBloc extends Bloc<ScheduleEvent, ScheduleState> {
  ScheduleBloc(
      {this.horizon = TimeHorizon.day,
      this.initialActivity,
      DateTime? initialAnchor})
      : initialAnchor = initialAnchor ?? Time.today().start,
        super(const ScheduleState()) {
    on<ScheduleFetch>(_onFetch);
    add(ScheduleFetch(this.initialAnchor, TimeDirection.ascending));
    add(ScheduleFetch(this.initialAnchor, TimeDirection.descending));
  }

  final TimeHorizon horizon;
  final DateTime initialAnchor;
  final Activity? initialActivity;

  Future<void> _onFetch(
      ScheduleFetch event, Emitter<ScheduleState> emit) async {
    final groupedEvents = await ScheduledEvent.list(event.anchor,
        direction: event.direction,
        horizon: horizon,
        activity: initialActivity);
    if (event.direction == TimeDirection.descending) {
      emit(ScheduleState(lists: {
        TimeDirection.descending: EventList(
            {}
              ..addAll(state.lists[TimeDirection.descending]!.events)
              ..addAll(groupedEvents.events),
            groupedEvents.nextAnchor),
        TimeDirection.ascending: state.lists[TimeDirection.ascending]!
      }));
    } else {
      emit(ScheduleState(lists: {
        TimeDirection.descending: state.lists[TimeDirection.descending]!,
        TimeDirection.ascending: EventList(
            {}
              ..addAll(state.lists[TimeDirection.ascending]!.events)
              ..addAll(groupedEvents.events),
            groupedEvents.nextAnchor),
      }));
    }
  }
}
