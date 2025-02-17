import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'onboarding_state.dart';

class OnboardingBloc extends Cubit<OnboardingState> {
  OnboardingBloc() : super(const OnboardingLoadingState()) {
    _defaultPrioritySubscription = Priority.watchDefault().listen((priority) {
      if (priority == null) {
        emit(const OnboardingProgressState());
      } else {
        emit(const OnboardingCompleteState());
      }
    });
  }

  @override
  Future<void> close() {
    _defaultPrioritySubscription.cancel();
    return super.close();
  }

  late StreamSubscription<Priority?> _defaultPrioritySubscription;

  void setLoading(bool loading) {
    emit(OnboardingProgressState(loading: loading));
  }

  void complete() {
    emit(const OnboardingCompleteState());
  }
}
