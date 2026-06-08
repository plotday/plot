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
  /** Return-Path header; "<>" / "" indicates a bounce/auto sender. */
  returnPath: string | null;
  /** Importance / X-Priority header, or null. */
  importance: string | null;
  /** Sender email address, lowercased, or null. */
  fromAddress: string | null;
  /** Count of To + Cc recipients. */
  recipientCount: number;
  /** Whether In-Reply-To / References was present. */
  isReply: boolean;
  /** Subject line, or null. */
  subject: string | null;
  /** Length (chars) of the message body text. */
  bodyLength: number;
  /** Gmail system category labels (e.g. ["CATEGORY_PROMOTIONS"]). */
  gmailCategories: string[];
};

// Recipient count at/above which a directly-addressed email is treated as a list.
const LIST_RECIPIENT_THRESHOLD = 8;
// Body length at/above which a list email reads as long-form "reading".
const READING_MIN_BODY = 1200;
// Body length below which an automated email reads as a "notification".
const NOTIFICATION_MAX_BODY = 700;

const NOREPLY_LOCALPART =
  /^(no-?reply|do-?not-?reply|donotreply|notifications?|notify|mailer-daemon|bounce|postmaster|automated|auto|alerts?|updates?)\b/;

const INVOICE_RE = /\b(invoice|amount due|payment due|past due|statement|bill)\b/i;
const RECEIPT_RE =
  /\b(receipt|order (confirmation|#|number)|your order|payment (received|confirmation)|thanks for your (order|purchase)|purchase confirmation)\b/i;
const PROMO_RE = /\b(sale|% off|\d+% ?off|deal|offer|discount|coupon|save \$|limited time)\b/i;

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
  if (INVOICE_RE.test(subject)) return "invoice";
  if (RECEIPT_RE.test(subject)) return "receipt";
  if (s.gmailCategories.includes("CATEGORY_PROMOTIONS")) return "promotion";
  if (reach === "list" && PROMO_RE.test(subject)) return "promotion";
  if (reach === "list" && s.bodyLength >= READING_MIN_BODY) return "reading";
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
