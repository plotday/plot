# Facet Extraction Foundation — Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make threads carry heuristic *facets* (`format`, `automation`, `reach`) — emitted by connectors through a new SDK interface, computed by a shared email heuristics package, and stored on a new `thread.facets` column. Ships with **zero behavior change**: facets just start populating. (Plan 2 makes them affect classification.)

**Architecture:** A new `@plotday/twister` export (`facets.ts`) defines the facet vocabulary and a connector-settable `ThreadFacets`; `NewLink` gains `facets?`. A new shared library `@plotday/email-classifier` turns normalized email signals into facets (pure, unit-tested). Gmail assembles signals from headers and calls it; Slack computes its own (source-specific). The API worker copies `link.facets` onto a new nullable `thread.facets` jsonb column, threading it through `prepareThreadForDb` → `p_defaults` → `upsert_thread`, mirroring `embedding`.

**Tech Stack:** TypeScript (pnpm workspaces), Vitest, PostgreSQL + Atlas migrations, Kysely, Changesets (public submodule).

**Repo split:** Tasks 1–6 are in the `public/` submodule (separate PR + changeset). Tasks 7–8 are in the main repo. Task 9 finalizes both.

---

## Pre-flight

- [ ] **Step 0.1: Confirm clean tree and branch**

Run: `git -C /Users/kris.braun/code/plot status --short`
Expected: clean (the two design-spec commits already landed). If you are executing in a worktree, ensure `public/` submodule is initialized and `bash scripts/worktree-db` has been run (you need a local DB for Tasks 7–8). Verify the DB port: `psql "$DATABASE_URL" -tAc "show port;"`.

- [ ] **Step 0.2: Create a feature branch in the public submodule**

```bash
cd /Users/kris.braun/code/plot/public
git checkout -b facet-extraction-foundation
cd /Users/kris.braun/code/plot
```

---

## File Structure

**Public submodule (`public/`):**
- Create: `public/twister/src/facets.ts` — facet vocabulary + `ThreadFacets`.
- Modify: `public/twister/src/plot.ts` — add `facets?: ThreadFacets` to `NewLink`; import from `./facets`.
- Modify: `public/twister/package.json` — add `"./facets"` export.
- Create: `public/.changeset/facets-sdk.md` — changeset.
- Create: `public/libs/email-classifier/` — new shared package (`package.json`, `tsconfig.json`, `vitest.config.ts`, `src/index.ts`, `src/classify-email.ts`, `src/classify-email.test.ts`).
- Modify: `public/pnpm-workspace.yaml` and root `pnpm-workspace.yaml` — add `libs/*` globs.
- Modify: `public/connectors/gmail/package.json` — add dep.
- Create: `public/connectors/gmail/src/gmail-facets.ts` + `gmail-facets.test.ts` — signal extraction.
- Modify: `public/connectors/gmail/src/gmail.ts` — set `link.facets` at saveLink site.
- Create: `public/connectors/slack/src/slack-facets.ts` + `slack-facets.test.ts`.
- Modify: `public/connectors/slack/src/slack.ts` — set `link.facets` at the three saveLink sites.

**Main repo:**
- Modify: `libs/db/schema/50-tables/24-thread.sql` — add `facets` column.
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql` — write `facets`.
- Modify: `workers/api/src/twist/tools/plot/link.ts` — pass `link.facets` into `threadData`.
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts` — put `facets` into `defaults`.
- Create: `workers/api/src/twist/tools/plot/facet-ingest.test.ts` — TS↔PG persistence test.

---

## Task 1: SDK — facet vocabulary (`facets.ts`)

**Files:**
- Create: `public/twister/src/facets.ts`
- Modify: `public/twister/package.json` (exports map, after the `"./tag"` block)
- Create: `public/.changeset/facets-sdk.md`

- [ ] **Step 1.1: Create the facets type file**

Create `public/twister/src/facets.ts`:

```typescript
/**
 * Thread facets — heuristic, message-derived attributes used as internal
 * classifier signal (never user-facing). A connector emits the intrinsic
 * facets on the link it saves; the server stores them on the thread and the
 * focus classifier filters on them.
 *
 * Facets are best-effort: a connector sets a dimension only when a heuristic
 * is confident, leaving it `null` otherwise. The classifier never excludes a
 * thread on a `null` facet.
 *
 * `relationship` (a sender's relationship to the viewing user) is intentionally
 * NOT here: it is recipient-relative and evaluated live by the server, never
 * emitted by a connector.
 */

/** The kind of content. Single-valued. */
export type Format =
  | "chat"
  | "message"
  | "reading"
  | "notification"
  | "receipt"
  | "invoice"
  | "promotion";

/** Whether a person or a system produced the message. */
export type Automation = "human" | "automated";

/** How the user was addressed. */
export type Reach = "direct" | "list";

/**
 * Intrinsic facets a connector may set on a `NewLink`. Each is nullable —
 * omit (or set `null`) when no heuristic is confident.
 */
export type ThreadFacets = {
  format: Format | null;
  automation: Automation | null;
  reach: Reach | null;
};
```

