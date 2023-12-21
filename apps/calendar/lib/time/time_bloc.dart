import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:equatable/equatable.dart';

import '../minutes.dart';

part 'time_event.dart';
part 'time_state.dart';

class TimeBloc extends Bloc<TimeEvent, TimeState> {
  TimeBloc() : super(const TimeIdle()) {
    on<TimeStarted>(_onStarted);
    on<TimePaused>(_onPaused);
    on<TimeResumed>(_onResumed);
    on<TimeStopped>(_onStopped);
    on<_TimeTicked>(_onTicked, transformer: droppable());
  }

  final Minutes _minutes = Minutes();

  StreamSubscription<int>? _minutesSubscription;

  @override
  Future<void> close() {
    _minutesSubscription?.cancel();
    return super.close();
  }

  void _onStarted(TimeStarted event, Emitter<TimeState> emit) {
    emit(const TimeProgressActive(0));
    _minutesSubscription?.cancel();
    _minutesSubscription = _minutes.stream
        .listen((duration) => add(_TimeTicked(duration: duration)));
    _minutes.start();
  }

  void _onPaused(TimePaused event, Emitter<TimeState> emit) {
    if (state is TimeProgressActive) {
      _minutesSubscription?.pause();
      emit(TimeProgressPaused((state as TimeProgressActive).duration));
    }
  }

  void _onResumed(TimeResumed resume, Emitter<TimeState> emit) {
    if (state is TimeProgressPaused) {
      _minutesSubscription?.resume();
      emit(TimeProgressActive((state as TimeProgressPaused).duration));
    }
  }

  void _onStopped(TimeStopped event, Emitter<TimeState> emit) {
    _minutesSubscription?.cancel();
    emit(const TimeIdle());
  }

  void _onTicked(_TimeTicked event, Emitter<TimeState> emit) {
    emit(TimeProgressActive(event.duration));
  }
}
