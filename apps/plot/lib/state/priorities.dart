import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'logging.dart';

part 'priorities_state.dart';

class PrioritiesBloc extends Cubit<PrioritiesState> {
  PrioritiesBloc() : _subscription = null, super(PrioritiesState()) {
    _loadPriorities();
  }

  @override
  Future<void> close() {
    _subscription?.cancel();
    return super.close();
  }

  void _loadPriorities() {
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

  StreamSubscription<List<Priority>>? _subscription;
}

