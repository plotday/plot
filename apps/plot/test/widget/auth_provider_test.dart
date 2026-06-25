import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart'
    show authProviderIconAsset, getAuthProviderConfig;
import 'package:plot/widget/setup_source.dart' show ProviderIcon;

/// Regression tests for connector OAuth provider mapping.
///
/// The Todoist connector reports its provider as the string `"todoist"`
/// (from the Twister SDK's `AuthProvider.Todoist = "todoist"`). The Flutter
/// app parses provider strings against the [AuthProvider] enum, falling back
/// to [AuthProvider.other] when no name matches. A missing enum value made
/// Todoist resolve to `other`, which rendered "Continue with Other" and
/// failed when clicked (the API has no OAuth config for `other`).
void main() {
  /// Mirrors the parse used in `twist_api.dart` for connector provider strings.
  AuthProvider parse(String name) => AuthProvider.values.firstWhere(
        (v) => v.name == name,
        orElse: () => AuthProvider.other,
      );

  test('parses "todoist" to AuthProvider.todoist, not other', () {
    expect(parse('todoist'), AuthProvider.todoist);
  });

  test('Todoist button reads "Continue with Todoist"', () {
    expect(getAuthProviderConfig(AuthProvider.todoist).buttonText,
        'Continue with Todoist');
  });

  // Unipile social connectors. WhatsApp and Instagram report their provider as
  // the strings "whatsapp" / "instagram". A missing enum value made them
  // resolve to `other`, which rendered "Continue with Other" with no logo.
  group('WhatsApp', () {
    test('parses "whatsapp" to a dedicated provider, not other', () {
      expect(parse('whatsapp'), isNot(AuthProvider.other));
    });

    test('button reads "Continue with WhatsApp"', () {
      expect(getAuthProviderConfig(parse('whatsapp')).buttonText,
          'Continue with WhatsApp');
    });

    test('has a bundled brand icon (button + account row)', () {
      expect(authProviderIconAsset(parse('whatsapp')), isNotNull);
      expect(
        ProviderIcon(provider: parse('whatsapp'), size: 16).hasIcon,
        isTrue,
      );
    });
  });

  group('Instagram', () {
    test('parses "instagram" to a dedicated provider, not other', () {
      expect(parse('instagram'), isNot(AuthProvider.other));
    });

    test('button reads "Continue with Instagram"', () {
      expect(getAuthProviderConfig(parse('instagram')).buttonText,
          'Continue with Instagram');
    });

    test('has a bundled brand icon (button + account row)', () {
      expect(authProviderIconAsset(parse('instagram')), isNotNull);
      expect(
        ProviderIcon(provider: parse('instagram'), size: 16).hasIcon,
        isTrue,
      );
    });
  });
}
