import { classifyEmail, type EmailSignals } from "@plotday/email-classifier";
import type { ThreadFacets } from "@plotday/twister/facets";
import type { GraphHeader, GraphMessage } from "./graph-mail-api";

function header(headers: GraphHeader[] | null, name: string): string | null {
  const h = headers?.find((x) => x.name.toLowerCase() === name.toLowerCase());
  return h?.value || null;
}

/**
 * Compute facets for an Outlook conversation's parent message. `headers` is
 * the parent's internetMessageHeaders (separate single-message fetch; null
 * when that fetch failed — header-driven signals just stay null).
 * `inferenceClassification === "other"` (Focused Inbox's bulk bucket) maps to
 * the classifier's CATEGORY_UPDATES slot so short automated "Other" mail
 * classifies as notification, mirroring Gmail's category labels.
 */
export function outlookFacets(
  headers: GraphHeader[] | null,
  message: GraphMessage,
  bodyText: string
): ThreadFacets {
  const signals: EmailSignals = {
    listId: header(headers, "List-Id"),
    listUnsubscribe: header(headers, "List-Unsubscribe"),
    precedence: header(headers, "Precedence"),
    autoSubmitted: header(headers, "Auto-Submitted"),
    returnPath: header(headers, "Return-Path"),
    importance:
      message.importance ??
      header(headers, "Importance") ??
      header(headers, "X-Priority"),
    fromAddress: message.from?.emailAddress?.address?.toLowerCase() ?? null,
    recipientCount:
      (message.toRecipients?.length ?? 0) + (message.ccRecipients?.length ?? 0),
    isReply:
      header(headers, "In-Reply-To") !== null ||
      header(headers, "References") !== null ||
      /^re:/i.test(message.subject ?? ""),
    subject: message.subject ?? null,
    bodyLength: bodyText.length,
    gmailCategories:
      message.inferenceClassification === "other" ? ["CATEGORY_UPDATES"] : [],
  };
  return classifyEmail(signals);
}
