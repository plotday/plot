import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/twist.dart' show addonNoticeText;

void main() {
  group('addonNoticeText', () {
    test('returns null for a non-premium connector', () {
      expect(
        addonNoticeText(
          isPremium: false,
          premium: const PremiumUsage(allowed: true),
          connectionName: 'Gmail',
          priceLabel: r'$5/month',
        ),
        isNull,
      );
    });

    test('charge copy names the connection and the price', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: const PremiumUsage(allowed: true, count: 0, purchased: 0),
        connectionName: 'LinkedIn',
        priceLabel: r'$5/month',
      );
      expect(text, contains('LinkedIn requires a connection add-on'));
      expect(text, contains(r'$5/month'));
      expect(text, contains("won't be charged until you add"));
    });

    test('omits the figure when the price is unknown (App Store not loaded)', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: const PremiumUsage(allowed: true, count: 0, purchased: 0),
        connectionName: 'LinkedIn',
        priceLabel: null,
      );
      expect(text, contains('requires a connection add-on'));
      expect(text, isNot(contains(r'$')));
    });

    test('spare-credit copy: no additional charge, no price', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: const PremiumUsage(allowed: true, count: 1, purchased: 2),
        connectionName: 'LinkedIn',
        priceLabel: r'$5/month',
      );
      expect(text, contains('uses one of your connection add-ons'));
      expect(text, contains('no additional charge'));
      expect(text, isNot(contains(r'$5/month')));
    });

    test('null premium payload (older server) treated as a charge', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: null,
        connectionName: 'LinkedIn',
        priceLabel: r'$5/month',
      );
      expect(text, contains('requires a connection add-on'));
    });
  });
}
