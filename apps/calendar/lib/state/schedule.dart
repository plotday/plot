import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/schedule.dart';
import 'package:plot/util/time.dart';

part 'schedule_state.dart';

class ScheduleBloc extends Cubit<ScheduleState> {
  ScheduleBloc() : super(ScheduleState()) {
    _subscription = ScheduledDay.store.stream().listen((event) {
      emit(state.copyWith());
    });
  }

  @override
  Future<void> close() async {
    _subscription?.cancel();
    await super.close();
  }

  StreamSubscription<void>? _subscription;
}
