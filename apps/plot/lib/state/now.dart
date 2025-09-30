import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';

part 'now_state.dart';

class NowBloc extends Cubit<NowState> {
  NowBloc() : super(const NowLoading());

  NowLoaded get loadedState => super.state as NowLoaded;

  StreamSubscription<void>? _subscription;

  @override
  Future<void> close() {
    stop();
    return super.close();
  }

  void start() {
    _subscription =
        Rx.combineLatest3(
          Priority.watchDefault(),
          ScheduledDay.watchToday(),
          Session.watchCurrent(),
          (priority, day, session) {
            return NowLoaded(
              defaultPriority: priority,
              day: day,
              session: session,
            );
          },
        ).listen((state) {
          emit(state);
        });
  }

  void stop() {
    _subscription?.cancel();
  }

  void setPriority(Priority? priority) async {
    if (loadedState.session?.priority == priority) return;
    await loadedState.session?.copyWith(end: DateTime.now()).save();
    await Session.resume(
      priority,
      end: loadedState.endFor(priority) ?? DateTime.now().addMinutes(3),
    );
  }
}