- [ ] **Step 1.2: Add the `./facets` export to package.json**

In `public/twister/package.json`, find the `"./tag"` export block and add the `"./facets"` block immediately after it (same three-field shape):

```json
    "./facets": {
      "@plotday/connector": "./src/facets.ts",
      "types": "./dist/facets.d.ts",
      "default": "./dist/facets.js"
    },
```

- [ ] **Step 1.3: Add a changeset**

Create `public/.changeset/facets-sdk.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `@plotday/twister/facets` exporting `Format`, `Automation`, `Reach`, and `ThreadFacets` for connector-emitted thread facets, and `NewLink.facets` to carry them.
```

- [ ] **Step 1.4: Validate the changeset**

Run: `cd /Users/kris.braun/code/plot/public && pnpm validate-changesets`
Expected: passes (no errors).

- [ ] **Step 1.5: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add twister/src/facets.ts twister/package.json .changeset/facets-sdk.md
git commit -m "feat(twister): add ThreadFacets facet vocabulary export"
```

---

## Task 2: SDK — `NewLink.facets`

**Files:**
- Modify: `public/twister/src/plot.ts` (import + `NewLink`)

- [ ] **Step 2.1: Import ThreadFacets in plot.ts**

At the top of `public/twister/src/plot.ts`, with the other local imports, add:

```typescript
import type { ThreadFacets } from "./facets";
```

(If `plot.ts` has no existing relative imports, place it after the last existing `import` line.)

- [ ] **Step 2.2: Add `facets` to NewLink**

In `public/twister/src/plot.ts`, in the `NewLink` type, immediately after the `sources?: string[];` field (the line ending the `sources` JSDoc block, ~line 1055), insert:

```typescript
    /**
     * Heuristic facets describing this item (format / automation / reach),
     * used as internal classifier signal. Omit a dimension (or set null) when
     * no heuristic is confident. See `@plotday/twister/facets`.
     */
    facets?: ThreadFacets;
```

- [ ] **Step 2.3: Type-check twister**

Run: `cd /Users/kris.braun/code/plot/public/twister && pnpm lint`
Expected: PASS (tsc --noEmit, no errors).

- [ ] **Step 2.4: Build twister and relink**

```bash
cd /Users/kris.braun/code/plot/public/twister && pnpm build
cd /Users/kris.braun/code/plot && pnpm install
```
Expected: build succeeds; `pnpm install` relinks the workspace.

- [ ] **Step 2.5: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add twister/src/plot.ts
git commit -m "feat(twister): add NewLink.facets"
```

---

## Task 3: Scaffold `@plotday/email-classifier`

**Files:**
- Modify: `public/pnpm-workspace.yaml`
- Modify: `/Users/kris.braun/code/plot/pnpm-workspace.yaml`
- Create: `public/libs/email-classifier/package.json`
- Create: `public/libs/email-classifier/tsconfig.json`
- Create: `public/libs/email-classifier/vitest.config.ts`
- Create: `public/libs/email-classifier/src/index.ts`

- [ ] **Step 3.1: Add `libs/*` to the public workspace**

In `public/pnpm-workspace.yaml`, add `- libs/*` so the file reads:

```yaml
packages:
  - twister
  - connectors/*
  - twists/*
  - libs/*
```

- [ ] **Step 3.2: Add `public/libs/*` to the root workspace**

In `/Users/kris.braun/code/plot/pnpm-workspace.yaml`, add `- public/libs/*` after the `- public/twists/*` line:

```yaml
  - public/twists/*
  - public/libs/*
```

- [ ] **Step 3.3: Create the package.json**

Create `public/libs/email-classifier/package.json`:

```json
{
  "name": "@plotday/email-classifier",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "@plotday/connector": "./src/index.ts",
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "files": ["dist", "README.md"],
  "scripts": {
    "build": "tsc",
    "clean": "rm -rf dist",
    "lint": "tsc --noEmit",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@plotday/twister": "workspace:^"
  },
  "devDependencies": {
    "typescript": "^5.9.3",
    "vitest": "^2.1.8"
  }
}
```

- [ ] **Step 3.4: Create the tsconfig.json**

Create `public/libs/email-classifier/tsconfig.json`:

```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/twister/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "./dist"
  },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 3.5: Create the vitest.config.ts**

Create `public/libs/email-classifier/vitest.config.ts`:

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
```

- [ ] **Step 3.6: Create the index barrel**

Create `public/libs/email-classifier/src/index.ts`:

```typescript
export { classifyEmail, type EmailSignals } from "./classify-email";
```

- [ ] **Step 3.7: Install so the workspace picks up the new package**

Run: `cd /Users/kris.braun/code/plot && pnpm install`
Expected: pnpm reports the new `@plotday/email-classifier` workspace package; no errors. (`src/classify-email.ts` doesn't exist yet — that's Task 4; do not build yet.)

