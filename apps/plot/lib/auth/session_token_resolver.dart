/// Session-token resolution policy, shared by the foreground auth service and
/// the background FCM isolate.
///
/// THE RULE: never report [TokenFailureReason.sessionInvalid] without server
/// confirmation. A bare local `!isSignedIn`, a network error, or a timeout is
/// [TokenFailureReason.networkError] — `clerk_auth` can transiently report "no
/// session" while offline, and force-signing-out on that unconfirmed signal
/// kicked a user out overnight (prod incident: an Android device with no
/// connectivity from ~22:53 through ~01:49 force-signed-out at 01:36, yet
/// Clerk's server logs showed the session was never revoked). Only a
/// server-confirmed "no session" — a successful `refreshClient()` that still
/// reports signed-out, or a non-recoverable Clerk error — counts as
/// [sessionInvalid].
library;

import 'auth_service_interface.dart';

/// Low-level session operations the resolver needs, abstracted away from
/// `clerk_auth` so the decision flow is pure and unit-testable without a live
/// Clerk client. The native auth service and the background isolate each
/// supply an adapter backed by their own `clerk.Auth` instance.
abstract class SessionOps {
  /// Whether the client currently believes it has an active session. This is
  /// a *local* flag — it can be transiently false while offline, which is
  /// exactly why [resolveSessionToken] never trusts it on its own.
  bool get isSignedIn;

  /// Fetch a fresh session JWT. Returns the token on success, or throws.
  Future<String> fetchToken();

  /// Reconcile client/session state with Clerk's server. Throws on failure
  /// (network unreachable, timeout, or a Clerk error).
  Future<void> refreshClient();

  /// Classify a thrown error as a definitive, non-recoverable auth failure
  /// (the server repudiated the session). Anything else is transient.
  bool isNonRecoverable(Object error);
}

/// Outcome of a server reconcile ([SessionOps.refreshClient] + re-reading
/// [SessionOps.isSignedIn]).
enum _Reconcile {
  /// Server reached; the session is active.
  signedIn,

  /// Server reached and confirmed there is no active session (or returned a
  /// non-recoverable auth error). Safe to force sign-out.
  confirmedInvalid,

  /// Could not reach the server (network/timeout). Unconfirmed — must NOT be
  /// treated as a sign-out.
  unreachable,
}

/// Resolve a session token, distinguishing transient failures (keep the user
/// signed in and retry) from server-confirmed session invalidation (sign out).
///
/// [onSessionInvalid] is invoked with a short cause string immediately before
/// returning [TokenFailureReason.sessionInvalid], so the caller can log *why*
/// re-auth was forced (the old code's `!isSignedIn` early-return was silent,
/// leaving no breadcrumb in error tracking).
Future<TokenResult> resolveSessionToken(
  SessionOps ops, {
  required bool forceRefresh,
  void Function(String cause)? onSessionInvalid,
}) async {
  TokenResult invalid(String cause) {
    onSessionInvalid?.call(cause);
    return (token: null, failure: TokenFailureReason.sessionInvalid);
  }

  const network = (token: null, failure: TokenFailureReason.networkError);

  // Reconcile with the server when either:
  //  - the caller forced it (a 401 told us the cached token is stale), or
  //  - we have no local session (don't trust a bare !isSignedIn — it can be a
  //    transient offline/init artifact).
  if (forceRefresh || !ops.isSignedIn) {
    switch (await _reconcile(ops)) {
      case _Reconcile.confirmedInvalid:
        return invalid('server reconcile confirmed no active session');
      case _Reconcile.unreachable:
        // Couldn't reach the server. If we also have no usable local session,
        // there's nothing to try — but it's transient, not a sign-out.
        if (!ops.isSignedIn) return network;
      // Otherwise a cached session is present; fall through and let the
      // cached token try (it may still work for the immediate request).
      case _Reconcile.signedIn:
        break; // session is active — fetch a token below
    }
  }

  try {
    return (token: await ops.fetchToken(), failure: null);
  } catch (e) {
    if (ops.isNonRecoverable(e)) {
      return invalid('non-recoverable auth error: $e');
    }
    // Transient-looking (timeout, parser hiccup, SDK state loss). One recovery
    // attempt: reconcile with the server, then refetch.
    switch (await _reconcile(ops)) {
      case _Reconcile.confirmedInvalid:
        return invalid('server reconcile confirmed no active session '
            'after a token-fetch failure');
      case _Reconcile.unreachable:
        return network;
      case _Reconcile.signedIn:
        try {
          return (token: await ops.fetchToken(), failure: null);
        } catch (e2) {
          if (ops.isNonRecoverable(e2)) {
            return invalid('non-recoverable auth error on retry: $e2');
          }
          return network;
        }
    }
  }
}

Future<_Reconcile> _reconcile(SessionOps ops) async {
  try {
    await ops.refreshClient();
  } catch (e) {
    if (ops.isNonRecoverable(e)) return _Reconcile.confirmedInvalid;
    return _Reconcile.unreachable;
  }
  // refreshClient succeeded → we reached the server. Its verdict on whether
  // we're still signed in is now authoritative.
  return ops.isSignedIn ? _Reconcile.signedIn : _Reconcile.confirmedInvalid;
}
