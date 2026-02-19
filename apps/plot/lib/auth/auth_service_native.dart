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
  await clerkAuth.initialize();

  return ClerkDartAuthService._(clerkAuth);
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
  ClerkDartAuthService._(this._auth);

  final clerk.Auth _auth;

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
    try {
      final token = await _auth.sessionToken();
      return token.jwt;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> signInWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      _guard(() => _auth.idTokenSignIn(
            provider: _toClerkProvider(provider),
            idToken: idToken,
          ));

  @override
  Future<void> signUpWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      _guard(() => _auth.idTokenSignUp(
            provider: _toClerkProvider(provider),
            idToken: idToken,
          ));

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
