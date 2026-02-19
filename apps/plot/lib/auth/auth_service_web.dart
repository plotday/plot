/// Web [AuthService] implementation backed by Clerk JS.
///
/// Clerk JS handles session management (cookies), token refresh, and OAuth
/// flows natively in the browser — unlike the `clerk_auth` Dart package which
/// makes raw HTTP calls.
///
/// DO NOT import this file directly — import `auth_service.dart` instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'auth_service_interface.dart';
import 'clerk_js_interop.dart';

// ---------------------------------------------------------------------------
// Clerk JS script loading
// ---------------------------------------------------------------------------

/// Derives the Clerk Frontend API domain from a publishable key.
///
/// Clerk publishable keys have format: `pk_<env>_<base64(domain$)>`
String _fapiDomain(String publishableKey) {
  final encoded = publishableKey.split('_').last;
  final decoded = utf8.decode(base64.decode(base64.normalize(encoded)));
  return decoded.endsWith('\$')
      ? decoded.substring(0, decoded.length - 1)
      : decoded;
}

/// Dynamically loads the Clerk JS SDK from the Clerk FAPI CDN.
///
/// Clerk JS must be loaded from its FAPI CDN (derived from the publishable key)
/// to enable cookie-based session management on the correct domain.
Future<void> _loadClerkJs(String publishableKey) async {
  // Skip if already loaded.
  if (globalContext['Clerk'] != null) return;

  final domain = _fapiDomain(publishableKey);
  final url = 'https://$domain/npm/@clerk/clerk-js@5/dist/clerk.browser.js';

  final completer = Completer<void>();
  final script = web.document.createElement('script') as web.HTMLScriptElement;
  script.src = url;
  script.crossOrigin = 'anonymous';
  script.setAttribute('data-clerk-publishable-key', publishableKey);
  script.addEventListener(
    'load',
    ((web.Event e) => completer.complete()).toJS,
  );
  script.addEventListener(
    'error',
    ((web.Event e) => completer.completeError(
          AuthError(message: 'Failed to load Clerk JS from $url'),
        )).toJS,
  );
  web.document.head!.append(script);
  await completer.future;
}

