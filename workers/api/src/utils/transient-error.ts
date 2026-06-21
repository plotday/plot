/**
 * Detect transient infrastructure errors that should be retried without
 * paging PostHog Error Tracking. The bar for inclusion is high: we only
 * silence patterns that are unambiguously platform-side and self-resolve
 * within seconds. Generic patterns like "internal error" or "The Durable
 * Object" mask real bugs (the connector worker crashing, a DO output-
 * gate violation, an unhandled throw inside user code that happens to
 * include those words) and stall investigation.
 *
 * If you find yourself wanting to add a broad pattern here to quiet a
 * flood, fix the underlying flake instead. handleTwistOperation already
 * calls tracker.captureException for everything that bubbles up, so
 * silencing here only changes retry semantics — not visibility.
 */
export function isTransientError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const msg = error.message;
  return (
    // Cloudflare network blip — typically resolves in seconds.
    msg.includes("Network connection lost") ||
    // Cloudflare bot-block / rate-limit — resolves on the next attempt.
    msg.includes("error code: 1019") ||
    // DO version churn during a deploy: the platform resets the DO so
    // the new code can take over. Retry picks up the new version cleanly.
    msg.includes("Durable Object reset because its code was updated") ||
    // Queues producer 5xx is well-defined and the only producer-side
    // path that's worth a silent retry. Anything more generic ("Bad
    // Gateway", "internal error") could be a real downstream failure.
    msg.includes("Queue send failed: Internal Server Error")
  );
}

/**
 * Detect downstream provider rate-limit / quota errors that bubble up from a
 * connector callback. These are expected under load, self-resolve once the
 * provider's rate window passes, and the queue consumers already retry them.
 * Capturing them to PostHog Error Tracking just adds noise (per AGENTS.md:
 * "Do NOT report expected/handled errors … only unexpected failures that
 * indicate bugs"). Unlike `isTransientError`, these are downstream-API-side,
 * not Cloudflare infra — keep the two classifiers separate so the infra list
 * stays narrow.
 *
 * Matched on the flattened error message: connector errors cross the twist
 * RPC boundary as plain strings (same constraint as `isInsufficientScopeError`
 * in twist/tools/auth-scope.ts). The markers below are the exact, unambiguous
 * signatures Google/Gmail emit — `rateLimitExceeded` (usageLimits reason),
 * `RATE_LIMIT_EXCEEDED` (ErrorInfo reason), `Quota exceeded` (quota message),
 * `userRateLimitExceeded`, and the HTTP 429 statusText. Deliberately NOT a
 * bare "429" or "403" substring, which would match unrelated payloads.
 */
export function isRateLimitError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const msg = error.message;
  return (
    msg.includes("rateLimitExceeded") ||
    msg.includes("userRateLimitExceeded") ||
    msg.includes("RATE_LIMIT_EXCEEDED") ||
    msg.includes("Quota exceeded") ||
    msg.includes("Too Many Requests")
  );
}

/**
 * Detect terminal authentication errors from a connector callback: the stored
 * OAuth token was rejected by the provider (revoked, expired-and-unrefreshable,
 * invalid credentials). Unlike rate-limits, these do NOT self-resolve on
 * retry — the token is dead until the user re-authenticates. Retrying just
 * loops the same 401 until the queue's retry cap, firing a capture each time
 * (the storm behind PostHog issue 019dbbae; e.g. a brand-new user whose
 * second same-account Google connection got a non-refreshable token). Callers
 * should ACK (drop) these without paging: `getActorToken` already clears the
 * token and flags `twist_instance_connection.needs_reauth_at` on the next
 * expiry, which drives the app's re-auth prompt.
 *
 * Matched on the flattened cross-RPC error message (same constraint as
 * `isInsufficientScopeError`). Markers are the exact, unambiguous credential-
 * rejection signatures: Google's `UNAUTHENTICATED` / `authError` /
 * `Invalid Credentials`, the OAuth `invalid_grant`, Microsoft Graph's
 * `InvalidAuthenticationToken`, the `401 Unauthorized` statusText, and the
 * Google-Calendar connector's `Authentication failed` wrapper. Deliberately
 * NOT a bare `401` substring, which could match unrelated payloads (ids,
 * timestamps, quota bodies). Scope-insufficient 403s are intentionally NOT
 * here — `isInsufficientScopeError` owns that case.
 */
export function isAuthError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const msg = error.message;
  return (
    msg.includes("Invalid Credentials") ||
    msg.includes("UNAUTHENTICATED") ||
    msg.includes("invalid_grant") ||
    msg.includes("InvalidAuthenticationToken") ||
    msg.includes("401 Unauthorized") ||
    msg.includes("Authentication failed") ||
    // Unipile messaging tools (LinkedIn/Instagram/WhatsApp): the stored
    // account credential is missing/cleared, so the user must reconnect.
    // `assertAccount` throws "<provider> channel <id> has no stored
    // credentials — reconnect" and also flags needs_reauth, so retrying only
    // re-throws the same terminal error until the queue cap (the LinkedIn
    // stuck-"Syncing" storm). ACK it like the other credential rejections.
    msg.includes("no stored credentials")
  );
}
