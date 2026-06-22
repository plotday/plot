/**
 * Build a stable PostHog `$exception_fingerprint` from an error's type and
 * message.
 *
 * PostHog's default fingerprint drops the error message whenever a *resolved*
 * stack trace exists. Every unhandled twist/connector throw rides the same
 * generic async stack (queue → Tasks.processQueue → handleMessage →
 * invokeWebhookCallback → handleTwistOperation → callCallback), so ~25 entirely
 * unrelated errors collapsed into a single "Error" issue (019ed581). Setting a
 * fingerprint derived from type + message at capture time forces distinct
 * errors into distinct issues.
 *
 * The message is normalized so repeats of the SAME logical error still group
 * together regardless of volatile tokens — UUIDs, opaque ids, stack line
 * numbers, counts. Without this, "Sync state not found for project <uuid>"
 * would mint a new issue per project. Plot's nested `__TWIST_ERROR__` envelopes
 * (a connector error re-wrapped as it crosses the twist RPC boundary) are
 * unwrapped to their leaf message first, both for readability and so the same
 * error reported across deploys (different line numbers) groups together.
 */
const MAX_FINGERPRINT_LENGTH = 200;

export function exceptionFingerprint(name: string, message: string): string {
  const leaf = unwrapTwistError(message ?? "");
  const normalized = normalizeMessage(stripErrorPrefix(leaf));
  return `${name}: ${normalized}`.trim().slice(0, MAX_FINGERPRINT_LENGTH);
}

/**
 * Unwrap one or more nested `__TWIST_ERROR__{...}` JSON envelopes down to the
 * innermost real message, mirroring handleTwistOperation's own decode: take the
 * JSON after the marker, read its `message`, and repeat while that is still an
 * envelope. Returns the best string reached when no envelope remains or the
 * payload isn't parseable.
 */
function unwrapTwistError(message: string): string {
  let current = message;
  for (let depth = 0; depth < 5 && current.includes("__TWIST_ERROR__"); depth++) {
    const markerIndex = current.indexOf("__TWIST_ERROR__");
    const encoded = current.slice(markerIndex + "__TWIST_ERROR__".length);
    try {
      const parsed = JSON.parse(encoded) as { message?: unknown };
      if (typeof parsed.message === "string") {
        current = parsed.message;
        continue;
      }
    } catch {
      // Not valid JSON after the marker — stop and use what we have.
    }
    break;
  }
  return current;
}

/** Drop a leading "Error: " (and similar) so prefixed/bare variants match. */
function stripErrorPrefix(message: string): string {
  return message.replace(/^(?:[A-Za-z.]*Error|error):\s+/, "");
}

/** Replace volatile tokens so the same logical error yields one fingerprint. */
function normalizeMessage(message: string): string {
  return (
    message
      // UUIDs (run first so the whole id collapses to a single token).
      .replace(
        /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,
        "<id>"
      )
      // Opaque ids: long runs of id-ish chars (base58/base64/hex, ≥16 chars).
      .replace(/[A-Za-z0-9_-]{16,}/g, "<id>")
      // Standalone number runs (stack line numbers, counts, status codes).
      .replace(/\b\d+\b/g, "<n>")
      // Collapse whitespace/newlines so multi-line messages key consistently.
      .replace(/\s+/g, " ")
      .trim()
  );
}
