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

  test('TwistAuthUrl: parses server-resolved scopes', () {
    final a = TwistAuthUrl.fromJson({
      'url': 'https://accounts.google.com/o/oauth2/auth',
      'clientId': 'cid',
      'state': 'st',
      'callback': 'cb',
      'scopes': [
        'https://www.googleapis.com/auth/gmail.modify',
        'https://www.googleapis.com/auth/tasks',
      ],
    });
    expect(a.scopes, [
      'https://www.googleapis.com/auth/gmail.modify',
      'https://www.googleapis.com/auth/tasks',
    ]);
  });

  test('TwistAuthUrl: missing scopes => empty list (back-compat)', () {
    final a = TwistAuthUrl.fromJson({
      'url': 'https://accounts.google.com/o/oauth2/auth',
      'clientId': 'cid',
      'state': 'st',
      'callback': 'cb',
    });
    expect(a.scopes, isEmpty);
  });
}
