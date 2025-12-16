import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';

part 'now_state.dart';

class NowBloc extends Cubit<NowState> {
  NowBloc() : super(const NowLoading());

  bool get loading => super.state is NowLoading;
  NowLoaded get loadedState => super.state as NowLoaded;

  StreamSubscription<void>? _subscription;

  @override
  Future<void> close() {
    stop();
    return super.close();
  }

  Future<void> start() {
    final completer = Completer<void>();
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
              context: state is NowLoaded ? (state as NowLoaded).context : null,
            );
          },
        ).listen((state) {
          emit(state);
          if (!completer.isCompleted) {
            completer.complete();
          }
        });
    return completer.future;
  }

  void stop() {
    _subscription?.cancel();
    // Reset state to prevent stale data from persisting across user sessions
    emit(const NowLoading());
  }

  /// Context is the priority being displayed, which may
  /// be more general than the focus.
  void setContext(Priority? priority) async {
    if (loadedState.context?.id == priority?.id) return;
    final newState = loadedState.copyWith(context: priority);
    emit(newState);
  }

  /// Focus is the priority of the current activity, which may
  /// be more specific than the context.
  void setFocus(Priority? priority) async {
    if (loadedState.context == null && priority != null) {
      setContext(priority);
    }
    if (loadedState.session?.priority?.id == priority?.id) return;
    await loadedState.session?.copyWith(end: DateTime.now()).save();
    await Session.resume(
      priority,
      end: loadedState.endFor(priority) ?? DateTime.now().addMinutes(3),
    );
  }
}