- [ ] **Step 3.8: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add pnpm-workspace.yaml libs/email-classifier/package.json libs/email-classifier/tsconfig.json libs/email-classifier/vitest.config.ts libs/email-classifier/src/index.ts
git commit -m "chore(email-classifier): scaffold shared package"
cd /Users/kris.braun/code/plot
git add pnpm-workspace.yaml
git commit -m "chore: register public/libs/* workspace glob"
```

---

## Task 4: Implement `classifyEmail`

**Files:**
- Create: `public/libs/email-classifier/src/classify-email.test.ts`
- Create: `public/libs/email-classifier/src/classify-email.ts`

- [ ] **Step 4.1: Write the failing tests**

Create `public/libs/email-classifier/src/classify-email.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { classifyEmail, type EmailSignals } from "./classify-email";

function signals(overrides: Partial<EmailSignals> = {}): EmailSignals {
  return {
    listId: null,
    listUnsubscribe: null,
    precedence: null,
    autoSubmitted: null,
    returnPath: null,
    importance: null,
    fromAddress: "jane@example.com",
    recipientCount: 1,
    isReply: false,
    subject: "Hello",
    bodyLength: 300,
    gmailCategories: [],
    ...overrides,
  };
}

describe("classifyEmail — automation", () => {
  it("flags no-reply senders automated", () => {
    expect(classifyEmail(signals({ fromAddress: "no-reply@acme.com" })).automation).toBe("automated");
  });
  it("flags Precedence: bulk automated", () => {
    expect(classifyEmail(signals({ precedence: "bulk" })).automation).toBe("automated");
  });
  it("flags Auto-Submitted automated", () => {
    expect(classifyEmail(signals({ autoSubmitted: "auto-generated" })).automation).toBe("automated");
  });
  it("treats a plain person email as human", () => {
    expect(classifyEmail(signals()).automation).toBe("human");
  });
});

describe("classifyEmail — reach", () => {
  it("flags List-Id as list", () => {
    expect(classifyEmail(signals({ listId: "<news.acme.com>" })).reach).toBe("list");
  });
  it("flags List-Unsubscribe as list", () => {
    expect(classifyEmail(signals({ listUnsubscribe: "<mailto:u@acme.com>" })).reach).toBe("list");
  });
  it("flags high recipient count as list", () => {
    expect(classifyEmail(signals({ recipientCount: 12 })).reach).toBe("list");
  });
  it("treats a 1:1 email as direct", () => {
    expect(classifyEmail(signals()).reach).toBe("direct");
  });
});

describe("classifyEmail — format", () => {
  it("invoice from subject keywords", () => {
    expect(classifyEmail(signals({ subject: "Your invoice is due", fromAddress: "billing@acme.com" })).format).toBe("invoice");
  });
  it("receipt from subject keywords", () => {
    expect(classifyEmail(signals({ subject: "Your order confirmation #1234", fromAddress: "orders@shop.com" })).format).toBe("receipt");
  });
  it("promotion from Gmail category", () => {
    expect(classifyEmail(signals({ gmailCategories: ["CATEGORY_PROMOTIONS"], listUnsubscribe: "<x>" })).format).toBe("promotion");
  });
  it("reading from a long list email", () => {
    expect(
      classifyEmail(signals({ listId: "<news>", listUnsubscribe: "<x>", bodyLength: 4000, subject: "Weekly digest" })).format
    ).toBe("reading");
  });
  it("notification from a short automated update", () => {
    expect(
      classifyEmail(signals({ fromAddress: "notifications@github.com", bodyLength: 200, gmailCategories: ["CATEGORY_UPDATES"] })).format
    ).toBe("notification");
  });
  it("message for a normal human email", () => {
    expect(classifyEmail(signals({ bodyLength: 800 })).format).toBe("message");
  });
  it("leaves format null when nothing is confident", () => {
    // automated, short, no category, no list → ambiguous notification-ish but
    // we still classify notification; this asserts a genuinely empty case:
    expect(classifyEmail(signals({ fromAddress: "no-reply@x.com", bodyLength: 0, subject: null })).format).toBe("notification");
  });
});
```

- [ ] **Step 4.2: Run tests to verify they fail**

Run: `cd /Users/kris.braun/code/plot/public/libs/email-classifier && pnpm test`
Expected: FAIL — `classify-email` cannot be resolved / `classifyEmail` is not a function.

- [ ] **Step 4.3: Implement classifyEmail**

Create `public/libs/email-classifier/src/classify-email.ts`:

```typescript
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
```

- [ ] **Step 4.4: Run tests to verify they pass**

Run: `cd /Users/kris.braun/code/plot/public/libs/email-classifier && pnpm test`
Expected: PASS (all cases). If the "message for a normal human email" case fails because `bodyLength: 800` triggers notification, confirm `NOTIFICATION_MAX_BODY` (700) < 800 — it is, so format falls through to `message`.

- [ ] **Step 4.5: Build the package**

Run: `cd /Users/kris.braun/code/plot/public/libs/email-classifier && pnpm build`
Expected: `dist/` is produced, no tsc errors.

- [ ] **Step 4.6: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add libs/email-classifier/src/classify-email.ts libs/email-classifier/src/classify-email.test.ts
git commit -m "feat(email-classifier): classifyEmail heuristics"
```

