/// Native (non-web) [AuthService] implementation.
///
/// Wraps the `clerk_auth` Dart package which makes HTTP calls to Clerk's
/// Frontend API. Used on macOS, iOS, Android, Windows, and Linux.
///
/// DO NOT import this file directly — import `auth_service.dart` instead.
library;

import 'dart:async';
import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:path_provider/path_provider.dart';

import 'package:plot/auth/auth_error_classifier.dart';
import 'package:plot/logging.dart';

import 'auth_service_interface.dart';

/// Factory called by the conditional-import dispatcher in auth_service.dart.
Future<AuthService> createAuthServiceImpl({
  required String publishableKey,
  String? profile,
}) async {
  final cacheDir = await _getClerkCacheDirectory(profile);
  final persistor = clerk.DefaultPersistor(
    getCacheDirectory: () async => cacheDir,
  );

  final sessionInvalidated = StreamController<void>.broadcast();
  final clerkAuth = _PlotClerkAuth(
    config: clerk.AuthConfig(
      publishableKey: publishableKey,
      persistor: persistor,
    ),
    onSessionInvalidated: () => sessionInvalidated.add(null),
  );

  final service = ClerkDartAuthService._(
    clerkAuth,
    publishableKey,
    profile,
    sessionInvalidated,
  );

  await clerkAuth.initialize().timeout(const Duration(seconds: 10));
  return service;
}

/// `clerk_auth`'s default [clerk.Auth.handleError] just rethrows. That works
/// for inline callers wrapped in try/catch, but the periodic
/// `_pollForSessionToken` runs from a [Timer] callback — when its renewal
/// hits `authentication_invalid` / `signed_out`, the throw escapes into the
/// zone unhandled. The app never finds out the session is dead and the
/// timer keeps re-arming, generating a recurring storm of identical errors.
///
/// This subclass intercepts those errors and notifies [Base] via
/// [onSessionInvalidated] so we can force sign-out, then preserves the throw
/// so existing inline callers (sign-in flow, [_guard]) keep working. The
/// classification rule lives in [isNonRecoverableAuthError] so that both
/// of clerk_auth's error-wrapping paths are handled — see that function's
/// doc comment for the gory details.
class _PlotClerkAuth extends clerk.Auth {
  _PlotClerkAuth({
    required super.config,
    required this.onSessionInvalidated,
  });

  final void Function() onSessionInvalidated;

  @override
  void handleError(Object error) {
    if (error is clerk.ClerkError && isNonRecoverableAuthError(error)) {
      onSessionInvalidated();
    }
    super.handleError(error);
  }
}

