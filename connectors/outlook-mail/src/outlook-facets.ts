import { classifyEmail, extractCta, extractLinkCandidates, type EmailSignals } from "@plotday/email-classifier";
import type { Cta, ThreadFacets } from "@plotday/twister/facets";
import type { GraphHeader, GraphMessage } from "./graph-mail-api";

function header(headers: GraphHeader[] | null, name: string): string | null {
  const h = headers?.find((x) => x.name.toLowerCase() === name.toLowerCase());
  return h?.value || null;
}

/** Pick the Authentication-Results added by Microsoft EOP (authserv-id contains protection.outlook.com). */
function trustedAuthResults(headers: GraphHeader[] | null): string | null {
  for (const h of headers ?? []) {
    if (h.name.toLowerCase() !== "authentication-results") continue;
    const authservId = h.value.split(";", 1)[0].trim().toLowerCase();
    if (authservId === "protection.outlook.com" || authservId.endsWith(".protection.outlook.com")) return h.value;
  }
  return null;
}

export type OutlookClassification = { facets: ThreadFacets; cta: Cta | null };

/**
 * Compute facets and extract CTA for an Outlook conversation's parent message. `headers` is
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
): OutlookClassification {
  const html = message.body?.contentType === "html" ? (message.body.content ?? "") : "";
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
    fromName: message.from?.emailAddress?.name ?? null,
    recipientCount:
      (message.toRecipients?.length ?? 0) + (message.ccRecipients?.length ?? 0),
    isReply:
      header(headers, "In-Reply-To") !== null ||
      header(headers, "References") !== null ||
      /^re:/i.test(message.subject ?? ""),
    subject: message.subject ?? null,
    bodyText,
    bodyLength: bodyText.length,
    links: extractLinkCandidates(html),
    authResults: trustedAuthResults(headers),
    gmailCategories:
      message.inferenceClassification === "other" ? ["CATEGORY_UPDATES"] : [],
  };
  return { facets: classifyEmail(signals), cta: extractCta(signals) };
}
