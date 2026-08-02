import type { MailSignals } from "@plotday/twister/signals";
import { getHeader, getHeaders, parseEmailAddress, parseEmailAddresses, type GmailMessage } from "./gmail-api";

const GMAIL_CATEGORY_LABELS = new Set([
  "CATEGORY_PROMOTIONS",
  "CATEGORY_UPDATES",
  "CATEGORY_SOCIAL",
  "CATEGORY_FORUMS",
  "CATEGORY_PERSONAL",
]);

const GMAIL_AUTHSERV_ID = "mx.google.com";

/** Pick the Authentication-Results added by Google's receiving MTA (by authserv-id). */
function trustedAuthResults(message: GmailMessage): string | null {
  for (const v of getHeaders(message, "Authentication-Results")) {
    const authservId = v.split(";", 1)[0].trim().toLowerCase();
    if (authservId === GMAIL_AUTHSERV_ID) return v;
  }
  return null;
}

const GMAIL_FLAG_LABELS = new Set(["IMPORTANT", "STARRED"]);

/**
 * Extract the normalized mail signals for a Gmail message. `bodyLength` is the
 * character length of the extracted plain-text body — pass the length of the
 * same string the note will carry, so the platform's format thresholds match
 * what the connector saw.
 *
 * This connector no longer classifies: it reports what it observed and the
 * platform decides.
 */
export function gmailSignals(message: GmailMessage, bodyLength: number): MailSignals {
  const from = parseEmailAddress(getHeader(message, "From") ?? "");
  const labels = message.labelIds ?? [];
  return {
    listId: getHeader(message, "List-Id"),
    listUnsubscribe: getHeader(message, "List-Unsubscribe"),
    precedence: getHeader(message, "Precedence"),
    autoSubmitted: getHeader(message, "Auto-Submitted"),
    returnPath: getHeader(message, "Return-Path"),
    importance: getHeader(message, "Importance") ?? getHeader(message, "X-Priority"),
    fromAddress: from?.email.toLowerCase() ?? null,
    fromName: from?.name ?? null,
    toCount: parseEmailAddresses(getHeader(message, "To")).length,
    ccCount: parseEmailAddresses(getHeader(message, "Cc")).length,
    isReply: getHeader(message, "In-Reply-To") !== null || getHeader(message, "References") !== null,
    subject: getHeader(message, "Subject"),
    bodyLength,
    authResults: trustedAuthResults(message),
    providerCategories: labels.filter((l) => GMAIL_CATEGORY_LABELS.has(l)),
    providerFlags: labels.filter((l) => GMAIL_FLAG_LABELS.has(l)),
  };
}
