/// Dart JS-interop bindings for the Clerk JS browser SDK.
///
/// Clerk JS is loaded dynamically by [auth_service_web.dart] at init time.
/// DO NOT import this file on native platforms.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// ---------------------------------------------------------------------------
// Clerk JS extension types
// ---------------------------------------------------------------------------

/// The main Clerk JS object, accessed via `window.Clerk`.
///
/// Clerk JS is loaded with `data-clerk-publishable-key` on the script tag,
/// which auto-creates the instance on `window.Clerk`.
extension type ClerkJS._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> load();
  external SessionJS? get session;
  external ClientJS? get client;
  external UserJS? get user;
  external JSPromise<JSAny?> signOut();
  external JSPromise<JSAny?> setActive(JSObject params);
  external JSPromise<JSAny?> handleRedirectCallback([JSObject? params]);
}

/// Clerk Client — holds the current sign-in / sign-up resources.
extension type ClientJS._(JSObject _) implements JSObject {
  external SignInJS? get signIn;
  external SignUpJS? get signUp;
}

/// Clerk SignIn resource.
extension type SignInJS._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> create(JSObject params);
  external JSPromise<JSAny?> attemptFirstFactor(JSObject params);
  external JSPromise<JSAny?> prepareSecondFactor(JSObject params);
  external JSPromise<JSAny?> attemptSecondFactor(JSObject params);
  external JSPromise<JSAny?> authenticateWithRedirect(JSObject params);
  external String? get status;
  external String? get createdSessionId;
}

/// Clerk SignUp resource.
extension type SignUpJS._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> create(JSObject params);
  external JSPromise<JSAny?> update(JSObject params);
  external JSPromise<JSAny?> prepareEmailAddressVerification(JSObject params);
  external JSPromise<JSAny?> attemptEmailAddressVerification(JSObject params);
  external JSPromise<JSAny?> authenticateWithRedirect(JSObject params);
  external String? get status;
  external String? get createdSessionId;
  external JSArray<JSString>? get missingFields;
  external String? get firstName;
  external String? get lastName;
  external String? get emailAddress;
}

/// Clerk ExternalAccount (nested in SignUp verifications).
extension type ExternalAccountJS._(JSObject _) implements JSObject {
  external String? get emailAddress;
  external String? get firstName;
  external String? get lastName;
  external String? get status;
}

/// Clerk Session.
extension type SessionJS._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> getToken([JSObject? options]);
  external void clearCache();
}

/// Clerk User.
extension type UserJS._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> update(JSObject params);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a plain JS object literal from a [Map].
///
/// Null values are omitted so they behave like "field not present" rather
/// than "field = null" (important for Clerk FAPI semantics).
JSObject jsObj(Map<String, Object?> props) {
  final obj = JSObject();
  for (final entry in props.entries) {
    final v = entry.value;
    if (v == null) continue;
    obj[entry.key] = switch (v) {
      String s => s.toJS,
      bool b => b.toJS,
      int i => i.toJS,
      double d => d.toJS,
      _ => throw ArgumentError('Unsupported JS value type: ${v.runtimeType}'),
    };
  }
  return obj;
}

/// Attempts to extract an [AuthError]-compatible message from a Clerk JS
/// error object (the rejection reason of a JS Promise).
///
/// Clerk JS errors typically have shape:
/// ```json
/// { "errors": [{ "code": "...", "message": "...", "longMessage": "..." }] }
/// ```
({String message, String? argument, String? code}) parseClerkJsError(
  Object error,
) {
  try {
    final jsError = error as JSAny;
    if (!jsError.isA<JSObject>()) {
      return (message: error.toString(), argument: null, code: null);
    }
    final jsObj = jsError as JSObject;
    final errorsRaw = jsObj['errors'];
    if (errorsRaw == null || !errorsRaw.isA<JSArray>()) {
      return (message: error.toString(), argument: null, code: null);
    }
    final errorsArray = errorsRaw as JSArray<JSObject>;
    if (errorsArray.length > 0) {
      final first = errorsArray.toDart[0];
      final code = (first['code'] as JSString?)?.toDart;
      final message = (first['message'] as JSString?)?.toDart;
      final longMessage = (first['longMessage'] as JSString?)?.toDart;
      return (
        message: message ?? 'Unknown Clerk error',
        argument: longMessage ?? message,
        code: code,
      );
    }
  } catch (_) {
    // Fall through to default
  }
  return (message: error.toString(), argument: null, code: null);
}
