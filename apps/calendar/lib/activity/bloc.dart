import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'activity.dart';

part 'event.dart';
part 'state.dart';

class ActivityBloc extends Bloc<ActivityEvent, ActivityState> {
  ActivityBloc() : super(const ActivityIdle()) {
    on<ActivityStarted>(_onStarted);
    on<ActivityPaused>(_onPaused);
    on<ActivityResumed>(_onResumed);
    on<ActivityStopped>(_onStopped);
  }

  void _onStarted(ActivityStarted event, Emitter<ActivityState> emit) {
    emit(ActivityProgressActive(
        event.activity, DateTime.now(), const Duration()));
  }

  void _onPaused(ActivityPaused event, Emitter<ActivityState> emit) {
    switch (state) {
      case ActivityProgressActive s:
        emit(ActivityProgressPaused(s.current, s.started, s.duration));
        break;
      default:
        break;
    }
  }

  void _onResumed(ActivityResumed resume, Emitter<ActivityState> emit) {
    switch (state) {
      case ActivityProgressPaused s:
        emit(ActivityProgressActive(s.current, s.started, s.duration));
        break;
      default:
        break;
    }
  }

  void _onStopped(ActivityStopped event, Emitter<ActivityState> emit) {
    emit(const ActivityIdle());
  }
}
