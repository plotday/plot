import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'logging.dart';

part 'priorities_state.dart';

class PrioritiesBloc extends Cubit<PrioritiesState> {
  PrioritiesBloc() : _subscription = null, super(PrioritiesState());

  @override
  Future<void> close() {
    stop();
    return super.close();
  }

  void start() {
    stop();
    _subscription = Priority.watch().listen((priorities) {
      log.info('Root priorities updated: ${priorities.length} priorities');
      emit(
        state.copyWith(
          priorities: priorities,
          root: Priority.asNested(priorities).first,
        ),
      );
    });
  }

  void stop() {
    _subscription?.cancel();
  }

  StreamSubscription<List<Priority>>? _subscription;
}
