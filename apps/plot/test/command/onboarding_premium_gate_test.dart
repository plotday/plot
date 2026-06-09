import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/twist.dart';

UsageData _usage({PremiumUsage? premium, List<TeamUsage> teams = const []}) {
  return UsageData(
    personal: PersonalUsage(
      connections: const ResourceUsage(count: 0, limit: 2),
      twists: const ResourceUsage(count: 0, limit: 2),
      premium: premium,
    ),
    teams: teams,
  );
}

TeamUsage _team() => const TeamUsage(
  id: 'team_1',
  name: 'Acme',
  connections: ResourceUsage(count: 0, limit: 50),
  premium: PremiumUsage(policy: PremiumPolicy.weighted, weight: 3),
  isAdmin: true,
);

void main() {
  group('premiumOnboardingGate', () {
    test('returns null for a non-premium connector', () {
      final gate = premiumOnboardingGate(
        usage: _usage(premium: const PremiumUsage(policy: PremiumPolicy.blocked)),
        isPremium: false,
      );
      expect(gate, isNull);
    });

    test('blocks Free/Core users with the upgrade-to-Pro command', () {
      final gate = premiumOnboardingGate(
        usage: _usage(premium: const PremiumUsage(policy: PremiumPolicy.blocked)),
        isPremium: true,
      );
      expect(gate, isNotNull);
      expect(gate!.title, 'Upgrade to Pro to add a Pro connection');
    });

    test('blocks when premium payload is missing (treated as blocked)', () {
      final gate = premiumOnboardingGate(usage: _usage(), isPremium: true);
      expect(gate, isNotNull);
      expect(gate!.title, 'Upgrade to Pro to add a Pro connection');
    });

    test('blocks a Pro user who already used their included Pro connection', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(
            policy: PremiumPolicy.credits,
            count: 1,
            limit: 1,
            included: 1,
          ),
        ),
        isPremium: true,
      );
      expect(gate, isNotNull);
      expect(gate!.title, "You've used your included Pro connection");
    });

    test('allows a Pro user with an unused included Pro connection', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(
            policy: PremiumPolicy.credits,
            count: 0,
            limit: 1,
            included: 1,
          ),
        ),
        isPremium: true,
      );
      expect(gate, isNull);
    });

    test('defers to the setup modal when the user has a team', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(policy: PremiumPolicy.blocked),
          teams: [_team()],
        ),
        isPremium: true,
      );
      expect(gate, isNull);
    });
  });
}
