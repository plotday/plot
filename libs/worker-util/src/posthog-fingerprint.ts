// PostHog groups `$exception` events into issues by `$exception_fingerprint`.
// When it isn't set, PostHog derives one at ingestion from (in order): the
// exception type, then — only if there's NO resolved stack trace — the message,
// otherwise the first (or first in-app) stack frame. Our Cloudflare Worker
// exceptions are plain `new Error(...)` (type always "Error") whose stack traces
// resolve but contain no in-app frames, only shared CF-runtime / posthog-node
// vendor frames. So every unrelated worker error collapses to `Error` + the same
// vendor frame — one giant "Error" issue — and the message, the one thing that
// distinguishes them, is discarded.
//
// The fix: set an explicit `$exception_fingerprint` from the exception type +
// message, normalized so we group by the KIND of error (a stable string) rather
// than fragmenting on the volatile ids/urls/numbers embedded in the message.
// See https://posthog.com/docs/error-tracking/fingerprints.

/**
 * Collapse the volatile parts of an exception message into a stable grouping
 * key. Strips ids, urls/paths, and numbers so that e.g. the same upstream 4xx
 * for different accounts groups together, while genuinely different failures
 * (memory limit vs. DO reset vs. queue error) stay separate.
 */
export function normalizeExceptionMessage(message: string): string {
  return message
    .replace(/\?[^\s]*/g, "") // drop query strings (e.g. ?limit=20)
    .replace(/\/[^\s/]+/g, (seg) => {
      // Normalize path segments: keep short, purely-alphabetic segments
      // (/chats, /messages) and api versions (/v2); replace id-bearing ones.
      const body = seg.slice(1);
      if (/^v\d+$/i.test(body)) return "/" + body;
      if (/^[a-z]+$/i.test(body) && body.length <= 12) return "/" + body;
      return "/<id>";
    })
    .replace(/\b([1-5])\d{2}\b/g, "$1xx") // HTTP status -> class (429 -> 4xx)
    .replace(
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi,
      "<uuid>",
    )
    .replace(/\b[a-z0-9]{16,}\b/gi, "<id>") // long opaque ids (hex, base58, ...)
    .replace(/\b\d+\b/g, "<n>") // remaining bare integers
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
}

// Minimal structural mirror of posthog-node's `EventMessage` — kept local so
// this package stays dependency-free. `(event) => event` is assignable to
// posthog-node's `BeforeSendFn` (`(event: EventMessage | null) => EventMessage | null`)
// because EventMessage's only required field is `event: string`.
type PostHogEvent = {
  event: string;
  properties?: Record<string | number, unknown>;
} | null;

/**
 * A posthog-node `before_send` hook that assigns a normalized
 * `$exception_fingerprint` to `$exception` events. Wire it into every
 * `new PostHog(...)` so unrelated worker errors stop collapsing into a single
 * "Error" issue.
 *
 * A caller-provided `$exception_fingerprint` is respected: PostHog's own
 * auto-fingerprint is computed server-side at ingestion, so anything already
 * present here was set intentionally.
 */
export function exceptionFingerprintBeforeSend<T extends PostHogEvent>(
  event: T,
): T {
  if (!event || event.event !== "$exception") return event;
  const props = event.properties;
  if (!props || props.$exception_fingerprint) return event;

  const list = props.$exception_list;
  if (!Array.isArray(list) || list.length === 0) return event;

  // Combine every exception in the (possibly chained) list so that different
  // cause chains don't merge.
  const key = list
    .map((e) => {
      const type = typeof e?.type === "string" ? e.type : "Error";
      const value = typeof e?.value === "string" ? e.value : "";
      return `${type}: ${normalizeExceptionMessage(value)}`;
    })
    .join(" <<< ");
  if (!key) return event;

  props.$exception_fingerprint = key;
  return event;
}
