# Importance Scoring Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the LLM importance scorer actually discriminate — replace the collapsed 0–100 float with an ordinal band fed by existing thread facets + per-(sender) engagement history, so promotional/ignored mail stops notifying while real mail still surfaces.

**Architecture:** A new focused core module `workers/api/src/state/importance/` with three small units — `band.ts` (pure ordinal↔number mapping + rubric), `engagement.ts` (per-recipient sender engagement aggregate), `features.ts` (fuse facets + sender + engagement into a prompt block). `note-analysis.ts` keeps its single LLM call but its prompt is enriched and its `importance` field becomes an ordinal band mapped to a number. No schema, no migration, no public/submodule change.

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Workers AI (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`), Vitest.

## Global Constraints

- **Server-only. No schema change, no migration, no `public/` submodule change.** (`libs/db/schema` untouched.)
- **Reads the existing public facet column `thread.facets` (jsonb) — never writes facets.**
- **Importance stays a `smallint` 0–100; the downstream gate `importance >= 50 OR urgent` is unchanged.**
- **Never ignore DB errors:** engagement reads are best-effort — wrap in try/catch, degrade to "insufficient history", `captureException` only for unexpected errors (PostHog), never for empty results.
- **Static imports only** at the top of each file (no dynamic `import()`).
- **The same single LLM call** produces `{active, urgent, importance, skip}` — do not add a second AI call.
- **Soft bias, no hard cap:** deterministic signals are prompt context + the failure-path fallback only. They never override a band the LLM actually returned.
- Run all commands from the worktree: `/Users/kris.braun/code/plot/.claude/worktrees/importance-scoring`. API tests run from `workers/api` via `pnpm vitest run <path>`.

---

### Task 1: `band.ts` — ordinal band, mapping, rubric, fallback (pure)

**Files:**
- Create: `workers/api/src/state/importance/band.ts`
- Test: `workers/api/src/state/importance/band.test.ts`

**Interfaces:**
- Produces:
  - `type ImportanceBand = "suppress" | "low" | "normal" | "elevated"`
  - `bandToImportance(band: ImportanceBand): number` → 15 | 45 | 60 | 85
  - `parseBand(raw: unknown): ImportanceBand | null` — accepts the four strings (case-insensitive, trimmed), else null
  - `type FallbackSignals = { facetAutomation: "human" | "automated" | null; facetReach: "direct" | "list" | null; facetFormat: string | null; senderEmailAutomated: boolean; senderKnown: boolean }`
  - `fallbackBand(s: FallbackSignals): ImportanceBand` — deterministic band when the LLM produced nothing
  - `IMPORTANCE_RUBRIC: string` — the prompt fragment describing the four bands
  - `IMPORTANCE_JSON_EXAMPLE: string` — `{"importance": "normal"}` style example (no numeric anchor)

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/state/importance/band.test.ts`:

```typescript
import { describe, expect, it } from "vitest";

import {
  bandToImportance,
  fallbackBand,
  IMPORTANCE_RUBRIC,
  parseBand,
} from "./band";

describe("bandToImportance", () => {
  it("maps suppress and low below the 50 gate", () => {
    expect(bandToImportance("suppress")).toBeLessThan(50);
    expect(bandToImportance("low")).toBeLessThan(50);
  });
  it("maps normal and elevated at/above the gate, elevated highest", () => {
    expect(bandToImportance("normal")).toBeGreaterThanOrEqual(50);
    expect(bandToImportance("elevated")).toBeGreaterThan(bandToImportance("normal"));
  });
  it("preserves strict ordering suppress < low < normal < elevated", () => {
    const seq = ["suppress", "low", "normal", "elevated"] as const;
    const vals = seq.map(bandToImportance);
    expect(vals).toEqual([...vals].sort((a, b) => a - b));
    expect(new Set(vals).size).toBe(4);
  });
});

describe("parseBand", () => {
  it("accepts the four bands case-insensitively", () => {
    expect(parseBand("Suppress")).toBe("suppress");
    expect(parseBand(" elevated ")).toBe("elevated");
  });
  it("rejects junk, numbers, and empty", () => {
    expect(parseBand("urgent")).toBeNull();
    expect(parseBand(50)).toBeNull();
    expect(parseBand(null)).toBeNull();
    expect(parseBand(undefined)).toBeNull();
  });
});

describe("fallbackBand", () => {
  const base = {
    facetAutomation: null,
    facetReach: null,
    facetFormat: null,
    senderEmailAutomated: false,
    senderKnown: false,
  };
  it("suppresses automated list mail", () => {
    expect(
      fallbackBand({ ...base, facetAutomation: "automated", facetReach: "list" }),
    ).toBe("low");
  });
  it("suppresses promotion-format mail", () => {
    expect(fallbackBand({ ...base, facetFormat: "promotion" })).toBe("low");
  });
  it("suppresses an unknown no-reply sender", () => {
    expect(
      fallbackBand({ ...base, senderEmailAutomated: true, senderKnown: false }),
    ).toBe("low");
  });
  it("does NOT suppress a no-reply sender the recipient already engages with", () => {
    expect(
      fallbackBand({ ...base, senderEmailAutomated: true, senderKnown: true }),
    ).toBe("normal");
  });
  it("defaults ordinary mail to normal (surfaces)", () => {
    expect(fallbackBand({ ...base, facetAutomation: "human", facetReach: "direct" })).toBe(
      "normal",
    );
  });
});

describe("IMPORTANCE_RUBRIC", () => {
  it("names all four bands and omits a numeric 0-100 instruction", () => {
    for (const b of ["suppress", "low", "normal", "elevated"]) {
      expect(IMPORTANCE_RUBRIC).toContain(b);
    }
    expect(IMPORTANCE_RUBRIC).not.toMatch(/0-100|0 to 100/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && pnpm vitest run src/state/importance/band.test.ts`
Expected: FAIL — "Cannot find module './band'".

- [ ] **Step 3: Write minimal implementation**

Create `workers/api/src/state/importance/band.ts`:

```typescript
/**
 * Importance bands. The LLM (and the deterministic failure-path fallback) pick
 * one of these four labels; `bandToImportance` maps to the 0..100 column the
 * notification gate (`importance >= 50 OR urgent`) and the feed ordering read.
 *
 * Why an ordinal, not a 0..100 number: a 70B model asked for a calibrated float
 * anchors on the example value and refuses the low end, so in prod importance
 * collapsed to ~50 (only 2 rows <50 in 21 days) and the suppression path never
 * fired. A four-way label is a task the model performs reliably.
 */
export type ImportanceBand = "suppress" | "low" | "normal" | "elevated";

const BAND_TO_IMPORTANCE: Record<ImportanceBand, number> = {
  suppress: 15, // below gate — no push/email/badge, sorts lowest
  low: 45, // below gate — exists, won't surface proactively
  normal: 60, // above gate — ordinary mail the recipient wants surfaced
  elevated: 85, // above gate — personal/direct/time-sensitive, sorts high
};

export function bandToImportance(band: ImportanceBand): number {
  return BAND_TO_IMPORTANCE[band];
}

export function parseBand(raw: unknown): ImportanceBand | null {
  if (typeof raw !== "string") return null;
  const v = raw.trim().toLowerCase();
  return v === "suppress" || v === "low" || v === "normal" || v === "elevated"
    ? v
    : null;
}

/**
 * Signals available without the LLM. Used only on the failure path (AI disabled,
 * quota exhausted, parse failure) — NOT to override a band the LLM returned.
 */
export type FallbackSignals = {
  facetAutomation: "human" | "automated" | null;
  facetReach: "direct" | "list" | null;
  facetFormat: string | null;
  senderEmailAutomated: boolean;
  senderKnown: boolean;
};

/**
 * Deterministic band when the LLM produced no usable band. Obvious bulk mail
 * stops notifying even on the failure path; everything else defaults to normal
 * (surfaces), preserving today's notify-by-default behaviour for real mail.
 */
export function fallbackBand(s: FallbackSignals): ImportanceBand {
  const automatedList = s.facetAutomation === "automated" && s.facetReach === "list";
  const promo = s.facetFormat === "promotion";
  const coldNoReply = s.senderEmailAutomated && !s.senderKnown;
  return automatedList || promo || coldNoReply ? "low" : "normal";
}

/** Prompt fragment: the four-band rubric. Keyed on the injected feature block. */
export const IMPORTANCE_RUBRIC = `importance — pick exactly one band:
- "suppress": promotional / mass-distribution / automated bulk the recipient consistently ignores. Strong signals: automation=automated AND reach=list; or historical read rate below ~15% over several prior threads; or a no-reply sender the recipient has no history with.
- "low": automated or FYI mail that isn't junk but needs no proactive surfacing (newsletters they open occasionally, non-skip receipts).
- "normal": ordinary correspondence the recipient would want surfaced proactively. This is the default when nothing points up or down.
- "elevated": personal or direct messages from known contacts, direct asks, time-sensitive items. Signals: high historical read/reply rate, reach=direct, a known sender.
Anything you mark urgent or active MUST be "normal" or "elevated".`;

export const IMPORTANCE_JSON_EXAMPLE = `{"importance": "normal"}`;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd workers/api && pnpm vitest run src/state/importance/band.test.ts`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/state/importance/band.ts workers/api/src/state/importance/band.test.ts
git commit -m "feat(importance): ordinal band type, mapping, rubric, deterministic fallback"
```

---

### Task 2: `engagement.ts` — per-recipient sender engagement aggregate

**Files:**
- Create: `workers/api/src/state/importance/engagement.ts`
- Test: `workers/api/src/state/importance/engagement.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `type EngagementCounts = { priorThreads: number; readCount: number; archivedUnreadCount: number; replyCount: number }`
  - `type SenderEngagement = { priorThreads: number; readRate: number | null; archivedUnreadRate: number | null; replyRate: number | null }`
  - `const MIN_ENGAGEMENT_HISTORY = 3`
  - `computeEngagement(c: EngagementCounts): SenderEngagement` (pure)
  - `getSenderEngagement(db: Kysely<DB>, recipientUserId: string, senderContactId: string, currentThreadId: string, env: Bindings, cache?: Map<string, Promise<SenderEngagement>>): Promise<SenderEngagement>` — best-effort; degrades to zero-history on error.

**Note:** `computeEngagement` carries the logic and is unit-tested here. `getSenderEngagement` is a thin SQL wrapper validated by typecheck + the Task 4 integration test (which mocks this module). A DB-backed test for the raw SQL is an optional follow-up (see end of plan).

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/state/importance/engagement.test.ts`:

```typescript
import { describe, expect, it } from "vitest";

import { computeEngagement, MIN_ENGAGEMENT_HISTORY } from "./engagement";

describe("computeEngagement", () => {
  it("returns null rates below the minimum history but still reports priorThreads", () => {
    const r = computeEngagement({
      priorThreads: MIN_ENGAGEMENT_HISTORY - 1,
      readCount: 0,
      archivedUnreadCount: 2,
      replyCount: 0,
    });
    expect(r.priorThreads).toBe(MIN_ENGAGEMENT_HISTORY - 1);
    expect(r.readRate).toBeNull();
    expect(r.archivedUnreadRate).toBeNull();
    expect(r.replyRate).toBeNull();
  });

  it("computes rates once enough history exists", () => {
    const r = computeEngagement({
      priorThreads: 10,
      readCount: 1,
      archivedUnreadCount: 8,
      replyCount: 0,
    });
    expect(r.priorThreads).toBe(10);
    expect(r.readRate).toBeCloseTo(0.1, 5);
    expect(r.archivedUnreadRate).toBeCloseTo(0.8, 5);
    expect(r.replyRate).toBeCloseTo(0, 5);
  });

  it("handles a fully-engaged sender", () => {
    const r = computeEngagement({
      priorThreads: 6,
      readCount: 6,
      archivedUnreadCount: 0,
      replyCount: 5,
    });
    expect(r.readRate).toBeCloseTo(1, 5);
    expect(r.replyRate).toBeCloseTo(5 / 6, 5);
  });

  it("treats zero history as priorThreads 0, null rates", () => {
    const r = computeEngagement({
      priorThreads: 0,
      readCount: 0,
      archivedUnreadCount: 0,
      replyCount: 0,
    });
    expect(r.priorThreads).toBe(0);
    expect(r.readRate).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && pnpm vitest run src/state/importance/engagement.test.ts`
Expected: FAIL — "Cannot find module './engagement'".

- [ ] **Step 3: Write minimal implementation**

Create `workers/api/src/state/importance/engagement.ts`:

```typescript
import { PostHog } from "posthog-node";
import { type Kysely, sql } from "kysely";

import type { DB } from "../../db";
import type { Bindings } from "../../env";

export const MIN_ENGAGEMENT_HISTORY = 3;
const ENGAGEMENT_WINDOW_DAYS = 120;

export type EngagementCounts = {
  priorThreads: number;
  readCount: number;
  archivedUnreadCount: number;
  replyCount: number;
};

export type SenderEngagement = {
  priorThreads: number;
  readRate: number | null;
  archivedUnreadRate: number | null;
  replyRate: number | null;
};

/** Pure: derive rates from raw counts. Rates are null until history is stable. */
export function computeEngagement(c: EngagementCounts): SenderEngagement {
  if (c.priorThreads < MIN_ENGAGEMENT_HISTORY) {
    return {
      priorThreads: c.priorThreads,
      readRate: null,
      archivedUnreadRate: null,
      replyRate: null,
    };
  }
  return {
    priorThreads: c.priorThreads,
    readRate: c.readCount / c.priorThreads,
    archivedUnreadRate: c.archivedUnreadCount / c.priorThreads,
    replyRate: c.replyCount / c.priorThreads,
  };
}

const ZERO_HISTORY: SenderEngagement = {
  priorThreads: 0,
  readRate: null,
  archivedUnreadRate: null,
  replyRate: null,
};

/**
 * How the recipient has historically treated mail from this sender. Best-effort
 * enrichment for the importance prompt: on any failure we degrade to
 * zero-history (the LLM then treats the sender as unknown) and capture only
 * unexpected errors. Optional `cache` memoizes per (recipient, sender) so a
 * batch of notes from the same sender issues the aggregate once.
 */
export async function getSenderEngagement(
  db: Kysely<DB>,
  recipientUserId: string,
  senderContactId: string,
  currentThreadId: string,
  env: Bindings,
  cache?: Map<string, Promise<SenderEngagement>>,
): Promise<SenderEngagement> {
  const key = `${recipientUserId}:${senderContactId}`;
  const cached = cache?.get(key);
  if (cached) return cached;

  const pending = (async (): Promise<SenderEngagement> => {
    try {
      const result = await sql<EngagementCounts>`
        WITH prior AS (
          SELECT
            (ts.read_at IS NOT NULL) AS was_read,
            (ts.read_at IS NULL AND tp.archived_at IS NOT NULL) AS archived_unread,
            EXISTS (
              SELECT 1 FROM note n
              WHERE n.thread_id = t.id
                AND n.draft = FALSE
                AND n.author_id = ANY("user".user_contact_ids(${recipientUserId}::uuid))
            ) AS replied
          FROM thread t
          JOIN thread_state ts
            ON ts.thread_id = t.id AND ts.user_id = ${recipientUserId}::uuid
          LEFT JOIN thread_priority tp
            ON tp.thread_id = t.id AND tp.user_id = ${recipientUserId}::uuid
          WHERE t.author_id = ${senderContactId}::uuid
            AND t.id <> ${currentThreadId}::uuid
            AND t.created_at > now() - (${ENGAGEMENT_WINDOW_DAYS} || ' days')::interval
        )
        SELECT
          count(*)::int AS "priorThreads",
          count(*) FILTER (WHERE was_read)::int AS "readCount",
          count(*) FILTER (WHERE archived_unread)::int AS "archivedUnreadCount",
          count(*) FILTER (WHERE replied)::int AS "replyCount"
        FROM prior
      `.execute(db);

      const row = result.rows[0];
      if (!row) return ZERO_HISTORY;
      return computeEngagement(row);
    } catch (error) {
      // Best-effort: degrade silently to zero-history, but flag unexpected
      // failures so a broken query/permission doesn't disappear.
      const postHog = new PostHog(env.POSTHOG_API_KEY, {
        host: env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      postHog.captureException(error as Error, recipientUserId, {
        context: "importance:getSenderEngagement",
        sender_contact_id: senderContactId,
      });
      await postHog.shutdown();
      return ZERO_HISTORY;
    }
  })();

  cache?.set(key, pending);
  return pending;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd workers/api && pnpm vitest run src/state/importance/engagement.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/state/importance/engagement.ts workers/api/src/state/importance/engagement.test.ts
git commit -m "feat(importance): per-recipient sender engagement aggregate"
```

---

### Task 3: `features.ts` — fuse facets + sender + engagement into a prompt block

**Files:**
- Create: `workers/api/src/state/importance/features.ts`
- Test: `workers/api/src/state/importance/features.test.ts`

**Interfaces:**
- Consumes: `SenderEngagement` from `./engagement`.
- Produces:
  - `isAutomatedSenderEmail(email: string | null): boolean` (pure)
  - `type ThreadFacetsLike = { format: string | null; automation: "human" | "automated" | null; reach: "direct" | "list" | null } | null`
  - `type MemberFeature = { memberNum: number; engagement: SenderEngagement }`
  - `formatImportanceFeatureBlock(args: { facets: ThreadFacetsLike; senderEmailAutomated: boolean; senderIsLinkedUser: boolean; members: MemberFeature[] }): string` (pure) — the prompt block injected into the user message.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/state/importance/features.test.ts`:

```typescript
import { describe, expect, it } from "vitest";

import { formatImportanceFeatureBlock, isAutomatedSenderEmail } from "./features";

describe("isAutomatedSenderEmail", () => {
  it("flags no-reply / notifications / mailer addresses", () => {
    for (const e of [
      "no-reply@acme.com",
      "noreply@acme.com",
      "do-not-reply@acme.com",
      "notifications@acme.com",
      "notification@x.io",
      "mailer-daemon@x.io",
      "bounce+abc@x.io",
      "postmaster@x.io",
    ]) {
      expect(isAutomatedSenderEmail(e)).toBe(true);
    }
  });
  it("does not flag ordinary personal addresses or null", () => {
    expect(isAutomatedSenderEmail("kris@plot.day")).toBe(false);
    expect(isAutomatedSenderEmail("jane.doe@gmail.com")).toBe(false);
    expect(isAutomatedSenderEmail(null)).toBe(false);
    expect(isAutomatedSenderEmail("")).toBe(false);
  });
});

describe("formatImportanceFeatureBlock", () => {
  it("renders facets, sender flags, and per-member engagement", () => {
    const block = formatImportanceFeatureBlock({
      facets: { format: "promotion", automation: "automated", reach: "list" },
      senderEmailAutomated: true,
      senderIsLinkedUser: false,
      members: [
        {
          memberNum: 1,
          engagement: {
            priorThreads: 9,
            readRate: 0.11,
            archivedUnreadRate: 0.78,
            replyRate: 0,
          },
        },
      ],
    });
    expect(block).toContain("promotion");
    expect(block).toContain("automated");
    expect(block).toContain("list");
    expect(block).toMatch(/no-?reply|automated sender/i);
    expect(block).toContain("#1");
    // read rate surfaced as a percentage the model can act on
    expect(block).toMatch(/11%/);
  });

  it("states when a sender is new / has no history", () => {
    const block = formatImportanceFeatureBlock({
      facets: null,
      senderEmailAutomated: false,
      senderIsLinkedUser: true,
      members: [
        {
          memberNum: 2,
          engagement: {
            priorThreads: 0,
            readRate: null,
            archivedUnreadRate: null,
            replyRate: null,
          },
        },
      ],
    });
    expect(block).toMatch(/no (prior |)history|new sender|first/i);
    expect(block).toContain("#2");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && pnpm vitest run src/state/importance/features.test.ts`
Expected: FAIL — "Cannot find module './features'".

- [ ] **Step 3: Write minimal implementation**

Create `workers/api/src/state/importance/features.ts`:

```typescript
import type { SenderEngagement } from "./engagement";

/**
 * Local-part patterns for machine senders (no-reply, notifications, bounces).
 * Used as one soft signal in the importance prompt — never a hard gate.
 */
const AUTOMATED_LOCALPART =
  /(^|[._+-])(no-?reply|do-?not-?reply|notifications?|mailer-?daemon|mailer|bounce|postmaster|donotreply)([._+-]|$)/i;

export function isAutomatedSenderEmail(email: string | null): boolean {
  if (!email) return false;
  const at = email.indexOf("@");
  const localPart = at >= 0 ? email.slice(0, at) : email;
  return AUTOMATED_LOCALPART.test(localPart);
}

export type ThreadFacetsLike = {
  format: string | null;
  automation: "human" | "automated" | null;
  reach: "direct" | "list" | null;
} | null;

export type MemberFeature = {
  memberNum: number;
  engagement: SenderEngagement;
};

function pct(rate: number | null): string | null {
  return rate === null ? null : `${Math.round(rate * 100)}%`;
}

/**
 * The deterministic feature block injected into the importance prompt. All
 * signals are advisory context the model weighs against the note content; the
 * model still picks the band (soft bias, no hard cap).
 */
export function formatImportanceFeatureBlock(args: {
  facets: ThreadFacetsLike;
  senderEmailAutomated: boolean;
  senderIsLinkedUser: boolean;
  members: MemberFeature[];
}): string {
  const lines: string[] = ["Signals (advisory — weigh against the content):"];

  if (args.facets) {
    const parts: string[] = [];
    if (args.facets.format) parts.push(`format=${args.facets.format}`);
    if (args.facets.automation) parts.push(`automation=${args.facets.automation}`);
    if (args.facets.reach) parts.push(`reach=${args.facets.reach}`);
    lines.push(`- Message facets: ${parts.length ? parts.join(", ") : "none"}`);
  } else {
    lines.push("- Message facets: none");
  }

  lines.push(
    `- Sender: ${args.senderEmailAutomated ? "automated/no-reply address" : "ordinary address"}; ${
      args.senderIsLinkedUser ? "a known person in the recipient's network" : "not a known person"
    }`,
  );

  for (const m of args.members) {
    const e = m.engagement;
    if (e.priorThreads === 0) {
      lines.push(`- Recipient #${m.memberNum}: new sender, no prior history`);
      continue;
    }
    const read = pct(e.readRate);
    if (read === null) {
      lines.push(
        `- Recipient #${m.memberNum}: only ${e.priorThreads} prior thread(s) from this sender (too few to judge engagement)`,
      );
      continue;
    }
    lines.push(
      `- Recipient #${m.memberNum}: reads ${read} of this sender's mail, replies ${pct(
        e.replyRate,
      )}, archives ${pct(e.archivedUnreadRate)} unread (${e.priorThreads} prior threads)`,
    );
  }

  return lines.join("\n");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd workers/api && pnpm vitest run src/state/importance/features.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/state/importance/features.ts workers/api/src/state/importance/features.test.ts
git commit -m "feat(importance): feature block fusing facets, sender, engagement"
```

---

### Task 4: Wire the importance module into `note-analysis.ts`

**Files:**
- Modify: `workers/api/src/queue/note-analysis.ts`
- Test: `workers/api/src/queue/note-analysis.test.ts`

**Interfaces:**
- Consumes: `bandToImportance`, `parseBand`, `fallbackBand`, `IMPORTANCE_RUBRIC`, `IMPORTANCE_JSON_EXAMPLE` from `../state/importance/band`; `getSenderEngagement`, `type SenderEngagement` from `../state/importance/engagement`; `isAutomatedSenderEmail`, `formatImportanceFeatureBlock`, `type ThreadFacetsLike` from `../state/importance/features`.
- Produces: unchanged external surface — `analyzeNote` / `applyThreadState` keep their signatures; `thread_state.importance` now derives from a band.

This task changes four things in `note-analysis.ts`:
1. `gatherContext` selects `facets` on the thread and `email` on the author, and fetches sender flags + per-member engagement into the context.
2. `classifyNote` injects the feature block + rubric and asks for an ordinal `importance`.
3. The classification type's `importance` becomes `ImportanceBand`; `parseClassification`/`parseClassificationOverride` parse the band (with the deterministic fallback) and map to a number via `bandToImportance`.
4. The default classification's importance is derived from `fallbackBand`, not a hardcoded 50.

- [ ] **Step 1: Write the failing tests** (append to `workers/api/src/queue/note-analysis.test.ts`)

Add this mock near the other `vi.mock` calls at the top of the file (after the `../rpc` mock):

```typescript
// The engagement aggregate needs a DB; mock it so classifyNote tests run without
// one. Each test sets the engagement it wants the prompt/scorer to see.
const senderEngagementMock = vi.fn(async () => ({
  priorThreads: 0,
  readRate: null as number | null,
  archivedUnreadRate: null as number | null,
  replyRate: null as number | null,
}));
vi.mock("../state/importance/engagement", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return { ...actual, getSenderEngagement: (...a: unknown[]) => senderEngagementMock(...(a as [])) };
});
```

Add a new `describe` block at the end of the file:

```typescript
import { bandToImportance } from "../state/importance/band";

// A minimal AI stub: returns whatever band/json we hand it.
function aiReturning(json: string) {
  return { run: vi.fn(async () => ({ response: json })) };
}

describe("classifyNote importance band → number", () => {
  beforeEach(() => {
    upsertCalls.length = 0;
    senderEngagementMock.mockClear();
  });

  it("maps an ordinal band to the mapped importance number", async () => {
    const env = { AI: aiReturning('{"state":{"default":{"active":false,"urgent":false,"importance":"elevated","skip":false},"overrides":{}}}') } as any;
    await applyThreadState(
      env,
      {} as any,
      "thread-1",
      "user-author",
      [{ id: "c-r", name: "R", userId: "user-r" }],
      {
        default: { active: false, urgent: false, importance: bandToImportance("elevated"), skip: false },
        overrides: {},
      },
      NOTE_SOURCE_CREATED_AT,
    );
    expect(upsertCalls[0].args.p_importance).toBe(bandToImportance("elevated"));
  });
});
```

> NOTE for the implementer: the assertion above pins the band→number contract through `applyThreadState`. The end-to-end "promotional → suppress" and "LLM failure → fallback low" behaviours are driven through `classifyNote`. Because `classifyNote` is not currently exported, **export it** in Step 3 and add these two tests, which assert the parsed+mapped result:

```typescript
import { classifyNote } from "./note-analysis";

const baseContext = {
  noteId: "n1",
  noteCreatedAt: NOTE_SOURCE_CREATED_AT,
  noteSourceCreatedAt: NOTE_SOURCE_CREATED_AT,
  noteContent: "Big sale this week!",
  noteAuthorId: "c-sender",
  noteAuthorName: "Acme",
  noteAuthorEmail: "no-reply@acme.com",
  senderIsLinkedUser: false,
  threadTitle: "Acme deals",
  facets: { format: "promotion", automation: "automated", reach: "list" },
  links: [],
  members: [{ id: "c-r", name: "R", userId: "user-r" }],
  memberIds: new Set(["c-r"]),
  existingTodos: [],
  clearedTodos: [],
  existingReplies: [],
  recentNotes: [],
} as any;

describe("classifyNote suppression", () => {
  it("maps a suppress band below the gate", async () => {
    const env = { AI: aiReturning('{"state":{"default":{"active":false,"urgent":false,"importance":"suppress","skip":false},"overrides":{}}}') } as any;
    const result = await classifyNote(env, baseContext);
    expect(result.state.default.importance).toBeLessThan(50);
  });

  it("falls back to a sub-gate band on unparseable AI output for automated list mail", async () => {
    const env = { AI: aiReturning("not json at all") } as any;
    const result = await classifyNote(env, baseContext);
    expect(result.state.default.importance).toBeLessThan(50);
  });

  it("falls back to normal (surfaces) for ordinary mail when AI output is unparseable", async () => {
    const env = { AI: aiReturning("not json at all") } as any;
    const result = await classifyNote(env, {
      ...baseContext,
      noteAuthorEmail: "jane@gmail.com",
      facets: { format: "message", automation: "human", reach: "direct" },
    });
    expect(result.state.default.importance).toBeGreaterThanOrEqual(50);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd workers/api && pnpm vitest run src/queue/note-analysis.test.ts`
Expected: FAIL — `classifyNote` not exported / `NoteContext` lacks `facets`/`noteAuthorEmail`/`senderIsLinkedUser` / importance is still a number not a band.

- [ ] **Step 3: Implement the wiring**

In `workers/api/src/queue/note-analysis.ts`:

**(a) Add imports at the top (after the existing imports):**

```typescript
import {
  bandToImportance,
  fallbackBand,
  type FallbackSignals,
  IMPORTANCE_JSON_EXAMPLE,
  IMPORTANCE_RUBRIC,
  parseBand,
} from "../state/importance/band";
import {
  getSenderEngagement,
  type SenderEngagement,
} from "../state/importance/engagement";
import {
  formatImportanceFeatureBlock,
  isAutomatedSenderEmail,
  type MemberFeature,
  type ThreadFacetsLike,
} from "../state/importance/features";
```

**(b) Extend `NoteContext`** — add these fields to the interface:

```typescript
  noteAuthorEmail: string | null;
  senderIsLinkedUser: boolean;
  facets: ThreadFacetsLike;
  memberEngagement: Map<string, SenderEngagement>; // keyed by member.id
```

**(c) In `gatherContext`:** add `facets` to the thread select — change

```typescript
    db
      .selectFrom("thread")
      .select(["title", "contacts", "groups"])
      .where("id", "=", threadId)
      .executeTakeFirst(),
```

to

```typescript
    db
      .selectFrom("thread")
      .select(["title", "contacts", "groups", "facets"])
      .where("id", "=", threadId)
      .executeTakeFirst(),
```

Change the author query to also select email — change

```typescript
      db
        .selectFrom("contact")
        .select("name")
        .where("id", "=", note.author_id)
        .executeTakeFirst(),
```

to

```typescript
      db
        .selectFrom("contact")
        .select(["name", "email"])
        .where("id", "=", note.author_id)
        .executeTakeFirst(),
```

After `const memberIds = new Set(...)` (before building `memberNameMap`), add the sender-linked check and per-member engagement:

```typescript
  // Is the sender a real, linked person in the system (vs a synthetic source)?
  const senderLinked = await db
    .selectFrom("user_contact")
    .select("contact_id")
    .where("contact_id", "=", note.author_id)
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .executeTakeFirst();
  const senderIsLinkedUser = !!senderLinked;

  // How each recipient has historically treated this sender. Best-effort;
  // getSenderEngagement degrades to zero-history on failure. One cache for the
  // call dedupes repeated (recipient, sender) lookups.
  const engagementCache = new Map<string, Promise<SenderEngagement>>();
  const memberEngagement = new Map<string, SenderEngagement>();
  await Promise.all(
    members
      .filter((m) => m.userId && m.userId !== note.author_id)
      .map(async (m) => {
        const eng = await getSenderEngagement(
          db,
          m.userId as string,
          note.author_id as string,
          threadId,
          env,
          engagementCache,
        );
        memberEngagement.set(m.id, eng);
      }),
  );
```

> `gatherContext` does not currently receive `env`. Add `env: Bindings` as its first parameter and pass it from `analyzeNote` (`gatherContext(env, db, noteId, threadId)`).

Add the new fields to the returned context object:

```typescript
    noteAuthorEmail: author?.email ?? null,
    senderIsLinkedUser,
    facets: (thread.facets as ThreadFacetsLike) ?? null,
    memberEngagement,
```

**(d) Change the classification type** — `ThreadStateClassification.importance` carries a number for the rest of the pipeline, but the LLM now emits a band. Keep the stored type as `number` (so `applyThreadState` is unchanged) and translate at parse time. Update the system prompt's importance section: replace the entire `importance (0-100): …` block and the JSON example line with:

```typescript
${IMPORTANCE_RUBRIC}

Respond with JSON only. No explanation.

Output schema:
{"state": {"default": {"active": false, "urgent": false, "importance": "normal", "skip": false}, "overrides": {"1": {"active": true, "urgent": false, "importance": "elevated"}}}}
```

(the `IMPORTANCE_JSON_EXAMPLE` constant documents the per-field shape; the schema line above shows it in context.)

**(e) Inject the feature block into the user message.** Build it before `const messages = [...]`:

```typescript
  const importanceFeatures = formatImportanceFeatureBlock({
    facets: context.facets,
    senderEmailAutomated: isAutomatedSenderEmail(context.noteAuthorEmail),
    senderIsLinkedUser: context.senderIsLinkedUser,
    members: context.members
      .map((m): MemberFeature | null => {
        const num = memberIdToNum.get(m.id);
        const engagement = context.memberEngagement.get(m.id);
        return num && engagement ? { memberNum: num, engagement } : null;
      })
      .filter((x): x is MemberFeature => x !== null),
  });
```

and add it to the user `content` (after `Recent notes:` / before the new-note line):

```typescript
${importanceFeatures}

New note by ${context.noteAuthorName ?? "Unknown"}${authorNum ? ` (member #${authorNum})` : ""}: ${context.noteContent.slice(0, 1000)}`,
```

**(f) Parse the band and map to a number.** Add a fallback-signals helper and use it in both the default and override parsers. Because the parsers are currently pure (no context), thread the fallback signals in. Change `classifyNote` to compute fallback signals once:

```typescript
  const fallback: FallbackSignals = {
    facetAutomation: context.facets?.automation ?? null,
    facetReach: context.facets?.reach ?? null,
    facetFormat: context.facets?.format ?? null,
    senderEmailAutomated: isAutomatedSenderEmail(context.noteAuthorEmail),
    // "known" at the thread level = any recipient has prior history. Used only
    // when the model failed; a conservative OR keeps a sender that ANY recipient
    // engages with out of the suppressed bucket.
    senderKnown: [...context.memberEngagement.values()].some((e) => e.priorThreads > 0),
  };
  const defaultBand = fallbackBand(fallback);
```

Update `defaultClassification` to use it:

```typescript
  const defaultClassification: ThreadStateClassification = {
    active: false,
    urgent: false,
    importance: bandToImportance(defaultBand),
    skip: false,
  };
```

Change `parseClassification` and `parseClassificationOverride` to translate the band. Replace the importance handling in `parseClassification`:

```typescript
    importance: ((): number => {
      const band = parseBand(raw.importance);
      return band ? bandToImportance(band) : fallback.importance;
    })(),
```

(where `fallback` is the already-mapped numeric default passed in — pass `defaultClassification` as the fallback as today). For `parseClassificationOverride`, replace the importance branch:

```typescript
  const band = parseBand(raw.importance);
  if (band) result.importance = bandToImportance(band);
```

**(g) Export `classifyNote`** (add `export` to its declaration) so the tests can call it.

> The `noteAuthorEmail`, `senderIsLinkedUser`, `facets`, and `memberEngagement` fields must be present on the `NoteContext` the tests construct — they are now required interface fields.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd workers/api && pnpm vitest run src/queue/note-analysis.test.ts`
Expected: PASS — the 3 original `applyThreadState` tests, the opt-out test, and the new band/suppression tests all green.

- [ ] **Step 5: Typecheck the worker**

Run: `cd workers/api && pnpm exec tsc --noEmit`
Expected: no errors. (Fix any type mismatches surfaced by the new fields.)

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/queue/note-analysis.ts workers/api/src/queue/note-analysis.test.ts
git commit -m "feat(importance): score from ordinal band + facets + engagement in note-analysis"
```

---

### Task 5: Docs + finalize (lint, full test pass)

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing updates bullet**

Open `docs/updates.md`. Under the top `## Next release` heading, add (to an existing `### Fixes` section if present, else create `### Notifications` above `### Fixes`):

```markdown
- Plot is better at telling promotional and automated mail apart from messages that actually matter, so you get fewer pointless notifications while real conversations still come through.
```

- [ ] **Step 2: Lint the API worker**

Run: `cd workers/api && pnpm lint`
Expected: no errors in changed files. Fix any lint issues.

- [ ] **Step 3: Run the full importance + note-analysis suite**

Run: `cd workers/api && pnpm vitest run src/state/importance src/queue/note-analysis.test.ts`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit -m "docs(importance): updates.md note on sharper notification relevance"
```

---

## Optional follow-up (not required for this plan)

- **DB-backed engagement integration test.** Set up the worktree DB (`bash scripts/worktree-db`), seed a recipient with known read/archive/reply history for a sender, and assert `getSenderEngagement` returns the expected rates against real Postgres. Validates the raw SQL (joins, the `user.user_contact_ids` reply check, the 120-day window) that the unit tests stub. Out of scope here because this task introduces no schema and the existing API test suite mocks the DB.

## Self-Review

**Spec coverage:**
- A (ordinal reframe) → Task 1 (`band.ts`) + Task 4 (prompt + parse/map). ✓
- B (deterministic cold-sender context) → facets read in Task 4(c), `isAutomatedSenderEmail` Task 3, fed to prompt + fallback. ✓
- C (engagement history) → Task 2 (`engagement.ts`) + Task 4 gather + feature block Task 3. ✓
- Soft bias / no hard cap → bands come from the LLM; deterministic signals only feed the prompt and the failure-path `fallbackBand`. ✓
- Deterministic fallback → Task 1 `fallbackBand`, Task 4(f) default + parse fallback. ✓
- Batch-cached engagement → `engagementCache` Map in Task 4(c), `cache` param in Task 2. ✓
- Error handling → Task 2 try/catch + `captureException`; facets-null tolerated in Task 3. ✓
- No schema / no public change → only `workers/api/src/**` + `docs/updates.md` touched. ✓
- Success criteria (re-run prod distribution) → operational, post-deploy; noted in spec. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `ImportanceBand`, `SenderEngagement`, `ThreadFacetsLike`, `MemberFeature`, `FallbackSignals`, `EngagementCounts` used consistently across tasks; `getSenderEngagement` signature matches its call site in Task 4(c) (`db, userId, senderId, threadId, env, cache`). ✓