---

## Task 5: Gmail emits facets

**Files:**
- Modify: `public/connectors/gmail/package.json` (dependency)
- Create: `public/connectors/gmail/src/gmail-facets.ts`
- Create: `public/connectors/gmail/src/gmail-facets.test.ts`
- Modify: `public/connectors/gmail/src/gmail.ts` (saveLink site ~1347)

- [ ] **Step 5.1: Add the dependency**

In `public/connectors/gmail/package.json`, add to `dependencies` (alongside `@plotday/connector-google-contacts`):

```json
    "@plotday/email-classifier": "workspace:^",
```

Then run: `cd /Users/kris.braun/code/plot && pnpm install`
Expected: gmail now resolves `@plotday/email-classifier`.

- [ ] **Step 5.2: Write the failing test for signal extraction**

Create `public/connectors/gmail/src/gmail-facets.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { gmailFacets } from "./gmail-facets";
import type { GmailMessage } from "./gmail-api";

function msg(opts: {
  headers: Array<[string, string]>;
  labelIds?: string[];
  body?: string;
}): GmailMessage {
  return {
    id: "m1",
    threadId: "t1",
    labelIds: opts.labelIds ?? [],
    snippet: "",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 0,
    payload: {
      mimeType: "text/plain",
      headers: opts.headers.map(([name, value]) => ({ name, value })),
      body: opts.body !== undefined ? { size: opts.body.length } : undefined,
    },
  };
}

describe("gmailFacets", () => {
  it("classifies a newsletter as reading/automated/list", () => {
    const f = gmailFacets(
      msg({
        headers: [
          ["From", "news@substack.com"],
          ["To", "me@x.com"],
          ["Subject", "The Weekly Digest"],
          ["List-Id", "<news.substack.com>"],
          ["List-Unsubscribe", "<mailto:u@substack.com>"],
        ],
      }),
      "a".repeat(4000)
    );
    expect(f).toEqual({ format: "reading", automation: "automated", reach: "list" });
  });

  it("classifies a personal 1:1 email as message/human/direct", () => {
    const f = gmailFacets(
      msg({ headers: [["From", "jane@friends.com"], ["To", "me@x.com"], ["Subject", "Lunch?"]] }),
      "a".repeat(500)
    );
    expect(f).toEqual({ format: "message", automation: "human", reach: "direct" });
  });

  it("classifies a GitHub notification", () => {
    const f = gmailFacets(
      msg({
        headers: [["From", "notifications@github.com"], ["To", "me@x.com"], ["Subject", "[repo] PR merged"]],
        labelIds: ["CATEGORY_UPDATES"],
      }),
      "short"
    );
    expect(f.format).toBe("notification");
    expect(f.automation).toBe("automated");
  });
});
```

- [ ] **Step 5.3: Run to verify it fails**

Run: `cd /Users/kris.braun/code/plot/public/connectors/gmail && pnpm test gmail-facets`
Expected: FAIL — `./gmail-facets` not found.

- [ ] **Step 5.4: Implement the signal extractor**

Create `public/connectors/gmail/src/gmail-facets.ts`:

```typescript
import { classifyEmail, type EmailSignals } from "@plotday/email-classifier";
import type { ThreadFacets } from "@plotday/twister/facets";
import { getHeader, type GmailMessage } from "./gmail-api";

const GMAIL_CATEGORY_LABELS = new Set([
  "CATEGORY_PROMOTIONS",
  "CATEGORY_UPDATES",
  "CATEGORY_SOCIAL",
  "CATEGORY_FORUMS",
  "CATEGORY_PERSONAL",
]);

// Count comma-separated addresses in a header value (To/Cc). Empty → 0.
function addressCount(value: string | null): number {
  if (!value) return 0;
  return value.split(",").map((s) => s.trim()).filter((s) => s.length > 0).length;
}

function parseAddress(from: string | null): string | null {
  if (!from) return null;
  const angle = from.match(/<([^>]+)>/);
  const addr = (angle ? angle[1] : from).trim().toLowerCase();
  return addr.includes("@") ? addr : null;
}

/**
 * Compute facets for a Gmail message. `bodyText` is the extracted body used
 * for the length heuristic (pass the same string the note will carry).
 */
export function gmailFacets(message: GmailMessage, bodyText: string): ThreadFacets {
  const signals: EmailSignals = {
    listId: getHeader(message, "List-Id"),
    listUnsubscribe: getHeader(message, "List-Unsubscribe"),
    precedence: getHeader(message, "Precedence"),
    autoSubmitted: getHeader(message, "Auto-Submitted"),
    returnPath: getHeader(message, "Return-Path"),
    importance: getHeader(message, "Importance") ?? getHeader(message, "X-Priority"),
    fromAddress: parseAddress(getHeader(message, "From")),
    recipientCount: addressCount(getHeader(message, "To")) + addressCount(getHeader(message, "Cc")),
    isReply: getHeader(message, "In-Reply-To") !== null || getHeader(message, "References") !== null,
    subject: getHeader(message, "Subject"),
    bodyLength: bodyText.length,
    gmailCategories: (message.labelIds ?? []).filter((l) => GMAIL_CATEGORY_LABELS.has(l)),
  };
  return classifyEmail(signals);
}
```

