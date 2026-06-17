import { GmailApiError } from "./gmail-api";

/**
 * How a failed Gmail send should be handled.
 *
 * - `transient`: retry (rate limit / 5xx / network blip).
 * - `permanent`: surface to the user as "Failed to send" (rejected recipient,
 *   message too large, malformed request) — retrying won't help.
 * - `auth`: the OAuth token is dead; handled out-of-band by the re-auth path
 *   (`needs_reauth_at`). Surface as a delivery error too so the user can
 *   reconnect, but don't retry.
 * - `unknown`: an unclassified error — the caller should rethrow so it reaches
 *   error tracking (it may be a genuine bug).
 */
export type SendErrorClass = "transient" | "permanent" | "auth" | "unknown";

export interface ClassifiedSendError {
  class: SendErrorClass;
  /** Stable machine code, e.g. "rate_limited", "too_large", "rejected". */
  code: string;
  /** User-safe message to show beside "Failed to send", or null. */
  message: string | null;
}

// Google reason markers (mirrors the server-side classifier vocabulary in
// workers/api/src/utils/transient-error.ts, which the connector can't import).
const RATE_LIMIT_MARKERS = [
  "rateLimitExceeded",
  "userRateLimitExceeded",
  "Quota exceeded",
  "quotaExceeded",
];
const AUTH_MARKERS = [
  "Invalid Credentials",
  "invalid_grant",
  "authError",
  "insufficientPermissions",
  "ACCESS_TOKEN_EXPIRED",
];
const TOO_LARGE_MARKERS = ["messageTooLarge", "Message too large", "too large"];
const RECIPIENT_MARKERS = [
  "Invalid To header",
  "Invalid Cc header",
  "Invalid Bcc header",
  "Recipient address rejected",
  "invalidArgument",
  "Invalid recipient",
  "No recipients",
];

function bodyIncludes(haystack: string, markers: string[]): boolean {
  const lower = haystack.toLowerCase();
  return markers.some((m) => lower.includes(m.toLowerCase()));
}

/**
 * Classify a thrown Gmail send error. Inspects {@link GmailApiError} status +
 * body; treats non-GmailApiError throws (network/fetch failures, which happen
 * before a response is read) as transient.
 */
export function classifySendError(error: unknown): ClassifiedSendError {
  // Network / fetch-layer failure: no HTTP response was produced.
  if (!(error instanceof GmailApiError)) {
    return {
      class: "transient",
      code: "network",
      message: "Network error while sending",
    };
  }

  const status = error.status;
  const body = error.message; // GmailApiError embeds the response body.

  // 429 — always rate limit.
  if (status === 429) {
    return { class: "transient", code: "rate_limited", message: "Rate limited by Gmail; will retry" };
  }

  // 5xx — Google-side transient.
  if (status >= 500 && status <= 599) {
    return { class: "transient", code: "server_error", message: "Gmail is temporarily unavailable; will retry" };
  }

  // 403 is ambiguous: rate-limit vs auth/permission. Check rate markers first.
  if (status === 403) {
    if (bodyIncludes(body, RATE_LIMIT_MARKERS)) {
      return { class: "transient", code: "rate_limited", message: "Rate limited by Gmail; will retry" };
    }
    return { class: "auth", code: "auth", message: "Gmail access expired — reconnect to send" };
  }

  // 401 — terminal auth.
  if (status === 401) {
    return { class: "auth", code: "auth", message: "Gmail access expired — reconnect to send" };
  }

  // 413 / too-large.
  if (status === 413 || bodyIncludes(body, TOO_LARGE_MARKERS)) {
    return { class: "permanent", code: "too_large", message: "Message is too large to send" };
  }

  // 400 and other 4xx: bad request — most commonly a rejected/invalid
  // recipient or malformed message. Permanent.
  if (status === 400 || (status >= 400 && status < 500)) {
    if (bodyIncludes(body, RECIPIENT_MARKERS)) {
      return { class: "permanent", code: "rejected", message: "A recipient address was rejected" };
    }
    if (bodyIncludes(body, AUTH_MARKERS)) {
      return { class: "auth", code: "auth", message: "Gmail access expired — reconnect to send" };
    }
    return { class: "permanent", code: "rejected", message: "Gmail rejected the message" };
  }

  // Anything else (e.g. an unexpected status): unknown — let the caller rethrow
  // so a genuine bug still reaches error tracking.
  return { class: "unknown", code: "unknown", message: null };
}
