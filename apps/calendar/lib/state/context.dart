import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/context.dart';

part 'context_state.dart';

class ContextBloc extends Cubit<ContextState> {
  ContextBloc() : super(ContextState(Context.store.list())) {
    _subscription = Context.store.stream().listen((contexts) {
      emit(state.copyWith(contexts: contexts));
    });
  }

  void dispose() {
    _subscription?.cancel();
  }

  StreamSubscription<List<Context>>? _subscription;
}
