import { classifyEmail, type EmailSignals } from "@plotday/email-classifier";
import type { ThreadFacets } from "@plotday/twister/facets";
import { getHeader, type GmailMessage } from "./gmail-api";

const GMAIL_CATEGORY_LABELS = new Set([
  "CATEGORY_PROMOTIONS",
  "CATEGORY_UPDATES",
  "CATEGORY_SOCIAL",
  "CATEGORY_FORUMS",
  "CATEGORY_PERSONAL",
]);

// Count comma-separated addresses in a header value (To/Cc). Empty → 0.
function addressCount(value: string | null): number {
  if (!value) return 0;
  return value.split(",").map((s) => s.trim()).filter((s) => s.length > 0).length;
}

function parseAddress(from: string | null): string | null {
  if (!from) return null;
  const angle = from.match(/<([^>]+)>/);
  const addr = (angle ? angle[1] : from).trim().toLowerCase();
  return addr.includes("@") ? addr : null;
}

/**
 * Compute facets for a Gmail message. `bodyText` is the extracted body used
 * for the length heuristic (pass the same string the note will carry).
 */
export function gmailFacets(message: GmailMessage, bodyText: string): ThreadFacets {
  const listId = getHeader(message, "List-Id");
  const listUnsubscribe = getHeader(message, "List-Unsubscribe");
  const explicitPrecedence = getHeader(message, "Precedence");
  // List-Id / List-Unsubscribe are definitive automation signals (RFC 2369/2919
  // mailing-list headers only appear on automated bulk mail). Synthesise a
  // "bulk" precedence when the explicit header is absent so the classifier's
  // computeAutomation() path fires correctly.
  const precedence = explicitPrecedence ?? (listId || listUnsubscribe ? "bulk" : null);

  const signals: EmailSignals = {
    listId,
    listUnsubscribe,
    precedence,
    autoSubmitted: getHeader(message, "Auto-Submitted"),
    returnPath: getHeader(message, "Return-Path"),
    importance: getHeader(message, "Importance") ?? getHeader(message, "X-Priority"),
    fromAddress: parseAddress(getHeader(message, "From")),
    recipientCount: addressCount(getHeader(message, "To")) + addressCount(getHeader(message, "Cc")),
    isReply: getHeader(message, "In-Reply-To") !== null || getHeader(message, "References") !== null,
    subject: getHeader(message, "Subject"),
    bodyLength: bodyText.length,
    gmailCategories: (message.labelIds ?? []).filter((l) => GMAIL_CATEGORY_LABELS.has(l)),
  };
  return classifyEmail(signals);
}
