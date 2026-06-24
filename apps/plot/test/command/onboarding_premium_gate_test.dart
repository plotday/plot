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
  premium: PremiumUsage(allowed: true, count: 0, purchased: 0),
  isAdmin: true,
);

void main() {
  group('premiumOnboardingGate', () {
    test('returns null for a non-add-on connector', () {
      final gate = premiumOnboardingGate(
        usage: _usage(premium: const PremiumUsage(allowed: false)),
        isPremium: false,
      );
      expect(gate, isNull);
    });

    test('blocks Free users with the upgrade-to-paid-plan command', () {
      final gate = premiumOnboardingGate(
        usage: _usage(premium: const PremiumUsage(allowed: false)),
        isPremium: true,
      );
      expect(gate, isNotNull);
      expect(gate!.title, 'Upgrade to use connection add-ons');
    });

    test('blocks when add-on payload is missing (treated as blocked)', () {
      final gate = premiumOnboardingGate(usage: _usage(), isPremium: true);
      expect(gate, isNotNull);
      expect(gate!.title, 'Upgrade to use connection add-ons');
    });

    test('prompts to buy an add-on when all purchased credits are used', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(allowed: true, count: 1, purchased: 1),
        ),
        isPremium: true,
      );
      expect(gate, isNotNull);
      expect(gate!.title, 'Add a connection add-on');
    });

    test('allows a paid user with a spare add-on credit', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(allowed: true, count: 0, purchased: 1),
        ),
        isPremium: true,
      );
      expect(gate, isNull);
    });

    test('defers to the setup modal when the user has a team', () {
      final gate = premiumOnboardingGate(
        usage: _usage(
          premium: const PremiumUsage(allowed: false),
          teams: [_team()],
        ),
        isPremium: true,
      );
      expect(gate, isNull);
    });
  });
}
