import 'package:flutter_test/flutter_test.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show SignInWithAppleCredentialsException;
import 'package:plot/widget/auth_button.dart'
    show isAppleWebInteropCastFailure, isAppleWebSignInFailure;

/// Regression test for noisy web Sign in with Apple error reporting.
///
/// On web, `SignInWithApple.getAppleIDCredential` runs the
/// `sign_in_with_apple_web` plugin, whose error handler casts Apple's JS
/// rejection with `e as SignInErrorI` (sign_in_with_apple_web.dart:61). When
/// the sign-in fails — most often because the user closes/dismisses the popup,
/// the popup is blocked, or `AppleID.auth` is unreachable — the rejection may
/// not be a JS object, so that cast throws
/// `type '…' is not a subtype of type 'JSObject'`, masking the real cause. It
/// is a user-recoverable / environmental condition, not a Plot bug (PostHog
/// issue 019f43c5), so it must not be captured to error tracking — just like a
/// user cancellation. The user still sees a retry toast.
void main() {
  group('isAppleWebInteropCastFailure', () {
    test('matches the minified JSObject-subtype TypeError seen in the wild', () {
      // Exact message shape captured in production (type names are minified).
      expect(
        isAppleWebInteropCastFailure(
          "TypeError: Instance of 'minified:ahF': type 'minified:ahF' is not "
          "a subtype of type 'JSObject'",
        ),
        isTrue,
      );
    });

    test('matches the non-minified JSObject-subtype TypeError', () {
      expect(
        isAppleWebInteropCastFailure(
          "type 'SomeDartType' is not a subtype of type 'JSObject'",
        ),
        isTrue,
      );
    });

    test('does not match unrelated cast errors', () {
      expect(
        isAppleWebInteropCastFailure(
          "type 'String' is not a subtype of type 'int'",
        ),
        isFalse,
      );
    });
  });

  group('isAppleWebSignInFailure', () {
    test('treats the plugin credentials exception as an expected failure', () {
      expect(
        isAppleWebSignInFailure(
          const SignInWithAppleCredentialsException(
            message: 'Authentication failed with popup_closed_by_user',
          ),
        ),
        isTrue,
      );
    });

    test('treats the JSObject-subtype TypeError as an expected failure', () {
      final Object typeError = _captureJSObjectSubtypeTypeError();
      expect(typeError, isA<TypeError>());
      expect(isAppleWebSignInFailure(typeError), isTrue);
    });

    test('still reports genuine, unrelated errors', () {
      // An arbitrary error (e.g. a bug in our onComplete callback) must remain
      // reportable — only the web-plugin failure signatures are suppressed.
      expect(isAppleWebSignInFailure(Exception('unexpected')), isFalse);
      expect(isAppleWebSignInFailure(StateError('boom')), isFalse);
      // A TypeError that is NOT the JSObject interop crash is still reported.
      expect(isAppleWebSignInFailure(_captureIntCastTypeError()), isFalse);
    });
  });
}

/// Produces a real [TypeError] whose message carries the `'JSObject'` signature,
/// mirroring what `sign_in_with_apple_web` throws on web. `dart:js_interop`'s
/// `JSObject` is not available on the Dart VM, so we synthesize the failing
/// cast against a type also named `JSObject` to reproduce the exact message
/// tail the guard matches on.
Object _captureJSObjectSubtypeTypeError() {
  try {
    final Object value = _NotAJSObject();
    value as JSObject;
    return StateError('cast unexpectedly succeeded');
  } catch (e) {
    return e;
  }
}

Object _captureIntCastTypeError() {
  try {
    final Object value = 'not an int';
    value as int;
    return StateError('cast unexpectedly succeeded');
  } catch (e) {
    return e;
  }
}

/// A stand-in for `dart:js_interop`'s `JSObject`, which is unavailable on the
/// Dart VM. A failed cast to it yields the same `not a subtype of type
/// 'JSObject'` message the guard keys on.
class JSObject {}

class _NotAJSObject {}
