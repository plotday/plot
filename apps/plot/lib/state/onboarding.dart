import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/onboarding/onboarding_steps.dart';

part 'onboarding_state.dart';

/// Index of the next visible (non-skipped) step from [current] moving by [dir]
/// (+1 forward, -1 back). Returns null when there is no such step — off the end
/// going forward (the flow completes) or off the start going back (a no-op).
/// Skip predicates are read live, so a step's visibility reflects the latest
/// state (e.g. the role follow-up step depends on the option just selected).
@visibleForTesting
int? nextVisibleStep(List<OnboardingStep> steps, int current, int dir) {
  var idx = current + dir;
  while (idx >= 0 && idx < steps.length) {
    if (!(steps[idx].shouldSkip?.call() ?? false)) return idx;
    idx += dir;
  }
  return null;
}

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
    // user's priorities and roles by the time we get here, so a non-root
    // focus OR a configured role (renamed/added beyond the seeded default)
    // is positive evidence the user has used Plot before. This backstops the
    // synced `onboarding_completed` flag for the rare case where it hasn't
    // landed yet (device 1 finished onboarding offline). Persist the flag so
    // future launches skip immediately without re-running this check.
    if (await Priority.hasNonRoot() || await Role.hasConfigured()) {
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

  /// Advance to the next visible step, or complete if none remain. Skipped
  /// steps (`shouldSkip` true) are walked over, so a conditional step the
  /// current selection doesn't need is passed automatically.
  void next() {
    final current = state;
    if (current is! OnboardingActive) return;

    final idx = nextVisibleStep(current.steps, current.currentStep, 1);
    if (idx == null) {
      _complete();
    } else {
      emit(OnboardingActive(currentStep: idx, steps: current.steps));
    }
  }

  /// Move back to the previous visible step, walking over any skipped steps.
  /// No-op when already on the first visible step.
  void previous() {
    final current = state;
    if (current is! OnboardingActive) return;
    final idx = nextVisibleStep(current.steps, current.currentStep, -1);
    if (idx == null) return;
    emit(OnboardingActive(currentStep: idx, steps: current.steps));
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
