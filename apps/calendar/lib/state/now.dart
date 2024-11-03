import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/clock.dart';

part 'now_state.dart';

class NowBloc extends Cubit<NowState> {
  NowBloc() : super(NowState()) {
    _secondsSubscription = Clock().seconds.listen((now) {
      emit(state.copyWith());
      if (_eventSubscription == null || !state.now.isSameDay(now)) {
        _eventSubscription =
            ScheduledDay.watch(Day(now.toDate())).listen((day) {
          emit(state.copyWith(
            day: day[now.toDate()],
          ));
        });
      }
    });
    _sessionSubscription = Session.watchCurrent()
        .listen((session) => emit(state.copyWith(session: session)));
  }

  StreamSubscription<void>? _secondsSubscription;
  StreamSubscription<Session?>? _sessionSubscription;
  StreamSubscription<void>? _eventSubscription;

  @override
  Future<void> close() {
    _secondsSubscription?.cancel();
    _sessionSubscription?.cancel();
    _eventSubscription?.cancel();
    return super.close();
  }

  void setContext(Activity? context) async {
    if (state.session?.activity == context) return;
    // TODO properly set and extend time
    await Session.resume(context,
        end: state.endFor(context) ?? DateTime.now().addMinutes(5));
  }

  // Future<void> _newActive(Emitter<NowState> emit, Session block) async {
  //   emit(ContextActive(
  //     block,
  //     selected: state.selected ?? block.context,
  //   ));
  //   _contextTimer?.cancel();
  //   _contextTimer = Timer(block.remaining, () => add(const ContextCompleted()));
  //   final newBlock = await block.save();
  //   emit(ContextActive(
  //     newBlock,
  //     selected: state.selected ?? newBlock.context,
  //   ));
  // }
  //
  // void _onStarted(ContextStarted event, Emitter<NowState> emit) async {
  //   await _newActive(emit,
  //       Session.now(event.context, duration: event.duration, end: event.end));
  // }
  //
  // void _onStopped(ContextStopped event, Emitter<NowState> emit) async {
  //   switch (state) {
  //     case ContextActive s:
  //       await _newActive(emit, s.active.copyStopped());
  //       break;
  //     default:
  //       break;
  //   }
  // }
  //
  // void _onResumed(ContextResumed event, Emitter<NowState> emit) async {
  //   switch (state) {
  //     case ContextActive s:
  //       await _newActive(
  //           emit,
  //           Session.now(s.active.context,
  //               planned: s.active.planned,
  //               duration: event.duration ??
  //                   (event.end == null ? s.active.remaining : null),
  //               end: event.end));
  //       break;
  //     default:
  //       break;
  //   }
  // }
  //
  // void _onTimeIncreased(
  //     ContextTimeIncreased event, Emitter<NowState> emit) async {
  //   switch (state) {
  //     case ContextActive s:
  //       await _newActive(
  //           emit,
  //           s.active.copyWith(
  //             planned: s.active.planned + const Duration(minutes: 5),
  //           ));
  //       break;
  //     default:
  //       if (state.selected == null) return;
  //       final selected = state.selected!.copyWith(
  //         pomodoro: state.selected!.pomodoro + const Duration(minutes: 5),
  //       );
  //       emit(ContextPaused(selected: selected));
  //       await selected.save();
  //       break;
  //   }
  // }
  //
  // void _onTimeDecreased(
  //     ContextTimeDecreased event, Emitter<NowState> emit) async {
  //   switch (state) {
  //     case ContextActive s:
  //       if (s.active.planned.inMinutes > 5) {
  //         await _newActive(
  //             emit,
  //             s.active.copyWith(
  //               planned: s.active.planned - const Duration(minutes: 5),
  //             ));
  //       }
  //       break;
  //     default:
  //       if (state.selected == null) return;
  //       final selected = state.selected!.copyWith(
  //         pomodoro: state.selected!.pomodoro - const Duration(minutes: 5),
  //       );
  //       emit(ContextPaused(selected: selected));
  //       await selected.save();
  //       break;
  //   }
  // }
  //
  // void _onCompleted(ContextCompleted event, Emitter<NowState> emit) async {
  //   emit(ContextPaused(selected: state.selected));
  // }
  //
  // Future<void> _onTicked(_ClockTicked event, Emitter<NowState> emit) async {
  //   final [current, next] = await Future.wait([
  //     Event.current(),
  //     Event.next(),
  //   ]);
  //   if (state.current != current.firstOrNull ||
  //       state.next != next.firstOrNull) {
  //     emit(
  //         state.copyWith(current: current.firstOrNull, next: next.firstOrNull));
  //   }
  // }
}
