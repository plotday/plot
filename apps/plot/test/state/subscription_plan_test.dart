import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/subscription_plan.dart';

void main() {
  group('planRank', () {
    test('orders plans free < core < pro = team', () {
      expect(planRank('free'), 0);
      expect(planRank('core'), 1);
      expect(planRank('pro'), 2);
      expect(planRank('team'), 2);
    });

    test('treats unknown/empty as free', () {
      expect(planRank('weird'), 0);
      expect(planRank(''), 0);
    });
  });

  group('planUpToastMessage', () {
    test('names core and pro on an upgrade', () {
      expect(
        planUpToastMessage(prevRank: 0, newRank: 1, newEffectivePlan: 'core'),
        "You're now on Plot Core",
      );
      expect(
        planUpToastMessage(prevRank: 1, newRank: 2, newEffectivePlan: 'pro'),
        "You're now on Plot Pro",
      );
      expect(
        planUpToastMessage(prevRank: 0, newRank: 2, newEffectivePlan: 'pro'),
        "You're now on Plot Pro",
      );
    });

    test('uses neutral wording for team (never names Team)', () {
      final msg =
          planUpToastMessage(prevRank: 0, newRank: 2, newEffectivePlan: 'team');
      expect(msg, 'You can now add more connections');
      expect(msg, isNot(contains('Team')));
    });

    test('returns null when rank did not increase', () {
      expect(
        planUpToastMessage(prevRank: 2, newRank: 2, newEffectivePlan: 'team'),
        isNull,
      );
      expect(
        planUpToastMessage(prevRank: 1, newRank: 1, newEffectivePlan: 'core'),
        isNull,
      );
      expect(
        planUpToastMessage(prevRank: 2, newRank: 0, newEffectivePlan: 'free'),
        isNull,
      );
    });

    test('returns null for an increase into free/unknown', () {
      expect(
        planUpToastMessage(prevRank: 0, newRank: 0, newEffectivePlan: 'free'),
        isNull,
      );
    });
  });
}
