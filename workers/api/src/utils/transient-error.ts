/**
 * Detect transient infrastructure errors (DO communication failures,
 * Hyperdrive connection issues, Cloudflare Queues producer 5xx blips,
 * cross-worker RPC drops) that should be retried silently.
 *
 * Used by queue consumers to retry without escalating to PostHog, and by
 * `handleTwistOperation` to skip writing user-facing twist log noise for
 * Cloudflare-side blips the twist developer cannot act on.
 */
export function isTransientError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const msg = error.message;
  return (
    msg.includes("Network connection lost") ||
    msg.includes("error code: 1019") ||
    msg.includes("The Durable Object") ||
    msg.includes("internal error") ||
    msg.includes("Queue send failed") ||
    msg.includes("Bad Gateway")
  );
}
