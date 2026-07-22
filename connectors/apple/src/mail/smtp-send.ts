import type { Smtp, SmtpMessage, SmtpSendResult } from "@plotday/twister/tools/smtp";

/** iCloud SMTP submission endpoint (STARTTLS on 587). */
const ICLOUD_SMTP = {
  host: "smtp.mail.me.com",
  port: 587,
  tls: false,
  starttls: true,
} as const;

export type SendError = {
  class: "transient" | "permanent" | "auth";
  /** Stable machine code: "rejected" | "rate_limited" | "server_error" | "auth" | "send_failed". */
  code: string;
  /** User-safe message, or null. */
  message: string | null;
};

export type SendOutcome =
  | { ok: true; result: SmtpSendResult }
  | { ok: false; error: SendError };

/**
 * Classify a thrown SMTP send error. The built-in Smtp tool throws
 * `Error(...)` with the server's reply lines embedded, so the 3-digit SMTP
 * reply code appears as a token — parse it best-effort.
 *  - 535 / "authentication failed"     → auth       (surface deliveryError)
 *  - 4xx / connection closed / network → transient  (retry)
 *  - 5xx (550/551/553 → recipient)     → permanent  (surface deliveryError)
 *  - unrecognised                      → permanent send_failed (surface, no page)
 */
export function classifySmtpError(err: unknown): SendError {
  const msg = err instanceof Error ? err.message : String(err);
  const lower = msg.toLowerCase();
  const codeMatch = msg.match(/\b([245]\d\d)\b/);
  const code = codeMatch ? parseInt(codeMatch[1], 10) : null;

  if (code === 535 || lower.includes("authentication failed")) {
    return { class: "auth", code: "auth", message: "Mail sign-in was rejected" };
  }
  if (
    lower.includes("connection closed") ||
    lower.includes("connection failed") ||
    lower.includes("network") ||
    (code !== null && code >= 400 && code < 500)
  ) {
    return { class: "transient", code: "rate_limited", message: null };
  }
  if (code !== null && code >= 500) {
    const rejected =
      code === 550 || code === 551 || code === 553 || lower.includes("reject");
    return {
      class: "permanent",
      code: rejected ? "rejected" : "server_error",
      message: rejected
        ? "The recipient address was rejected"
        : "The mail server rejected the message",
    };
  }
  return { class: "permanent", code: "send_failed", message: null };
}

const BACKOFF_MS = [400, 1200];

/** Bounded in-process retry for transient SMTP failures (3 attempts). */
export async function sendWithRetry(
  send: () => Promise<SmtpSendResult>,
  sleep: (ms: number) => Promise<void> = (ms) =>
    new Promise((r) => setTimeout(r, ms))
): Promise<SendOutcome> {
  let last: SendError | null = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return { ok: true, result: await send() };
    } catch (err) {
      const error = classifySmtpError(err);
      if (error.class !== "transient") return { ok: false, error };
      last = error;
      if (attempt < BACKOFF_MS.length) await sleep(BACKOFF_MS[attempt]);
    }
  }
  return {
    ok: false,
    error: last ?? { class: "transient", code: "rate_limited", message: null },
  };
}

/**
 * Open an iCloud SMTP session, send `message`, and disconnect (in finally). A
 * rejected/failed send throws (the tool throws Error); callers wrap this call
 * in `sendWithRetry` so each retry opens a fresh session.
 */
export async function sendViaSmtp(
  smtp: Smtp,
  appleId: string,
  appPassword: string,
  message: SmtpMessage
): Promise<SmtpSendResult> {
  const session = await smtp.connect({
    ...ICLOUD_SMTP,
    username: appleId,
    password: appPassword,
  });
  try {
    return await smtp.send(session, message);
  } finally {
    await smtp.disconnect(session);
  }
}
