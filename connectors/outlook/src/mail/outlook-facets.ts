import type { MailSignals } from "@plotday/twister/signals";
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

/**
 * Extract normalized mail signals for an Outlook conversation's parent message.
 * `headers` is the parent's internetMessageHeaders (a separate single-message
 * fetch; null when that fetch failed — header-driven signals then stay null).
 *
 * Focused Inbox's bucket is emitted verbatim ("focused" / "other"); mapping it
 * onto a content category is the platform's decision, not the connector's.
 */
export function outlookSignals(headers: GraphHeader[] | null, message: GraphMessage): MailSignals {
  return {
    listId: header(headers, "List-Id"),
    listUnsubscribe: header(headers, "List-Unsubscribe"),
    precedence: header(headers, "Precedence"),
    autoSubmitted: header(headers, "Auto-Submitted"),
    returnPath: header(headers, "Return-Path"),
    importance: message.importance ?? header(headers, "Importance") ?? header(headers, "X-Priority"),
    fromAddress: message.from?.emailAddress?.address?.toLowerCase() ?? null,
    fromName: message.from?.emailAddress?.name ?? null,
    toCount: message.toRecipients?.length ?? 0,
    ccCount: message.ccRecipients?.length ?? 0,
    isReply:
      header(headers, "In-Reply-To") !== null ||
      header(headers, "References") !== null ||
      /^re:/i.test(message.subject ?? ""),
    subject: message.subject ?? null,
    authResults: trustedAuthResults(headers),
    providerCategories: message.inferenceClassification ? [message.inferenceClassification] : [],
    providerFlags: message.flag?.flagStatus === "flagged" ? ["FLAGGED"] : [],
  };
}
