/**
 * Shape-preserving anonymization (v2).
 *
 * Replaces the v1 opaque tokens (`Person <hash>` / `c-<hash>@example.test`)
 * with realistic, deterministic fakes so anonymized corpora keep the
 * statistical shape the classifier relies on:
 *
 * - Freemail input domains map into a fixed pool of REAL freemail domains
 *   that are present in the DB's freemail seed
 *   (libs/db/schema/99-data/10-domains.sql), so freemail-ness survives in
 *   `connection_org_key` / `author_matches_org_domain`.
 * - Org input domains map to stable fake org domains built from word pools
 *   (e.g. "lumenforge.com") — absent from `public.domain`, so they still
 *   count as org domains, and domain equality is preserved (same source
 *   domain => same fake domain), keeping org-key grouping intact.
 *
 * Every derivation is seeded from sha256(NAMESPACE + salt + input): the same
 * input produces the same output across calls, processes, and re-runs. The
 * mapping is never persisted; it is recomputed from raw values when needed.
 *
 * Idempotency is NOT guaranteed (anonymizing an already-fake value may remap
 * it); determinism IS.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { FIRST_NAMES, LAST_NAMES, ORG_WORDS_A, ORG_WORDS_B } from "./name-pools";

const NAMESPACE = "plotday-eval-anonymize-v2";

/** Deterministic short hash for stable PII tokens. */
export function hashShort(input: string, length = 8): string {
  return createHash("sha256").update(`${NAMESPACE}:${input}`).digest("hex").slice(0, length);
}

/** Deterministic pool index: sha256 hex slice (48 bits) mod pool size. */
function pickIndex(input: string, salt: string, poolSize: number): number {
  const hex = createHash("sha256")
    .update(`${NAMESPACE}:${salt}:${input}`)
    .digest("hex")
    .slice(0, 12);
  return Number.parseInt(hex, 16) % poolSize;
}

/**
 * Output pool for freemail domains. Fixed and intentionally small; every
 * member is present in the freemail seed
 * (libs/db/schema/99-data/10-domains.sql), so the classifier's freemail
 * check keeps treating anonymized addresses as freemail.
 */
export const FREEMAIL_POOL = [
  "gmail.com",
  "yahoo.com",
  "outlook.com",
  "hotmail.com",
  "icloud.com",
  "aol.com",
] as const;

/**
 * Core freemail list used when the SQL seed file is unreadable (e.g. the
 * package consumed outside the monorepo). Detection only — output always
 * comes from FREEMAIL_POOL.
 */
const FREEMAIL_FALLBACK = [
  "gmail.com",
  "googlemail.com",
  "yahoo.com",
  "hotmail.com",
  "outlook.com",
  "live.com",
  "icloud.com",
  "me.com",
  "aol.com",
  "proton.me",
  "protonmail.com",
  "gmx.com",
];

/**
 * Parse the freemail domain names from the DB seed file. The seed's rows look
 * like `('gmail.com', true),`. Falls back to FREEMAIL_FALLBACK if the file
 * is missing or yields nothing.
 */
function loadFreemailDomains(): Set<string> {
  try {
    const sqlPath = join(
      dirname(fileURLToPath(import.meta.url)),
      "..",
      "..",
      "..",
      "db",
      "schema",
      "99-data",
      "10-domains.sql"
    );
    const sql = readFileSync(sqlPath, "utf8");
    const parsed = new Set<string>();
    for (const m of sql.matchAll(/\('([^']+)',\s*true\)/g)) {
      parsed.add(m[1]!.toLowerCase());
    }
    if (parsed.size > 0) return parsed;
  } catch {
    // Fall through to the hard-coded core list. Not reported anywhere:
    // this is an expected condition when the package runs standalone.
  }
  return new Set(FREEMAIL_FALLBACK);
}

const FREEMAIL_DOMAINS = loadFreemailDomains();

/**
 * True when `domain` is a known freemail provider. Exact-match only on the
 * full lowercased domain, mirroring the DB's
 * `lower(split_part(email, '@', 2))` check — `mail.google.com` is NOT
 * freemail even though `gmail.com` is.
 */
export function isFreemailDomain(domain: string): boolean {
  return FREEMAIL_DOMAINS.has(domain.trim().toLowerCase());
}

/**
 * Realistic fake name. Multi-token input -> "First Last"; single token ->
 * one fake first name. Deterministic in the raw input string.
 */
export function anonymizeName(name: string | null): string | null {
  if (!name) return name;
  const trimmed = name.trim();
  if (!trimmed) return name;
  const tokens = trimmed.split(/\s+/);
  const first = FIRST_NAMES[pickIndex(trimmed, "first-name", FIRST_NAMES.length)]!;
  if (tokens.length === 1) return first;
  const last = LAST_NAMES[pickIndex(trimmed, "last-name", LAST_NAMES.length)]!;
  return `${first} ${last}`;
}

/**
 * Freemail domains map into FREEMAIL_POOL (real freemail, still classified
 * as freemail by the DB seed); org domains map to stable fake org domains
 * (`<wordA><wordB>.com`). Case-insensitive on input; output is lowercase.
 * Same input domain => same output domain.
 */
export function anonymizeDomain(domain: string): string {
  const lower = domain.trim().toLowerCase();
  if (!lower) return domain;
  if (FREEMAIL_DOMAINS.has(lower)) {
    return FREEMAIL_POOL[pickIndex(lower, "freemail", FREEMAIL_POOL.length)]!;
  }
  const wordA = ORG_WORDS_A[pickIndex(lower, "org-a", ORG_WORDS_A.length)]!;
  const wordB = ORG_WORDS_B[pickIndex(lower, "org-b", ORG_WORDS_B.length)]!;
  return `${wordA}${wordB}.com`;
}

