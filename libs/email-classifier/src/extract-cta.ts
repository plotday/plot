import type { Cta } from "@plotday/twister/facets";
import type { EmailSignals } from "./classify-email";

// ---- service name ----------------------------------------------------------
const SERVICE_NOISE =
  /\b(no-?reply|do-?not-?reply|notifications?|notify|team|support|security|account|alerts?|mail(er)?|info|hello|accounts?)\b/gi;

function titleCase(s: string): string {
  return s.replace(/\b\w/g, (c) => c.toUpperCase());
}

function registrableName(address: string | null): string | null {
  if (!address) return null;
  const at = address.indexOf("@");
  if (at === -1) return null;
  const domain = address.slice(at + 1).toLowerCase();
  const parts = domain.split(".").filter(Boolean);
  if (parts.length < 2) return null;
  const label = parts[parts.length - 2];
  return label ? titleCase(label) : null;
}

function serviceName(s: EmailSignals): string {
  const name = (s.fromName ?? "").replace(SERVICE_NOISE, " ").replace(/\s+/g, " ").trim();
  if (name) return name;
  return registrableName(s.fromAddress) ?? "this service";
}

// ---- OTP code --------------------------------------------------------------
const CODE_KEYWORD =
  /(one[\s-]?time|verification|security|confirmation|access|login|sign[\s-]?in|auth(entication)?|2fa|two[\s-]?factor|otp|passcode|pass\s?code|pin|code)/i;
const CODE_TOKEN = /\b([A-Z]{0,4}-?\d{3,8}|\d{4,8})\b/;

function looksLikeYear(t: string): boolean {
  return /^\d{4}$/.test(t) && Number(t) >= 1900 && Number(t) <= 2100;
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
    return tok;
  }
  return null;
}

// ---- DMARC + confirm link --------------------------------------------------
function dmarcPasses(authResults: string | null): boolean {
  if (!authResults) return false;
  return /\bdmarc\s*=\s*pass\b/i.test(authResults);
}

const CONFIRM_VERB =
  /\b(confirm|verify|activate|complete (your )?(sign[\s-]?up|registration))\b/i;
const NEGATIVE_LINK =
  /\b(wasn'?t (you|me)|was not (you|me)|did ?n'?t (request|sign)|not (you|me)|reset|change (your )?password|unsubscribe|report|cancel|decline|manage|view (in|on) (browser|web)|privacy|terms|help|update preferences)\b/i;

function extractConfirmUrl(s: EmailSignals): string | null {
  if (!dmarcPasses(s.authResults)) return null;
  const matches = s.links.filter(
    (l) => CONFIRM_VERB.test(l.text) && !NEGATIVE_LINK.test(l.text)
  );
  if (matches.length === 0) return null;
  const distinct = Array.from(new Set(matches.map((m) => m.href)));
  if (distinct.length !== 1) return null;
  return distinct[0];
}

// ---- public API ------------------------------------------------------------
/**
 * Extract a time-sensitive CTA from an email's signals. OTP wins over confirm
 * when both are present. Confirm links require DMARC pass. Returns null unless
 * a high-confidence detection is made (bias to false-negative).
 */
export function extractCta(s: EmailSignals): Cta | null {
  const code = extractOtp(s);
  const service = serviceName(s);
  if (code) {
    return { kind: "otp", service, code, url: extractConfirmUrl(s) };
  }
  const url = extractConfirmUrl(s);
  if (url) {
    return { kind: "confirm", service, code: null, url };
  }
  return null;
}
