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
import 'package:plot/auth/clerk_session_ops.dart';
import 'package:plot/auth/session_token_resolver.dart';
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
  // Preserve the specific server code (e.g. `authorization_invalid`) for
  // telemetry; [_mapErrorCode] otherwise flattens it to serverErrorResponse.
  clerkCode: e.errors?.error.code,
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
  }) {
    // Delegates to the shared resolver policy ([resolveSessionToken]). The key
    // invariant: NEVER report [TokenFailureReason.sessionInvalid] without
    // server confirmation. A bare `!_auth.isSignedIn` is NOT confirmation —
    // clerk_auth reports it transiently while offline, and the previous
    // early-return here force-signed users out during network outages even
    // though Clerk's server never revoked the session. The resolver reconciles
    // with the server before concluding the session is dead, and only treats a
    // reachable-server "no session" (or a non-recoverable Clerk error) as
    // [sessionInvalid]; an unreachable server is [networkError] (stay signed
    // in, retry). The [onSessionInvalid] callback logs the cause at WARNING so
    // error tracking shows *why* re-auth was forced — the old `!isSignedIn`
    // path was silent, leaving no breadcrumb.
    return resolveSessionToken(
      ClerkSessionOps(_auth),
      forceRefresh: forceRefresh,
      onSessionInvalid: (cause) =>
          log.warning('Forcing re-auth — session confirmed invalid: $cause'),
    );
  }

  /// Guarantee the Clerk client (and its client token) is established before
  /// an id-token sign-in/up.
  ///
  /// `clerk_auth`'s `Auth.initialize()` fetches the client via
  /// `_fetchClientAndEnv()`, which **silently swallows any exception** and
  /// returns `Client.empty` — so a single failed/timed-out `/v1/client` call
  /// (most likely on a cold first launch: fresh install, new VM, flaky first
  /// TLS handshake) leaves the Api token cache with no client token. The next
  /// FAPI request (`createSignIn`) then goes out **without** the
  /// `Authorization` header, and Clerk rejects it with "You are not authorized
  /// to perform this request" (`authorization_invalid`). This surfaced on
  /// Windows/Linux Google sign-in as a hard failure even once the id_token
  /// audience was correct, because [_reinitialize] deletes the cache and
  /// re-inits on every fresh sign-in, re-running the swallow-prone fetch.
  ///
  /// Force-create the client and confirm it actually stuck; if it can't be
  /// established, fail with a clear, user-actionable error instead of firing
  /// an unauthenticated sign-in that 401s with an opaque message.
  Future<void> _ensureClientEstablished() async {
    if (_auth.client.isNotEmpty) return;
    await _auth.resetClient();
    if (_auth.client.isEmpty) {
      throw const AuthError(
        message:
            'Could not reach the sign-in service. '
            'Check your connection and try again.',
      );
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
        // Reinitialise can leave the client un-established if clerk_auth
        // silently swallowed a failed client fetch; without a client token the
        // sign-in below 401s as authorization_invalid.
        await _ensureClientEstablished();
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
        await _ensureClientEstablished();
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
  Future<void> setUserPassword({required String password}) => _guard(() async {
        // Clerk refuses `password` on PATCH /me ("Password is not a valid
        // parameter and can only be updated via /v1/me/change_password"),
        // so we use that endpoint. The SDK's `updateUserPassword` requires
        // a current password; users that just verified their email don't
        // have one yet, so we POST directly and omit `current_password`.
        await _auth.fetchApiResponse(
          '/me/change_password',
          method: clerk.HttpMethod.post,
          withSession: true,
          params: {
            'new_password': password,
            'sign_out_of_other_sessions': false,
          },
        );
      });

  @override
  Future<void> refreshClient() => _guard(() => _auth.refreshClient());

  @override
  Future<void> resetClient() => _guard(() => _auth.resetClient());

  @override
  Future<void> signOut() => _guard(() => _auth.signOut());
}
