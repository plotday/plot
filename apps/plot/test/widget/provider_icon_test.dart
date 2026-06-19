import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/setup_source.dart';

void main() {
  group('ProviderIcon.hasIcon', () {
    // The bug: these providers have bundled brand assets but were missing from
    // the icon switch, so the account row rendered a blank square.
    test('linkedin resolves to a bundled icon', () {
      expect(
        const ProviderIcon(provider: AuthProvider.linkedin, size: 16).hasIcon,
        isTrue,
      );
    });

    test('apple resolves to a bundled icon', () {
      expect(
        const ProviderIcon(provider: AuthProvider.apple, size: 16).hasIcon,
        isTrue,
      );
    });

    test('linear resolves to a bundled icon', () {
      // linear was wired up but its only asset was white-on-white; it now has a
      // light variant too. It must keep reporting a known icon.
      expect(
        const ProviderIcon(provider: AuthProvider.linear, size: 16).hasIcon,
        isTrue,
      );
    });

    test('unmapped providers fall back (no bundled icon)', () {
      expect(
        const ProviderIcon(provider: AuthProvider.other, size: 16).hasIcon,
        isFalse,
      );
    });
  });
}
