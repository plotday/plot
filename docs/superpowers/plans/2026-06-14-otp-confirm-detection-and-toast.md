# OTP / Confirm Detection + Time-Sensitive Action Toast — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect OTP-code and "confirm your account" emails at ingest, extract the code/link/service heuristically (DMARC-gated for links), sync the payload to the client on a new `note.cta` column, and surface it as a 5-minute dismissable in-app toast (replace-by-latest) plus an immediate background OS notification.

**Architecture:** Detection is a pure heuristic in the shared `public/libs/email-classifier` lib (used by Gmail + Outlook). The SDK (`public/twister`) defines the new `Format` values and the `Cta` payload type, carried on `NewNote.cta` → a new synced `note.cta` jsonb column → the Flutter `Note` model. A Flutter controller watches recent notes with a `cta` and drives one global toast; the API fires an immediate gate-bypassing data-only push when a fresh `cta` note is persisted, which the client renders as a local OS notification.

**Tech Stack:** TypeScript (twister SDK, email-classifier, connectors, Cloudflare Workers API), Atlas/Postgres (schema), Dart/Flutter + Drift + forui (app), FCM (push).

**Spec:** `docs/superpowers/specs/2026-06-14-otp-confirm-detection-and-toast-design.md`

---

## Conventions for every task

- **Public submodule** (`public/`): all of Phase 1–3 is inside the `public/` git submodule. Before starting, create a branch in the submodule: `cd public && git checkout -b otp-confirm-detection`. After editing twister, run `cd public/twister && pnpm build`. All Phase 1–3 work ships as **one public PR**; the core repo references the submodule commit.
- **Changesets:** ONLY `public/twister/src/**` changes need a changeset (see `public/AGENTS.md`). `email-classifier` and connector changes do **not**.
- **Lint/build before commit:** TS packages — `pnpm exec tsc --noEmit` in the package (or `pnpm lint`). Flutter — `cd apps/plot && flutter analyze` on changed files.
- **Worktree DB:** this plan adds a migration. Use the worktree's DB. Verify the port before every DB command: `psql "$DATABASE_URL" -tAc "show port;"` must NOT print 54322 if you're in a worktree (see `libs/db/AGENTS.md`).

---

## File structure

**`public/` submodule:**
- `public/twister/src/facets.ts` — `Format` += `otp`/`confirm`; new `Cta` + `CtaKind` types.
- `public/twister/src/plot.ts` — `NewNote.cta` + `Note.cta` fields.
- `public/.changeset/otp-confirm-cta.md` — changeset.
- `public/libs/email-classifier/src/classify-email.ts` — `EmailSignals` new input fields (no logic change to `classifyEmail`).
- `public/libs/email-classifier/src/extract-cta.ts` — **new** — `extractCta(signals): Cta | null`.
- `public/libs/email-classifier/src/extract-link-candidates.ts` — **new** — `extractLinkCandidates(html): {text,href}[]`.
- `public/libs/email-classifier/src/index.ts` — export the new functions/types.
- `public/libs/email-classifier/src/extract-cta.test.ts` — **new** — heuristic tests (+ anonymized corpus).
- `public/libs/email-classifier/src/extract-link-candidates.test.ts` — **new**.
- `public/connectors/gmail/src/gmail-facets.ts` — populate new signals, call `extractCta`, return `{facets, cta}`.
- `public/connectors/gmail/src/gmail-api.ts` — export a helper to get raw HTML for the parent message (for link extraction).
- `public/connectors/gmail/src/gmail.ts` — attach `cta` to the parent note.
- `public/connectors/outlook-mail/src/outlook-facets.ts` — same as gmail-facets.
- `public/connectors/outlook-mail/src/outlook-mail.ts` — attach `cta` to the parent note.

**Core repo:**
- `libs/db/schema/50-tables/25-note.sql` — `cta jsonb` column + comment.
- `libs/db/schema/90-user-schema/31-note.sql` — add `n.cta` to `user.note`; `NULL::jsonb AS cta` to `user.note_redacted`.
- `libs/db/migrations/*` — generated.
- `libs/db/src/types.ts` — regenerated.
- `workers/api/src/twist/tools/plot/note.ts` — map `note.cta` into `dbNote`.
- `workers/api/src/notifications/otp-push.ts` — **new** — immediate gate-bypassing OTP push.
- `workers/api/src/twist/tools/plot/note.ts` (or createNote caller) — call the OTP push after persisting a fresh-cta note.
- `apps/plot/lib/store/note.dart` — `Cta` model, `cta` column, converter, `Note.cta`.
- `apps/plot/lib/store/store.dart` — schemaVersion bump + migration step.
- `apps/plot/lib/state/otp_prompt_controller.dart` — **new** — watch + window + replace-by-latest.
- `apps/plot/lib/state/root_provider.dart` — instantiate controller + render overlay.
- `apps/plot/lib/widget/otp_toast.dart` — **new** — the toast widget (otp/confirm variants).
- `apps/plot/lib/notifications/notification_service.dart` + `background_handler.dart` — handle `type:"otp"`.
- `apps/plot/test/store/...` + `apps/plot/test/...` — Flutter tests.
- `docs/updates.md`, `docs/features.md` — user-facing docs.

---

## Phase 1 — SDK types (twister)

### Task 1: Add `otp`/`confirm` to `Format` and the `Cta` type

**Files:**
- Modify: `public/twister/src/facets.ts`

- [ ] **Step 1: Extend `Format` and add `Cta`/`CtaKind`.**

In `public/twister/src/facets.ts`, change the `Format` union and append the new types at the end of the file:

```ts
/** The kind of content. Single-valued. */
export type Format =
  | "chat"
  | "message"
  | "reading"
  | "notification"
  | "receipt"
  | "invoice"
  | "promotion"
  | "otp"        // time-sensitive one-time passcode
  | "confirm";   // confirm/verify-your-account call to action
```

```ts
/**
 * A time-sensitive call-to-action extracted from a message (e.g. an OTP code
 * or a "confirm your account" link). Carried on a note so the client can show
 * an ephemeral prompt. Heuristic + best-effort; null when nothing confident is
 * found. Link (`url`) is only ever populated for DMARC-authenticated mail.
 */
export type CtaKind = "otp" | "confirm";

export type Cta = {
  kind: CtaKind;
  /** Display name of the originating service, e.g. "Acme". */
  service: string;
  /** The one-time code, for kind === "otp". Null otherwise. */
  code: string | null;
  /** The confirm/verify URL, for kind === "confirm". Null otherwise. DMARC-verified. */
  url: string | null;
};
```

- [ ] **Step 2: Verify types compile.**

