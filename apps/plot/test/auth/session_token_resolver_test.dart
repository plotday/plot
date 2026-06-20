import 'package:flutter_test/flutter_test.dart';

import 'package:plot/auth/auth_service_interface.dart';
import 'package:plot/auth/session_token_resolver.dart';

/// Hand-written fake (the codebase uses no mocking library — pure-function
/// policy is tested with fakes). Models clerk_auth's observable surface:
/// [isSignedIn] can flip after a successful [refreshClient], [fetchToken] and
/// [refreshClient] can throw, and a configurable set of errors is treated as
/// non-recoverable.
class _FakeOps implements SessionOps {
  _FakeOps({
    this.signedIn = true,
    this.token,
    this.tokenError,
    this.refreshError,
    this.signedInAfterRefresh,
    this.nonRecoverable = const {},
  });

  bool signedIn;
  final String? token;
  final Object? tokenError;
  final Object? refreshError;

  /// Value [isSignedIn] takes after a *successful* [refreshClient] (simulates
  /// the server reconciling the client to signed-in or signed-out).
  final bool? signedInAfterRefresh;
  final Set<Object> nonRecoverable;

  int fetchCalls = 0;
  int refreshCalls = 0;

  @override
  bool get isSignedIn => signedIn;

  @override
  Future<String> fetchToken() async {
    fetchCalls++;
    final err = tokenError;
    if (err != null) throw err;
    final t = token;
    if (t == null) throw StateError('no token configured for fetchToken');
    return t;
  }

  @override
  Future<void> refreshClient() async {
    refreshCalls++;
    final err = refreshError;
    if (err != null) throw err;
    if (signedInAfterRefresh != null) signedIn = signedInAfterRefresh!;
  }

  @override
  bool isNonRecoverable(Object error) => nonRecoverable.contains(error);
}

void main() {
  // Distinct sentinel errors so the fake can classify them.
  final networkErr = Exception('Could not connect');
  final invalidErr = Exception('authentication_invalid');

  group('resolveSessionToken', () {
    test('signed in with a valid token returns the token (no reconcile)',
        () async {
      final ops = _FakeOps(signedIn: true, token: 'jwt-123');
      var invalidCalled = false;

      final result = await resolveSessionToken(
        ops,
        forceRefresh: false,
        onSessionInvalid: (_) => invalidCalled = true,
      );

      expect(result.token, 'jwt-123');
      expect(result.failure, isNull);
      expect(invalidCalled, isFalse);
      expect(ops.refreshCalls, 0, reason: 'no reconcile needed when signed in');
    });

    // THE REGRESSION GUARD. Prod incident: an overnight network outage made
    // clerk_auth transiently report !isSignedIn; the old code returned
    // sessionInvalid and force-signed the user out even though Clerk's server
    // never revoked the session. A reconcile that cannot reach the server is
    // NOT confirmation — it must be networkError so the user stays signed in.
    test('NOT signed in + server unreachable → networkError, NOT '
        'sessionInvalid, and does not signal invalid', () async {
      final ops = _FakeOps(signedIn: false, refreshError: networkErr);
      var invalidCalled = false;

      final result = await resolveSessionToken(
        ops,
        forceRefresh: false,
        onSessionInvalid: (_) => invalidCalled = true,
      );

      expect(result.failure, TokenFailureReason.networkError);
      expect(result.token, isNull);
      expect(invalidCalled, isFalse,
          reason: 'never force sign-out on an unconfirmed local flag');
      expect(ops.refreshCalls, 1, reason: 'attempted server reconcile');
    });

    test('NOT signed in + reconcile reaches server and confirms signed-out → '
        'sessionInvalid (with cause)', () async {
      final ops = _FakeOps(signedIn: false, signedInAfterRefresh: false);
      String? cause;

      final result = await resolveSessionToken(
        ops,
        forceRefresh: false,
        onSessionInvalid: (c) => cause = c,
      );

      expect(result.failure, TokenFailureReason.sessionInvalid);
      expect(cause, isNotNull,
          reason: 'cause string is logged so PostHog shows WHY');
    });

    test('NOT signed in + reconcile restores the session → returns token',
        () async {
      final ops = _FakeOps(
        signedIn: false,
        signedInAfterRefresh: true,
        token: 'jwt-after-reconcile',
      );

      final result = await resolveSessionToken(ops, forceRefresh: false);

      expect(result.token, 'jwt-after-reconcile');
      expect(result.failure, isNull);
      expect(ops.refreshCalls, 1);
      expect(ops.fetchCalls, 1);
    });

    test('NOT signed in + reconcile throws a non-recoverable error → '
        'sessionInvalid', () async {
      final ops = _FakeOps(
        signedIn: false,
        refreshError: invalidErr,
        nonRecoverable: {invalidErr},
      );

      final result = await resolveSessionToken(ops, forceRefresh: false);

      expect(result.failure, TokenFailureReason.sessionInvalid);
    });

    test('signed in + fetchToken throws non-recoverable → sessionInvalid',
        () async {
      final ops = _FakeOps(
        signedIn: true,
        tokenError: invalidErr,
        nonRecoverable: {invalidErr},
      );

      final result = await resolveSessionToken(ops, forceRefresh: false);

      expect(result.failure, TokenFailureReason.sessionInvalid);
    });

    test('signed in + fetchToken transient + recovery cannot reach server → '
        'networkError (stay signed in)', () async {
      final ops = _FakeOps(
        signedIn: true,
        tokenError: networkErr,
        refreshError: networkErr,
      );
      var invalidCalled = false;

      final result = await resolveSessionToken(
        ops,
        forceRefresh: false,
        onSessionInvalid: (_) => invalidCalled = true,
      );

      expect(result.failure, TokenFailureReason.networkError);
      expect(invalidCalled, isFalse);
    });

    test('forceRefresh + server unreachable but local session present → '
        'still tries cached token and succeeds', () async {
      // forceRefresh reconciles first; a network failure there is NOT fatal —
      // the cached token may still work for the immediate retry.
      final ops = _FakeOps(
        signedIn: true,
        refreshError: networkErr,
        token: 'cached-jwt',
      );

      final result = await resolveSessionToken(ops, forceRefresh: true);

      expect(result.token, 'cached-jwt');
      expect(result.failure, isNull);
      expect(ops.refreshCalls, 1, reason: 'forceRefresh reconciles first');
    });

    test('forceRefresh + reconcile reaches server and confirms signed-out → '
        'sessionInvalid', () async {
      final ops = _FakeOps(signedIn: true, signedInAfterRefresh: false);

      final result = await resolveSessionToken(ops, forceRefresh: true);

      expect(result.failure, TokenFailureReason.sessionInvalid);
    });
  });
}
