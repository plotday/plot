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
        search: state.search,
      ));
      start();
    }
  }

  void updateSearch(String search) {
    if (state.search != search) {
      log.info('Updating priorities search to "$search"');
      emit(state.copyWith(search: search));
      start();
    }
  }

  Future<void> start() {
    final completer = Completer<void>();
    stop();
    _subscription = Priority.watch(
      archived: state.archivedFilter,
      search: state.search.isNotEmpty ? state.search : null,
    ).listen(
      (priorities) {
        final orgPriorities = priorities.where((p) => p.organizationId != null).toList();
        if (orgPriorities.isNotEmpty) {
          log.info('PrioritiesBloc: ${orgPriorities.length} org priorities: ${orgPriorities.map((p) => '${p.title}(orgId=${p.organizationId}, root=${p.root}, personal=${p.personal})').toList()}');
        } else {
          log.info('PrioritiesBloc: 0 org priorities out of ${priorities.length} total');
        }
        emit(
          state.copyWith(
            priorities: priorities,
            root: Priority.asNested(priorities).firstOrNull ?? state.root,
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
