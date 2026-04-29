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
