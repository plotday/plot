/// [SessionOps] backed by a `clerk_auth` [clerk.Auth] instance.
///
/// Used by BOTH the native auth service and the background FCM isolate so the
/// session-resolution policy in [resolveSessionToken] is identical in the
/// foreground and background — the background handler used to apply a much
/// blunter "any failure means signed out" rule, which over-fired the
/// "Plot signed out" notification on transient network failures.
library;

import 'package:clerk_auth/clerk_auth.dart' as clerk;

import 'auth_error_classifier.dart';
import 'session_token_resolver.dart';

class ClerkSessionOps implements SessionOps {
  ClerkSessionOps(this._auth);

  final clerk.Auth _auth;

  @override
  bool get isSignedIn => _auth.isSignedIn;

  @override
  Future<String> fetchToken() async {
    final token = await _auth.sessionToken();
    return token.jwt;
  }

  @override
  Future<void> refreshClient() => _auth.refreshClient();

  @override
  bool isNonRecoverable(Object error) =>
      error is clerk.ClerkError && isNonRecoverableAuthError(error);
}
