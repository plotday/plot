import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart'
    show GoogleSignInExceptionCode;
import 'package:plot/widget/auth_button.dart'
    show shouldReportGoogleSignInFailure;

/// Regression test for noisy Google sign-in error reporting.
///
/// `providerConfigurationError` means the device's underlying auth SDK (Google
/// Play Services / the Android Credential Manager) is unavailable or has no
/// registered credential provider — an environmental condition on the user's
/// device, not a bug in Plot. The user is shown an error toast, so reporting it
/// to error tracking only adds noise (PostHog issue 019ede98, seen in the wild
/// as "getCredentialAsync no provider dependencies found"). It must not be
/// captured, just like a user cancellation.
void main() {
  group('shouldReportGoogleSignInFailure', () {
    test('does not report environmental / user-driven failures', () {
      expect(
        shouldReportGoogleSignInFailure(
          GoogleSignInExceptionCode.providerConfigurationError,
        ),
        isFalse,
      );
      expect(
        shouldReportGoogleSignInFailure(GoogleSignInExceptionCode.canceled),
        isFalse,
      );
    });

    test('reports genuine app-side and unknown failures', () {
      expect(
        shouldReportGoogleSignInFailure(
          GoogleSignInExceptionCode.clientConfigurationError,
        ),
        isTrue,
      );
      expect(
        shouldReportGoogleSignInFailure(GoogleSignInExceptionCode.interrupted),
        isTrue,
      );
      expect(
        shouldReportGoogleSignInFailure(GoogleSignInExceptionCode.unknownError),
        isTrue,
      );
    });
  });
}
