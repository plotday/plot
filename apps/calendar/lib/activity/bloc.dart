import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import '../util/date_time.dart';
import 'activity.dart';
import 'time_block.dart';

part 'event.dart';
part 'state.dart';

class ActivityBloc extends Bloc<ActivityEvent, ActivityState> {
  ActivityBloc() : super(const ActivityIdle()) {
    on<_ActivityInit>(_onInit);
    on<ActivitySelected>(_onSelected);
    on<ActivityStarted>(_onStarted);
    on<ActivityPaused>(_onPaused);
    on<ActivityResumed>(_onResumed);
    on<ActivityStopped>(_onStopped);
    add(const _ActivityInit());
  }

  void _onInit(_ActivityInit event, Emitter<ActivityState> emit) {
    final current = TimeBlock.current;
    if (current == null) return;
    emit(ActivityProgressActive(
      current.activity,
      DateTime.now().difference(current.at.start),
      at: current.at,
    ));
  }

  void _onSelected(ActivitySelected event, Emitter<ActivityState> emit) {
    emit(state.copyWith(selected: event.activity));
  }

  void _onStarted(ActivityStarted event, Emitter<ActivityState> emit) {
    emit(ActivityProgressActive(
      event.activity,
      const Duration(),
      at: event.at,
    ));
    TimeBlock.add(event.activity, event.at);
  }

  void _onPaused(ActivityPaused event, Emitter<ActivityState> emit) {
    switch (state) {
      case ActivityProgressActive s:
        emit(ActivityProgressPaused(
          s.active,
          s.elapsed,
          at: s.at,
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
          at: s.at,
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
