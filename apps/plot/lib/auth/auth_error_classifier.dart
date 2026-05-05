/// Classifies [clerk.ClerkError]s as recoverable (transient — keep retrying)
/// vs non-recoverable (the session is dead — sign out and prompt re-auth).
///
/// Why this exists as a separate file: clerk_auth wraps server errors through
/// multiple layers and loses structured information along the way. The
/// canonical "session is dead" sub-codes (e.g. `authentication_invalid`,
/// `signed_out`) survive in different shapes depending on which path the
/// error took, so detection must inspect several signals. Centralising the
/// rule keeps the policy testable and prevents drift between override sites.
library;

import 'package:clerk_auth/clerk_auth.dart' as clerk;

/// Server-side Clerk error sub-codes that mean the session has been
/// definitively repudiated and no amount of retry will recover it. Any
/// other sub-code (form errors, rate limits, server hiccups, network
/// failures) is treated as transient.
///
/// Conservative on purpose: we'd rather keep a user signed in across a flaky
/// network than force them to re-auth on a transient blip.
const _nonRecoverableSubCodes = <String>{
  // 401 — token rejected, session no longer valid
  'authentication_invalid',
  // Clerk explicitly signed the session out (e.g. revoked from another device)
  'signed_out',
  // Session ID isn't known to Clerk anymore (deleted server-side)
  'session_not_found',
};

/// Returns true if [error] indicates a definitively non-recoverable auth
/// failure. The caller should treat this as a hard sign-out signal.
///
/// clerk_auth surfaces sub-codes in two different shapes — both must be
/// detected:
///
/// 1. **Multi-error path** (`api.dart:908`): the API throws
///    `ExternalError(errors: collection)`, and `Auth._catchExternalErrors`
///    wraps it via `ClerkError.from`, preserving the [ExternalErrorCollection]
///    on [clerk.ClerkError.errors]. We inspect each error's `code`.
///
/// 2. **Single-error path** (`api.dart:906`): the API throws the leaf
///    `ExternalError` directly (no nested collection), so
///    `Auth._catchExternalErrors` falls into its `else` branch and
///    constructs `ClerkError(message: error.toString(), code:
///    serverErrorResponse)`. The leaf's `code` is now only visible as a
///    substring inside `message` — specifically as `code: <subcode>` from
///    the JSON-map `toString()` of the original [ExternalError]. We
///    recognise that shape, but only that exact shape, to avoid false
///    positives from prose that happens to mention the same string.
///
/// This is the actual production failure mode: a 401 with
/// `authentication_invalid` arrives as path 2, the previous override only
/// handled path 1, so `onSessionInvalidated` never fired and the polling
/// timer kept retrying every ~53 s with no path to recovery.
bool isNonRecoverableAuthError(clerk.ClerkError error) {
  // Path 1: structured collection survived. `clerk_auth` doesn't publicly
  // export the `ExternalError` element type from its `src/` directory, so
  // we read `.code` via dynamic dispatch rather than pull in an
  // implementation_imports violation. Each element is an ExternalError
  // with a `String? code` field.
  final collected = error.errors?.errors;
  if (collected != null) {
    for (final dynamic e in collected) {
      final code = e.code as String?;
      if (code != null && _nonRecoverableSubCodes.contains(code)) return true;
    }
  }
  // Path 2: leaf error's code only survives in `message`. Match the exact
  // `code: <value>` fragment that ExternalError.toString() emits via its
  // JSON map. The leading `code: ` keeps prose mentions from matching.
  final msg = error.toString();
  for (final code in _nonRecoverableSubCodes) {
    if (msg.contains('code: $code')) return true;
  }
  return false;
}
