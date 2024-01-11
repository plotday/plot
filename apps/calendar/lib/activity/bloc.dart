import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import '../util/date_time.dart';
import 'activity.dart';
import 'time_block.dart';

part 'event.dart';
part 'state.dart';

class ActivityBloc extends Bloc<ActivityEvent, ActivityState> {
  ActivityBloc()
      : super(ActivityIdle(
            TimeBlock.current?.activity ?? Activity.list().first)) {
    on<_ActivityInit>(_onInit);
    on<ActivitySelected>(_onSelected);
    on<ActivityStarted>(_onStarted);
    on<ActivityStopped>(_onStopped);
    on<ActivityResumed>(_onResumed);
    add(const _ActivityInit());
  }

  void _onInit(_ActivityInit event, Emitter<ActivityState> emit) {
    final current = TimeBlock.current;
    if (current == null) return;
    emit(ActivityActive(current, selected: state.selected));
  }

  void _onSelected(ActivitySelected event, Emitter<ActivityState> emit) {
    emit(state.copyWith(selected: event.activity));
  }

  void _onStarted(ActivityStarted event, Emitter<ActivityState> emit) async {
    final block = await TimeBlock.add(event.activity,
        duration: event.duration, end: event.end);
    emit(ActivityActive(
      block,
      selected: state.selected,
    ));
  }

  void _onStopped(ActivityStopped event, Emitter<ActivityState> emit) async {
    switch (state) {
      case ActivityActive s:
        final block = await s.active.update(
            at: Interval(s.active.at.start, DateTime.now()),
            remaining: s.active.at.end.difference(DateTime.now()).inSeconds,
            status: TimeBlockStatus.stopped);
        emit(ActivityActive(
          block,
          selected: state.selected,
        ));
        break;
      default:
        break;
    }
  }

  void _onResumed(ActivityResumed event, Emitter<ActivityState> emit) async {
    switch (state) {
      case ActivityActive s:
        final block = await TimeBlock.add(s.active.activity,
            duration: event.duration ?? s.active.remaining, end: event.end);
        emit(ActivityActive(
          block,
          selected: state.selected,
        ));
        break;
      default:
        break;
    }
  }
}