/**
 * Anonymized email. Local part derived from the anonymized name when
 * provided (`first.last`), else from the local part's hash; domain via
 * anonymizeDomain, so the freemail/org class is preserved.
 */
export function anonymizeEmail(email: string | null, name?: string | null): string | null {
  if (!email) return email;
  const trimmed = email.trim();
  if (!trimmed) return email;
  const at = trimmed.lastIndexOf("@");
  if (at <= 0 || at === trimmed.length - 1) {
    // Not email-shaped; replace wholesale with a stable opaque token rather
    // than risking a partial leak.
    return `c-${hashShort(trimmed.toLowerCase(), 12)}`;
  }
  const rawLocal = trimmed.slice(0, at);
  const rawDomain = trimmed.slice(at + 1);
  // A blank/whitespace-only name is "no name": anonymizeName passes it
  // through unchanged, which would otherwise collapse to a "." local part.
  const fakeName = name?.trim() ? anonymizeName(name) : null;
  const local = fakeName
    ? fakeName.toLowerCase().split(/\s+/).join(".")
    : `c-${hashShort(rawLocal.toLowerCase(), 12)}`;
  return `${local}@${anonymizeDomain(rawDomain)}`;
}

/** Coherent fake name+email pair for one person. */
export function anonymizePerson(p: { name: string | null; email: string | null }): {
  name: string | null;
  email: string | null;
} {
  return {
    name: anonymizeName(p.name),
    email: anonymizeEmail(p.email, p.name),
  };
}

/** Email-shaped substrings (used by anonymizeTopic and the leak-check CLI). */
export const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}/g;

/**
 * Catches @-address-shaped tokens that EMAIL_RE (intentionally ASCII-only)
 * cannot match — e.g. internationalized addresses like `anna@münchen.de`.
 * A "token" is a maximal run of plausible address characters (no whitespace,
 * no `:`/`<`/`>`/`,`/`;`/parens/quotes, so `channel:`-style prefixes stay
 * outside the match) containing an `@` with non-empty content on both sides.
 */
const LEFTOVER_AT_TOKEN_RE = /[^\s:<>,;()"'`]+@[^\s:<>,;()"'`]+/gu;

/** EMAIL_RE anchored to the whole string (does this token LOOK like a fake?). */
const ASCII_EMAIL_EXACT_RE = new RegExp(`^(?:${EMAIL_RE.source})$`);

/**
 * Rewrites email-shaped substrings inside topic strings via anonymizeEmail;
 * everything else stays verbatim. Determinism preserves topic equality and
 * the `channel:` / `priority:` prefix structure (e.g. Gmail channels keyed
 * by address: `channel:kris@plot.day` -> `channel:<fake>@<fake-domain>`).
 * Note `priority:@plot.app` has no local part, so it is left unchanged.
 *
 * Second pass: EMAIL_RE is ASCII-only by design — there is no safe way to
 * parse IDN / non-ASCII addresses with a regex, and a partial parse risks
 * leaving raw PII fragments behind. So we fail closed instead: any remaining
 * @-bearing token the first pass did not rewrite is replaced wholesale with
 * an opaque deterministic token (`c-<hash>@redacted.example`). Losing the
 * token's shape beats leaking it. First-pass outputs are themselves full
 * ASCII email matches, so they are recognized and left alone.
 */
export function anonymizeTopic(topic: string | null): string | null {
  if (!topic) return topic;
  const firstPass = topic.replace(EMAIL_RE, (match) => anonymizeEmail(match) ?? match);
  return firstPass.replace(LEFTOVER_AT_TOKEN_RE, (token) =>
    ASCII_EMAIL_EXACT_RE.test(token) ? token : `c-${hashShort(token, 12)}@redacted.example`
  );
}

const GROUP_TOKEN_RE = /[A-Za-z][A-Za-z'-]*/g;

/**
 * Replaces tokens in a group name that match any token of any collected
 * contact name (case-insensitive, whole-word) with the corresponding token
 * of the contact's anonymized name (messaging groups are routinely named
 * after participants). Non-token characters (separators, emoji, digits) are
 * preserved.
 *
 * Returns the scrubbed name, whether any token was replaced, and the tokens
 * that matched no contact-name token (`residueTokens`) — the caller decides
 * whether residue warrants a warn-and-audit entry.
 */
export function scrubGroupName(
  groupName: string,
  contactNames: string[]
): { scrubbed: string; replacedAny: boolean; residueTokens: string[] } {
  // Map each raw contact-name token (lowercased) to its anonymized
  // counterpart token. First raw token -> fake first; every later raw token
  // (middle names, surnames) -> fake last, so surname-only mentions still
  // scrub to the same person's fake surname.
  const tokenMap = new Map<string, string>();
  for (const contactName of contactNames) {
    if (!contactName) continue;
    const rawTokens = contactName.trim().split(/\s+/).filter(Boolean);
    if (rawTokens.length === 0) continue;
    const fake = anonymizeName(contactName);
    if (!fake) continue;
    const fakeTokens = fake.split(" ");
    const fakeFirst = fakeTokens[0]!;
    const fakeLast = fakeTokens[fakeTokens.length - 1]!;
    rawTokens.forEach((raw, i) => {
      const key = raw.toLowerCase();
      if (!tokenMap.has(key)) tokenMap.set(key, i === 0 ? fakeFirst : fakeLast);
    });
  }

  let replacedAny = false;
  const residueTokens: string[] = [];
  const scrubbed = groupName.replace(GROUP_TOKEN_RE, (token) => {
    const fake = tokenMap.get(token.toLowerCase());
    if (fake !== undefined) {
      replacedAny = true;
      return fake;
    }
    residueTokens.push(token);
    return token;
  });
  return { scrubbed, replacedAny, residueTokens };
}
