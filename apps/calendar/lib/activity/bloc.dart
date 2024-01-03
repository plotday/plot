import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'activity.dart';
import 'time_block.dart';

part 'event.dart';
part 'state.dart';

class ActivityBloc extends Bloc<ActivityEvent, ActivityState> {
  ActivityBloc() : super(const ActivityIdle()) {
    on<ActivitySelected>(_onSelected);
    on<ActivityStarted>(_onStarted);
    on<ActivityPaused>(_onPaused);
    on<ActivityResumed>(_onResumed);
    on<ActivityStopped>(_onStopped);
  }

  void _onSelected(ActivitySelected event, Emitter<ActivityState> emit) {
    emit(state.copyWith(selected: event.activity));
  }

  void _onStarted(ActivityStarted event, Emitter<ActivityState> emit) {
    emit(ActivityProgressActive(
      event.activity,
      const Duration(),
      start: event.start,
      end: event.end,
    ));
    TimeBlock.start(event.activity, event.start, event.end);
  }

  void _onPaused(ActivityPaused event, Emitter<ActivityState> emit) {
    switch (state) {
      case ActivityProgressActive s:
        emit(ActivityProgressPaused(
          s.active,
          s.elapsed,
          start: s.start,
          end: s.end,
        ));
        break;
      default:
        break;
    }
  }

  void _onResumed(ActivityResumed resume, Emitter<ActivityState> emit) {
    switch (state) {
      case ActivityProgressPaused s:
        emit(ActivityProgressActive(
          s.active,
          s.elapsed,
          start: s.start,
          end: s.end,
        ));
        break;
      default:
        break;
    }
  }

  void _onStopped(ActivityStopped event, Emitter<ActivityState> emit) {
    emit(const ActivityIdle());
  }
}
