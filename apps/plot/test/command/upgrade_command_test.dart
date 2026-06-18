import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/upgrade.dart';

void main() {
  SubscriptionInfo sub({
    String plan = 'free',
    String? origin,
    String status = 'active',
  }) => SubscriptionInfo(
    plan: plan,
    effectivePlan: plan,
    effectiveSource: 'personal',
    origin: origin,
    status: status,
  );

  test('free → core + pro', () {
    expect(ShowUpgradeOptions.plansFor(sub()), ['core', 'pro']);
  });
  test('stripe trial core → core + pro', () {
    expect(
      ShowUpgradeOptions.plansFor(
        sub(plan: 'core', origin: 'stripe', status: 'trialing'),
      ),
      ['core', 'pro'],
    );
  });
  test('app_store core → pro only', () {
    expect(
      ShowUpgradeOptions.plansFor(sub(plan: 'core', origin: 'app_store')),
      ['pro'],
    );
  });
  test('paid stripe / pro → none', () {
    expect(
      ShowUpgradeOptions.plansFor(sub(plan: 'pro', origin: 'app_store')),
      isEmpty,
    );
    expect(
      ShowUpgradeOptions.plansFor(
        sub(plan: 'core', origin: 'stripe', status: 'active'),
      ),
      isEmpty,
    );
  });
}
