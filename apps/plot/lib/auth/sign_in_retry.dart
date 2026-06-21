/// Resilience helpers for the foreground first-time sign-in flow.
///
/// A *fresh install* (the App Store reviewer's case, or any new device) has no
/// locally restored identity, so the sign-in UI must complete the full
/// Clerk-auth + `/activate` round trip synchronously before the user is in.
/// A warm install hides backend slowness because it restores identity from
/// local storage and re-validates `/activate` in the background. The fresh
/// path has no such cushion: a single transient backend stall (a saturated DB
/// pool, a worker mid-deploy) on the `/activate` leg surfaces to the user as
/// "Sign-in is taking too long."
///
/// [retryAsync] gives that leg several bounded attempts so a brief backend
/// burst is ridden out instead of failing the sign-in. `/activate` is
/// idempotent (activate-or-fetch), so retrying it is safe.
library;

import 'dart:async';

import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';

/// Thrown by `Base.resolveIdentity` when `/activate` could not resolve the
/// user's identity — the server was reachable but unhealthy (5xx) or
/// unreachable, and the JWT fallback carried no identity (the first-time
/// case, before `/activate` has stamped `external_id`/`contact_id`).
///
/// A dedicated type (rather than a bare `Exception`) lets the first-time
/// sign-in retry loop recognise this as transient and try again, instead of
/// giving up on a stall that a moment later would have succeeded.
class IdentityResolutionException implements Exception {
  const IdentityResolutionException(this.message);

  final String message;

  @override
  String toString() => 'IdentityResolutionException: $message';
}

/// Awaitable delay, injectable so tests run without real time passing.
typedef AsyncDelay = Future<void> Function(Duration duration);

Future<void> _realDelay(Duration duration) => Future<void>.delayed(duration);

/// Default backoff for the sign-in resolve loop: wait `attempt` seconds after
/// the failed attempt numbered `attempt` (1s after the 1st, 2s after the 2nd).
Duration defaultSignInBackoff(int attempt) => Duration(seconds: attempt);

/// Runs [action] until it succeeds or attempts are exhausted.
///
/// Retries only while [isRetryable] returns true for the thrown error *and*
/// attempts remain. Between tries it waits [backoff] (passed the 1-based
/// number of the attempt that just failed) via [delay]. On the final attempt,
/// or for a non-retryable error, the error is rethrown unchanged.
Future<T> retryAsync<T>(
  Future<T> Function() action, {
  int maxAttempts = 3,
  required bool Function(Object error) isRetryable,
  Duration Function(int attempt) backoff = defaultSignInBackoff,
  AsyncDelay delay = _realDelay,
}) async {
  assert(maxAttempts >= 1, 'maxAttempts must be at least 1');
  var attempt = 0;
  while (true) {
    attempt++;
    try {
      return await action();
    } catch (error) {
      if (attempt >= maxAttempts || !isRetryable(error)) rethrow;
      await delay(backoff(attempt));
    }
  }
}

/// Whether [error] from the sign-in resolve leg is worth retrying.
///
/// Transient: a timeout, a network failure, an unresolved identity (server
/// unhealthy + no JWT fallback), or a 5xx server hiccup. Everything else —
/// 4xx rejections, auth errors, programmer errors — is terminal and surfaces
/// to the user immediately.
bool isTransientSignInError(Object error) {
  if (error is TimeoutException) return true;
  if (error is NetworkException) return true;
  if (error is IdentityResolutionException) return true;
  if (error is ApiException) return error.statusCode >= 500;
  return false;
}
