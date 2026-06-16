import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/onboarding/onboarding_steps.dart';

FullScreenStep _step({bool skip = false}) => FullScreenStep(
  title: 't',
  body: 'b',
  background: const ThemeColor(0),
  shouldSkip: skip ? () => true : null,
);

void main() {
  group('nextVisibleStep', () {
    test('forward returns the immediate next step when none skip', () {
      final steps = [_step(), _step(), _step()];
      expect(nextVisibleStep(steps, 0, 1), 1);
      expect(nextVisibleStep(steps, 1, 1), 2);
    });

    test('forward walks over consecutive skipped steps', () {
      final steps = [_step(), _step(skip: true), _step(skip: true), _step()];
      expect(nextVisibleStep(steps, 0, 1), 3);
    });

    test('forward returns null when only skipped steps remain (→ complete)', () {
      final steps = [_step(), _step(skip: true)];
      expect(nextVisibleStep(steps, 0, 1), isNull);
    });

    test('forward returns null at the end of the list', () {
      final steps = [_step(), _step()];
      expect(nextVisibleStep(steps, 1, 1), isNull);
    });

    test('back walks over a skipped step', () {
      final steps = [_step(), _step(skip: true), _step()];
      expect(nextVisibleStep(steps, 2, -1), 0);
    });

    test('back returns null at the start of the list', () {
      final steps = [_step(), _step()];
      expect(nextVisibleStep(steps, 0, -1), isNull);
    });

    test('predicate is read live so it reflects the current selection', () {
      var skip = true;
      final steps = [
        _step(),
        FullScreenStep(
          title: 't',
          body: 'b',
          background: const ThemeColor(0),
          shouldSkip: () => skip,
        ),
        _step(),
      ];
      expect(nextVisibleStep(steps, 0, 1), 2); // skipped while skip == true
      skip = false;
      expect(nextVisibleStep(steps, 0, 1), 1); // now visible
    });
  });

  group('OnboardingSteps role follow-up', () {
    test('requires a non-empty name before it can advance', () {
      final followUp = OnboardingSteps.all
          .whereType<FullScreenStep>()
          .firstWhere((s) => s.canAdvance != null);
      // Reactive: the pager listens to this so Next enables/disables as the
      // user types.
      expect(followUp.advanceListenable, isNotNull);
      // Default selection has empty text, so advancing is blocked until a name
      // is typed.
      expect(followUp.canAdvance!(), isFalse);
    });
  });

  group('OnboardingSteps dismissibility', () {
    test('welcome + role steps are non-dismissible; later steps allow the ×',
        () {
      final steps = OnboardingSteps.all;
      // Steps 0–2 are welcome, role picker, and role follow-up — no × until a
      // role has been chosen and committed.
      expect(steps[0].dismissible, isFalse, reason: 'welcome');
      expect(steps[1].dismissible, isFalse, reason: 'role picker');
      expect(steps[2].dismissible, isFalse, reason: 'role follow-up');
      // "Connect your tools" onward (a role is committed) can be dismissed.
      for (final step in steps.skip(3)) {
        expect(step.dismissible, isTrue);
      }
    });
  });
}
