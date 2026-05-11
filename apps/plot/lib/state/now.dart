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
        Rx.combineLatest5(
          Priority.watchDefault(),
          ScheduledDay.watchToday(),
          Session.watchCurrent(),
          Priority.watch(archived: false),
          streamPriorityBlocksGroupedByPriority(),
          (priority, day, session, priorities, blocksByPriority) {
            return NowLoaded(
              defaultPriority: priority,
              day: day,
              session: session,
              priorities: priorities,
              priorityBlocksByPriority: blocksByPriority,
              context: state is NowLoaded ? (state as NowLoaded).context : null,
              currentEvent:
                  state is NowLoaded ? (state as NowLoaded).currentEvent : null,
            );
          },
        ).listen(
          (state) {
            emit(state);
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object error, StackTrace? stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
        );
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
    // Sticky-until-navigated-away: clear currentEvent whenever the
    // displayed priority changes to one that doesn't own the event.
    final currentEvent = loadedState.currentEvent;
    final keepEvent =
        currentEvent != null && currentEvent.priority.id == priority?.id;
    final newState = loadedState.copyWith(
      context: priority,
      currentEvent: keepEvent ? currentEvent : null,
    );
    emit(newState);
  }

  /// Set the agenda's currently-selected event. Pass null to clear.
  /// Also pulls the context to the event's priority so PriorityPage
  /// displays the correct workspace.
  void setCurrentEvent(Thread? event) {
    if (loadedState.currentEvent?.id == event?.id &&
        loadedState.currentEvent?.occurrence == event?.occurrence) {
      return;
    }
    if (event != null && loadedState.context?.id != event.priority.id) {
      emit(
        loadedState.copyWith(context: event.priority, currentEvent: event),
      );
      return;
    }
    emit(loadedState.copyWith(currentEvent: event));
  }

  /// Focus is the priority of the current activity, which may
  /// be more specific than the context.
  void setFocus(Priority? priority) async {
    if (loadedState.context == null && priority != null) {
      setContext(priority);
    }
    if (loadedState.session?.priority?.id == priority?.id) return;
    await loadedState.session?.copyWith(end: Time.now()).save();
    await Session.resume(
      priority,
      end: loadedState.endFor(priority) ?? Time.now().addMinutes(3),
    );
  }
}
