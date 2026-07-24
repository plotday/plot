import { classifyEmail, extractCta, extractLinkCandidates, type EmailSignals } from "@plotday/email-classifier";
import type { Cta, ThreadFacets } from "@plotday/twister/facets";
import type { MailMessage } from "./transform";

/**
 * Candidate authserv-id root(s) for iCloud Mail's own receiving MTA.
 * VERIFIED 2026-07-24 against a real inbound "Welcome to iCloud Mail"
 * message from noreply@email.apple.com: iCloud stamps `Authentication-Results`
 * headers whose authserv-id is a `*.icloud.com` sub-host (`bimi.icloud.com`,
 * `dmarc.icloud.com`, `dkim-verifier.icloud.com`, `spf.icloud.com` were all
 * observed on that message).
 */
const ICLOUD_AUTHSERV_CANDIDATES = ["icloud.com"];

/**
 * Pick the Authentication-Results value carrying iCloud's own DMARC verdict.
 *
 * Unlike Gmail/Outlook (one combined Authentication-Results header per hop),
 * iCloud stamps a SEPARATE header per mechanism — SPF, DKIM, DMARC, and (for
 * BIMI-enrolled senders) BIMI each get their own `*.icloud.com`-hosted
 * header, and BIMI's appears FIRST on the wire when present. Matching only
 * on a trusted authserv-id and returning the first hit would silently pick
 * the BIMI header, which carries no `dmarc=` verdict at all — so this also
 * requires the value itself to contain a `dmarc=` token, not just a trusted
 * host.
 */
function trustedAuthResults(results: string[] | undefined): string | null {
  for (const v of results ?? []) {
    const authservId = v.split(";", 1)[0].trim().toLowerCase();
    const trustedHost = ICLOUD_AUTHSERV_CANDIDATES.some(
      (c) => authservId === c || authservId.endsWith(`.${c}`)
    );
    if (trustedHost && /\bdmarc\s*=/i.test(v)) return v;
  }
  return null;
}

export type AppleMailClassification = { facets: ThreadFacets; cta: Cta | null };

/**
 * Compute facets and extract CTA for an Apple Mail (IMAP) message. `bodyText`
 * is the extracted body used for the length heuristic (pass the same string
 * the note will carry).
 */
export function appleMailFacets(message: MailMessage, bodyText: string): AppleMailClassification {
  const from = message.from && message.from[0] ? message.from[0] : null;
  const signals: EmailSignals = {
    listId: message.listId ?? null,
    listUnsubscribe: message.listUnsubscribe ?? null,
    precedence: message.precedence ?? null,
    autoSubmitted: message.autoSubmitted ?? null,
    returnPath: message.returnPath ?? null,
    importance: message.importance ?? message.xPriority ?? null,
    fromAddress: from?.address.toLowerCase() ?? null,
    fromName: from?.name ?? null,
    recipientCount: (message.to?.length ?? 0) + (message.cc?.length ?? 0),
    isReply: message.inReplyTo != null || (message.references?.length ?? 0) > 0,
    subject: message.subject ?? null,
    bodyText,
    bodyLength: bodyText.length,
    links: extractLinkCandidates(message.bodyHtml ?? ""),
    authResults: trustedAuthResults(message.authenticationResults),
    gmailCategories: [],
  };
  return { facets: classifyEmail(signals), cta: extractCta(signals) };
}
