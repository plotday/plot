/// Native (non-web) [AuthService] implementation.
///
/// Wraps the `clerk_auth` Dart package which makes HTTP calls to Clerk's
/// Frontend API. Used on macOS, iOS, Android, Windows, and Linux.
///
/// DO NOT import this file directly — import `auth_service.dart` instead.
library;

import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:path_provider/path_provider.dart';

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

  final clerkAuth = clerk.Auth(
    config: clerk.AuthConfig(
      publishableKey: publishableKey,
      persistor: persistor,
    ),
  );

  final service = ClerkDartAuthService._(clerkAuth, publishableKey, profile);

  await clerkAuth.initialize().timeout(const Duration(seconds: 10));
  return service;
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
};

clerk.IdTokenProvider _toClerkProvider(IdTokenProvider p) => switch (p) {
  IdTokenProvider.google => clerk.IdTokenProvider.google,
  IdTokenProvider.apple => clerk.IdTokenProvider.apple,
};

AuthErrorCode _mapErrorCode(clerk.ClerkErrorCode? code) => switch (code) {
  clerk.ClerkErrorCode.noSuchFirstFactorStrategy =>
    AuthErrorCode.noSuchFirstFactorStrategy,
  clerk.ClerkErrorCode.noAssociatedStrategy =>
    AuthErrorCode.noAssociatedStrategy,
  clerk.ClerkErrorCode.serverErrorResponse =>
    AuthErrorCode.serverErrorResponse,
  _ => AuthErrorCode.unknown,
};

AuthError _wrapClerkError(clerk.ClerkError e) => AuthError(
  message: e.message,
  argument: e.argument,
  code: _mapErrorCode(e.code),
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
  ClerkDartAuthService._(this._auth, this._publishableKey, this._profile);

  clerk.Auth _auth;
  final String _publishableKey;
  final String? _profile;

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
    _auth = clerk.Auth(
      config: clerk.AuthConfig(
        publishableKey: _publishableKey,
        persistor: persistor,
      ),
    );
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
  Future<TokenResult> getSessionTokenWithReason() async {
    try {
      final token = await _auth.sessionToken();
      return (token: token.jwt, failure: null);
    } on clerk.ClerkError catch (e) {
      log.warning('Session token request failed (ClerkError): $e');

      // Clerk 5xx = transient server error, not a dead session.
      if (e.code == clerk.ClerkErrorCode.serverErrorResponse) {
        return (token: null, failure: TokenFailureReason.networkError);
      }

      // Clerk returned a definitive error. Try recovery via refreshClient.
      try {
        log.info('Attempting session recovery via refreshClient');
        await _auth.refreshClient();
        final token = await _auth.sessionToken();
        log.info('Session recovery succeeded');
        return (token: token.jwt, failure: null);
      } on clerk.ClerkError catch (recoveryError) {
        // Recovery also got a ClerkError — if it's not a server error,
        // the session is definitively dead.
        if (recoveryError.code == clerk.ClerkErrorCode.serverErrorResponse) {
          return (token: null, failure: TokenFailureReason.networkError);
        }
        log.warning('Session recovery failed (ClerkError): $recoveryError');
        return (token: null, failure: TokenFailureReason.sessionInvalid);
      } catch (recoveryError) {
        // Network error during recovery — transient.
        log.warning('Session recovery failed (network): $recoveryError');
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
          idToken: idToken,
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