/// Factory called by the conditional-import dispatcher in auth_service.dart.
Future<AuthService> createAuthServiceImpl({
  required String publishableKey,
  // [profile] is unused on web — Clerk JS manages its own persistence.
  String? profile,
}) async {
  await _loadClerkJs(publishableKey);
  // Access the auto-initialized Clerk instance from window.Clerk.
  final clerk = globalContext['Clerk'] as ClerkJS;
  await clerk.load().toDart;
  return ClerkJsAuthService._(clerk);
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

AuthErrorCode _mapJsErrorCode(String? code) => switch (code) {
  'strategy_for_user_invalid' => AuthErrorCode.noSuchFirstFactorStrategy,
  'form_strategy_not_found' => AuthErrorCode.noSuchFirstFactorStrategy,
  'external_account_not_found' => AuthErrorCode.noAssociatedStrategy,
  'clerk_server_error' => AuthErrorCode.serverErrorResponse,
  _ => AuthErrorCode.unknown,
};

AuthError _toAuthError(Object error) {
  final parsed = parseClerkJsError(error);
  return AuthError(
    message: parsed.message,
    argument: parsed.argument,
    code: _mapJsErrorCode(parsed.code),
  );
}

/// Wraps an async block, catching JS errors and rethrowing as [AuthError].
Future<T> _guard<T>(Future<T> Function() fn) async {
  try {
    return await fn();
  } on AuthError {
    rethrow;
  } catch (e) {
    throw _toAuthError(e);
  }
}

/// Safely casts a [JSAny?] to a [SignInJS], throwing [AuthError] if the
/// result is not the expected type (e.g. Clerk returned an error object).
SignInJS _asSignIn(JSAny? result) {
  if (result != null && result.isA<JSObject>()) return result as SignInJS;
  throw AuthError(message: 'Unexpected sign-in response from Clerk');
}

/// Safely casts a [JSAny?] to a [SignUpJS].
SignUpJS _asSignUp(JSAny? result) {
  if (result != null && result.isA<JSObject>()) return result as SignUpJS;
  throw AuthError(message: 'Unexpected sign-up response from Clerk');
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

class ClerkJsAuthService implements AuthService {
  ClerkJsAuthService._(this._clerk);

  final ClerkJS _clerk;

  /// The current sign-in object from a multi-step flow (e.g. email → password).
  SignInJS? _pendingSignIn;

  /// The current sign-up object from a multi-step flow (e.g. email OTP → password).
  SignUpJS? _pendingSignUp;

  // -- State -----------------------------------------------------------------

  @override
  bool get isSignedIn => _clerk.session != null;

  @override
  List<String>? get signUpMissingFields {
    final signUp = _pendingSignUp;
    if (signUp == null) return null;
    final fields = signUp.missingFields;
    if (fields == null) return null;
    return [for (final f in fields.toDart) f.toDart];
  }

  @override
  bool get needsSecondFactor => _pendingSignIn?.status == 'needs_second_factor';

  @override
  Future<String?> getSessionToken() async {
    final session = _clerk.session;
    if (session == null) return null;
    try {
      final result = await session.getToken().toDart;
      return (result as JSString?)?.toDart;
    } catch (_) {
      return null;
    }
  }

  // -- Activate session after completion -------------------------------------

  Future<void> _activateIfComplete(String? status, String? sessionId) async {
    if (status == 'complete' && sessionId != null) {
      await _clerk.setActive(jsObj({'session': sessionId})).toDart;
    }
  }

  // -- Sign-in ---------------------------------------------------------------

  @override
  Future<void> signInWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      _guard(() async {
        final strategy = switch (provider) {
          IdTokenProvider.google => 'google_one_tap',
          IdTokenProvider.apple => 'oauth_token_apple',
        };

        final result = _asSignIn(await _clerk.client!.signIn!
            .create(jsObj({
              'strategy': strategy,
              'token': idToken,
            }))
            .toDart);

        _pendingSignIn = result;
        await _activateIfComplete(result.status, result.createdSessionId);
      });

  @override
  Future<void> signUpWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      _guard(() async {
        final strategy = switch (provider) {
          IdTokenProvider.google => 'google_one_tap',
          IdTokenProvider.apple => 'oauth_token_apple',
        };

        final result = _asSignUp(await _clerk.client!.signUp!
            .create(jsObj({
              'strategy': strategy,
              'token': idToken,
            }))
            .toDart);

        _pendingSignUp = result;
        await _activateIfComplete(result.status, result.createdSessionId);
      });

  @override
  Future<void> attemptSignIn({
    required AuthStrategy strategy,
    String? identifier,
    String? password,
  }) =>
      _guard(() async {
        switch (strategy) {
          case AuthStrategy.emailAddress:
            // Step 1: identify by email — creates a sign-in resource.
            final result = _asSignIn(await _clerk.client!.signIn!
                .create(jsObj({'identifier': identifier}))
                .toDart);
            _pendingSignIn = result;

          case AuthStrategy.password:
            // Step 2: attempt first factor with password.
            final si = _pendingSignIn ?? _clerk.client!.signIn!;
            final result = _asSignIn(await si
                .attemptFirstFactor(jsObj({
                  'strategy': 'password',
                  'password': password,
                }))
                .toDart);
            _pendingSignIn = result;
            await _activateIfComplete(result.status, result.createdSessionId);

          case AuthStrategy.emailCode:
            // Not used for sign-in in the current app.
            throw AuthError(message: 'emailCode strategy not supported for sign-in');
        }
      });

  @override
  Future<void> prepareSecondFactor() => _guard(() async {
        final si = _pendingSignIn;
        if (si == null) {
          throw AuthError(message: 'No active sign-in session');
        }
        _pendingSignIn = _asSignIn(await si
            .prepareSecondFactor(jsObj({'strategy': 'email_code'}))
            .toDart);
      });

  @override
  Future<void> attemptSecondFactor({required String code}) =>
      _guard(() async {
        final si = _pendingSignIn;
        if (si == null) {
          throw AuthError(message: 'No active sign-in session');
        }
        final result = _asSignIn(await si
            .attemptSecondFactor(
                jsObj({'strategy': 'email_code', 'code': code}))
            .toDart);
        _pendingSignIn = result;
        await _activateIfComplete(result.status, result.createdSessionId);
      });

  @override
  Future<void> attemptSignUp({
    required AuthStrategy strategy,
    String? emailAddress,
    String? code,
    String? password,
    String? passwordConfirmation,
    String? firstName,
    String? lastName,
  }) =>
      _guard(() async {
        switch (strategy) {
          case AuthStrategy.emailCode when emailAddress != null:
            // Start sign-up + prepare email verification in one go.
            final signUp = _asSignUp(await _clerk.client!.signUp!
                .create(jsObj({'emailAddress': emailAddress}))
                .toDart);
            _pendingSignUp = signUp;
            // Ask Clerk to send the verification code.
            _pendingSignUp = _asSignUp(await signUp
                .prepareEmailAddressVerification(
                    jsObj({'strategy': 'email_code'}))
                .toDart);

          case AuthStrategy.emailCode when code != null:
            // Verify the emailed OTP code.
            final su = _pendingSignUp;
            if (su == null) {
              throw AuthError(message: 'No active sign-up session');
            }
            final result = _asSignUp(
                await su.attemptEmailAddressVerification(jsObj({'code': code})).toDart);
            _pendingSignUp = result;
            await _activateIfComplete(result.status, result.createdSessionId);

          case AuthStrategy.emailCode:
            throw AuthError(
                message: 'emailCode strategy requires emailAddress or code');

          case AuthStrategy.password:
            // Complete sign-up by providing password (and optionally name).
            final su = _pendingSignUp;
            if (su == null) {
              throw AuthError(message: 'No active sign-up session');
            }
            final result = _asSignUp(await su
                .update(jsObj({
                  'password': password,
                  if (passwordConfirmation != null)
                    'passwordConfirmation': passwordConfirmation,
                  if (firstName != null) 'firstName': firstName,
                  if (lastName != null) 'lastName': lastName,
                }))
                .toDart);
            _pendingSignUp = result;
            await _activateIfComplete(result.status, result.createdSessionId);

          case AuthStrategy.emailAddress:
            throw AuthError(
                message: 'emailAddress strategy not supported for sign-up');
        }
      });

  @override
  Future<void> transfer() => _guard(() async {
        // Only transfer if needed — mirrors the native clerk_auth behavior
        // which checks isTransferable before calling the API. If the sign-in
        // already completed (e.g. google_one_tap), calling transfer would fail
        // with "not authorized" since the session is already active.
        if (_pendingSignIn?.status == 'complete' ||
            _pendingSignUp?.status == 'complete') {
          return;
        }
        final result = _asSignIn(await _clerk.client!.signIn!
            .create(jsObj({'transfer': true}))
            .toDart);
        _pendingSignIn = result;
        await _activateIfComplete(result.status, result.createdSessionId);
      });

  // -- User management -------------------------------------------------------

  @override
  Future<void> updateUser({String? firstName, String? lastName}) =>
      _guard(() async {
        final user = _clerk.user;
        if (user == null) {
          throw AuthError(message: 'No signed-in user to update');
        }
        await user
            .update(jsObj({
              if (firstName != null) 'firstName': firstName,
              if (lastName != null) 'lastName': lastName,
            }))
            .toDart;
      });

  // -- Client management -----------------------------------------------------

  @override
  Future<void> refreshClient() async {
    // Clerk JS auto-manages client state; no action needed.
  }

  @override
  Future<void> resetClient() async {
    // Reset pending state so the next sign-up starts fresh.
    _pendingSignIn = null;
    _pendingSignUp = null;
  }

  @override
  Future<void> signOut() => _guard(() async {
        _pendingSignIn = null;
        _pendingSignUp = null;
        await _clerk.signOut().toDart;
      });
}
