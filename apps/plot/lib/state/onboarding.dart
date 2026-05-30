import 'package:drift/drift.dart' as drift;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/onboarding/onboarding_steps.dart';

part 'onboarding_state.dart';

/// Manages the onboarding flow lifecycle.
///
/// Created eagerly but only started after [UserReady]. Call [start] once
/// the database is available.
class OnboardingBloc extends Cubit<OnboardingState> {
  OnboardingBloc() : super(const OnboardingLoading());

  /// Check whether onboarding has been completed and activate if not.
  Future<void> start() async {
    final settings = await UserSettingsEntity.get();
    if (settings?.onboardingCompleted == true) {
      emit(const OnboardingCompleted());
      return;
    }

    // Second-device short-circuit: critical sync has already pulled the
    // user's priorities by the time we get here, so any non-root priority
    // is positive evidence the user has used Plot before. Persist the flag
    // so future launches skip immediately without re-running this check.
    if (await Priority.hasNonRoot()) {
      await UserSettingsEntity.save(
        UserSettingsCompanion(
          onboardingCompleted: const drift.Value(true),
        ),
      );
      emit(const OnboardingCompleted());
      return;
    }

    emit(OnboardingActive(
      currentStep: 0,
      steps: OnboardingSteps.all,
    ));
  }

  /// Advance to the next step, or complete if at the end.
  void next() {
    final current = state;
    if (current is! OnboardingActive) return;

    if (current.isLastStep) {
      _complete();
    } else {
      emit(OnboardingActive(
        currentStep: current.currentStep + 1,
        steps: current.steps,
      ));
    }
  }

  /// Move back one step. No-op when already on the first step.
  void previous() {
    final current = state;
    if (current is! OnboardingActive) return;
    if (current.currentStep == 0) return;
    emit(OnboardingActive(
      currentStep: current.currentStep - 1,
      steps: current.steps,
    ));
  }

  /// Dismiss the entire onboarding flow.
  void dismiss() {
    _complete();
  }

  /// Reset the completion flag and re-emit [OnboardingActive] from step 0.
  /// Used by the debug "Restart onboarding" command so developers can replay
  /// the flow without resetting the database.
  Future<void> restart() async {
    await UserSettingsEntity.save(
      UserSettingsCompanion(
        onboardingCompleted: const drift.Value(null),
      ),
    );
    emit(OnboardingActive(
      currentStep: 0,
      steps: OnboardingSteps.all,
    ));
  }

  Future<void> _complete() async {
    emit(const OnboardingCompleted());
    await UserSettingsEntity.save(
      UserSettingsCompanion(
        onboardingCompleted: const drift.Value(true),
      ),
    );
  }
}
