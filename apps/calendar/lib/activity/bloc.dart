import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import '../util/time.dart';
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
    on<ActivityTimeIncreased>(_onTimeIncreased);
    on<ActivityTimeDecreased>(_onTimeDecreased);
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

  Future<void> _newActive(Emitter<ActivityState> emit, TimeBlock block) async {
    emit(ActivityActive(
      block,
      selected: state.selected,
    ));
    final newBlock = await block.save();
    emit(ActivityActive(
      newBlock,
      selected: state.selected,
    ));
  }

  void _onStarted(ActivityStarted event, Emitter<ActivityState> emit) async {
    await _newActive(
        emit,
        TimeBlock.now(event.activity,
            duration: event.duration, end: event.end));
  }

  void _onStopped(ActivityStopped event, Emitter<ActivityState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(emit, s.active.copyStopped());
        break;
      default:
        break;
    }
  }

  void _onResumed(ActivityResumed event, Emitter<ActivityState> emit) async {
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
      ActivityTimeIncreased event, Emitter<ActivityState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(
            emit,
            s.active.copyWith(
              planned: s.active.planned + const Duration(minutes: 5),
            ));
        break;
      default:
        break;
    }
  }

  void _onTimeDecreased(
      ActivityTimeDecreased event, Emitter<ActivityState> emit) async {
    switch (state) {
      case ActivityActive s:
        await _newActive(
            emit,
            s.active.copyWith(
              planned: s.active.planned - const Duration(minutes: 5),
            ));
        break;
      default:
        break;
    }
  }
}
