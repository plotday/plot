#!/usr/bin/env tsx
/**
 * PII leak check for anonymized corpora.
 *
 * Library mode (`leakCheck`): the seeders collect the raw PII they saw —
 * emails, contact names, non-freemail domains — and scan every serialized
 * YAML document BEFORE writing it:
 *   - raw value outside title scope  => hard violation (caller must not write)
 *   - raw value on a title / gold_rationale / notes line => warning (titles
 *     are preserved verbatim by policy; warnings are surfaced for audit)
 *
 * CLI mode (`pnpm exec tsx src/seeder/leak-check.ts --corpus <name>`): a
 * heuristic spot check that needs NO raw PII / prod access. It flags
 * email-shaped strings whose domain is neither in the anonymizer's freemail
 * pool nor an example/test domain, grouped by domain for HUMAN review.
 * Because the anonymizer's fake org domains are intentionally realistic,
 * the CLI cannot distinguish them from genuinely leaked org domains — it
 * reports candidates instead of failing, and always exits 0. It also cannot
 * detect leaked freemail addresses (a raw `someone@gmail.com` looks exactly
 * like an anonymized one) or leaked bare names; only the seeder-side
 * `leakCheck` with the raw PII list can do that.
 */
import { readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import { EMAIL_RE, FREEMAIL_POOL, isFreemailDomain } from "./anonymize";

export type RawPii = {
  emails: string[];
  names: string[];
  orgDomains: string[];
};

export type LeakFinding = {
  path: string;
  line: number;
  kind: "email" | "name" | "domain";
  value: string;
  context: string;
};

export type LeakReport = {
  violations: LeakFinding[];
  warnings: LeakFinding[];
};

/**
 * Lines whose hits are warnings instead of violations: thread/priority
 * titles are preserved verbatim by policy, and gold_rationale / notes are
 * free-text authored fields that are audited rather than rewritten.
 * Detection is per-LINE (a finding on the first line of a multi-line scalar
 * is warning-scoped; continuation lines are not — conservative on purpose).
 */
const WARN_SCOPE_RE = /^\s*(?:-\s*)?(?:title|gold_rationale|notes):/;

/**
 * Name-scan false-positive guards: names shorter than MIN_NAME_LENGTH (4)
 * characters are skipped (a contact literally named "Re" or "Ed" would match
 * half the corpus), as are names that are common English/email words.
 */
const MIN_NAME_LENGTH = 4;
const COMMON_WORD_NAMES = new Set([
  "info",
  "mail",
  "email",
  "news",
  "team",
  "admin",
  "sales",
  "support",
  "hello",
  "contact",
  "user",
  "test",
  "none",
  "null",
  "true",
  "false",
  "home",
  "work",
  "noreply",
  "notifications",
  "update",
  "updates",
  "service",
  "alert",
  "alerts",
  "billing",
  "help",
  "office",
]);

function truncate(s: string, max = 160): string {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`;
}

/**
 * Scans serialized YAML docs for raw PII values (case-insensitive; emails
 * use substring match, names use word boundaries, domains use a left
 * boundary). Hits on warn-scoped lines (see WARN_SCOPE_RE) become warnings;
 * everything else becomes a violation. Freemail domains are never treated
 * as domain leaks (gmail.com is not PII), even if passed in `orgDomains`.
 */
export function leakCheck(docs: { path: string; text: string }[], pii: RawPii): LeakReport {
  const emailNeedles = [...new Set(pii.emails.map((e) => e.trim().toLowerCase()).filter(Boolean))];
  // Full-name needles AND per-token needles: a lone leaked first name
  // ("channel:#anna-standup" when pii has "Anna Vendor") is still PII, and a
  // full-name needle would never match it. Tokens split on non-letter
  // boundaries so punctuated names ("Anna (Vendor)") still yield "vendor".
  // The same false-positive guards apply per token (length >= 4, common-word
  // skip), so short/generic tokens don't flood the report.
  // Name-needle policy (tuned on the real kris extraction, which has
  // service-named contacts like "Plot", "Linear", "Link", "Google"):
  //  - MULTI-token full names ("Anna Vendor") are unambiguous PII →
  //    violation-grade.
  //  - Single-token full names and individual name tokens are ambiguous
  //    (brands, services, words that legitimately appear in structural
  //    YAML) → warning-grade, surfaced for human audit.
  //  - Name needles match on WORD BOUNDARIES ("link" must not match
  //    "linked_to_user"); emails keep substring matching. Domain needles use
  //    a LEFT boundary only (see domainBoundaryRe below).
  const fullNameNeedleSet = new Set<string>();
  const tokenNeedleSet = new Set<string>();
  for (const rawName of pii.names) {
    const full = rawName.trim().toLowerCase();
    if (!full) continue;
    const tokens = full.split(/[^\p{L}]+/u).filter(Boolean);
    if (
      tokens.length > 1 &&
      full.length >= MIN_NAME_LENGTH &&
      !COMMON_WORD_NAMES.has(full)
    ) {
      fullNameNeedleSet.add(full);
    }
    for (const token of tokens) {
      if (token.length >= MIN_NAME_LENGTH && !COMMON_WORD_NAMES.has(token)) {
        tokenNeedleSet.add(token);
      }
    }
  }
  const fullNameNeedles = [...fullNameNeedleSet];
  const tokenNeedles = [...tokenNeedleSet].filter(
    (t) => !fullNameNeedleSet.has(t)
  );
  const domainNeedles = [
    ...new Set(
      pii.orgDomains
        .map((d) => d.trim().toLowerCase())
        .filter((d) => d.length > 0 && !isFreemailDomain(d))
    ),
  ];

  // Word-boundary regexes for name needles, compiled once. Lines and needles
  // are both lowercased before matching.
  const boundaryRe = new Map<string, RegExp>();
  for (const n of [...fullNameNeedles, ...tokenNeedles]) {
    const escaped = n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    boundaryRe.set(n, new RegExp(`(?<!\\p{L})${escaped}(?!\\p{L})`, "u"));
  }

  // Domain needles must not match when directly preceded by a letter/digit/
  // hyphen: anonymized fake org domains are intentionally realistic and can
  // coincidentally CONTAIN a real needle as a suffix substring (observed:
  // fake "pebblebay.com"/"pinebay.com" flagged for real needle "ebay.com").
  // Subdomain leaks still match ("mail.ebay.com" — preceded by "."), and
  // there is deliberately NO trailing boundary: "ebay.com.au" containing
  // "ebay.com" IS a leak-ish match.
  const domainBoundaryRe = new Map<string, RegExp>();
  for (const d of domainNeedles) {
    const escaped = d.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    domainBoundaryRe.set(d, new RegExp(`(?<![a-z0-9-])${escaped}`));
  }

  const report: LeakReport = { violations: [], warnings: [] };
  const seen = new Set<string>();

  for (const doc of docs) {
    const lines = doc.text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const rawLine = lines[i]!;
      const lowerLine = rawLine.toLowerCase();
      const warnScope = WARN_SCOPE_RE.test(rawLine);
      const scan = (
        kind: LeakFinding["kind"],
        needles: string[],
        forceWarn = false
      ) => {
        for (const needle of needles) {
          const re =
            kind === "name"
              ? boundaryRe.get(needle)
              : kind === "domain"
                ? domainBoundaryRe.get(needle)
                : null;
          if (re ? !re.test(lowerLine) : !lowerLine.includes(needle)) continue;
          const dedupeKey = `${doc.path}\u0000${i + 1}\u0000${kind}\u0000${needle}`;
          if (seen.has(dedupeKey)) continue;
          seen.add(dedupeKey);
          const finding: LeakFinding = {
            path: doc.path,
            line: i + 1,
            kind,
            value: needle,
            context: truncate(rawLine.trim()),
          };
          (warnScope || forceWarn ? report.warnings : report.violations).push(
            finding
          );
        }
      };
      scan("email", emailNeedles);
      scan("name", fullNameNeedles);
      scan("name", tokenNeedles, true);
      scan("domain", domainNeedles);
    }
  }
  return report;
}

// --- CLI: heuristic corpus spot-check (no raw PII required) ----------------

const HEURISTIC_EXEMPT_TLDS = new Set(["test", "example", "invalid", "localhost"]);
const HEURISTIC_EXEMPT_DOMAINS = new Set<string>([
  ...FREEMAIL_POOL,
  "example.com",
  "example.org",
  "example.net",
]);

function isHeuristicallyExempt(domain: string): boolean {
  if (HEURISTIC_EXEMPT_DOMAINS.has(domain)) return true;
  const tld = domain.slice(domain.lastIndexOf(".") + 1);
  return HEURISTIC_EXEMPT_TLDS.has(tld);
}

function walkFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      walkFiles(full, out);
    } else if (/\.(ya?ml|md)$/.test(entry)) {
      out.push(full);
    }
  }
  return out;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: { corpus: { type: "string" } },
  });
  if (!values.corpus) {
    console.error("Usage: leak-check --corpus <name>");
    process.exit(2);
  }
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const corpusDir = join(scriptDir, "..", "..", "corpora", values.corpus);

  let files: string[];
  try {
    files = walkFiles(corpusDir);
  } catch {
    console.error(`No corpus directory at ${corpusDir}`);
    process.exit(2);
  }

  // domain -> email -> [file:line, ...]
  const suspects = new Map<string, Map<string, string[]>>();
  let emailCount = 0;
  for (const file of files) {
    const lines = readFileSync(file, "utf8").split("\n");
    for (let i = 0; i < lines.length; i++) {
      for (const match of lines[i]!.matchAll(EMAIL_RE)) {
        emailCount++;
        const email = match[0].toLowerCase();
        const domain = email.slice(email.lastIndexOf("@") + 1);
        if (isHeuristicallyExempt(domain)) continue;
        const byEmail = suspects.get(domain) ?? new Map<string, string[]>();
        const locs = byEmail.get(email) ?? [];
        locs.push(`${file.slice(corpusDir.length + 1)}:${i + 1}`);
        byEmail.set(email, locs);
        suspects.set(domain, byEmail);
      }
    }
  }

  console.log(`Heuristic leak scan of corpus '${values.corpus}'`);
  console.log(`  files scanned: ${files.length}, email-shaped strings: ${emailCount}`);
  console.log("");
  if (suspects.size === 0) {
    console.log("No candidate emails outside the freemail pool / example domains.");
  } else {
    console.log(
      `Candidate emails for HUMAN review, grouped by domain (${suspects.size} domain(s)):`
    );
    for (const [domain, byEmail] of [...suspects.entries()].sort()) {
      console.log(`  ${domain}`);
      for (const [email, locs] of [...byEmail.entries()].sort()) {
        const shown = locs.slice(0, 3).join(", ");
        const more = locs.length > 3 ? ` (+${locs.length - 3} more)` : "";
        console.log(`    ${email}  @ ${shown}${more}`);
      }
    }
  }
  console.log("");
  console.log("What this scan CAN detect: email-shaped strings whose domain is not in");
  console.log(`the anonymizer freemail pool (${FREEMAIL_POOL.join(", ")})`);
  console.log("and not an example/test domain. Anonymized org emails are intentionally");
  console.log("realistic, so every candidate above may be a legitimate fake — review by hand.");
  console.log("What it CANNOT detect: leaked freemail addresses (raw someone@gmail.com is");
  console.log("indistinguishable from a fake), leaked bare names, or leaked org domains");
  console.log("appearing outside an email. The seeder-side leakCheck() with the raw PII");
  console.log("list is the enforced gate; this CLI is a spot check only.");
  process.exit(0);
}

function isMainModule(): boolean {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (isMainModule()) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
