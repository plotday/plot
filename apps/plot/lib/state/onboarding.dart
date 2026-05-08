import 'package:drift/drift.dart' as drift;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/onboarding/onboarding_roles.dart';
import 'package:plot/widget/onboarding/onboarding_steps.dart';

part 'onboarding_state.dart';

/// Manages the onboarding flow lifecycle.
///
/// Created eagerly but only started after [UserReady]. Call [start] once
/// the database is available.
class OnboardingBloc extends Cubit<OnboardingState> {
  OnboardingBloc() : super(const OnboardingLoading());

  /// Selection state for the "What fills your days?" step. Held on the bloc
  /// so toggles survive back/forward step navigation. Initialised lazily by
  /// [OnboardingRoles] from existing top-level priorities; cleared whenever
  /// the flow is dismissed, restarted, or completed.
  RolesStepData? rolesData;

  /// Persist any staged role changes from the "What fills your days?" step.
  /// Called by the step's `onBeforeNext` hook when the user advances.
  Future<void> commitRoles() async {
    await rolesData?.commit();
  }

  /// Check whether onboarding has been completed and activate if not.
  Future<void> start() async {
    final settings = await UserSettingsEntity.get();
    if (settings?.onboardingCompleted == true) {
      emit(const OnboardingCompleted());
    } else {
      emit(OnboardingActive(
        currentStep: 0,
        steps: OnboardingSteps.all,
      ));
    }
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
    rolesData = null;
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
    rolesData = null;
    emit(const OnboardingCompleted());
    await UserSettingsEntity.save(
      UserSettingsCompanion(
        onboardingCompleted: const drift.Value(true),
      ),
    );
  }
}
