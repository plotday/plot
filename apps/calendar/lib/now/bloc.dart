import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import '../priority/activity.dart';
import 'time_block.dart';

part 'event.dart';
part 'state.dart';

class NowBloc extends Bloc<NowEvent, NowState> {
  NowBloc()
      : super(TimeBlock.current == null
            ? ActivityIdle(Activity.list().first)
            : ActivityActive(TimeBlock.current!,
                selected: TimeBlock.current!.activity)) {
    on<ActivitySelected>(_onSelected);
    on<ActivityStarted>(_onStarted);
    on<ActivityStopped>(_onStopped);
    on<ActivityResumed>(_onResumed);
    on<ActivityTimeIncreased>(_onTimeIncreased);
    on<ActivityTimeDecreased>(_onTimeDecreased);
    on<ActivityCompleted>(_onCompleted);
  }

  Timer? _activityTimer;

  @override
  Future<void> close() {
    _activityTimer?.cancel();
    return super.close();
  }

  void _onSelected(ActivitySelected event, Emitter<NowState> emit) {
    emit(state.copyWith(selected: event.activity));
  }

  Future<void> _newActive(Emitter<NowState> emit, TimeBlock block) async {
    emit(ActivityActive(
      block,
      selected: state.selected,
    ));
    _activityTimer?.cancel();
    _activityTimer =
        Timer(block.remaining, () => add(const ActivityCompleted()));
    final newBlock = await block.save();
    emit(ActivityActive(
      newBlock,
      selected: state.selected,
    ));
  }

  void _onStarted(ActivityStarted event, Emitter<NowState> emit) async {
    await _newActive(
        emit,
        TimeBlock.now(event.activity,
            duration: event.duration, end: event.end));
  }

  void _onStopped(ActivityStopped event, Emitter<NowState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(emit, s.active.copyStopped());
        break;
      default:
        break;
    }
  }

  void _onResumed(ActivityResumed event, Emitter<NowState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(
            emit,
            TimeBlock.now(s.active.activity,
                planned: s.active.planned,
                duration: event.duration ??
                    (event.end == null ? s.active.remaining : null),
                end: event.end));
        break;
      default:
        break;
    }
  }

  void _onTimeIncreased(
      ActivityTimeIncreased event, Emitter<NowState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(
            emit,
            s.active.copyWith(
              planned: s.active.planned + const Duration(minutes: 5),
            ));
        break;
      default:
        final selected = state.selected.copyWith(
          pomodoro: state.selected.pomodoro + const Duration(minutes: 5),
        );
        emit(ActivityIdle(selected));
        await selected.save();
        break;
    }
  }

  void _onTimeDecreased(
      ActivityTimeDecreased event, Emitter<NowState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(
            emit,
            s.active.copyWith(
              planned: s.active.planned - const Duration(minutes: 5),
            ));
        break;
      default:
        final selected = state.selected.copyWith(
          pomodoro: state.selected.pomodoro - const Duration(minutes: 5),
        );
        emit(ActivityIdle(selected));
        await selected.save();
        break;
    }
  }

  void _onCompleted(ActivityCompleted event, Emitter<NowState> emit) async {
    emit(ActivityIdle(state.selected));
  }
}