Run: `cd public/twister && pnpm exec tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit (in submodule).**

```bash
cd public && git add twister/src/facets.ts && git commit -m "feat(twister): add otp/confirm Format + Cta type"
```

### Task 2: Add `cta` to `NewNote` and `Note`

**Files:**
- Modify: `public/twister/src/plot.ts` (the `Note` type ~658-699 and `NewNote` type ~710-747)

- [ ] **Step 1: Import `Cta` and add the field.**

At the top of `plot.ts`, ensure `Cta` is imported from `./facets` (there is already a `ThreadFacets` import path used by `NewLink`; add `Cta` to it):

```ts
import type { Cta } from "./facets";
```

On the `Note` type, add (nullable, following the AGENTS.md entity standard):

```ts
  /**
   * A time-sensitive call-to-action extracted from this note's message
   * (OTP code or confirm link). Null when none detected. Set by the runtime
   * from the connector's extraction; clients read it to show an ephemeral prompt.
   */
  cta: Cta | null;
```

On `NewNote` (the `Partial`-style new type), add the optional field:

```ts
  cta?: Cta | null;
```

- [ ] **Step 2: Verify + build twister.**

Run: `cd public/twister && pnpm exec tsc --noEmit && pnpm build`
Expected: no errors; `dist/` updated.

- [ ] **Step 3: Add changeset.**

Create `public/.changeset/otp-confirm-cta.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `otp` and `confirm` Format values and a `Cta` type ({ kind, service, code, url }) on Note/NewNote for time-sensitive OTP / confirm-link prompts.
```

Validate: `cd public && pnpm validate-changesets`
Expected: passes.

- [ ] **Step 4: Commit (in submodule).**

```bash
cd public && git add twister/src/plot.ts .changeset/otp-confirm-cta.md && git commit -m "feat(twister): add Cta to Note/NewNote + changeset"
```

---

## Phase 2 — email-classifier extraction

### Task 3: Extend `EmailSignals` with body/from-name/links/auth inputs

**Files:**
- Modify: `public/libs/email-classifier/src/classify-email.ts` (the `EmailSignals` type, lines 8-37)

- [ ] **Step 1: Add the new nullable input fields.**

Append to the `EmailSignals` type (do NOT change `classifyEmail` logic — it ignores these):

```ts
  /** Plain-text body for code-keyword scanning. Null if unavailable. */
  bodyText: string | null;
  /** Sender display name (e.g. "Acme Security"), for service-name derivation. Null if unavailable. */
  fromName: string | null;
  /** Anchor candidates from the HTML body: visible text → href. Empty if none. */
  links: { text: string; href: string }[];
  /** Raw Authentication-Results header value, for DMARC parsing. Null if unavailable. */
  authResults: string | null;
```

> These are additive. Existing `classifyEmail` callers in tests will fail to typecheck until updated — that is handled in Task 6/7 where connectors set them, and in Task 5's tests which construct full signals. Provide them in any test fixture you touch.

- [ ] **Step 2: Verify compile (expect downstream test breakage, fix in later tasks).**

Run: `cd public/libs/email-classifier && pnpm exec tsc --noEmit`
Expected: errors ONLY in `classify-email.test.ts` (missing new fields). Note them; they're fixed in Task 5 Step 5.

- [ ] **Step 3: Commit.**

```bash
cd public && git add libs/email-classifier/src/classify-email.ts && git commit -m "feat(email-classifier): add bodyText/fromName/links/authResults to EmailSignals"
```

### Task 4: `extractLinkCandidates(html)` helper (TDD)

**Files:**
- Create: `public/libs/email-classifier/src/extract-link-candidates.ts`
- Create: `public/libs/email-classifier/src/extract-link-candidates.test.ts`

- [ ] **Step 1: Write the failing test.**

`extract-link-candidates.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { extractLinkCandidates } from "./extract-link-candidates";