Future<Directory> _getClerkCacheDirectory(String? profile) async {
  final appSupport = await getApplicationSupportDirectory();
  final dirName = profile != null ? 'clerk_profile_$profile' : 'clerk';
  final dir = Directory('${appSupport.path}/$dirName');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

// ---------------------------------------------------------------------------
// Strategy / provider mapping helpers
// ---------------------------------------------------------------------------

clerk.Strategy _toClerkStrategy(AuthStrategy s) => switch (s) {
  AuthStrategy.emailAddress => clerk.Strategy.emailAddress,
  AuthStrategy.password => clerk.Strategy.password,
  AuthStrategy.emailCode => clerk.Strategy.emailCode,
  AuthStrategy.resetPasswordEmailCode => clerk.Strategy.resetPasswordEmailCode,
};

clerk.IdTokenProvider _toClerkProvider(IdTokenProvider p) => switch (p) {
  IdTokenProvider.google => clerk.IdTokenProvider.google,
  IdTokenProvider.apple => clerk.IdTokenProvider.apple,
};

AuthErrorCode _mapErrorCode(clerk.ClerkError e) {
  // For server-side errors, inspect the individual Clerk error codes returned
  // by the API (e.g. 'external_account_not_found') so they can be mapped to
  // the correct AuthErrorCode rather than falling through as serverErrorResponse.
  if (e.code == clerk.ClerkErrorCode.serverErrorResponse) {
    final clerkCode = e.errors?.error.code;
    if (clerkCode == 'external_account_not_found') {
      return AuthErrorCode.noAssociatedStrategy;
    }
    return AuthErrorCode.serverErrorResponse;
  }
  return switch (e.code) {
    clerk.ClerkErrorCode.noSuchFirstFactorStrategy =>
      AuthErrorCode.noSuchFirstFactorStrategy,
    clerk.ClerkErrorCode.noAssociatedStrategy =>
      AuthErrorCode.noAssociatedStrategy,
    _ => AuthErrorCode.unknown,
  };
}

AuthError _wrapClerkError(clerk.ClerkError e) => AuthError(
  message: e.message,
  argument: e.argument,
  code: _mapErrorCode(e),
);

/// Wraps a function that may throw [clerk.ClerkError] and re-throws as
/// [AuthError].
Future<T> _guard<T>(Future<T> Function() fn) async {
  try {
    return await fn();
  } on clerk.ClerkError catch (e) {
    throw _wrapClerkError(e);
  }
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

class ClerkDartAuthService implements AuthService {
  ClerkDartAuthService._(
    this._auth,
    this._publishableKey,
    this._profile,
    this._sessionInvalidated,
  );

  clerk.Auth _auth;
  final String _publishableKey;
  final String? _profile;
  final StreamController<void> _sessionInvalidated;

  @override
  Stream<void> get sessionInvalidatedStream => _sessionInvalidated.stream;

  _PlotClerkAuth _buildAuth(clerk.Persistor persistor) => _PlotClerkAuth(
        config: clerk.AuthConfig(
          publishableKey: _publishableKey,
          persistor: persistor,
        ),
        onSessionInvalidated: () {
          if (!_sessionInvalidated.isClosed) {
            _sessionInvalidated.add(null);
          }
        },
      );

  /// Create a fresh Clerk [Auth] instance, discarding any stale state.
  ///
  /// The `clerk_auth` package has a bug where [Auth.signOut] can leave stale
  /// client tokens in the token cache if the DELETE `/client` call returns a
  /// non-200 response. Subsequent API calls then use the invalid token and
  /// fail with "not authorized". Reinitialising with a clean cache file
  /// ensures a fresh client token is obtained.
  Future<void> _reinitialize() async {
    _auth.terminate();

    final cacheDir = await _getClerkCacheDirectory(_profile);
    final cacheFile = File('${cacheDir.path}/clerk_sdk.json');
    if (cacheFile.existsSync()) {
      cacheFile.deleteSync();
    }

    final persistor = clerk.DefaultPersistor(
      getCacheDirectory: () async => cacheDir,
    );
    _auth = _buildAuth(persistor);
    await _auth.initialize().timeout(const Duration(seconds: 10));
  }

  @override
  bool get isSignedIn => _auth.isSignedIn;

  @override
  List<String>? get signUpMissingFields =>
      _auth.client.signUp?.missingFields.map((f) => f.name).toList();

  @override
  bool get needsSecondFactor =>
      _auth.client.signIn?.needsSecondFactor == true;

  @override
  Future<String?> getSessionToken() async {
    final result = await getSessionTokenWithReason();
    return result.token;
  }

  @override
  Future<TokenResult> getSessionTokenWithReason({
    bool forceRefresh = false,
  }) async {
    // If clerk_auth has no local session, `_auth.sessionToken()` throws a
    // generic `noSessionTokenRetrieved` error that isn't recognised as
    // non-recoverable (see [isNonRecoverableAuthError] doc — that code is
    // intentionally treated as transient because outages can also surface
    // it). Without this early-return we'd retry forever in the sync layer.
    // The state happens whenever the SDK couldn't load or kept no usable
    // session at startup — e.g. a build pointed at a different Clerk
    // environment from the one that wrote the cache, or a sign-out that
    // didn't fully tear local identity down. The web implementation
    // already does the same null-session check.
    if (!_auth.isSignedIn) {
      return (token: null, failure: TokenFailureReason.sessionInvalid);
    }

    // The sync layer calls with [forceRefresh] = true after the API
    // returns 401 — we *know* the previous token was rejected, so the
    // locally cached JWT (which `_auth.sessionToken()` would otherwise
    // hand right back) is suspect. Reconcile with Clerk's server first
    // so a revoked session surfaces as `authentication_invalid` here
    // instead of silently looping at the sync layer.
    if (forceRefresh) {
      try {
        log.info('Forcing session reconciliation via refreshClient');
        await _auth.refreshClient();
      } on clerk.ClerkError catch (e) {
        log.warning('Forced refreshClient failed (ClerkError): $e');
        if (isNonRecoverableAuthError(e)) {
          return (token: null, failure: TokenFailureReason.sessionInvalid);
        }
        // Transient — let the normal sessionToken() path try its luck.
      } catch (e) {
        log.warning('Forced refreshClient failed (network): $e');
        // Don't return early on a generic network error — the cached
        // token might still work for the immediate retry, and if not
        // the sessionToken() call below will surface the real failure.
      }
      // After a successful refreshClient, Clerk may have learned the
      // session is gone (`isSignedIn` flips to false). Skip the token
      // fetch in that case and report sessionInvalid directly.
      if (!_auth.isSignedIn) {
        return (token: null, failure: TokenFailureReason.sessionInvalid);
      }
    }

    try {
      final token = await _auth.sessionToken();
      return (token: token.jwt, failure: null);
    } on clerk.ClerkError catch (e) {
      log.warning('Session token request failed (ClerkError): $e');

      // If the first error is already non-recoverable (server explicitly
      // repudiated the session), don't bother attempting refresh — refresh
      // would hit the same 401, and the longer we delay surfacing
      // [TokenFailureReason.sessionInvalid] the longer the caller spins
      // retrying with a token that will never come.
      if (isNonRecoverableAuthError(e)) {
        return (token: null, failure: TokenFailureReason.sessionInvalid);
      }

      // First error was transient-looking (timeout, parser hiccup, SDK
      // state loss after [Auth.initialize] wiped the cached session, etc.).
      // Try a single refresh-and-retry before giving up.
      try {
        log.info('Attempting session recovery via refreshClient');
        await _auth.refreshClient();
        // refreshClient may have reconciled to "no session" without
        // throwing (e.g. server reports the client has no active session
        // for this environment). Calling sessionToken() now would throw
        // the same generic noSessionTokenRetrieved we already saw — and
        // the caller would treat it as transient and loop. Detect the
        // signed-out state directly and return sessionInvalid so Base
        // forces sign-out.
        if (!_auth.isSignedIn) {
          return (token: null, failure: TokenFailureReason.sessionInvalid);
        }
        final token = await _auth.sessionToken();
        log.info('Session recovery succeeded');
        return (token: token.jwt, failure: null);
      } on clerk.ClerkError catch (recoveryError) {
        log.warning('Session recovery failed (ClerkError): $recoveryError');
        // The recovery attempt itself surfaced an authoritative "session is
        // dead" code — treat as definitive.
        if (isNonRecoverableAuthError(recoveryError)) {
          return (token: null, failure: TokenFailureReason.sessionInvalid);
        }
        return (token: null, failure: TokenFailureReason.networkError);
      } catch (recoveryError) {
        log.warning('Session recovery failed: $recoveryError');
        return (token: null, failure: TokenFailureReason.networkError);
      }
    } catch (e) {
      // SocketException, TimeoutException, DNS failures, etc.
      log.warning('Session token request failed (network): $e');
      return (token: null, failure: TokenFailureReason.networkError);
    }
  }

  @override
  Future<void> signInWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      _guard(() async {
        // After sign-out, clerk_auth can leave stale client tokens that cause
        // "not authorized" errors. Reinitialise to ensure a clean client.
        if (!_auth.isSignedIn) {
          await _reinitialize();
        }
        await _auth.idTokenSignIn(
          provider: _toClerkProvider(provider),
          token: idToken,
        );
      });

  @override
  Future<void> signInWithRedirect({required IdTokenProvider provider}) =>
      throw UnsupportedError('signInWithRedirect is only supported on web');

  @override
  Future<void> signUpWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      _guard(() async {
        if (!_auth.isSignedIn) {
          await _reinitialize();
        }
        await _auth.idTokenSignUp(
          provider: _toClerkProvider(provider),
          idToken: idToken,
        );
      });

  @override
  Future<void> attemptSignIn({
    required AuthStrategy strategy,
    String? identifier,
    String? password,
  }) =>
      _guard(() => _auth.attemptSignIn(
            strategy: _toClerkStrategy(strategy),
            identifier: identifier,
            password: password,
          ));

  @override
  Future<void> signInWithTicket({required String ticket}) => _guard(() async {
        // Clerk's ticket strategy isn't exposed through `attemptSignIn` in the
        // Dart SDK, so we drop down to the low-level API. The trailing
        // `_housekeeping` (inside `fetchApiResponse`) creates the session on
        // the Client when Clerk returns `status: 'complete'`.
        await _auth.fetchApiResponse(
          '/client/sign_ins',
          method: clerk.HttpMethod.post,
          params: {
            'strategy': clerk.Strategy.ticket.name,
            'ticket': ticket,
          },
        );
      });

  @override
  Future<void> prepareSecondFactor() =>
      _guard(() => _auth.attemptSignIn(strategy: clerk.Strategy.emailCode));

  @override
  Future<void> attemptSecondFactor({required String code}) =>
      _guard(
          () => _auth.attemptSignIn(strategy: clerk.Strategy.emailCode, code: code));

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
      _guard(() => _auth.attemptSignUp(
            strategy: _toClerkStrategy(strategy),
            emailAddress: emailAddress,
            code: code,
            password: password,
            passwordConfirmation: passwordConfirmation,
            firstName: firstName,
            lastName: lastName,
          ));

  @override
  Future<void> transfer() => _guard(() => _auth.transfer());

  @override
  Future<void> initiatePasswordReset({required String email}) => _guard(
        () => _auth.initiatePasswordReset(
          identifier: email,
          strategy: clerk.Strategy.resetPasswordEmailCode,
        ),
      );

  @override
  Future<void> resetPassword({required String code, required String password}) =>
      _guard(
        () => _auth.attemptSignIn(
          strategy: clerk.Strategy.resetPasswordEmailCode,
          code: code,
          password: password,
        ),
      );

  @override
  Future<void> updateUser({String? firstName, String? lastName}) =>
      _guard(() => _auth.updateUser(
            firstName: firstName,
            lastName: lastName,
          ));

  @override
  Future<void> refreshClient() => _guard(() => _auth.refreshClient());

  @override
  Future<void> resetClient() => _guard(() => _auth.resetClient());

  @override
  Future<void> signOut() => _guard(() => _auth.signOut());
}
