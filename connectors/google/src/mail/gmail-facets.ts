import { classifyEmail, extractCta, extractLinkCandidates, type EmailSignals } from "@plotday/email-classifier";
import type { Cta, ThreadFacets } from "@plotday/twister/facets";
import { getHeader, getHeaders, getMessageHtml, parseEmailAddress, parseEmailAddresses, type GmailMessage } from "./gmail-api";

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

export type GmailClassification = { facets: ThreadFacets; cta: Cta | null };

/**
 * Compute facets and extract CTA for a Gmail message. `bodyText` is the extracted body used
 * for the length heuristic (pass the same string the note will carry).
 */
export function gmailFacets(message: GmailMessage, bodyText: string): GmailClassification {
  const from = parseEmailAddress(getHeader(message, "From") ?? "");
  const signals: EmailSignals = {
    listId: getHeader(message, "List-Id"),
    listUnsubscribe: getHeader(message, "List-Unsubscribe"),
    precedence: getHeader(message, "Precedence"),
    autoSubmitted: getHeader(message, "Auto-Submitted"),
    returnPath: getHeader(message, "Return-Path"),
    importance: getHeader(message, "Importance") ?? getHeader(message, "X-Priority"),
    fromAddress: from?.email.toLowerCase() ?? null,
    fromName: from?.name ?? null,
    recipientCount:
      parseEmailAddresses(getHeader(message, "To")).length +
      parseEmailAddresses(getHeader(message, "Cc")).length,
    isReply: getHeader(message, "In-Reply-To") !== null || getHeader(message, "References") !== null,
    subject: getHeader(message, "Subject"),
    bodyText,
    bodyLength: bodyText.length,
    links: extractLinkCandidates(getMessageHtml(message)),
    authResults: trustedAuthResults(message),
    gmailCategories: (message.labelIds ?? []).filter((l) => GMAIL_CATEGORY_LABELS.has(l)),
  };
  return { facets: classifyEmail(signals), cta: extractCta(signals) };
}
