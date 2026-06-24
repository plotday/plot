import type { Cta } from "@plotday/twister/facets";
import { classifyEmail, type EmailSignals } from "./classify-email";

// ---- domains ---------------------------------------------------------------
// Minimal multi-label public suffixes for registrable-domain comparison.
// Not a full PSL — conservative: unknown suffixes fall back to last 2 labels.
const MULTI_SUFFIX = new Set([
  "co.uk", "org.uk", "gov.uk", "ac.uk", "co.jp", "com.au", "net.au", "org.au",
  "co.nz", "com.br", "co.in", "co.za",
]);

function registrableDomain(host: string | null): string | null {
  if (!host) return null;
  let h = host.toLowerCase().trim().replace(/^www\./, "").replace(/:\d+$/, "");
  const parts = h.split(".").filter(Boolean);
  if (parts.length < 2) return null;
  const last2 = parts.slice(-2).join(".");
  if (parts.length >= 3 && MULTI_SUFFIX.has(last2)) return parts.slice(-3).join(".");
  return last2;
}

function domainOfAddress(address: string | null): string | null {
  if (!address) return null;
  const at = address.indexOf("@");
  return at === -1 ? null : address.slice(at + 1);
}

// ---- service name ----------------------------------------------------------
const SERVICE_NOISE =
  /\b(no-?reply|do-?not-?reply|notifications?|notify|team|support|security|account|alerts?|mail(er)?|info|hello|accounts?)\b/gi;

function titleCase(s: string): string {
  return s.replace(/\b\w/g, (c) => c.toUpperCase());
}

function serviceName(s: EmailSignals): string {
  const name = (s.fromName ?? "")
    .replace(SERVICE_NOISE, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 60);
  if (name) return name;
  const reg = registrableDomain(domainOfAddress(s.fromAddress));
  if (reg) return titleCase(reg.split(".")[0]);
  return "this service";
}

// ---- OTP code --------------------------------------------------------------
const CODE_KEYWORD =
  /(one[\s-]?time|verification|security|confirmation|access|login|sign[\s-]?in|auth(entication)?|2fa|two[\s-]?factor|otp|passcode|pass\s?code|pin|code)/i;
// Alphanumeric (e.g. "G-557812", "ABZ419") OR a 4–8 digit numeric code.
// Numeric-only requires ≥4 digits to avoid matching short incidental numbers.
const CODE_TOKEN = /\b([A-Z]{1,4}-\d{3,8}|[A-Z]{1,4}\d{3,8}|\d{4,8})\b/;

function looksLikeYear(t: string): boolean {
  return /^\d{4}$/.test(t) && Number(t) >= 1900 && Number(t) <= 2100;
}

// All-same-digit numeric tokens (0000, 9999, 000000, …) are promo placeholders,
// never real one-time codes. Cheap, high-precision FP filter for marketing mail
// that survives the reach/promotion gate (e.g. a direct "Your code: 000000").
function looksLikePlaceholder(t: string): boolean {
  return /^(\d)\1{3,}$/.test(t);
}

function extractOtp(s: EmailSignals): string | null {
  const hay = `${s.subject ?? ""}\n${s.bodyText ?? ""}`;
  if (!hay.trim()) return null;
  for (const rawLine of hay.split(/\n+/)) {
    const line = rawLine.trim();
    if (!CODE_KEYWORD.test(line)) continue;
    if (/\$\s?\d|#\s?\d|\border\b|\binvoice\b|\btotal\b/i.test(line)) continue;
    const m = line.match(CODE_TOKEN);
    if (!m) continue;
    const tok = m[1];
    if (looksLikeYear(tok)) continue;
    if (looksLikePlaceholder(tok)) continue;
    return tok;
  }
  return null;
}

// ---- DMARC + confirm link --------------------------------------------------
// The DMARC-verified registrable domain from the RECEIVING provider's trusted
// Authentication-Results. Returns null unless there is a `dmarc=pass` WITH a
// `header.from` domain.
//
// SECURITY CONTRACT: the connector MUST pass only its provider MTA's
// Authentication-Results header value (selected by authserv-id), NEVER a
// sender-inserted one — otherwise `dmarc=pass` can be forged. See the Gmail /
// Outlook connector tasks for trusted-header selection.
function dmarcVerifiedDomain(authResults: string | null): string | null {
  if (!authResults) return null;
  // NOTE: header.from is normally a bare domain (RFC 7489 §6.6.1), but some
  // MTAs emit the full mailbox form (user@domain) — strip the localpart.
  const m = authResults.match(
    /dmarc\s*=\s*pass\b[^;]*?header\.from\s*=\s*"?([a-z0-9.@-]+)"?/i
  );
  if (!m) return null;
  const raw = m[1].includes("@") ? m[1].split("@")[1] : m[1];
  return registrableDomain(raw);
}

function httpHost(href: string): string | null {
  let u: URL;
  try {
    u = new URL(href);
  } catch {
    return null;
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  return u.hostname;
}

const CONFIRM_VERB =
  /\b(confirm|verify|activate|complete (your )?(sign[\s-]?up|registration))\b/i;
const NEGATIVE_LINK =
  /\b(wasn'?t (you|me)|was not (you|me)|did ?n'?t (request|sign)|not (you|me)|reset|change (your )?password|unsubscribe|report|cancel|decline|manage|view (in|on) (browser|web)|privacy|terms|help|update preferences)\b/i;

function extractConfirmUrl(s: EmailSignals): string | null {
  const verified = dmarcVerifiedDomain(s.authResults);
  if (!verified) return null;
  // The DMARC-verified domain must match the sender's own domain (reject a
  // dmarc=pass issued for some other header.from).
  const sender = registrableDomain(domainOfAddress(s.fromAddress));
  if (!sender || sender !== verified) return null;
  // The link must use http(s) AND sit on the verified registrable domain
  // (subdomains allowed). This is what makes a DMARC pass meaningful for links.
  const matches = s.links.filter((l) => {
    if (!CONFIRM_VERB.test(l.text) || NEGATIVE_LINK.test(l.text)) return false;
    const host = httpHost(l.href);
    return host !== null && registrableDomain(host) === verified;
  });
  if (matches.length === 0) return null;
  const distinct = Array.from(new Set(matches.map((m) => m.href)));
  if (distinct.length !== 1) return null;
  return distinct[0];
}

// ---- public API ------------------------------------------------------------
/**
 * Extract a time-sensitive CTA from an email's signals. OTP wins over confirm
 * when both are present. Confirm links require: a DMARC pass aligned to the
 * sender's domain, an http(s) scheme, and the link host on the verified
 * registrable domain. Returns null unless a high-confidence detection is made
 * (bias to false-negative).
 *
 * Bulk/promotional mail is suppressed up front: a genuine one-time code or
 * account-confirmation link is transactional and directly addressed — never a
 * mailing-list blast. Gating on reach=list / format=promotion eliminates the
 * dominant false-positive class (a 4-8 digit discount code, price, or SKU
 * sitting near the word "code" in a marketing email) that otherwise fires an
 * immediate, gate-bypassing OTP push for every promo the user receives.
 */
export function extractCta(s: EmailSignals): Cta | null {
  const { reach, format } = classifyEmail(s);
  if (reach === "list" || format === "promotion") return null;

  const service = serviceName(s);
  const code = extractOtp(s);
  if (code) return { kind: "otp", service, code, url: extractConfirmUrl(s) };
  const url = extractConfirmUrl(s);
  if (url) return { kind: "confirm", service, code: null, url };
  return null;
}
