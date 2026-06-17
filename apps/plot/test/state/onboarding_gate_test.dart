import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/onboarding.dart';

/// Locks in the gate that decides whether onboarding runs, is skipped as a
/// returning user, or is treated as already complete.
///
/// The load-bearing case is the last one: the role-question step renames the
/// seeded role (so `Role.hasConfigured()` becomes true), which used to trip
/// the "returning user" backstop on a mid-flow restart and suppress onboarding
/// forever. Once this device has shown onboarding, the backstop must NOT fire —
/// onboarding keeps running until the user completes or dismisses it.
void main() {
  group('onboardingGate', () {
    test('completed flag wins regardless of everything else', () {
      expect(
        onboardingGate(
          completedFlag: true,
          shownBefore: false,
          hasPriorUseEvidence: true,
        ),
        OnboardingGate.completed,
      );
      expect(
        onboardingGate(
          completedFlag: true,
          shownBefore: true,
          hasPriorUseEvidence: false,
        ),
        OnboardingGate.completed,
      );
    });

    test('fresh user with no prior-use evidence runs onboarding', () {
      expect(
        onboardingGate(
          completedFlag: false,
          shownBefore: false,
          hasPriorUseEvidence: false,
        ),
        OnboardingGate.run,
      );
    });

    test('returning user (evidence, never shown here) is skipped', () {
      expect(
        onboardingGate(
          completedFlag: false,
          shownBefore: false,
          hasPriorUseEvidence: true,
        ),
        OnboardingGate.skipReturningUser,
      );
    });

    test('mid-flow restart: shown here + evidence still RUNS (the fix)', () {
      // The user passed the role step (renaming the seed → evidence is true)
      // then relaunched before completing/dismissing. Because onboarding was
      // already shown on this device, the backstop is bypassed and onboarding
      // re-runs rather than being permanently suppressed.
      expect(
        onboardingGate(
          completedFlag: false,
          shownBefore: true,
          hasPriorUseEvidence: true,
        ),
        OnboardingGate.run,
      );
    });

    test('shown here, no evidence, not completed → runs', () {
      expect(
        onboardingGate(
          completedFlag: false,
          shownBefore: true,
          hasPriorUseEvidence: false,
        ),
        OnboardingGate.run,
      );
    });
  });
}
