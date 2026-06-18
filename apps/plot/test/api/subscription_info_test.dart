import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';

void main() {
  SubscriptionInfo of(Map<String, dynamic> j) => SubscriptionInfo.fromJson(j);

  test('stripe trial is convertible, not paid', () {
    final s = of({'plan': 'core', 'effective_plan': 'core', 'origin': 'stripe', 'status': 'trialing'});
    expect(s.isStripeTrial, isTrue);
    expect(s.isPaidStripe, isFalse);
    expect(s.isAppStore, isFalse);
  });

  test('active stripe core is paid', () {
    final s = of({'plan': 'core', 'effective_plan': 'core', 'origin': 'stripe', 'status': 'active'});
    expect(s.isPaidStripe, isTrue);
    expect(s.isStripeTrial, isFalse);
  });

  test('free defaults (origin null) are not paid/trial/appstore', () {
    final s = of({'plan': 'free', 'effective_plan': 'free', 'status': 'active'});
    expect(s.isPaidStripe, isFalse);
    expect(s.isStripeTrial, isFalse);
    expect(s.isAppStore, isFalse);
    expect(s.isFree, isTrue);
  });

  test('app_store origin', () {
    final s = of({'plan': 'pro', 'effective_plan': 'pro', 'origin': 'app_store', 'status': 'active'});
    expect(s.isAppStore, isTrue);
  });
}
