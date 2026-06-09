import { classifyEmail, type EmailSignals } from "@plotday/email-classifier";
import type { ThreadFacets } from "@plotday/twister/facets";
import { getHeader, parseEmailAddress, parseEmailAddresses, type GmailMessage } from "./gmail-api";

const GMAIL_CATEGORY_LABELS = new Set([
  "CATEGORY_PROMOTIONS",
  "CATEGORY_UPDATES",
  "CATEGORY_SOCIAL",
  "CATEGORY_FORUMS",
  "CATEGORY_PERSONAL",
]);

/**
 * Compute facets for a Gmail message. `bodyText` is the extracted body used
 * for the length heuristic (pass the same string the note will carry).
 */
export function gmailFacets(message: GmailMessage, bodyText: string): ThreadFacets {
  const signals: EmailSignals = {
    listId: getHeader(message, "List-Id"),
    listUnsubscribe: getHeader(message, "List-Unsubscribe"),
    precedence: getHeader(message, "Precedence"),
    autoSubmitted: getHeader(message, "Auto-Submitted"),
    returnPath: getHeader(message, "Return-Path"),
    importance: getHeader(message, "Importance") ?? getHeader(message, "X-Priority"),
    fromAddress: parseEmailAddress(getHeader(message, "From") ?? "")?.email.toLowerCase() ?? null,
    recipientCount:
      parseEmailAddresses(getHeader(message, "To")).length +
      parseEmailAddresses(getHeader(message, "Cc")).length,
    isReply: getHeader(message, "In-Reply-To") !== null || getHeader(message, "References") !== null,
    subject: getHeader(message, "Subject"),
    bodyLength: bodyText.length,
    gmailCategories: (message.labelIds ?? []).filter((l) => GMAIL_CATEGORY_LABELS.has(l)),
  };
  return classifyEmail(signals);
}
