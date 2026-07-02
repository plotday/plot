import 'package:flutter_test/flutter_test.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/checkout_await.dart';

UsageData _usage({
  required int personalPurchased,
  int twistAddonCount = 0,
  List<int> teamPurchased = const [],
}) =>
    UsageData.fromJson({
      'personal': {
        'connections': {'count': 0},
        'twists': {'count': 0},
        'premium': {
          'allowed': true,
          'count': 0,
          'purchased': personalPurchased,
        },
        'twistAddonCount': twistAddonCount,
      },
      'teams': [
        for (var i = 0; i < teamPurchased.length; i++)
          {
            'id': 'team$i',
            'name': 'Team $i',
            'plan': 'team',
            'connections': {'count': 0},
            'premium': {
              'allowed': true,
              'count': 0,
              'purchased': teamPurchased[i],
            },
            'is_admin': true,
          },
      ],
      'pricing': {'connectionAddonPrice': 5},
    });

void main() {
  test('connectionAddonCreditTotal sums personal + all teams', () {
    expect(connectionAddonCreditTotal(_usage(personalPurchased: 2)), 2);
    expect(
      connectionAddonCreditTotal(
        _usage(personalPurchased: 1, teamPurchased: [3, 2]),
      ),
      6,
    );
  });

  test('twistAddonCreditTotal reads personal twistAddonCount', () {
    expect(
      twistAddonCreditTotal(_usage(personalPurchased: 0, twistAddonCount: 4)),
      4,
    );
  });
}
