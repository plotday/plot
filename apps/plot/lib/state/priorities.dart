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

  /// Set the archived filter (false = active only, null = show all)
  void setArchivedFilter(bool showAll) {
    final newFilter = showAll ? null : false;
    if (state.archivedFilter != newFilter) {
      log.info('Setting archivedFilter to $newFilter (showAll: $showAll)');
      // Use constructor instead of copyWith to properly set null value
      emit(PrioritiesState(
        priorities: state.priorities,
        root: state.root,
        archivedFilter: newFilter,
      ));
      start();
    }
  }

  Future<void> start() {
    final completer = Completer<void>();
    stop();
    _subscription = Priority.watch(archived: state.archivedFilter).listen(
      (priorities) {
        emit(
          state.copyWith(
            priorities: priorities,
            root: Priority.asNested(priorities).first,
          ),
        );
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        log.severe('Error watching priorities', error, stackTrace);
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }

  void stop() {
    _subscription?.cancel();
  }

  StreamSubscription<List<Priority>>? _subscription;
}
