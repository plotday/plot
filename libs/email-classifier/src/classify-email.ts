import type { Automation, Format, Reach, ThreadFacets } from "@plotday/twister/facets";

/**
 * Normalized email signals an email connector assembles from raw RFC 5322
 * headers + Gmail labels. Every field is optional-by-nullability so connectors
 * can populate only what they have.
 */
export type EmailSignals = {
  /** List-Id header value, or null. */
  listId: string | null;
  /** List-Unsubscribe header value, or null. */
  listUnsubscribe: string | null;
  /** Precedence header (e.g. "bulk", "list", "auto_reply"), or null. */
  precedence: string | null;
  /** Auto-Submitted header (e.g. "auto-generated"), or null. */
  autoSubmitted: string | null;
  /**
   * Return-Path header; "<>" / "" indicates a bounce/auto sender. (Connectors
   * whose header getter coerces an empty value to null will pass null here, so
   * the empty-string bounce signal only fires when the value is literally "<>".)
   */
  returnPath: string | null;
  /** Importance / X-Priority header, or null. Carried by connectors; reserved for future heuristics. */
  importance: string | null;
  /** Sender email address, lowercased, or null. */
  fromAddress: string | null;
  /** Count of To + Cc recipients. */
  recipientCount: number;
  /** Whether In-Reply-To / References was present. Carried by connectors; reserved for future heuristics. */
  isReply: boolean;
  /** Subject line, or null. */
  subject: string | null;
  /** Length (chars) of the message body text. */
  bodyLength: number;
  /** Gmail system category labels (e.g. ["CATEGORY_PROMOTIONS"]). */
  gmailCategories: string[];
  /** Plain-text body for code-keyword scanning. Null if unavailable. */
  bodyText: string | null;
  /** Sender display name (e.g. "Acme Security"), for service-name derivation. Null if unavailable. */
  fromName: string | null;
  /** Anchor candidates from the HTML body: visible text → href. Empty if none. */
  links: { text: string; href: string }[];
  /** Raw Authentication-Results header value, for DMARC parsing. Null if unavailable. */
  authResults: string | null;
};

// Recipient count at/above which a directly-addressed email is treated as a list.
const LIST_RECIPIENT_THRESHOLD = 8;
// Body length at/above which a list email reads as long-form "reading".
const READING_MIN_BODY = 1200;
// Body length below which an automated email reads as a "notification".
const NOTIFICATION_MAX_BODY = 700;

const NOREPLY_LOCALPART =
  /^(no-?reply|do-?not-?reply|donotreply|notifications?|notify|mailer-daemon|bounce|postmaster|automated|auto|alerts?|updates?)\b/;

// Calendar invitation-response notification emails (Google/Outlook). The
// subject is prefixed with the responder's verdict, e.g. "Accepted: <event>".
const CAL_RESPONSE_RE = /^\s*(accepted|declined|tentative(?:ly accepted)?):\s/i;

function calendarResponseVerdict(
  subject: string,
  automation: Automation
): "accepted" | "declined" | "tentative" | null {
  // Only automated invitation replies count — a human writing "Accepted: ..."
  // is ordinary correspondence, not a calendar response.
  if (automation !== "automated") return null;
  const m = CAL_RESPONSE_RE.exec(subject);
  if (!m) return null;
  const verb = m[1].toLowerCase();
  if (verb === "accepted") return "accepted";
  if (verb === "declined") return "declined";
  return "tentative";
}

const INVOICE_RE = /\b(invoice|amount due|payment due|past due|statement|bill)\b/i;
const RECEIPT_RE =
  /\b(receipt|order (confirmation|#|number)|your order|payment (received|confirmation)|thanks for your (order|purchase)|purchase confirmation)\b/i;
const PROMO_RE = /\b(sale|% off|\d+% ?off|deal|special offer|discount|coupon|save \$|limited time)\b/i;

function localPart(address: string | null): string {
  if (!address) return "";
  const at = address.indexOf("@");
  return (at === -1 ? address : address.slice(0, at)).toLowerCase();
}

function computeAutomation(s: EmailSignals): Automation {
  const prec = (s.precedence ?? "").toLowerCase();
  if (prec === "bulk" || prec === "list" || prec === "junk" || prec === "auto_reply") return "automated";
  const auto = (s.autoSubmitted ?? "").toLowerCase();
  if (auto && auto !== "no") return "automated";
  if (s.returnPath !== null && (s.returnPath === "" || s.returnPath === "<>")) return "automated";
  // Mailing-list headers (List-Id / List-Unsubscribe) indicate bulk/automated
  // mail — newsletters, announcements, notifications. (A human posting to a
  // discussion list is the rare exception we accept under best-effort.)
  if (s.listId || s.listUnsubscribe) return "automated";
  if (NOREPLY_LOCALPART.test(localPart(s.fromAddress))) return "automated";
  return "human";
}

function computeReach(s: EmailSignals): Reach {
  if (s.listId || s.listUnsubscribe) return "list";
  if (s.recipientCount >= LIST_RECIPIENT_THRESHOLD) return "list";
  const prec = (s.precedence ?? "").toLowerCase();
  if (prec === "bulk" || prec === "list") return "list";
  return "direct";
}

function computeFormat(s: EmailSignals, automation: Automation, reach: Reach): Format | null {
  const subject = s.subject ?? "";
  // Calendar invitation responses: an acceptance is a passive confirmation, so
  // mark it a notification (routes to the muted FYI focus — "skip active"). A
  // decline or tentative may need follow-up, so return null to keep it active
  // AND to stop it falling through to the generic short-automated → notification
  // branch below, which would otherwise sweep it into FYI.
  const verdict = calendarResponseVerdict(subject, automation);
  if (verdict === "accepted") return "notification";
  if (verdict !== null) return null;
  if (INVOICE_RE.test(subject)) return "invoice";
  if (RECEIPT_RE.test(subject)) return "receipt";
  if (s.gmailCategories.includes("CATEGORY_PROMOTIONS")) return "promotion";
  if (reach === "list" && PROMO_RE.test(subject)) return "promotion";
  if (reach === "list" && s.bodyLength >= READING_MIN_BODY) return "reading";
  // A directly-addressed reply is part of a two-way conversation, so treat it
  // as correspondence even when the sending system stamps automated headers
  // (support desks, ticketing systems like Zendesk/Front). Without this, a
  // short automated reply falls through to the notification branch below and
  // gets swept into the muted FYI focus, burying real back-and-forth — e.g. a
  // support agent replying "we need more info" on a request the user opened.
  // Scoped to `direct` reach so list/bulk mail is unaffected.
  if (s.isReply && reach === "direct") return "message";
  if (automation === "automated" && s.bodyLength < NOTIFICATION_MAX_BODY) return "notification";
  if (s.gmailCategories.includes("CATEGORY_UPDATES") || s.gmailCategories.includes("CATEGORY_SOCIAL")) {
    return "notification";
  }
  if (automation === "human") return "message";
  return null;
}

/** Classify an email's intrinsic facets from normalized signals. */
export function classifyEmail(s: EmailSignals): ThreadFacets {
  const automation = computeAutomation(s);
  const reach = computeReach(s);
  return {
    format: computeFormat(s, automation, reach),
    automation,
    reach,
  };
}
