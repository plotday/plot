import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart' show getAuthProviderConfig;

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
}