describe("extractLinkCandidates", () => {
  it("pairs anchor text with href", () => {
    const html = `<p>Hi</p><a href="https://acme.com/confirm?t=abc">Confirm email</a>`;
    expect(extractLinkCandidates(html)).toEqual([
      { text: "Confirm email", href: "https://acme.com/confirm?t=abc" },
    ]);
  });

  it("collapses inner tags and whitespace in anchor text", () => {
    const html = `<a href="https://x.io/v"><b>Verify</b>\n  account</a>`;
    expect(extractLinkCandidates(html)).toEqual([
      { text: "Verify account", href: "https://x.io/v" },
    ]);
  });

  it("ignores anchors without an href and non-http schemes", () => {
    const html = `<a>nope</a><a href="mailto:x@y.z">mail</a><a href="https://ok.io/c">go</a>`;
    expect(extractLinkCandidates(html)).toEqual([
      { text: "go", href: "https://ok.io/c" },
    ]);
  });

  it("returns [] for empty/no-anchor html", () => {
    expect(extractLinkCandidates("<p>no links</p>")).toEqual([]);
    expect(extractLinkCandidates("")).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it; verify it fails.**

Run: `cd public/libs/email-classifier && pnpm exec vitest run src/extract-link-candidates.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement.**

`extract-link-candidates.ts` (regex-based; runs in the connector before server-side markdown conversion — we only need text↔href pairs, not a full DOM):

```ts
export type LinkCandidate = { text: string; href: string };

const ANCHOR_RE = /<a\b[^>]*?\bhref\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi;
const TAG_RE = /<[^>]+>/g;

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&nbsp;/gi, " ");
}

/** Extract visible-text → href pairs from email HTML. http(s) only. */
export function extractLinkCandidates(html: string): LinkCandidate[] {
  if (!html) return [];
  const out: LinkCandidate[] = [];
  for (const m of html.matchAll(ANCHOR_RE)) {
    const href = decodeEntities((m[2] ?? m[3] ?? m[4] ?? "").trim());
    if (!/^https?:\/\//i.test(href)) continue;
    const text = decodeEntities(m[5].replace(TAG_RE, " "))
      .replace(/\s+/g, " ")
      .trim();
    out.push({ text, href });
  }
  return out;
}
```

- [ ] **Step 4: Run; verify pass.**

Run: `cd public/libs/email-classifier && pnpm exec vitest run src/extract-link-candidates.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit.**

```bash
cd public && git add libs/email-classifier/src/extract-link-candidates.ts libs/email-classifier/src/extract-link-candidates.test.ts && git commit -m "feat(email-classifier): extractLinkCandidates html anchor helper"
```

### Task 5: `extractCta(signals)` heuristic (TDD)

**Files:**
- Create: `public/libs/email-classifier/src/extract-cta.ts`
- Create: `public/libs/email-classifier/src/extract-cta.test.ts`
- Modify: `public/libs/email-classifier/src/classify-email.test.ts` (add new EmailSignals fields to existing fixtures)

- [ ] **Step 1: Write the failing test (positives, negatives, DMARC gate).**

`extract-cta.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { extractCta } from "./extract-cta";
import type { EmailSignals } from "./classify-email";

function signals(over: Partial<EmailSignals>): EmailSignals {
  return {
    listId: null, listUnsubscribe: null, precedence: null, autoSubmitted: null,
    returnPath: null, importance: null, fromAddress: null, recipientCount: 1,
    isReply: false, subject: null, bodyLength: 0, gmailCategories: [],
    bodyText: null, fromName: null, links: [], authResults: null,
    ...over,
  };
}

describe("extractCta — OTP", () => {
  it("extracts a keyword-anchored numeric code", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@acme.com", fromName: "Acme",
      subject: "Your verification code",
      bodyText: "Your verification code is 482913. It expires in 10 minutes.",
    }));
    expect(cta).toEqual({ kind: "otp", service: "Acme", code: "482913", url: null });
  });

  it("extracts a grouped/alphanumeric code (Google style)", () => {
    const cta = extractCta(signals({
      fromAddress: "no-reply@google.com",
      subject: "G-557812 is your Google verification code",
      bodyText: "G-557812 is your Google verification code.",
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("G-557812");
    expect(cta?.service).toBe("Google");
  });

  it("does NOT treat an order total / price as a code", () => {
    expect(extractCta(signals({
      fromAddress: "orders@shop.com",
      subject: "Your order #100423",
      bodyText: "Order #100423 total $129.99 ships soon.",
    }))).toBeNull();
  });

  it("does NOT treat a bare 4-digit year as a code", () => {
    expect(extractCta(signals({
      bodyText: "Copyright 2026 Acme Inc. All rights reserved.",
    }))).toBeNull();
  });
});

describe("extractCta — confirm link", () => {
  const dmarcPass = "spf=pass; dkim=pass; dmarc=pass header.from=acme.com";

  it("extracts a confirm link when DMARC passes and anchor text is positive", () => {
    const cta = extractCta(signals({
      fromAddress: "hello@acme.com", fromName: "Acme",
      subject: "Confirm your email",
      authResults: dmarcPass,
      links: [{ text: "Confirm email", href: "https://acme.com/confirm?t=xyz" }],
    }));
    expect(cta).toEqual({ kind: "confirm", service: "Acme", code: null, url: "https://acme.com/confirm?t=xyz" });
  });

  it("SKIPS the link when DMARC does not pass", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm your email",
      authResults: "spf=fail; dkim=none; dmarc=fail header.from=acme.com",
      links: [{ text: "Confirm email", href: "https://evil.example/confirm" }],
    }))).toBeNull();
  });

  it("SKIPS negative-context links (wasn't you / reset / unsubscribe)", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Security alert",
      authResults: dmarcPass,
      links: [
        { text: "This wasn't me", href: "https://acme.com/secure" },
        { text: "Reset your password", href: "https://acme.com/reset" },
        { text: "Unsubscribe", href: "https://acme.com/u" },
      ],
    }))).toBeNull();
  });

  it("SKIPS when two distinct confirm-verb links conflict", () => {
    expect(extractCta(signals({
      fromAddress: "hello@acme.com", subject: "Confirm",
      authResults: dmarcPass,
      links: [
        { text: "Confirm email", href: "https://acme.com/a" },
        { text: "Verify account", href: "https://acme.com/b" },
      ],
    }))).toBeNull();
  });

  it("prefers OTP when both a code and a confirm link are present", () => {
    const cta = extractCta(signals({
      fromAddress: "hello@acme.com", fromName: "Acme",
      subject: "Confirm your email",
      authResults: dmarcPass,
      bodyText: "Your code is 224466 or click below.",
      links: [{ text: "Confirm email", href: "https://acme.com/confirm" }],
    }));
    expect(cta?.kind).toBe("otp");
    expect(cta?.code).toBe("224466");
  });
});

describe("extractCta — none", () => {
  it("returns null for ordinary mail", () => {
    expect(extractCta(signals({
      fromAddress: "jane@friend.com", fromName: "Jane",
      subject: "Lunch tomorrow?", bodyText: "Want to grab lunch at noon?",
    }))).toBeNull();
  });
});
```

- [ ] **Step 2: Run; verify it fails.**

Run: `cd public/libs/email-classifier && pnpm exec vitest run src/extract-cta.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `extract-cta.ts`.**

```ts
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
  // Drop a common public suffix's last label; take the registrable label.
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
// A code token: 4–8 chars, digits or grouped alnum like G-557812 / ABZ-419.
// Bounded so it doesn't swallow a $-amount, order# or year.
const CODE_TOKEN = /\b([A-Z]{0,4}-?\d{3,8}|\d{4,8})\b/;

function looksLikeYear(t: string): boolean {
  return /^\d{4}$/.test(t) && Number(t) >= 1900 && Number(t) <= 2100;
}

function extractOtp(s: EmailSignals): string | null {
  const hay = `${s.subject ?? ""}\n${s.bodyText ?? ""}`;
  if (!hay.trim()) return null;
  // Scan line by line; require an OTP keyword and a token on the SAME line
  // (tight adjacency rejects prices/order numbers elsewhere in the body).
  for (const rawLine of hay.split(/\n+/)) {
    const line = rawLine.trim();
    if (!CODE_KEYWORD.test(line)) continue;
    // Reject lines that are clearly money/order to avoid grabbing their numbers.
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
  // Collapse to distinct hrefs; ambiguity (>1 distinct target) ⇒ skip.
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
```

- [ ] **Step 4: Run; verify pass.**

Run: `cd public/libs/email-classifier && pnpm exec vitest run src/extract-cta.test.ts`
Expected: PASS (all describe blocks). If a case fails, tighten the specific regex/branch — do NOT loosen toward false positives.

- [ ] **Step 5: Fix existing `classify-email.test.ts` fixtures.**

The new `EmailSignals` fields are required by the type. Add `bodyText: null, fromName: null, links: [], authResults: null` to every `EmailSignals` literal in `classify-email.test.ts` (or add a local `signals()` helper there mirroring Task 5 Step 1 and route fixtures through it).

Run: `cd public/libs/email-classifier && pnpm exec vitest run`
Expected: PASS (all suites, including pre-existing classify tests).

- [ ] **Step 6: Export from index.**

In `public/libs/email-classifier/src/index.ts`, add:

```ts
export { extractCta } from "./extract-cta";
export { extractLinkCandidates, type LinkCandidate } from "./extract-link-candidates";
```

- [ ] **Step 7: Verify package compiles + commit.**

Run: `cd public/libs/email-classifier && pnpm exec tsc --noEmit && pnpm exec vitest run`
Expected: clean.

```bash
cd public && git add libs/email-classifier/src/extract-cta.ts libs/email-classifier/src/extract-cta.test.ts libs/email-classifier/src/index.ts libs/email-classifier/src/classify-email.test.ts && git commit -m "feat(email-classifier): extractCta OTP/confirm heuristic + tests"
```

### Task 6: Anonymized prod corpus → fixtures

**Files:**
- Modify: `public/libs/email-classifier/src/extract-cta.test.ts` (append a `describe("corpus")` block)

- [ ] **Step 1: Pull real examples (read-only).**

Use the `prod-db-investigate` skill (read-only, prod port 5433). Query recent `note` rows joined to OTP/confirm-shaped subjects AND negatives, e.g.:

```sql
-- OTP / confirm candidates
SELECT n.content, t.title
FROM note n JOIN thread t ON t.id = n.thread_id
WHERE n.content ~* '(verification code|one-time|passcode|confirm your (email|account)|verify your (email|account))'
ORDER BY n.created_at DESC LIMIT 60;
-- Negatives: reset / wasn't you / receipts / promos with numbers
SELECT n.content, t.title
FROM note n JOIN thread t ON t.id = n.thread_id
WHERE n.content ~* '(reset your password|was ?n.t you|unsubscribe|order #|total \$)'
ORDER BY n.created_at DESC LIMIT 60;
```

- [ ] **Step 2: Anonymize and bake in.**

For each kept example, **anonymize**: replace the real code with a synthetic same-shape code, replace real URLs with structurally-faithful fake ones (same path shape, fake domain), scrub names/emails/PII — preserving the phrasing/structure the heuristics rely on. Add each as a case in a new `describe("extractCta — corpus")` block asserting the expected `Cta` (or `null` for negatives). Aim ≥10 positives, ≥10 negatives.

- [ ] **Step 3: Run; verify pass; tune for ZERO false positives.**

Run: `cd public/libs/email-classifier && pnpm exec vitest run src/extract-cta.test.ts`
Expected: PASS. If a negative produces a CTA, tighten the heuristic (never loosen to make a positive pass at the cost of a false positive). Document any positive you choose to give up on as a comment.

- [ ] **Step 4: Commit.**

```bash
cd public && git add libs/email-classifier/src/extract-cta.test.ts && git commit -m "test(email-classifier): anonymized prod corpus for extractCta"
```

---

## Phase 3 — connectors

### Task 7: Gmail — populate signals, extract CTA, attach to note

**Files:**
- Modify: `public/connectors/gmail/src/gmail-api.ts` (export a parent-HTML getter)
- Modify: `public/connectors/gmail/src/gmail-facets.ts`
- Modify: `public/connectors/gmail/src/gmail.ts` (the facet block ~1371-1388)

- [ ] **Step 1: Expose the parent message's raw HTML.**

`extractBody`/`findPartContent` in `gmail-api.ts` are module-private. Export a small helper that returns the decoded HTML (or "") for a message, reusing them:

```ts
/** Decoded HTML body for a message (empty string if none). For link extraction. */
export function getMessageHtml(message: GmailMessage): string {
  const html = findPartContent(message.payload, "text/html");
  return html ? decodeBase64Url(html) : "";
}
```

(Place near `extractBody`; it must call the same private helpers.)

- [ ] **Step 2: Update `gmailFacets` to return facets + cta.**

Change the signature/return and populate the new signals:

```ts
import { classifyEmail, extractCta, extractLinkCandidates, type EmailSignals } from "@plotday/email-classifier";
import type { Cta, ThreadFacets } from "@plotday/twister/facets";
import { getHeader, getMessageHtml, parseEmailAddress, parseEmailAddresses, type GmailMessage } from "./gmail-api";

export type GmailClassification = { facets: ThreadFacets; cta: Cta | null };

export function gmailFacets(message: GmailMessage, bodyText: string): GmailClassification {
  const from = parseEmailAddress(getHeader(message, "From") ?? "");
  const signals: EmailSignals = {
    listId: getHeader(message, "List-Id"),
    listUnsubscribe: getHeader(message, "List-Unsubscribe"),
    precedence: getHeader(message, "Precedence"),
    autoSubmitted: getHeader(message, "Auto-Submitted"),
    returnPath: getHeader(message, "Return-Path"),
    importance: getHeader(message, "Importance") ?? getHeader(message, "X-Priority"),
    fromAddress: from?.email.toLowerCase() ?? null,
    fromName: from?.name ?? null,
    recipientCount:
      parseEmailAddresses(getHeader(message, "To")).length +
      parseEmailAddresses(getHeader(message, "Cc")).length,
    isReply: getHeader(message, "In-Reply-To") !== null || getHeader(message, "References") !== null,
    subject: getHeader(message, "Subject"),
    bodyText,
    bodyLength: bodyText.length,
    links: extractLinkCandidates(getMessageHtml(message)),
    authResults: getHeader(message, "Authentication-Results"),
    gmailCategories: (message.labelIds ?? []).filter((l) => GMAIL_CATEGORY_LABELS.has(l)),
  };
  return { facets: classifyEmail(signals), cta: extractCta(signals) };
}
```

> Verify `parseEmailAddress` returns a `.name`; if its return type lacks `name`, read the display name from the raw `From` header instead.

- [ ] **Step 3: Wire it in `gmail.ts`.**

In the facet block (~1371-1388), set both the thread facets (preferring the OTP/confirm format) and the note's `cta`:

```ts
const facetParent = thread.messages.find((m) => !m.labelIds?.includes("DRAFT"));
if (facetParent) {
  const facetNote = plotThread.notes?.find(
    (n) => "key" in n && (n as { key: string }).key === facetParent.id
  );
  const facetBody = facetNote?.content ?? plotThread.preview ?? "";
  const { facets, cta } = gmailFacets(facetParent, facetBody);
  plotThread.facets = cta
    ? { ...facets, format: cta.kind }   // otp/confirm wins the format slot
    : facets;
  if (cta && facetNote) {
    (facetNote as { cta?: Cta | null }).cta = cta;
  }
}
```

Add `import type { Cta } from "@plotday/twister/facets";` if not already present.

- [ ] **Step 4: Build.**

Run: `cd public/connectors/gmail && pnpm exec tsc --noEmit`
Expected: no errors.

- [ ] **Step 5: Commit.**

```bash
cd public && git add connectors/gmail/src/gmail-api.ts connectors/gmail/src/gmail-facets.ts connectors/gmail/src/gmail.ts && git commit -m "feat(gmail): extract OTP/confirm cta and attach to note"
```

### Task 8: Outlook-mail — same wiring

**Files:**
- Modify: `public/connectors/outlook-mail/src/graph-mail-api.ts` (HTML getter, if not already trivially available)
- Modify: `public/connectors/outlook-mail/src/outlook-facets.ts`
- Modify: `public/connectors/outlook-mail/src/outlook-mail.ts` (facet block ~1335-1357)

- [ ] **Step 1: Get the parent HTML.** Outlook already has `message.body.content` with `contentType === "html"` (graph-mail-api.ts ~658). Use it directly (no new helper needed) — pass it through `extractLinkCandidates`.

- [ ] **Step 2: Update `outlookFacets`** to mirror Task 7 Step 2:

```ts
import { classifyEmail, extractCta, extractLinkCandidates, type EmailSignals } from "@plotday/email-classifier";
import type { Cta, ThreadFacets } from "@plotday/twister/facets";

export type OutlookClassification = { facets: ThreadFacets; cta: Cta | null };

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
    importance: message.importance ?? header(headers, "Importance") ?? header(headers, "X-Priority"),
    fromAddress: message.from?.emailAddress?.address?.toLowerCase() ?? null,
    fromName: message.from?.emailAddress?.name ?? null,
    recipientCount: (message.toRecipients?.length ?? 0) + (message.ccRecipients?.length ?? 0),
    isReply:
      header(headers, "In-Reply-To") !== null ||
      header(headers, "References") !== null ||
      /^re:/i.test(message.subject ?? ""),
    subject: message.subject ?? null,
    bodyText,
    bodyLength: bodyText.length,
    links: extractLinkCandidates(html),
    authResults: header(headers, "Authentication-Results"),
    gmailCategories: message.inferenceClassification === "other" ? ["CATEGORY_UPDATES"] : [],
  };
  return { facets: classifyEmail(signals), cta: extractCta(signals) };
}
```

> Confirm `GraphRecipient.emailAddress` carries `name` (it does in Graph). If not, leave `fromName: null`.

- [ ] **Step 3: Wire in `outlook-mail.ts`** facet block — same shape as Task 7 Step 3 (`const { facets, cta } = outlookFacets(...)`; set `plotThread.facets` with `format: cta.kind` when cta; set `facetNote.cta = cta`).

- [ ] **Step 4: Build + commit.**

Run: `cd public/connectors/outlook-mail && pnpm exec tsc --noEmit`

```bash
cd public && git add connectors/outlook-mail/src/outlook-facets.ts connectors/outlook-mail/src/outlook-mail.ts && git commit -m "feat(outlook-mail): extract OTP/confirm cta and attach to note"
```

### Task 9: Install + bump submodule pointer; open public PR

- [ ] **Step 1: Refresh workspace link.**

From core repo root: `pnpm install` (picks up the rebuilt twister `dist/`).

- [ ] **Step 2: Push the public branch + open PR.**

```bash
cd public && git push -u origin otp-confirm-detection
# open PR via gh in the public repo
```

- [ ] **Step 3: Stage the submodule pointer in core** (committed later with core changes):

```bash
cd /Users/kris.braun/code/plot && git add public
```

---

## Phase 4 — database: `note.cta` column

### Task 10: Add `note.cta` column + view + migration

**Files:**
- Modify: `libs/db/schema/50-tables/25-note.sql`
- Modify: `libs/db/schema/90-user-schema/31-note.sql`
- Generate: `libs/db/migrations/*`
- Regenerate: `libs/db/src/types.ts`

- [ ] **Step 1: Add the column to the table.**

In `25-note.sql`, add after `"actions" jsonb,` (line 17):

```sql
    "cta" jsonb, -- time-sensitive call-to-action {kind, service, code, url}; client shows ephemeral prompt
```

And a comment after the `actions` comment block:

```sql
COMMENT ON COLUMN "public"."note"."cta" IS 'Time-sensitive call-to-action extracted at ingest (OTP code or confirm link): {kind:"otp"|"confirm", service, code, url}. NULL when none. Set by the twist runtime from connector extraction; drives the client''s ephemeral OTP/confirm toast and push.';
```

- [ ] **Step 2: Surface it on the view.**

In `90-user-schema/31-note.sql`:
- `user.note` SELECT (after `n.actions,` line 27): add `n.cta,`
- `user.note_redacted` SELECT (after `NULL::jsonb AS actions,` line 83): add `NULL::jsonb AS cta,`

- [ ] **Step 3: Generate the migration.**

Run: `pnpm gen-migration -- add_note_cta`
Expected: a new file in `libs/db/migrations/` adding the `cta` column and recreating the two views. (`squawk` is fine: adding a nullable column is an expand-safe op.)

- [ ] **Step 4: Append a one-shot seq bump** so existing clients re-pull and pick up the new view column. At the END of the generated migration:

```sql
-- Bump note rows so clients re-pull and receive the new cta column.
UPDATE note SET updated_at = now() WHERE archived_at IS NULL;
```

> If the table is very large this is a heavy update; acceptable for a one-time additive surface. (Matches `libs/db/AGENTS.md` "Also bump on schema changes that add view columns".)

- [ ] **Step 5: Apply + regenerate types.**

Run: `psql "$DATABASE_URL" -tAc "show port;"` (confirm correct DB), then `pnpm apply-migrations`
Expected: applies; auto-runs `pnpm types`.

- [ ] **Step 6: Verify sync.**

Run: `pnpm diff-schema-migrations` (expect no diff) and `pnpm --filter @plotday/db run lint` (types in sync).

- [ ] **Step 7: Commit.**

```bash
git add libs/db/schema/50-tables/25-note.sql libs/db/schema/90-user-schema/31-note.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add note.cta column + surface on user.note view"
```

---

## Phase 5 — API: persist cta + immediate OTP push

### Task 11: Map `note.cta` into the DB write

**Files:**
- Modify: `workers/api/src/twist/tools/plot/note.ts` (the `dbNote` object ~531-552)

- [ ] **Step 1: Add the mapping.**

In the `dbNote` literal, after `actions: note.actions ? JSON.stringify(note.actions) : null,` add:

```ts
      cta: note.cta ? JSON.stringify(note.cta) : null,
```

- [ ] **Step 2: Typecheck.**

Run: `cd workers/api && pnpm exec tsc --noEmit` (or `pnpm lint`)
Expected: no errors (`NewNote.cta` now exists from the rebuilt twister).

- [ ] **Step 3: Commit.**

```bash
git add workers/api/src/twist/tools/plot/note.ts && git commit -m "feat(api): persist note.cta on note write"
```

### Task 12: Immediate, gate-bypassing OTP push

**Files:**
- Read first: `workers/api/src/notifications/send.ts` (`sendDataNotificationToUser`), `workers/api/src/state/push-notify.ts` (gates), `workers/api/src/utils/fcm.ts` (`sendDataMessage`).
- Create: `workers/api/src/notifications/otp-push.ts`
- Modify: the note-creation caller (in `workers/api/src/twist/tools/plot/note.ts` or its `saveLink`/`createNotes` caller) to invoke it after a fresh-cta note is persisted.

- [ ] **Step 1: Write `otp-push.ts`.**

A small function that, given a persisted note's `{ id, threadId, cta, sourceCreatedAt }`, resolves the visible user(s) for the thread and fires a **data-only** push that the client treats as time-sensitive. Data-only (no `notification` block) keeps the code off FCM/APNs.

```ts
import type { DB } from "@plotday/db";
import type { Kysely } from "kysely";
import { sendDataNotificationToUser } from "./send";

const WINDOW_MS = 5 * 60 * 1000;

/**
 * Fire an immediate, gate-bypassing OTP/confirm push for a freshly-ingested
 * note that carries a `cta`. Data-only: the code is read from the local DB on
 * the client, never sent through FCM/APNs. No-op when the note is older than
 * the 5-minute window at persist time.
 */
export async function maybeSendCtaPush(
  env: Env,
  db: Kysely<DB>,
  note: { id: string; threadId: string; sourceCreatedAt: Date; cta: { kind: string } | null }
): Promise<void> {
  if (!note.cta) return;
  if (Date.now() - note.sourceCreatedAt.getTime() > WINDOW_MS) return;

  // Visible users for this thread (OTP threads are single-user mailboxes).
  const rows = await db
    .selectFrom("thread_priority")
    .select("user_id")
    .where("thread_id", "=", note.threadId)
    .where("revoked_at", "is", null)
    .execute();

  for (const { user_id } of rows) {
    await sendDataNotificationToUser(env, db, user_id, {
      type: "otp",
      noteId: note.id,
      threadId: note.threadId,
      kind: note.cta.kind,
    });
  }
}
```

> Verify the exact signature of `sendDataNotificationToUser` (env/db/userId/payload) against `send.ts` and adapt. The payload values must be strings (FCM `data` is `Record<string,string>`). This path deliberately does NOT go through `push-notify.ts`'s importance/inactivity/window gates.

- [ ] **Step 2: Call it after persisting a cta note.**

In the note-write path, after the row is inserted/upserted and you have its `id` + `source_created_at`, call `maybeSendCtaPush(...)` via `c.executionCtx.waitUntil(...)` using a **fresh** DB connection (per AGENTS.md: never use the request-scoped `db` inside `waitUntil`). If the note write happens deep in the twist runtime where `executionCtx` isn't handy, await it inline (it's a tiny query + N FCM calls). Guard on `dbNote.cta !== null`.

```ts
if (dbNote.cta) {
  await maybeSendCtaPush(plot.env, plot.db, {
    id: dbNote.id ?? insertedId,
    threadId: activityId,
    sourceCreatedAt: new Date(dbNote.source_created_at),
    cta: note.cta ?? null,
  });
}
```

> Adapt to however `plot` exposes `env`. If `env` isn't reachable here, place the call one level up in the `saveLink` handler where `env` is available, passing the persisted note rows down.

- [ ] **Step 3: Typecheck.**

Run: `cd workers/api && pnpm exec tsc --noEmit`
Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git add workers/api/src/notifications/otp-push.ts workers/api/src/twist/tools/plot/note.ts && git commit -m "feat(api): immediate gate-bypassing OTP/confirm push on cta note"
```

---

## Phase 6 — Flutter store: `Note.cta`

### Task 13: `Cta` model + `cta` column + converter + migration

**Files:**
- Modify: `apps/plot/lib/store/note.dart`
- Modify: `apps/plot/lib/store/store.dart` (schemaVersion + migration)

- [ ] **Step 1: Add the `Cta` model + converter (TDD).**

Create `apps/plot/test/store/cta_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('Cta round-trips through json', () {
    const cta = Cta(kind: CtaKind.otp, service: 'Acme', code: '123456', url: null);
    final json = cta.toJson();
    expect(Cta.fromJson(json), cta);
  });

  test('confirm cta parses', () {
    final cta = Cta.fromJson({
      'kind': 'confirm', 'service': 'Acme', 'code': null, 'url': 'https://a/c',
    });
    expect(cta.kind, CtaKind.confirm);
    expect(cta.url, 'https://a/c');
  });
}
```

- [ ] **Step 2: Run; verify fail.**

Run: `cd apps/plot && flutter test test/store/cta_test.dart`
Expected: FAIL (Cta undefined).

- [ ] **Step 3: Implement `Cta` in `note.dart`** (top of file, after `typedef NoteId`):

```dart
enum CtaKind { otp, confirm }

class Cta extends Equatable {
  const Cta({required this.kind, required this.service, this.code, this.url});

  final CtaKind kind;
  final String service;
  final String? code;
  final String? url;

  factory Cta.fromJson(Map<String, dynamic> json) => Cta(
        kind: json['kind'] == 'confirm' ? CtaKind.confirm : CtaKind.otp,
        service: json['service'] as String? ?? '',
        code: json['code'] as String?,
        url: json['url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind == CtaKind.confirm ? 'confirm' : 'otp',
        'service': service,
        'code': code,
        'url': url,
      };

  @override
  List<Object?> get props => [kind, service, code, url];
}

class CtaConverter extends TypeConverter<Cta?, String?> {
  const CtaConverter();
  @override
  Cta? fromSql(String? fromDb) =>
      fromDb == null ? null : Cta.fromJson(jsonDecode(fromDb) as Map<String, dynamic>);
  @override
  String? toSql(Cta? value) => value == null ? null : jsonEncode(value.toJson());
}
```

> Confirm `jsonDecode/Encode` (`dart:convert`) and `TypeConverter` are imported/available in `store.dart`'s part context (the `actions` `UserActionsConverter` already uses this pattern — mirror its imports).

- [ ] **Step 4: Add the Drift column** to the `Notes` table class (after `actions`):

```dart
  TextColumn get cta => text().nullable().map(const CtaConverter())();
```

- [ ] **Step 5: Add `cta` to the `Note` model** (the `Note` class ~99): add `Cta? cta` to the factory params, the fields, `props`/equality, and wherever `Note` is built from `NoteRow` (`Note.fromRow`/`fromJson`). Map the row's `cta` through.

> Find the `Note.fromRow`/`fromNoteRow` constructor in `note.dart` and thread `cta: row.cta` through. Add `cta` to `props` for equality.

- [ ] **Step 6: Migration + schemaVersion.**

In `store.dart`: bump `schemaVersion` (current → +1) and add to `onUpgrade`:

```dart
if (from < <NEW_VERSION>) {
  await m.addColumn(notes, notes.cta);
}
```

(Views are auto-recreated; no extra step.)

- [ ] **Step 7: Codegen + analyze + test.**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Then: `flutter analyze lib/store/note.dart lib/store/store.dart` and `flutter test test/store/cta_test.dart`
Expected: analyze clean; tests PASS.

- [ ] **Step 8: Commit.**

```bash
git add apps/plot/lib/store/note.dart apps/plot/lib/store/store.dart apps/plot/test/store/cta_test.dart apps/plot/lib/store/*.g.dart
git commit -m "feat(app): Note.cta model + column + migration"
```

---

## Phase 7 — Flutter in-app toast

### Task 14: `OtpPromptController` (watch + window + replace-by-latest) (TDD)

**Files:**
- Create: `apps/plot/lib/state/otp_prompt_controller.dart`
- Create: `apps/plot/test/state/otp_prompt_controller_test.dart`

- [ ] **Step 1: Write the failing test** for the pure logic (selection + window + dismiss), decoupled from Drift by passing in candidate notes:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/otp_prompt_controller.dart';
import 'package:plot/store/store.dart';

Note _note(String id, Cta cta, DateTime sent) => /* build a minimal Note with id, cta, sourceCreatedAt: sent */;

void main() {
  test('selects the latest in-window cta note', () {
    final now = DateTime.now();
    final c = OtpPromptController.forTest();
    c.onNotes([
      _note('a', const Cta(kind: CtaKind.otp, service: 'A', code: '111111'), now.subtract(const Duration(minutes: 1))),
      _note('b', const Cta(kind: CtaKind.otp, service: 'B', code: '222222'), now.subtract(const Duration(seconds: 5))),
    ], now: now);
    expect(c.current.value?.note.id.toString(), 'b'); // latest wins
  });

  test('ignores notes older than 5 minutes', () {
    final now = DateTime.now();
    final c = OtpPromptController.forTest();
    c.onNotes([
      _note('old', const Cta(kind: CtaKind.otp, service: 'A', code: '111111'), now.subtract(const Duration(minutes: 6))),
    ], now: now);
    expect(c.current.value, isNull);
  });

  test('dismissed cta does not reappear', () {
    final now = DateTime.now();
    final c = OtpPromptController.forTest();
    final n = _note('a', const Cta(kind: CtaKind.otp, service: 'A', code: '111111'), now);
    c.onNotes([n], now: now);
    c.dismiss();
    c.onNotes([n], now: now);
    expect(c.current.value, isNull);
  });
}
```

- [ ] **Step 2: Run; verify fail.**

Run: `cd apps/plot && flutter test test/state/otp_prompt_controller_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement the controller.**

```dart
import 'package:flutter/foundation.dart';
import 'package:plot/store/store.dart';

const kCtaWindow = Duration(minutes: 5);

class OtpPrompt {
  OtpPrompt(this.note);
  final Note note;
  Cta get cta => note.cta!;
}

class OtpPromptController {
  OtpPromptController._();
  factory OtpPromptController.forTest() => OtpPromptController._();

  final ValueNotifier<OtpPrompt?> current = ValueNotifier(null);
  final Set<String> _dismissed = {};
  // TODO(production ctor): subscribe to a Drift watch and call onNotes().

  /// Evaluate candidate notes (those with a non-null cta) and pick the latest
  /// in-window, non-dismissed one. Replace-by-latest is implicit.
  void onNotes(List<Note> notes, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final eligible = notes
        .where((n) => n.cta != null)
        .where((n) => !_dismissed.contains(n.id.toString()))
        .where((n) => t.difference(n.sourceCreatedAt) < kCtaWindow)
        .toList()
      ..sort((a, b) => b.sourceCreatedAt.compareTo(a.sourceCreatedAt));
    current.value = eligible.isEmpty ? null : OtpPrompt(eligible.first);
  }

  void dismiss() {
    final n = current.value?.note;
    if (n != null) _dismissed.add(n.id.toString());
    current.value = null;
  }

  void dispose() => current.dispose();
}
```

- [ ] **Step 4: Run; verify pass.**

Run: `cd apps/plot && flutter test test/state/otp_prompt_controller_test.dart`
Expected: PASS (3 tests). Implement the `_note` test helper to build a `Note` with the given `id`, `cta`, and `sourceCreatedAt` (reuse the `Note(...)` factory; fill required fields with dummies).

- [ ] **Step 5: Add the production Drift wiring.**

Add a real constructor that watches notes with a non-null `cta` within the window and an expiry timer that re-evaluates. Use the existing `Note`/`NotesBase` query infrastructure (e.g. a Drift `select` on `notes` where `cta IS NOT NULL` ordered by `sourceCreatedAt desc limit 5`, `.watch()`), mapping rows → `Note`, calling `onNotes`. Schedule a `Timer` for the soonest window-expiry to re-run `onNotes`.

```dart
import 'dart:async';

OtpPromptController(Store store) {
  _sub = (store.select(store.notes)
        ..where((t) => t.cta.isNotNull())
        ..orderBy([(t) => OrderingTerm.desc(t.sourceCreatedAt)])
        ..limit(5))
      .watch()
      .listen((rows) => onNotes(rows.map(/* NoteRow -> Note */).toList()));
}
```

> Match how other controllers turn a `NoteRow` into a `Note` (see existing `Note.get`/`getForThread` mapping in `note.dart`). Re-arm the expiry `Timer` inside `onNotes`.

- [ ] **Step 6: Analyze + commit.**

Run: `cd apps/plot && flutter analyze lib/state/otp_prompt_controller.dart`

```bash
git add apps/plot/lib/state/otp_prompt_controller.dart apps/plot/test/state/otp_prompt_controller_test.dart
git commit -m "feat(app): OtpPromptController watch + window + replace-by-latest"
```

### Task 15: The toast widget (otp/confirm variants)

**Files:**
- Create: `apps/plot/lib/widget/otp_toast.dart`

- [ ] **Step 1: Build the widget.**

A forui-styled card (NOT material) bound to an `OtpPrompt`, with `onDismiss` and the two variants. Reuse the copy-to-clipboard + ✓ pattern from `lib/widget/toast.dart`'s `_CopyButton`; use `url_launcher` for confirm.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:plot/state/otp_prompt_controller.dart';
import 'package:plot/store/store.dart';

class OtpToast extends StatelessWidget {
  const OtpToast({super.key, required this.prompt, required this.onDismiss});
  final OtpPrompt prompt;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cta = prompt.cta;
    final isOtp = cta.kind == CtaKind.otp && cta.code != null;
    return FCard(
      child: Row(
        children: [
          Expanded(
            child: isOtp
                ? _OtpBody(service: cta.service, code: cta.code!)
                : Text('Confirm your ${cta.service} account'),
          ),
          if (isOtp)
            _CopyCode(code: cta.code!)
          else
            FButton(
              onPress: () => launchUrl(Uri.parse(cta.url!), mode: LaunchMode.externalApplication),
              label: const Text('Confirm'),
            ),
          FButton.icon(onPress: onDismiss, child: const Icon(/* close glyph from lib/widget/icon.dart */)),
        ],
      ),
    );
  }
}

class _OtpBody extends StatelessWidget {
  const _OtpBody({required this.service, required this.code});
  final String service;
  final String code;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$service verification code'),
          Text(code, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ],
      );
}

class _CopyCode extends StatefulWidget {
  const _CopyCode({required this.code});
  final String code;
  @override
  State<_CopyCode> createState() => _CopyCodeState();
}

class _CopyCodeState extends State<_CopyCode> {
  bool _copied = false;
  @override
  Widget build(BuildContext context) => FButton(
        onPress: () async {
          await Clipboard.setData(ClipboardData(text: widget.code));
          if (mounted) setState(() => _copied = true);
        },
        label: Text(_copied ? 'Copied' : 'Copy'),
      );
}
```

> Match exact forui APIs (`FCard`, `FButton`, `FButton.icon`) and the app's icon helper from `lib/widget/icon.dart`. Apply the desktop-cursor rule (no pointer cursor on buttons; pointer only for the confirm link is acceptable since it navigates externally — keep consistent with existing link treatment).

- [ ] **Step 2: Analyze + commit.**

Run: `cd apps/plot && flutter analyze lib/widget/otp_toast.dart`

```bash
git add apps/plot/lib/widget/otp_toast.dart && git commit -m "feat(app): OtpToast otp/confirm variants"
```

### Task 16: Wire the controller + overlay into RootProvider

**Files:**
- Modify: `apps/plot/lib/state/root_provider.dart`

- [ ] **Step 1: Instantiate the controller** with the `Store` in `RootProviderState` (alongside existing listeners, e.g. near `_setupReAuthListener`), and dispose it.

- [ ] **Step 2: Render the overlay.** Add an `OverlayPortal` (or reuse the app's `showOverlayToast` infra) driven by `ValueListenableBuilder<OtpPrompt?>(valueListenable: controller.current, ...)`, showing `OtpToast(prompt: p, onDismiss: controller.dismiss)` top-end, above content but consistent with existing toast placement. Only one shows at a time (controller guarantees it).

- [ ] **Step 3: Analyze.**

Run: `cd apps/plot && flutter analyze lib/state/root_provider.dart`
Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git add apps/plot/lib/state/root_provider.dart && git commit -m "feat(app): show OTP/confirm toast from RootProvider"
```

---

## Phase 8 — Flutter background push

### Task 17: Handle `type:"otp"` data push

**Files:**
- Read first: `apps/plot/lib/notifications/notification_service.dart` (foreground `onMessage`, data routing ~674-681), `background_handler.dart` (~28-92), `notification_display.dart` (show + stable id).
- Modify: `notification_service.dart`, `background_handler.dart`

- [ ] **Step 1: Foreground.** In the FCM `onMessage`/data handler, when `message.data['type'] == 'otp'`: trigger a sync (so `note.cta` lands locally), then let the existing `OtpPromptController` watch surface the in-app toast. Do NOT also show an OS notification in foreground (avoid double). Return early from the generic `sync_wake` path for `type:"otp"`.

- [ ] **Step 2: Background.** In `background_handler.dart`, when `message.data['type'] == 'otp'`: sync, read the note's `cta` from the local DB by `noteId`, and show a local OS notification **immediately** (bypass the notify-window defer): OTP → title `'<service>'`, body `'Code: <code>'` (enables iOS autofill); confirm → title `'Confirm your <service> account'`, tap deep-links to `threadId`. Use a single reserved stable notification id (e.g. a constant like `999999`) so a newer CTA replaces the prior one. If the cta isn't in the DB yet after sync, fall back to a generic "You have a new verification message" with deep-link.

> Keep the code OFF FCM — read it from the synced local DB here, never from `message.data`. (The push payload only carries `noteId/threadId/kind`.)

- [ ] **Step 3: Analyze.**

Run: `cd apps/plot && flutter analyze lib/notifications/notification_service.dart lib/notifications/background_handler.dart`
Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git add apps/plot/lib/notifications/notification_service.dart apps/plot/lib/notifications/background_handler.dart
git commit -m "feat(app): render OTP/confirm push when backgrounded"
```

---

## Phase 9 — verification, docs, finalize

### Task 18: Full-suite checks

- [ ] **Step 1: TS gates.**

Run (core): `pnpm --filter @plotday/api lint` and `cd public/libs/email-classifier && pnpm exec vitest run`
Expected: green.

- [ ] **Step 2: Flutter analyze (changed files) + relevant tests.**

Run: `cd apps/plot && flutter analyze` (or scoped to changed files) and `flutter test test/store/cta_test.dart test/state/otp_prompt_controller_test.dart`
Expected: clean + green.

- [ ] **Step 3: DB sync check.**

Run: `pnpm diff-schema-migrations` (no diff) and `pnpm --filter @plotday/db run lint` (types in sync).

### Task 19: Run-app verification

- [ ] **Step 1:** Use the `run-app` skill to launch Plot.app. Manually insert a test `note` with a `cta` (OTP) and a fresh `source_created_at` into the local DB (or sync a real OTP), and confirm: the in-app toast appears, Copy works, it auto-dismisses after the window, dismiss hides it, and a newer cta replaces an older one. Repeat for a `confirm` cta (button opens URL). Note any UI polish needed.

> If run-app is blocked (Clerk/mDNS), record what was and wasn't verified, per project norms.

### Task 20: Docs + finalize

**Files:**
- Modify: `docs/updates.md`, `docs/features.md`

- [ ] **Step 1: `docs/updates.md`** — under `## Next release`, add a `### ` section (e.g. `### Codes & confirmations`) with a plain-language bullet: "Plot now spots one-time codes and confirm-your-account emails and pops them up with a quick copy button or confirm button — handy before they expire."

- [ ] **Step 2: `docs/features.md`** — add the capability under the relevant pillar.

- [ ] **Step 3: Run `/finalize`** (lint, backwards-compat, error capture, docs, public submodule PR/changeset checks).

- [ ] **Step 4: Commit + finishing-a-development-branch.**

```bash
git add docs/updates.md docs/features.md && git commit -m "docs: OTP/confirm detection + toast"
```

Then use `superpowers:finishing-a-development-branch` to decide merge/PR. Remember: the `public/` PR (Phase 1–3) merges first; then re-bump the core submodule pointer and open the core PR.

---

## Self-review notes

- **Spec coverage:** §2 (sources/SDK) → T1–T9; §4 (extraction) → T3–T8; §5 (delivery/note.cta) → T10–T11; §6 (in-app toast) → T13–T16; §7 (background push) → T12, T17; §8 (testing/corpus) → T5,T6,T14,T18,T19. All sections mapped.
- **Type consistency:** `Cta {kind,service,code,url}` is identical across twister (T1), classifier (T5), DB jsonb (T10), API map (T11), Dart model (T13). `extractCta`/`extractLinkCandidates` names consistent T4/T5/T7/T8.
- **Ordering risk:** twister must be built (T2) before connectors (T7/T8) and API (T11) typecheck against `NewNote.cta`; DB column (T10) before API map (T11); Dart column (T13) before controller (T14). Phases are sequenced accordingly.
- **Known verify-points flagged inline:** `parseEmailAddress` `.name` availability; `sendDataNotificationToUser` exact signature + how `env` is reached in the note-write path; `NoteRow→Note` mapping; exact forui widget APIs. These require the implementing agent to read the live file (noted at each task).
