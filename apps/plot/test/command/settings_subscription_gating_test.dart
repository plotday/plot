import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/settings.dart';
import 'package:plot/command/upgrade.dart';

void main() {
  SubscriptionInfo sub({String plan = 'free', String? origin, String status = 'active'}) =>
      SubscriptionInfo(plan: plan, effectivePlan: plan, effectiveSource: 'personal', origin: origin, status: status);

  List<Type> types(List<Object> cmds) => cmds.map((c) => c.runtimeType).toList();

  test('stripe trial (App Store) → upgrade + restore, no manage', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'core', origin: 'stripe', status: 'trialing'), isAppStoreBuild: true);
    expect(types(cmds), [ShowUpgradeOptions, RestorePurchasesCommand]);
  });

  test('paid stripe (App Store) → manage + restore, no upgrade', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'core', origin: 'stripe', status: 'active'), isAppStoreBuild: true);
    expect(types(cmds), [ManageSubscriptionCommand, RestorePurchasesCommand]);
  });

  test('app_store core → upgrade(pro) + manage + restore', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'core', origin: 'app_store'), isAppStoreBuild: true);
    expect(types(cmds), [ShowUpgradeOptions, ManageSubscriptionCommand, RestorePurchasesCommand]);
  });

  test('app_store pro → manage + restore', () {
    final cmds = subscriptionCommandsFor(
        subscription: sub(plan: 'pro', origin: 'app_store'), isAppStoreBuild: true);
    expect(types(cmds), [ManageSubscriptionCommand, RestorePurchasesCommand]);
  });

  test('free (App Store) → upgrade + restore', () {
    final cmds = subscriptionCommandsFor(subscription: sub(), isAppStoreBuild: true);
    expect(types(cmds), [ShowUpgradeOptions, RestorePurchasesCommand]);
  });

  test('non-App-Store free → upgrade only (no restore)', () {
    final cmds = subscriptionCommandsFor(subscription: sub(), isAppStoreBuild: false);
    expect(types(cmds), [ShowUpgradeOptions]);
  });
}