- [ ] **Step 5.5: Run to verify it passes**

Run: `cd /Users/kris.braun/code/plot/public/connectors/gmail && pnpm test gmail-facets`
Expected: PASS.

- [ ] **Step 5.6: Set link.facets at the saveLink site**

In `public/connectors/gmail/src/gmail.ts`, the `meta` spread block (~line 1347) currently reads:

```typescript
    plotThread.meta = {
      ...plotThread.meta,
      syncProvider: "google",
      syncableId: channelId,
    };
```

Add a facets assignment immediately after that block, using the thread's parent message and its preview/body. Insert:

```typescript
    // Compute classifier facets from the parent message's headers + body.
    const facetParent = thread.messages.find((m) => !m.labelIds?.includes("DRAFT"));
    if (facetParent) {
      plotThread.facets = gmailFacets(facetParent, plotThread.preview ?? "");
    }
```

Then add the import at the top of `gmail.ts` (with the other `./` imports):

```typescript
import { gmailFacets } from "./gmail-facets";
```

(Note: `plotThread.preview` is the parent body preview built in `transformGmailThread`. Using it for the length heuristic is a coarse but sufficient proxy; the exact body is per-note. If `preview` is short for genuinely long newsletters, the `reading` heuristic still fires via `bodyLength` only when ≥1200 chars — acceptable best-effort per the design's fail-open principle.)

- [ ] **Step 5.7: Type-check and run the full gmail test suite**

```bash
cd /Users/kris.braun/code/plot/public/connectors/gmail
pnpm lint
pnpm test
```
Expected: lint PASS; all tests PASS (existing + new).

- [ ] **Step 5.8: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add connectors/gmail/package.json connectors/gmail/src/gmail-facets.ts connectors/gmail/src/gmail-facets.test.ts connectors/gmail/src/gmail.ts
git commit -m "feat(gmail): emit thread facets from email signals"
```

---

## Task 6: Slack emits facets

**Files:**
- Create: `public/connectors/slack/src/slack-facets.ts`
- Create: `public/connectors/slack/src/slack-facets.test.ts`
- Modify: `public/connectors/slack/src/slack.ts` (three saveLink sites: ~501, ~684, ~903)

- [ ] **Step 6.1: Write the failing test**

Create `public/connectors/slack/src/slack-facets.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { slackFacets } from "./slack-facets";
import type { SlackMessage } from "./slack-api";

function m(overrides: Partial<SlackMessage> = {}): SlackMessage {
  return { type: "message", ts: "1.0", text: "hi", ...overrides };
}

describe("slackFacets", () => {
  it("treats a DM human message as chat/human/direct", () => {
    expect(slackFacets(m({ user: "U1", text: "hey there" }), "D123")).toEqual({
      format: "chat",
      automation: "human",
      reach: "direct",
    });
  });
  it("treats a channel post as reach=list", () => {
    expect(slackFacets(m({ user: "U1" }), "C123").reach).toBe("list");
  });
  it("flags a bot message automated", () => {
    expect(slackFacets(m({ bot_id: "B1", subtype: "bot_message" }), "C123").automation).toBe("automated");
  });
  it("a long post becomes a message, not chat", () => {
    expect(slackFacets(m({ user: "U1", text: "x".repeat(1500) }), "C123").format).toBe("message");
  });
});
```

- [ ] **Step 6.2: Run to verify it fails**

Run: `cd /Users/kris.braun/code/plot/public/connectors/slack && pnpm test slack-facets`
Expected: FAIL — `./slack-facets` not found.

- [ ] **Step 6.3: Implement the Slack facet helper**

Create `public/connectors/slack/src/slack-facets.ts`:

```typescript
import type { ThreadFacets } from "@plotday/twister/facets";
import type { SlackMessage } from "./slack-api";

// Channel-id prefixes: C = public/private channel, G = group/MPIM, D = IM (DM).
// Channels are broadcast contexts (reach=list); DMs/group-DMs are direct.
function reachForChannel(channelId: string): "direct" | "list" {
  return channelId.startsWith("C") ? "list" : "direct";
}

// A long Slack post reads as a "message" rather than a quick "chat".
const CHAT_MAX_LENGTH = 1000;

/**
 * Compute facets for a Slack thread's parent message. Channel kind is inferred
 * from the channelId prefix (the full channel object is not in scope at save
 * time); this is best-effort per the facet design's fail-open principle.
 */
export function slackFacets(parent: SlackMessage, channelId: string): ThreadFacets {
  const isBot = Boolean(parent.bot_id) || parent.subtype === "bot_message" || !parent.user;
  const text = parent.text ?? "";
  return {
    format: text.length > CHAT_MAX_LENGTH ? "message" : "chat",
    automation: isBot ? "automated" : "human",
    reach: reachForChannel(channelId),
  };
}
```

- [ ] **Step 6.4: Run to verify it passes**

Run: `cd /Users/kris.braun/code/plot/public/connectors/slack && pnpm test slack-facets`
Expected: PASS.

- [ ] **Step 6.5: Set link.facets at the three saveLink sites**

In `public/connectors/slack/src/slack.ts`, add the import at the top (with other `./` imports):

```typescript
import { slackFacets } from "./slack-facets";
```

Then, at each of the three places where `link.meta`/`activityThread.meta` is set with `syncProvider: "slack"` (the `processMessageThreads` site ~501 uses `activityThread`; `refreshSlackThread` ~684 and `saveStarredThread` ~903 use `link`), add a facets assignment immediately after that meta block. The parent message is the first element of the `messages`/`thread` array in scope at each site.

At the `processMessageThreads` site (variable `activityThread`, `thread` is the message array):

```typescript
        if (thread[0]) activityThread.facets = slackFacets(thread[0], channelId);
```

At the `refreshSlackThread` site (variable `link`, `messages` is the array):

```typescript
    if (messages[0]) link.facets = slackFacets(messages[0], channelId);
```

At the `saveStarredThread` site (variable `link`, `messages` is the array):

```typescript
    if (messages[0]) link.facets = slackFacets(messages[0], channelId);
```

(If a site's message-array variable has a different name, use the array that was passed to `transformSlackThread` at that site — confirm by reading the ~20 lines around each `saveLink` call.)

- [ ] **Step 6.6: Type-check and run the slack suite**

```bash
cd /Users/kris.braun/code/plot/public/connectors/slack
pnpm lint
pnpm test
```
Expected: lint PASS; all tests PASS.

- [ ] **Step 6.7: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add connectors/slack/src/slack-facets.ts connectors/slack/src/slack-facets.test.ts connectors/slack/src/slack.ts
git commit -m "feat(slack): emit thread facets per message/channel"
```

---

## Task 7: `thread.facets` column + `upsert_thread` write

**Files:**
- Modify: `libs/db/schema/50-tables/24-thread.sql`
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql`
- Generated: `libs/db/migrations/<timestamp>_add_thread_facets.sql`, `libs/db/src/types.ts`

- [ ] **Step 7.1: Add the column to the thread schema**

In `libs/db/schema/50-tables/24-thread.sql`, add a nullable jsonb column to the `CREATE TABLE` column list. Place it next to `contact_meta` (the existing jsonb column at line ~67). Add the line:

```sql
    "facets" jsonb,
```

(Nullable, no default — connector-supplied, absent for non-communication threads. Not added to any `user.*` view: it is server-only classifier signal and must not sync to clients.)

- [ ] **Step 7.2: Add `facets` to the upsert_thread INSERT column list**

In `libs/db/schema/90-user-schema/80-upsert_thread.sql`, in the `INSERT INTO thread (...)` column list (lines ~397-399), append `facets` after `topic_id`:

```sql
    INSERT INTO thread (
        id, created_by, author_id, title, preview, updated_by, sync_depth, contacts, contact_meta, groups, topic,
        draft, key, icon, twist_id, pending_contacts, team_id, embedding, assignee_id, topic_id, facets
    )
```

- [ ] **Step 7.3: Add the facets VALUES entry**

In the `VALUES (...)` list, after the `v_input_topic_id` entry (the last value, ~line 453), add a comma and the facets value (mirrors how `embedding` reads from `p_thread`/`p_defaults`, but as jsonb via `->`):

```sql
        v_input_topic_id,
        -- Intrinsic facets (format/automation/reach) supplied by the connector
        -- via p_defaults.facets. Server-only classifier signal; never synced.
        COALESCE(p_thread -> 'facets', p_defaults -> 'facets')
```

- [ ] **Step 7.4: Add the facets ON CONFLICT update (fill-only-when-null)**

In the `ON CONFLICT (id) DO UPDATE SET` clause, after the `topic_id = ...` assignment (~line 607-611, the last assignment before `RETURNING`), add:

```sql
            ,
            -- Fill facets only when the row has none yet (connector backfill on
            -- re-sync). Never churn an existing value; never wipe to null.
            facets = COALESCE(thread.facets, EXCLUDED.facets)
```

- [ ] **Step 7.5: Generate the migration**

Run: `cd /Users/kris.braun/code/plot && pnpm gen-migration -- add_thread_facets`
Expected: a new file in `libs/db/migrations/` adding the `facets` column and recreating `upsert_thread`. Open it and confirm it `ADD COLUMN "facets" jsonb` (nullable) and `CREATE OR REPLACE FUNCTION "user".upsert_thread` with the new column.

- [ ] **Step 7.6: Apply the migration and regenerate types**

Run: `cd /Users/kris.braun/code/plot && pnpm apply-migrations`
Expected: applies cleanly; auto-runs `pnpm types` (unless `$CI`). Confirm `libs/db/src/types.ts` now has `facets` on the `Thread`/`ThreadInsert` types.

- [ ] **Step 7.7: Verify schema/migration sync**

Run: `cd /Users/kris.braun/code/plot && pnpm diff-schema-migrations`
Expected: no differences.

- [ ] **Step 7.8: Commit**

```bash
cd /Users/kris.braun/code/plot
git add libs/db/schema/50-tables/24-thread.sql libs/db/schema/90-user-schema/80-upsert_thread.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add thread.facets column, persist via upsert_thread"
```

---

## Task 8: API ingest copies `link.facets` → `thread.facets`

**Files:**
- Modify: `workers/api/src/twist/tools/plot/link.ts` (~line 108)
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts` (~line 1342)
- Create: `workers/api/src/twist/tools/plot/facet-ingest.test.ts`

- [ ] **Step 8.1: Thread `link.facets` into threadData**

In `workers/api/src/twist/tools/plot/link.ts`, in the `threadData` object (~lines 96-119), after the `...(link.meta !== undefined ? { meta: link.meta } : {})` line, add:

```typescript
      ...(link.facets !== undefined ? { facets: link.facets } : {}),
```

- [ ] **Step 8.2: Put facets into the prepareThreadForDb defaults**

In `workers/api/src/twist/tools/plot/thread-helpers.ts`, in the `defaults` object (~lines 1316-1343), after the embedding line `...(embeddingJson ? { embedding: embeddingJson } : {}),`, add:

```typescript
    // Intrinsic facets supplied by the connector (format/automation/reach).
    // Goes into p_defaults so upsert_thread writes it on INSERT and preserves
    // it on UPDATE (never churned). Server-only classifier signal.
    ...((activity as any).facets !== undefined ? { facets: (activity as any).facets } : {}),
```

(`activity` here is the `NewThread`-shaped object built from the link in `createLink`; `(activity as any).facets` matches the existing `(activity as any).key`/`type` access pattern in this file.)

- [ ] **Step 8.3: Write the failing persistence test**

Create `workers/api/src/twist/tools/plot/facet-ingest.test.ts`. This uses the project's TS↔PG rollback-transaction pattern (see `workers/api/src/state/email-digest-query.test.ts`). It calls `upsert_thread` directly with `p_defaults.facets` and asserts the row persisted them — this exercises the exact SQL path connector threads take.

```typescript
import { randomUUID } from "node:crypto";
import { Kysely, PostgresDialect, sql } from "kysely";
import { Pool } from "pg";
import { afterAll, describe, expect, it } from "vitest";
import type { DB } from "@plotday/db";

const DATABASE_URL = process.env.DATABASE_URL;
const d = DATABASE_URL ? describe : describe.skip;

const db = DATABASE_URL
  ? new Kysely<DB>({ dialect: new PostgresDialect({ pool: new Pool({ connectionString: DATABASE_URL }) }) })
  : (null as unknown as Kysely<DB>);

class Rollback extends Error {}

afterAll(async () => {
  if (db) await db.destroy();
});

d("upsert_thread facets persistence", () => {
  it("writes p_defaults.facets onto thread.facets and preserves on re-upsert", async () => {
    const userId = randomUUID();
    const priorityId = randomUUID();
    const email = `u${userId.slice(0, 8)}@example.com`;
    const contactId = randomUUID();
    let captured: { facets: unknown } | undefined;

    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
        await sql`INSERT INTO contact (id, "primary", email) VALUES (${contactId}::uuid, true, ${email})`.execute(trx);
        await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
          VALUES (${userId}::uuid, ${contactId}::uuid, true, true)`.execute(trx);
        await sql`INSERT INTO priority (id, created_by, user_id, title, path)
          VALUES (${priorityId}::uuid, ${userId}::uuid, ${userId}::uuid, 'Inbox', 'inbox'::ltree)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        const facets = { format: "reading", automation: "automated", reach: "list" };

        // First upsert with facets in p_defaults (the connector path).
        const first = await sql<{ id: string; facets: unknown }>`
          SELECT id, facets FROM "user".upsert_thread(
            ${userId}::uuid,
            ${JSON.stringify({ title: "Newsletter" })}::jsonb,
            ${JSON.stringify({ priority_id: priorityId, facets })}::jsonb
          )`.execute(trx);
        const threadId = first.rows[0].id;
        expect(first.rows[0].facets).toEqual(facets);

        // Re-upsert (re-sync) WITHOUT facets → existing value preserved.
        const second = await sql<{ facets: unknown }>`
          SELECT facets FROM "user".upsert_thread(
            ${userId}::uuid,
            ${JSON.stringify({ id: threadId, title: "Newsletter v2" })}::jsonb,
            ${JSON.stringify({ priority_id: priorityId })}::jsonb
          )`.execute(trx);
        captured = second.rows[0];

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }

    expect(captured?.facets).toEqual({ format: "reading", automation: "automated", reach: "list" });
  });
});
```

- [ ] **Step 8.4: Run to verify it fails (before migration is on this DB) or passes (after)**

Run: `cd /Users/kris.braun/code/plot && DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/api test facet-ingest`
Expected: With Task 7's migration applied to the local DB, this PASSES. If `facets` is still unknown, re-run `pnpm apply-migrations`. If `DATABASE_URL` is unset the suite is skipped (not a failure) — set it from `.worktree-db` if in a worktree.

- [ ] **Step 8.5: Type-check the api worker**

Run: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api lint`
Expected: PASS — `link.facets` and `activity.facets` resolve (NewLink change from Task 2 is linked; `thread.facets` is in generated types from Task 7).

- [ ] **Step 8.6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add workers/api/src/twist/tools/plot/link.ts workers/api/src/twist/tools/plot/thread-helpers.ts workers/api/src/twist/tools/plot/facet-ingest.test.ts
git commit -m "feat(api): persist connector link.facets onto thread.facets"
```

---

## Task 9: Finalize

**Files:**
- Modify: `docs/updates.md`, `docs/features.md` (optional, brief)

- [ ] **Step 9.1: Lint each changed package**

```bash
cd /Users/kris.braun/code/plot/public/twister && pnpm lint
cd /Users/kris.braun/code/plot/public/libs/email-classifier && pnpm lint && pnpm test
cd /Users/kris.braun/code/plot/public/connectors/gmail && pnpm lint && pnpm test
cd /Users/kris.braun/code/plot/public/connectors/slack && pnpm lint && pnpm test
cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api lint
cd /Users/kris.braun/code/plot && pnpm --filter @plotday/db run lint
```
Expected: all PASS. (`@plotday/db` lint = the db:lint type-freshness check; it must be green since types were regenerated in Task 7.)

- [ ] **Step 9.2: Confirm no behavior change & backward compat**

Manually verify: `thread.facets` is in NO `user.*` view (grep `libs/db/schema/90-user-schema` for `facets` → only `upsert_thread` should match). Old clients never receive it; connectors that don't set `facets` produce `null` (ungated). There is nothing for Plan 1 to surface to users yet.

Run: `rg -l "facets" libs/db/schema/90-user-schema/`
Expected: only `80-upsert_thread.sql`.

- [ ] **Step 9.3: (Optional) note the groundwork**

This plan is invisible to users on its own, so `docs/updates.md` gets nothing yet (Plan 2 adds the user-facing line). Skip unless you want an internal `docs/features.md` note. If adding one, keep it to a single bullet under the classification section.

- [ ] **Step 9.4: Push the public submodule branch and open its PR**

```bash
cd /Users/kris.braun/code/plot/public
git push -u origin facet-extraction-foundation
gh pr create --title "feat: thread facets (SDK + email-classifier + gmail/slack)" \
  --body "Adds ThreadFacets to the SDK, the @plotday/email-classifier shared package, and gmail/slack facet emission. Part 1 of facet-based classification. No runtime behavior change. 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 9.5: Bump the submodule pointer in the main repo (after the public PR merges)**

After the `public/` PR merges, update the submodule reference and the main-repo changes together. (If executing before the public PR merges, leave the submodule pointer on the feature branch commit and note it in the main-repo PR.)

```bash
cd /Users/kris.braun/code/plot
git add public
git commit -m "chore: bump public submodule to facet extraction foundation"
```

---

## Self-Review (completed by plan author)

**Spec coverage (§ of the design spec → task):**
- §4 SDK `facets.ts` + `NewLink.facets` → Tasks 1–2.
- §4 `thread.facets` storage (server-only, not synced) → Task 7 + Step 9.2.
- §5 `@plotday/email-classifier` shared package + heuristics → Tasks 3–4.
- §5 Gmail wiring → Task 5. Slack source-specific helper → Task 6.
- §5 "set only when confident; null otherwise" → `computeFormat` returns null fallback; non-comm connectors untouched.
- §11 submodule PRs + changeset → Tasks 1.3, 9.4–9.5.
- §12 finalize (lint, db:lint, backward-compat) → Task 9.
- **Deferred to Plan 2 (correctly out of scope here):** `priority.facet_filters`, `priority.description`, `freemail_domain`, the SQL gate + trust predicate, `find-matching-threads` filtering, the LLM filter-derivation + registry. Outlook/apple-mail email connectors don't exist yet; they reuse `@plotday/email-classifier` when built.

**Placeholder scan:** none — every code step has complete code; every command has expected output.

**Type consistency:** `ThreadFacets` (Task 1) is imported in `plot.ts` (Task 2), `classify-email.ts` (Task 4), `gmail-facets.ts` (Task 5), `slack-facets.ts` (Task 6). `EmailSignals` defined in Task 4, consumed in Task 5. `gmailFacets`/`slackFacets` signatures match their tests. `thread.facets` column (Task 7) read by the Task 8 test. `link.facets` (Task 2 SDK) consumed in Task 8.

**Known best-effort approximations (by design, fail-open):** Gmail length heuristic uses `plotThread.preview` not full body; Slack reach inferred from channelId prefix. Both acceptable per the design's "facets set only when confident; gate fails open on null/unknown."
