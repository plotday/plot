import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';
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

/// The outcome of [OnboardingBloc.start]'s gate.
enum OnboardingGate {
  /// The synced `onboarding_completed` flag is set — the user already
  /// completed or dismissed onboarding. Show nothing.
  completed,

  /// Positive evidence the user has used Plot on another device (or before the
  /// flag existed) AND onboarding has never been shown on this device — treat
  /// as a returning user and skip (persisting the flag).
  skipReturningUser,

  /// Run onboarding from the start.
  run,
}

/// Pure decision for whether onboarding should run, given the persisted
/// completion flag, whether onboarding has already been shown on THIS device,
/// and whether there is prior-use evidence (a non-root focus or a role renamed
/// off the seeded default).
///
/// The returning-user backstop must only fire BEFORE this device has entered
/// the flow. Once onboarding has been shown here but not completed/dismissed,
/// the user is mid-flow — the role-question step has already renamed the seed
/// (so [Role.hasConfigured] is now true), and naively re-checking the backstop
/// would suppress onboarding forever. So `shownBefore` bypasses it: keep
/// running until the user completes (final step) or dismisses (×), which is the
/// only thing that sets the completion flag.
@visibleForTesting
OnboardingGate onboardingGate({
  required bool completedFlag,
  required bool shownBefore,
  required bool hasPriorUseEvidence,
}) {
  if (completedFlag) return OnboardingGate.completed;
  if (!shownBefore && hasPriorUseEvidence) {
    return OnboardingGate.skipReturningUser;
  }
  return OnboardingGate.run;
}

/// Manages the onboarding flow lifecycle.
///
/// Created eagerly but only started after [UserReady]. Call [start] once
/// the database is available.
class OnboardingBloc extends Cubit<OnboardingState> {
  OnboardingBloc() : super(const OnboardingLoading());

  /// Local-only (per-device, per-user) marker that onboarding has been shown
  /// on this device. Distinct from the synced `onboarding_completed` flag: it
  /// records that the flow was *entered* here, so a mid-flow restart re-shows
  /// onboarding instead of tripping the returning-user backstop. Not synced —
  /// it is about this device's flow, not cross-device account state.
  static String _shownKey(String userId) => 'onboarding_shown:$userId';

  /// Check whether onboarding has been completed and activate if not.
  ///
  /// Onboarding keeps re-running on every launch until the user completes it
  /// (reaches the final step) or dismisses it (×) — both set the synced
  /// `onboarding_completed` flag. The returning-user backstop (prior-use
  /// evidence from another device / a pre-flag account) only applies the first
  /// time onboarding would show on this device; see [onboardingGate].
  Future<void> start() async {
    final userId = Base.userIdOrNull;
    // Racing a forced sign-out that already nulled the user — nothing to show.
    if (userId == null) return;

    final settings = await UserSettingsEntity.get();
    final prefs = ProfilePreferences.instance;
    final shownBefore = prefs.getBool(_shownKey(userId.toString())) ?? false;

    // Critical sync has already pulled the user's priorities and roles by the
    // time we get here, so a non-root focus OR a role renamed/added beyond the
    // seeded default is evidence the user has used Plot before. Only meaningful
    // when onboarding has never been shown here, so skip the queries once it
    // has (they would otherwise fire mid-flow, since onboarding itself renames
    // the seeded role).
    final hasPriorUseEvidence = !shownBefore &&
        (await Priority.hasNonRoot() || await Role.hasConfigured());

    switch (onboardingGate(
      completedFlag: settings?.onboardingCompleted == true,
      shownBefore: shownBefore,
      hasPriorUseEvidence: hasPriorUseEvidence,
    )) {
      case OnboardingGate.completed:
        emit(const OnboardingCompleted());
      case OnboardingGate.skipReturningUser:
        // Persist the flag so future launches skip immediately without
        // re-running the evidence check.
        await UserSettingsEntity.save(
          UserSettingsCompanion(
            onboardingCompleted: const drift.Value(true),
          ),
        );
        emit(const OnboardingCompleted());
      case OnboardingGate.run:
        // Mark this device as having entered the flow so a mid-flow restart
        // re-shows onboarding (bypassing the backstop) until the user
        // completes or dismisses it.
        await prefs.setBool(_shownKey(userId.toString()), true);
        emit(OnboardingActive(
          currentStep: 0,
          steps: OnboardingSteps.all,
        ));
    }
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
    // Mark as shown so relaunches keep replaying until the user completes or
    // dismisses, matching a fresh user's mid-flow behaviour (and so the
    // backstop doesn't suppress the replay on next launch).
    final userId = Base.userIdOrNull;
    if (userId != null) {
      await ProfilePreferences.instance
          .setBool(_shownKey(userId.toString()), true);
    }
    emit(OnboardingActive(
      currentStep: 0,
      steps: OnboardingSteps.all,
    ));
  }

  /// Debug-only: open onboarding directly at the step whose
  /// [OnboardingStep.title] equals [title]. Used by the store-listing
  /// screenshot scene runner to render a specific step (e.g. "Connect your
  /// tools") without walking the whole flow. No-op in release builds or when
  /// no step matches.
  void showStepForScreenshot(String title) {
    if (!kDebugMode) return;
    final steps = OnboardingSteps.all;
    final index = steps.indexWhere((s) => s.title == title);
    if (index < 0) return;
    emit(OnboardingActive(currentStep: index, steps: steps));
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
