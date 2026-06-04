/**
 * Pure, dependency-free helpers for OAuth scope handling. Kept out of the
 * integrations.ts monolith so they can be unit-tested in isolation.
 */

/**
 * Extract the scopes the user actually granted from an OAuth token exchange
 * response. OAuth 2.0 defines `scope` as a space-separated string of granted
 * scopes (RFC 6749 §3.3); when present, it reflects the user's actual consent —
 * including any scopes they unchecked on a granular consent screen (Google,
 * Microsoft).
 *
 * Some providers return the granted scopes somewhere other than the top-level
 * `scope` field — e.g. Slack user-token-only apps return them at
 * `authed_user.scope`. Pass the provider config's `extractGrantedScopes` to
 * read from the right place.
 *
 * Returns null when no scope string is present, so callers can skip enforcement
 * instead of treating absence as "everything missing".
 */
export function parseGrantedScopes(
  tokenResponse: any,
  config?: { extractGrantedScopes?: (response: any) => string | undefined }
): string[] | null {
  const raw = config?.extractGrantedScopes?.(tokenResponse) ?? tokenResponse?.scope;
  if (typeof raw === "string" && raw.trim().length > 0) {
    return raw.split(/\s+/).filter(Boolean);
  }
  return null;
}

const TWIST_ERROR_MARKER = "__TWIST_ERROR__";

// Google's two signals that an access token is missing a required scope. Both
// are specific enough that a match means the token itself is under-scoped — not
// a transient 403 (ACL, WAF, rate-limit), which we deliberately do NOT flag.
const INSUFFICIENT_SCOPE_MARKERS = [
  "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
  "insufficientPermissions",
];

/**
 * True when an error thrown by a connector API call means the stored token is
 * permanently missing a required scope (user must re-authorize).
 *
 * Connector errors cross the twist RPC boundary flattened to a string: the
 * runtime re-wraps them as `__TWIST_ERROR__{json}` where the inner `message`
 * holds the original error text (entrypoint.ts). We unwrap that envelope (same
 * approach as error-handling.ts) before checking for the scope markers.
 */
export function isInsufficientScopeError(rawErrorMessage: string): boolean {
  let message = rawErrorMessage;
  const markerIndex = message.indexOf(TWIST_ERROR_MARKER);
  if (markerIndex !== -1) {
    try {
      const decoded = JSON.parse(
        message.slice(markerIndex + TWIST_ERROR_MARKER.length)
      );
      if (typeof decoded?.message === "string") {
        message = decoded.message;
      }
    } catch {
      // Malformed envelope — fall through and test the raw string.
    }
  }
  return INSUFFICIENT_SCOPE_MARKERS.some((m) => message.includes(m));
}
