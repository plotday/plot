import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:equatable/equatable.dart';

import 'scheduled_event.dart';
import '../activity/activity.dart';
import '../clock.dart';

part 'event.dart';
part 'state.dart';

class ScheduleBloc extends Bloc<ScheduleEvent, ScheduleState> {
  ScheduleBloc() : super(const ScheduleLoadingState()) {
    on<_ScheduleUpdated>(_onUpdated);
    on<_ScheduleTicked>(_onTicked, transformer: droppable());
    _secondsSubscription =
        Clock().seconds.listen((void _) => add(const _ScheduleTicked()));
  }

  StreamSubscription<void>? _secondsSubscription;

  @override
  Future<void> close() {
    _secondsSubscription?.cancel();
    return super.close();
  }

  void _onUpdated(_ScheduleUpdated event, Emitter<ScheduleState> emit) {
    emit(ScheduleLoadedState(event.current, event.next));
  }

  Future<void> _onTicked(
      _ScheduleTicked event, Emitter<ScheduleState> emit) async {
    final [current, next] = await Future.wait([
      ScheduledEvent.current(),
      ScheduledEvent.next(),
    ]);
    add(_ScheduleUpdated(current, next));
  }
}
