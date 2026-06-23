import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/twist_api.dart';

void main() {
  test('TwistIntegrations: products absent => not composite (back-compat)', () {
    final ti = TwistIntegrations.fromJson(
        {'providers': <dynamic>[], 'accounts': <dynamic>[], 'syncables': <dynamic>[]});
    expect(ti.products, isNull);
    expect(ti.isComposite, isFalse);
  });

  test('TwistIntegrations: products present => composite + parsed', () {
    final ti = TwistIntegrations.fromJson({
      'providers': <dynamic>[], 'accounts': <dynamic>[], 'syncables': <dynamic>[],
      'products': [
        {'key': 'mail', 'label': 'Mail', 'description': 'Email', 'icon': 'm.svg', 'scopeGroupId': 'mail'},
      ],
      'productStatus': [
        {'key': 'mail', 'enabled': true, 'reason': 'granted'},
        {'key': 'tasks', 'enabled': false, 'reason': 'scope-missing'},
        {'key': 'x', 'enabled': false, 'reason': 'totally-new-reason'},
      ],
    });
    expect(ti.isComposite, isTrue);
    expect(ti.products!.single.key, 'mail');
    expect(ti.productStatus!.firstWhere((s) => s.key == 'mail').enabled, isTrue);
    expect(ti.productStatus!.firstWhere((s) => s.key == 'tasks').reason, ProductStatusReason.scopeMissing);
    // unknown reason falls back to .other (forward-compat)
    expect(ti.productStatus!.firstWhere((s) => s.key == 'x').reason, ProductStatusReason.other);
  });
}
