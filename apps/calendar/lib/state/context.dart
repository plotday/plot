import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/context.dart';
import 'package:plot/router.dart';

part 'context_state.dart';

class ContextBloc extends Cubit<ContextState> {
  ContextBloc(RouteChangeObserver routeStream)
      : super(ContextState(Context.store.list())) {
    _subscription = Context.store.stream().listen((contexts) {
      emit(state.copyWith(contexts: contexts));
    });
    _routeSubscription = routeStream.stream.listen((routeChange) {
      // emit(state.copyWith(contexts: contexts));
    });
  }

  void dispose() {
    _subscription.cancel();
    _routeSubscription.cancel();
  }

  late StreamSubscription<List<Context>> _subscription;
  late StreamSubscription<RouteChange> _routeSubscription;
}
