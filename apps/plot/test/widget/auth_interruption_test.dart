import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/auth_button.dart'
    show isAuthUserCanceled, isAuthCallbackTimeout;

/// Regression tests for classifying expected OAuth web-auth interruptions so
/// they are NOT reported to error tracking.
///
/// On web there is no explicit "cancel" signal. When the user closes or
/// abandons the OAuth popup, flutter_web_auth_2's web implementation polls
/// localStorage for the callback and, after its timeout, throws
/// `PlatformException(code: 'error', message: 'Timeout waiting for callback
/// value')` (see flutter_web_auth_2 src/web.dart). This is the web equivalent
/// of the user not finishing the flow — expected, user-recoverable, and must
/// not be captured as a bug. The original PostHog issue reported exactly this
/// PlatformException from the twist-connect flow.
void main() {
  group('isAuthUserCanceled', () {
    test('true for native cancellation (PlatformException CANCELED)', () {
      expect(
        isAuthUserCanceled(
          PlatformException(code: 'CANCELED', message: 'User canceled'),
        ),
        isTrue,
      );
    });

    test('false for the web callback timeout', () {
      // The web timeout is not a native cancel; it has its own classifier.
      expect(
        isAuthUserCanceled(
          PlatformException(
            code: 'error',
            message: 'Timeout waiting for callback value',
          ),
        ),
        isFalse,
      );
    });

    test('false for non-PlatformException errors', () {
      expect(isAuthUserCanceled(Exception('boom')), isFalse);
    });
  });

  group('isAuthCallbackTimeout', () {
    test('true for the web "Timeout waiting for callback value" exception', () {
      expect(
        isAuthCallbackTimeout(
          PlatformException(
            code: 'error',
            message: 'Timeout waiting for callback value',
          ),
        ),
        isTrue,
      );
    });

    test('false for native cancellation', () {
      expect(
        isAuthCallbackTimeout(
          PlatformException(code: 'CANCELED', message: 'User canceled'),
        ),
        isFalse,
      );
    });

    test('false for an unrelated PlatformException with code "error"', () {
      // Must not over-broaden: only the specific timeout message qualifies, so
      // genuine provider/runtime errors still get reported.
      expect(
        isAuthCallbackTimeout(
          PlatformException(code: 'error', message: 'Something actually broke'),
        ),
        isFalse,
      );
    });

    test('false for non-PlatformException errors', () {
      expect(isAuthCallbackTimeout(Exception('boom')), isFalse);
    });
  });
}
