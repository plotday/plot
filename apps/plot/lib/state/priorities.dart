import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

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
      emit(
        PrioritiesState(
          priorities: state.priorities,
          root: state.root,
          archivedFilter: newFilter,
          search: state.search,
        ),
      );
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
    _subscription =
        Priority.watch(
          archived: state.archivedFilter,
          search: state.search.isNotEmpty ? state.search : null,
        ).listen(
          (priorities) {
            emit(
              state.copyWith(
                priorities: priorities,
                root: Priority.asNested(priorities)
                        .firstWhereOrNull((p) => p.root) ??
                    state.root,
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
    // The sidebar groups focuses under their roles. Roles are not affected by
    // the archived/search filters that scope the focus watch, so always watch
    // the live (non-archived) roles independently of the priorities query.
    _rolesSubscription = Role.watch().listen(
      (roles) => emit(state.copyWith(roles: roles)),
      onError: (Object error, StackTrace? stackTrace) {
        log.severe('Error watching roles', error, stackTrace);
      },
    );
    return completer.future;
  }

  void stop() {
    _subscription?.cancel();
    _rolesSubscription?.cancel();
  }

  StreamSubscription<List<Priority>>? _subscription;
  StreamSubscription<List<Role>>? _rolesSubscription;
}
