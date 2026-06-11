# Classifier Signal Port + Classification Decision Log — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the facet gate + connection-origin signals into the TS hybrid classifier's scoring stage, and add an append-only `classification_decision` table that records every applied filing decision and explicit user move.

**Architecture:** Part A extends `libs/classifier`'s scoring stage with two signals whose semantics stay single-sourced in SQL (`thread_facets_gated()`, `connection_org_key()` called via `ctx.rawQuery`). Part B adds a no-FK, non-synced log table written from four apply sites: the API worker choke point (`classifyThreadForUser`), the classify queue consumer, the three SQL trigger paths, and the `/sync/priority-moves` endpoint. Spec: `docs/superpowers/specs/2026-06-10-classifier-signal-port-decision-log-design.md`.

**Tech Stack:** TypeScript (Cloudflare Workers, Kysely, vitest), PostgreSQL (Atlas migrations, pgTAP), pnpm monorepo.

---

## Environment setup (once, before Task 1)

This plan includes a DB schema change, so the worktree needs its own Postgres:

```bash
bash scripts/worktree-db
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"   # MUST print the worktree port, never 54322
```

If working in the main checkout instead, `$DATABASE_URL` (port 54322) is correct as-is — but still run the sanity check. **Never run migrations against a port you haven't verified.**

All `pnpm --filter @plotday/eval test` runs need `DATABASE_URL` exported (tests are `describe.runIf(!!process.env.DATABASE_URL)`).

---

### Task 1: Baseline eval capture

Snapshot current classifier behavior on both corpora so Part A can prove it changed nothing (the new signals must be inert without corpus support).

**Files:** none (writes `/tmp` artifacts only)

- [ ] **Step 1: Verify the eval suite passes today**

Run: `DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval test`
Expected: all test files pass (corpus, sql-current, ts-hybrid-*, llm-cache). If something fails here, STOP — the baseline is broken and Part A cannot be verified; report it.

- [ ] **Step 2: Capture the kris-corpus baseline**

The CLI exits 1 when there are regressions vs `expected` labels (pre-existing; not our concern), hence `|| true`:

```bash
DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval eval -- \
  --corpus kris --classifiers ts:hybrid:default --format json > /tmp/eval-baseline-kris.json || true
DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval eval -- \
  --corpus synthetic-tiny --classifiers ts:hybrid:default --format json > /tmp/eval-baseline-tiny.json || true
jq '.summary.perClassifierTraining' /tmp/eval-baseline-kris.json
```

Expected: JSON files written; the summary shows accuracy numbers per training set. We use `ts:hybrid:default` (not the LLM variant) so the check is deterministic and needs no Gemini key — it exercises the same scoring stage Part A modifies.

---

### Task 2: Candidate type + `originBonus` param + plumbing (no behavior change)

Add the three new `Candidate` fields and the `originBonus` param, and update every construction site so the whole repo type-checks. No scoring logic changes yet.

**Files:**
- Modify: `libs/classifier/src/types.ts`
- Modify: `libs/classifier/src/ts-hybrid.defaults.ts`
- Modify: `workers/api/src/state/classify-thread.ts`
- Modify: `workers/classify/src/handler.ts`
- Modify: `libs/eval/src/runner/run.ts`

- [ ] **Step 1: Extend `Candidate` in `libs/classifier/src/types.ts`**

Add to the `Candidate` interface (after `author`):

```ts
  /** thread.facets (format/automation/reach). Null ⇒ facet gate fails open. */
  facets: Record<string, string> | null;
  /**
   * Author contact id (thread.author_id) — the contact-level identity the
   * facet gate's trusted-sender exception checks against thread.contacts.
   * Distinct from `author` (thread.created_by: a user or twist_instance id).
   */
  authorContactId: string | null;
  /**
   * Originating connection (twist_instance id): thread.created_by when
   * thread.twist_id is set, else null. Drives the origin signal; null
   * disables it for this candidate.
   */
  connectionId: string | null;
```

- [ ] **Step 2: Add `OriginBonus` + `originBonus` to `libs/classifier/src/ts-hybrid.defaults.ts`**

Below the `AggregationMode` type, add:

```ts
export type OriginBonus = { exact: number; org: number };
```

In `HybridParams`, after `negativePenaltyWeight: number;`, add:

```ts
  /**
   * Per-neighbor additive bonus when a user_moved example came from the
   * SAME connection as the candidate (exact) or a connection sharing its
   * org key (org) — mirrors the SQL scorer's 0.18/0.09 origin term. Added
   * to the per-neighbor combined score BEFORE aggregation, outside the
   * normalized SignalWeights. NOTE: topk_mean divides by k, so the
   * post-aggregation effect is ~1/k of the SQL constants — these defaults
   * are a starting point, tunable once the eval corpus models
   * connections. Set both to 0 to disable.
   */
  originBonus: OriginBonus;
```

In `DEFAULTS`, after the `negativePenaltyWeight: 0.3,` entry, add:

```ts
  originBonus: { exact: 0.18, org: 0.09 },
```

(`DEFAULTS_LLM` spreads `DEFAULTS`, so it inherits this.)

- [ ] **Step 3: Plumb through `workers/api/src/state/classify-thread.ts`**

Extend `ClassifyArgs`:

```ts
export type ClassifyArgs = {
  userId: string;
  threadId?: string;
  embedding?: string | null;
  topic?: string | null;
  contacts?: string[] | null;
  groups?: string[] | null;
  /** Pre-insert callers: thread.facets when known. */
  facets?: Record<string, string> | null;
  /** Pre-insert callers: originating twist_instance id when known. */
  connectionId?: string | null;
};
```

In `buildCandidate`, initialize the new fields and hydrate them from the thread row. The locals block becomes:

```ts
  let title = "";
  let topic = args.topic ?? null;
  let contacts = args.contacts ?? [];
  let groups = args.groups ?? [];
  let embedding = parseEmbedding(args.embedding ?? null);
  let author: string | null = null;
  let facets: Record<string, string> | null = args.facets ?? null;
  let authorContactId: string | null = null;
  let connectionId: string | null = args.connectionId ?? null;
```

The hydration query gains three columns (note: pg returns `bigint` as string — only nullness matters):

```ts
    const res = await sql<{
      title: string | null;
      topic: string | null;
      contacts: string[] | null;
      groups: string[] | null;
      embedding: string | null;
      created_by: string | null;
      facets: Record<string, string> | null;
      author_id: string | null;
      twist_id: string | null;
    }>`SELECT t.title, t.topic, t.contacts, t.groups,
              CASE WHEN t.embedding IS NULL THEN NULL ELSE t.embedding::text END AS embedding,
              t.created_by, t.facets, t.author_id, t.twist_id
         FROM public.thread t
        WHERE t.id = ${args.threadId}::uuid`.execute(db);
    const r = res.rows[0];
    if (r) {
      title = r.title ?? "";
      topic = topic ?? r.topic;
      contacts = (args.contacts ?? r.contacts ?? []) as string[];
      groups = (args.groups ?? r.groups ?? []) as string[];
      embedding = embedding ?? parseEmbedding(r.embedding);
      author = r.created_by;
      facets = facets ?? r.facets ?? null;
      authorContactId = r.author_id;
      connectionId = connectionId ?? (r.twist_id != null ? r.created_by : null);
    }
```

And the returned object gains `facets, authorContactId, connectionId`.

- [ ] **Step 4: Plumb through `workers/classify/src/handler.ts`**

Candidate initialization gains the three nulls:

```ts
  const candidate: Candidate = {
    threadId: job.threadId,
    title: "",
    topic: null,
    contacts: [],
    groups: [],
    embedding: null,
    author: null,
    facets: null,
    authorContactId: null,
    connectionId: null,
  };
```

The hydration query type/text gains the same three columns as Step 3 (`t.facets, t.author_id, t.twist_id`), and the hydration block gains:

```ts
    candidate.facets = r.facets ?? null;
    candidate.authorContactId = r.author_id;
    candidate.connectionId = r.twist_id != null ? r.created_by : null;
```

- [ ] **Step 5: Plumb through `libs/eval/src/runner/run.ts`**

In `runOneCase`, the object passed to `classifier.classify(ctx, {...})` gains:

```ts
      // Corpus schema v1 does not model facets, author contacts, or
      // connections — both new signals are inert in eval until the corpus
      // v2 workstream adds them.
      facets: null,
      authorContactId: null,
      connectionId: null,
```

- [ ] **Step 6: Type-check everything that consumes `Candidate`**

```bash
pnpm --filter @plotday/classifier lint
pnpm --filter @plotday/eval lint
pnpm --filter @plotday/api lint
pnpm --filter @plotday/classify lint
```

Expected: all pass. If tsc flags other `Candidate` object literals (e.g. in `libs/eval/tests/*.test.ts`), add the same three `null` fields there.

- [ ] **Step 7: Run the existing classifier tests**

Run: `DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval test && pnpm --filter @plotday/classify test`
Expected: PASS (behavior unchanged — new fields are dead until Task 3).

- [ ] **Step 8: Commit**

```bash
git add libs/classifier/src/types.ts libs/classifier/src/ts-hybrid.defaults.ts \
  workers/api/src/state/classify-thread.ts workers/classify/src/handler.ts libs/eval/src/runner/run.ts
git commit -m "feat(classifier): add facets/authorContactId/connectionId to Candidate + originBonus param

Plumbing only — no scoring behavior change yet.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Include any test files touched in Step 6.)

---

### Task 3: Origin signal in the TS scoring stage

**Files:**
- Modify: `libs/classifier/src/ts-hybrid-signals.ts`
- Modify: `libs/classifier/src/ts-hybrid-scoring.ts`
- Modify: `libs/classifier/src/index.ts`
- Test: `libs/eval/tests/ts-hybrid-origin-facets.test.ts` (new)

- [ ] **Step 1: Write the failing tests**

Create `libs/eval/tests/ts-hybrid-origin-facets.test.ts`. These tests use a fake `ClassifierContext` that answers `rawQuery` by SQL substring (same idea as `workers/classify/src/handler.test.ts`), so they need no database and run unconditionally.

```ts
import { describe, expect, it } from "vitest";

import {
  DEFAULTS,
  originBonus,
  scoringStage,
  type Candidate,
  type ClassifierContext,
  type HybridParams,
} from "@plotday/classifier";

const USER = "user-1";
const P1 = "priority-1";
const P2 = "priority-2";
const CONN_A = "conn-a";
const CONN_B = "conn-b";

// top1 aggregation + all post-aggregation bonuses off so origin/gate effects
// are directly observable; only three queries remain reachable: neighbors,
// connection_org_key, thread_facets_gated.
const PARAMS: HybridParams = {
  ...DEFAULTS,
  aggregation: { mode: "top1" },
  priorityTitleMatchWeight: 0,
  accountHierarchyBonusWeight: 0,
  negativePenaltyWeight: 0,
};

type Route = { match: string; rows: (values: unknown[]) => unknown[] };

function fakeCtx(routes: Route[], queries: string[] = []): ClassifierContext {
  return {
    db: undefined as never,
    rawQuery: async (text: string, values?: unknown[]) => {
      queries.push(text);
      const route = routes.find((r) => text.includes(r.match));
      if (!route) throw new Error(`fakeCtx: unmatched query: ${text.slice(0, 100)}`);
      return { rows: route.rows(values ?? []) };
    },
    userId: USER,
    schemaName: "public",
    corpusName: "test",
  };
}

function neighbor(priorityId: string, threadId: string, connId: string | null) {
  return {
    priority_id: priorityId,
    thread_id: threadId,
    title: null,
    topic: null,
    created_by: connId,
    contacts_expanded: [],
    groups: [],
    embedding: null,
    conn_id: connId,
  };
}

const orgKeys = (map: Record<string, string | null>): Route => ({
  match: "connection_org_key",
  rows: (v) => (v[0] as string[]).map((id) => ({ conn_id: id, org_key: map[id] ?? null })),
});

const gate = (gatedIds: string[]): Route => ({
  match: "thread_facets_gated",
  rows: (v) => (v[3] as string[]).map((pid) => ({ pid, gated: gatedIds.includes(pid) })),
});

const CANDIDATE: Candidate = {
  threadId: "t-cand",
  title: "Receipt",
  topic: null,
  contacts: [],
  groups: [],
  embedding: null,
  author: null,
  facets: null,
  authorContactId: null,
  connectionId: null,
};

describe("originBonus (pure)", () => {
  const BONUS = { exact: 0.18, org: 0.09 };
  it("exact connection match wins", () => {
    expect(originBonus(CONN_A, "domain:acme.com", CONN_A, "domain:acme.com", BONUS)).toBe(0.18);
  });
  it("org-key match scores org", () => {
    expect(originBonus(CONN_B, "domain:acme.com", CONN_A, "domain:acme.com", BONUS)).toBe(0.09);
  });
  it("no candidate connection ⇒ 0", () => {
    expect(originBonus(CONN_A, "domain:acme.com", null, null, BONUS)).toBe(0);
  });
  it("null org keys never match each other", () => {
    expect(originBonus(CONN_B, null, CONN_A, null, BONUS)).toBe(0);
  });
});

describe("scoringStage origin wiring", () => {
  it("same-connection neighbor wins on origin alone", async () => {
    const ctx = fakeCtx([
      { match: "user_moved = TRUE", rows: () => [neighbor(P1, "t1", CONN_A)] },
      orgKeys({}),
      gate([]),
    ]);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(true);
    if (out.matched) expect(out.priorityId).toBe(P1);
    expect(out.explain.topNeighbors[0]!.origin).toBe(0.18);
  });

  it("org-key match contributes the org bonus", async () => {
    const ctx = fakeCtx([
      { match: "user_moved = TRUE", rows: () => [neighbor(P1, "t1", CONN_B)] },
      orgKeys({ [CONN_A]: "domain:acme.com", [CONN_B]: "domain:acme.com" }),
      gate([]),
    ]);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(true); // 0.09 >= scoreThreshold 0.08
    expect(out.explain.topNeighbors[0]!.origin).toBe(0.09);
  });

  it("no candidate connection ⇒ org-key query never issued, origin 0", async () => {
    const queries: string[] = [];
    const ctx = fakeCtx(
      [{ match: "user_moved = TRUE", rows: () => [neighbor(P1, "t1", CONN_A)] }, gate([])],
      queries
    );
    const out = await scoringStage(ctx, CANDIDATE, PARAMS);
    expect(out.matched).toBe(false);
    expect(queries.some((q) => q.includes("connection_org_key"))).toBe(false);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @plotday/eval exec vitest run tests/ts-hybrid-origin-facets.test.ts`
Expected: FAIL — `originBonus`/`scoringStage` not exported, `originBonus` not defined, `conn_id`/`origin` fields unknown.

- [ ] **Step 3: Implement the pure helper in `libs/classifier/src/ts-hybrid-signals.ts`**

Change the import at the top to include `OriginBonus`:

```ts
import type { Nonlinearity, OriginBonus, SignalWeights } from "./ts-hybrid.defaults";
```

Add at the end of the file:

```ts
/**
 * Connection-origin bonus for one neighbor (mirrors the SQL scorer's origin
 * CASE in classify_thread_for_user): exact when the neighbor came from the
 * SAME connection as the candidate, org when both connections share an org
 * key (connection_org_key), else 0.
 */
export function originBonus(
  neighborConnId: string | null,
  neighborOrgKey: string | null,
  candidateConnId: string | null,
  candidateOrgKey: string | null,
  bonus: OriginBonus
): number {
  if (candidateConnId === null) return 0;
  if (neighborConnId !== null && neighborConnId === candidateConnId) return bonus.exact;
  if (
    candidateOrgKey !== null &&
    neighborOrgKey !== null &&
    neighborOrgKey === candidateOrgKey
  ) {
    return bonus.org;
  }
  return 0;
}
```

- [ ] **Step 4: Wire origin into `libs/classifier/src/ts-hybrid-scoring.ts`**

Import the helper (extend the existing `./ts-hybrid-signals` import list with `originBonus`).

Add `conn_id` to the neighbor query — the SELECT becomes:

```ts
    `SELECT tp.priority_id,
            tp.thread_id,
            mt.title,
            mt.topic,
            mt.created_by,
            CASE WHEN mt.twist_id IS NOT NULL THEN mt.created_by ELSE NULL END AS conn_id,
            public.expand_contacts(mt.contacts) AS contacts_expanded,
            mt.groups,
            CASE WHEN mt.embedding IS NULL THEN NULL ELSE mt.embedding::text END AS embedding
       FROM public.thread_priority tp
       JOIN public.thread mt ON mt.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND mt.archived_at IS NULL`,
```

Add `conn_id: string | null;` to `NeighborRow` and to the raw-row type in the `.map()`, mapping it through (`conn_id: r.conn_id`).

After `expandedCandidateContacts` is computed, resolve org keys (mirrors the SQL `conn_key` CTE):

```ts
  // Connection-origin: resolve org keys for the candidate's connection and
  // every distinct neighbor connection in one round trip. Skipped when the
  // candidate has no originating connection — origin is then 0 everywhere.
  const orgKeyByConn = new Map<string, string | null>();
  let candidateOrgKey: string | null = null;
  const originEnabled =
    (params.originBonus.exact > 0 || params.originBonus.org > 0) &&
    candidate.connectionId !== null;
  if (originEnabled) {
    const connIds = new Set<string>([candidate.connectionId!]);
    for (const n of rows) if (n.conn_id) connIds.add(n.conn_id);
    const orgRes = await ctx.rawQuery(
      `SELECT conn_id, public.connection_org_key(conn_id) AS org_key
         FROM unnest($1::uuid[]) AS conn_id`,
      [[...connIds]]
    );
    for (const r of orgRes.rows as { conn_id: string; org_key: string | null }[]) {
      orgKeyByConn.set(r.conn_id, r.org_key);
    }
    candidateOrgKey = orgKeyByConn.get(candidate.connectionId!) ?? null;
  }
```

In the per-neighbor loop, compute origin and add it to `combined` (the same position the SQL scorer adds it):

```ts
    const origin = originEnabled
      ? originBonus(
          n.conn_id,
          n.conn_id ? (orgKeyByConn.get(n.conn_id) ?? null) : null,
          candidate.connectionId,
          candidateOrgKey,
          params.originBonus
        )
      : 0;
    const combined =
      combineSignals(values, params.weights, params.nonlinearity) + origin;
```

Add `origin: round(origin),` to the `debugTop.push({...})` entry, and `origin: number;` to `ScoringExplain.topNeighbors`'s element type.

- [ ] **Step 5: Export from `libs/classifier/src/index.ts`**

Add (alongside the existing exports; check what's already there and only add the missing ones):

```ts
export { originBonus } from "./ts-hybrid-signals";
export { scoringStage } from "./ts-hybrid-scoring";
export type { OriginBonus } from "./ts-hybrid.defaults";
```

- [ ] **Step 6: Run the new tests**

Run: `pnpm --filter @plotday/eval exec vitest run tests/ts-hybrid-origin-facets.test.ts`
Expected: `originBonus (pure)` and `scoringStage origin wiring` PASS. The `gate(...)` routes in these tests are never queried yet (`fakeCtx` routes are consulted on demand) — they become live in Task 4.

- [ ] **Step 7: Run the full classifier-related suites**

Run: `DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval test && pnpm --filter @plotday/classifier lint`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add libs/classifier/src libs/eval/tests/ts-hybrid-origin-facets.test.ts
git commit -m "feat(classifier): connection-origin bonus in TS scoring stage

Mirrors the SQL scorer's origin term (exact 0.18 / org 0.09) per neighbor
before aggregation, resolved via connection_org_key().

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Facet gate in the TS scoring stage

**Files:**
- Modify: `libs/classifier/src/ts-hybrid-scoring.ts`
- Test: `libs/eval/tests/ts-hybrid-origin-facets.test.ts` (extend)

- [ ] **Step 1: Write the failing tests** — append to the test file:

```ts
describe("scoringStage facet gate wiring", () => {
  const twoNeighbors: Route = {
    match: "user_moved = TRUE",
    rows: () => [neighbor(P1, "t1", CONN_A), neighbor(P2, "t2", CONN_B)],
  };
  const bothOrgs = orgKeys({
    [CONN_A]: "domain:acme.com",
    [CONN_B]: "domain:acme.com",
  });

  it("gated top priority falls through to the next candidate", async () => {
    // P1 scores 0.18 (exact), P2 scores 0.09 (org). Gate drops P1 ⇒ P2 wins.
    const ctx = fakeCtx([twoNeighbors, bothOrgs, gate([P1])]);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(true);
    if (out.matched) expect(out.priorityId).toBe(P2);
    expect(out.explain.facetGated).toEqual([P1]);
  });

  it("fully gated ranking ⇒ no match", async () => {
    const ctx = fakeCtx([twoNeighbors, bothOrgs, gate([P1, P2])]);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(false);
    expect(out.explain.facetGated).toEqual(expect.arrayContaining([P1, P2]));
  });

  it("gate query runs even with null candidate facets (trustedSendersOnly gates regardless)", async () => {
    const queries: string[] = [];
    const ctx = fakeCtx([twoNeighbors, bothOrgs, gate([])], queries);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(true);
    expect(queries.some((q) => q.includes("thread_facets_gated"))).toBe(true);
  });

  it("empty ranking skips the gate query", async () => {
    const queries: string[] = [];
    const ctx = fakeCtx(
      [{ match: "user_moved = TRUE", rows: () => [] }],
      queries
    );
    const out = await scoringStage(ctx, CANDIDATE, PARAMS);
    expect(out.matched).toBe(false);
    expect(queries.some((q) => q.includes("thread_facets_gated"))).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @plotday/eval exec vitest run tests/ts-hybrid-origin-facets.test.ts`
Expected: the new describe FAILS (`facetGated` undefined, P1 wins despite gate route).

- [ ] **Step 3: Implement the gate in `ts-hybrid-scoring.ts`**

Change `const merged` to `let merged`. Add `facetGated?: string[];` to `ScoringExplain`. Immediately after `merged.sort((a, b) => b.score - a.score);` insert:

```ts
  // Facet gate (mirrors classify_thread_for_user's scoring-stage gate):
  // drop ranked priorities whose facet_filters this candidate violates,
  // unless the author is trusted for that focus. Only the scoring stage is
  // gated — structural stages and cold-start are not; the LLM tie-breaker
  // inherits the gate because it draws candidates from this ranking.
  // Always evaluated when a ranking exists: trustedSendersOnly gates
  // regardless of candidate facets, and thread_facets_gated returns
  // immediately for priorities with null facet_filters.
  let facetGated: string[] = [];
  if (merged.length > 0) {
    const gateRes = await ctx.rawQuery(
      `SELECT pid, public.thread_facets_gated($1::uuid, $2::jsonb, $3::uuid, pid) AS gated
         FROM unnest($4::uuid[]) AS pid`,
      [
        ctx.userId,
        candidate.facets === null ? null : JSON.stringify(candidate.facets),
        candidate.authorContactId,
        merged.map((m) => m.priorityId),
      ]
    );
    const gatedSet = new Set(
      (gateRes.rows as { pid: string; gated: boolean }[])
        .filter((r) => r.gated)
        .map((r) => r.pid)
    );
    if (gatedSet.size > 0) {
      facetGated = merged
        .filter((m) => gatedSet.has(m.priorityId))
        .map((m) => m.priorityId);
      merged = merged.filter((m) => !gatedSet.has(m.priorityId));
    }
  }
```

In the `explain` construction add:

```ts
    facetGated: facetGated.length > 0 ? facetGated : undefined,
```

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @plotday/eval exec vitest run tests/ts-hybrid-origin-facets.test.ts`
Expected: ALL PASS (origin + gate describes).

- [ ] **Step 5: Run the full eval suite** (the synthetic-tiny corpus now exercises the gate query against the real DB — `thread_facets_gated` already exists there from the facet migrations):

Run: `DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add libs/classifier/src/ts-hybrid-scoring.ts libs/eval/tests/ts-hybrid-origin-facets.test.ts
git commit -m "feat(classifier): facet gate in TS scoring stage

Batched thread_facets_gated() over the ranked priorities, dropped before
threshold checks; scoring-stage-only, matching the SQL scorer's semantics.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Prove Part A is inert on existing corpora

**Files:** none

- [ ] **Step 1: Re-run the eval captures from Task 1**

```bash
DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval eval -- \
  --corpus kris --classifiers ts:hybrid:default --format json > /tmp/eval-after-kris.json || true
DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval eval -- \
  --corpus synthetic-tiny --classifiers ts:hybrid:default --format json > /tmp/eval-after-tiny.json || true
```

- [ ] **Step 2: Diff predictions and stages — MUST be empty**

```bash
for c in kris tiny; do
  diff <(jq -S '.results | map({caseId, trainingSet, predicted, stage})' /tmp/eval-baseline-$c.json) \
       <(jq -S '.results | map({caseId, trainingSet, predicted, stage})' /tmp/eval-after-$c.json) \
    && echo "$c: identical"
done
```

Expected: `kris: identical` and `tiny: identical`. The corpora model no connections and no facet_filters, so both new signals must be no-ops. **Any diff is a fail-open bug — stop and fix before continuing.**

---

### Task 6: `paramsHash` + versioned production classifier name

**Files:**
- Create: `libs/classifier/src/params-hash.ts`
- Modify: `libs/classifier/src/index.ts`
- Modify: `libs/classifier-runtime/src/factory.ts`
- Test: `libs/eval/tests/params-hash.test.ts` (new)

- [ ] **Step 1: Write the failing test** — create `libs/eval/tests/params-hash.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { DEFAULTS, DEFAULTS_LLM, paramsHash } from "@plotday/classifier";

describe("paramsHash", () => {
  it("is a stable 8-hex-char digest", () => {
    expect(paramsHash(DEFAULTS_LLM)).toMatch(/^[0-9a-f]{8}$/);
    expect(paramsHash(DEFAULTS_LLM)).toBe(paramsHash(DEFAULTS_LLM));
  });

  it("changes when any parameter changes", () => {
    expect(paramsHash({ ...DEFAULTS, scoreThreshold: 0.09 })).not.toBe(paramsHash(DEFAULTS));
    expect(paramsHash(DEFAULTS_LLM)).not.toBe(paramsHash(DEFAULTS));
  });

  it("is key-order independent", () => {
    const reordered = JSON.parse(JSON.stringify(DEFAULTS)) as typeof DEFAULTS;
    expect(paramsHash(reordered)).toBe(paramsHash(DEFAULTS));
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @plotday/eval exec vitest run tests/params-hash.test.ts`
Expected: FAIL — `paramsHash` is not exported.

- [ ] **Step 3: Implement** — create `libs/classifier/src/params-hash.ts`:

```ts
import type { HybridParams } from "./ts-hybrid.defaults";

/**
 * Stable short hash of the resolved classifier parameters (weights, floors,
 * prompt ids, model). Stamped into the production classifier's name so every
 * classification_decision row attributes the decision to an exact
 * configuration. NOT cryptographic — FNV-1a over a key-sorted JSON
 * rendering; collisions are irrelevant for version discrimination.
 */
export function paramsHash(params: HybridParams): string {
  const s = stableStringify(params);
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  return `{${keys
    .map((k) => `${JSON.stringify(k)}:${stableStringify(record[k])}`)
    .join(",")}}`;
}
```

Add to `libs/classifier/src/index.ts`:

```ts
export { paramsHash } from "./params-hash";
```

- [ ] **Step 4: Stamp the production classifier name** — in `libs/classifier-runtime/src/factory.ts`, add `paramsHash` to the `@plotday/classifier` import, and change the construction to:

```ts
  const classifier = makeHybridLlmClassifier(
    `ts:hybrid-llm:production@${paramsHash(DEFAULTS_LLM)}`,
    {
      params: DEFAULTS_LLM,
      llmClientFor,
      consumeBudget: kvBudget(env.LLM_CACHE),
    }
  );
```

- [ ] **Step 5: Run tests + lints**

Run: `pnpm --filter @plotday/eval exec vitest run tests/params-hash.test.ts && pnpm --filter @plotday/classifier lint && pnpm --filter @plotday/classifier-runtime lint`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add libs/classifier/src/params-hash.ts libs/classifier/src/index.ts \
  libs/classifier-runtime/src/factory.ts libs/eval/tests/params-hash.test.ts
git commit -m "feat(classifier): paramsHash stamped into production classifier name

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `classification_decision` table + SQL trigger logging + migration + pgTAP

**Files:**
- Create: `libs/db/schema/50-tables/32-classification_decision.sql`
- Modify: `libs/db/schema/95-triggers/23-thread_group_peers.sql`
- Modify: `libs/db/schema/95-triggers/30-topic_member_change.sql`
- Modify: `libs/db/schema/60-functions/apply_channel_default.sql`
- Create: `libs/db/tests/70-classification-decision-log.sql`
- Generated: `libs/db/migrations/<timestamp>_classification_decision_log.sql`, `libs/db/src/types.ts`

- [ ] **Step 1: Create the table schema file** — `libs/db/schema/50-tables/32-classification_decision.sql`:

```sql
-- Append-only log of applied classification decisions and explicit user
-- moves. One row per APPLIED decision: the TS hybrid classifier (API worker
-- foreground + classify worker consumer), the SQL classifier's inline
-- trigger paths (stage 'sql:applied'), and user corrections
-- (stage 'user_move'). Previews (classify_thread_for_user_explain admin
-- routes, /sync/priority-match) are never logged.
--
-- Deliberately has NO foreign keys: no lock coupling with the
-- deadlock-sensitive thread/thread_priority write paths, and rows must
-- survive cleanup of their referents. Not synced — no user.* view reads
-- this table; it exists for offline mining (eval seeder via the readonly
-- prod proxy: an auto-decision row followed by a user_move row with a
-- different priority_id is a labeled misclassification) and for
-- survival-rate telemetry per stage/classifier version.
CREATE TABLE "public"."classification_decision" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "thread_id" uuid NOT NULL,
    "user_id" uuid NOT NULL,
    -- Chosen filing as the classifier returned it; NULL only for stage
    -- 'none' (callers' root fallback is not substituted in).
    "priority_id" uuid,
    -- Cascade stage ('scoring', 'llm_tiebreaker', ...), 'sql:applied' for
    -- the SQL trigger paths, or 'user_move'.
    "stage" text NOT NULL,
    "scores" jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- 'ts:hybrid-llm:production@<paramsHash>' | 'sql:classify_thread_for_user' | 'user'
    "classifier" text NOT NULL,
    "llm_calls" int NOT NULL DEFAULT 0,
    "cache_hits" int NOT NULL DEFAULT 0,
    "budget_exhausted" boolean NOT NULL DEFAULT FALSE,
    "duration_ms" real,
    "created_at" timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE "public"."classification_decision" IS 'Append-only log of applied classification decisions (classifier stages, sql:applied trigger paths) and explicit user moves (stage=user_move). No FKs by design; not synced.';

CREATE INDEX classification_decision_user_thread_idx
    ON "public"."classification_decision" ("user_id", "thread_id", "created_at");
```

- [ ] **Step 2: Log from the group-member trigger** — in `libs/db/schema/95-triggers/23-thread_group_peers.sql`, inside `file_thread_priority_on_group_member_change`'s INSERT branch, replace the statement that ends `...DO UPDATE SET revoked_at = NULL WHERE thread_priority.revoked_at IS NOT NULL;` with (the `affected` and `candidates` CTEs are unchanged; the filing INSERT moves into a `filed` CTE, and decisions are logged only for rows actually inserted — `(xmax = 0)` distinguishes a fresh insert from the conflict-path un-revoke, which preserves the prior filing and must not log):

```sql
        WITH affected AS (
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ),
        candidates AS (
            SELECT a.thread_id, public.classify_thread_for_user(v_peer_user_id, a.thread_id) AS pid
            FROM affected a
        ),
        filed AS (
            INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
            SELECT c.thread_id, v_peer_user_id, c.pid,
                   CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
            FROM candidates c
            -- Re-join case: if a row already exists with revoked_at set
            -- (the user previously lost access), un-revoke it. Prior priority
            -- filing is preserved — we do not overwrite priority_id /
            -- classify_at. Rows without revoked_at are left alone (the user
            -- already had active access via another path).
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
            SET revoked_at = NULL
            WHERE thread_priority.revoked_at IS NOT NULL
            RETURNING thread_priority.thread_id, thread_priority.priority_id,
                      (xmax = 0) AS inserted
        )
        -- Decision log: only freshly-inserted, resolved filings are applied
        -- decisions. Un-revokes preserve the prior filing; pending rows
        -- (pid NULL) are decided later by the classify worker, which logs.
        INSERT INTO classification_decision (thread_id, user_id, priority_id, stage, classifier)
        SELECT f.thread_id, v_peer_user_id, f.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
        FROM filed f
        WHERE f.inserted AND f.priority_id IS NOT NULL;
```

(Keep the comment that previously sat on the ON CONFLICT — shown inline above. The subsequent `INSERT INTO thread_state ...` statement is untouched.)

- [ ] **Step 3: Log from the topic grant helper** — in `libs/db/schema/95-triggers/30-topic_member_change.sql`, inside `grant_topic_threads_to_user`, replace the filing statement with the same pattern:

```sql
    WITH candidates AS (
        SELECT t.id AS thread_id, public.classify_thread_for_user(p_user_id, t.id) AS pid
        FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ),
    filed AS (
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT c.thread_id, p_user_id, c.pid,
               CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
        FROM candidates c
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
        SET revoked_at = NULL
        WHERE thread_priority.revoked_at IS NOT NULL
        RETURNING thread_priority.thread_id, thread_priority.priority_id,
                  (xmax = 0) AS inserted
    )
    INSERT INTO classification_decision (thread_id, user_id, priority_id, stage, classifier)
    SELECT f.thread_id, p_user_id, f.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
    FROM filed f
    WHERE f.inserted AND f.priority_id IS NOT NULL;
```

- [ ] **Step 4: Log from `apply_channel_default`** — in `libs/db/schema/60-functions/apply_channel_default.sql`, change the `updated` CTE's `RETURNING 1` to `RETURNING tp.thread_id, tp.user_id, tp.priority_id`, and insert a `logged` CTE between `updated` and the final SELECT:

```sql
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                r.user_id, r.thread_id, r.new_priority_id
            ),
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = r.user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND (
              r.new_priority_id IS DISTINCT FROM tp.priority_id
              OR public.channel_default_marker (
                     r.user_id, r.thread_id, r.new_priority_id
                 ) IS DISTINCT FROM tp.applied_default_channel_id
          )
        RETURNING tp.thread_id, tp.user_id, tp.priority_id
    ),
    logged AS (
        INSERT INTO public.classification_decision (thread_id, user_id, priority_id, stage, classifier)
        SELECT u.thread_id, u.user_id, u.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
        FROM updated u
    )
    SELECT COUNT(*) INTO v_updated FROM updated;
```

- [ ] **Step 5: Generate and apply the migration**

```bash
psql "$DATABASE_URL" -tAc "show port;"   # verify target DB first
pnpm gen-migration -- classification_decision_log
pnpm apply-migrations
pnpm diff-schema-migrations               # expected: no differences
pnpm --filter @plotday/db run lint        # expected: types in sync (apply-migrations regenerated them)
```

Expected: migration created and applied; `libs/db/src/types.ts` regenerated (must be committed).

- [ ] **Step 6: Verify grants** (the global default privileges should cover the new table):

```bash
psql "$DATABASE_URL" -tAc "SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type)
  FROM information_schema.table_privileges
  WHERE table_name = 'classification_decision' GROUP BY grantee;"
```

Expected: `api` has DELETE,INSERT,SELECT,UPDATE and `readonly` has SELECT. If `readonly` is missing, add explicit grants to the generated migration (`GRANT SELECT ON public.classification_decision TO readonly;`), re-hash (`atlas migrate hash --dir file://libs/db/migrations`), and re-apply.

- [ ] **Step 7: Write the pgTAP test** — create `libs/db/tests/70-classification-decision-log.sql`:

```sql
-- classification_decision: the SQL trigger paths log applied decisions;
-- pending peer rows, conflict-preserved filings (re-join un-revoke), and
-- previews do not log. Covers group-member add, topic grant, and
-- channel-default re-file.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(8);

-- Setup: author + peer users, a group, a thread referencing the group
-- BEFORE the peer joins (so joining classifies the back-catalog inline).
DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_peer   uuid := gen_random_uuid();
    v_peer_c uuid;
    v_group  uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_author, 'cdl-author@test.plot');
    INSERT INTO "public"."user" (id, email) VALUES (v_peer, 'cdl-peer@test.plot');
    v_peer_c := public.upsert_user_contact(v_peer, 'cdl-peer@test.plot', 'CDL Peer', NULL);
    INSERT INTO "group" (id, name, created_by) VALUES (v_group, 'cdl-group', v_author);
    INSERT INTO thread (id, created_by, title, groups)
    VALUES (gen_random_uuid(), v_author, 'cdl thread pre-membership', ARRAY[v_group]);
    -- Peer joins: file_thread_priority_on_group_member_change classifies inline.
    INSERT INTO group_member (group_id, contact_id) VALUES (v_group, v_peer_c);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')),
    1, 'group-member add logs exactly one decision for the peer');

SELECT is(
    (SELECT stage || '|' || classifier FROM classification_decision
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')),
    'sql:applied|sql:classify_thread_for_user',
    'decision carries the sql stage + classifier markers');

SELECT is(
    (SELECT priority_id FROM classification_decision
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')),
    (SELECT id FROM priority
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')
        AND nlevel(path) = 1),
    'decision priority is the peer root (root_fallback for an untrained peer)');

-- Re-join: leaving revokes; re-joining un-revokes and preserves the prior
-- filing — no new decision row.
DO $$
DECLARE
    v_g uuid := (SELECT id FROM "group" WHERE name = 'cdl-group');
    v_c uuid := (SELECT id FROM contact WHERE email = 'cdl-peer@test.plot');
BEGIN
    DELETE FROM group_member WHERE group_id = v_g AND contact_id = v_c;
    INSERT INTO group_member (group_id, contact_id) VALUES (v_g, v_c);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')),
    1, 're-join un-revoke preserves filing and logs no new decision');

-- New thread into the group AFTER membership exists: the peer gets a
-- PENDING row (priority NULL, classify_at set) — no decision applied here.
DO $$
BEGIN
    INSERT INTO thread (id, created_by, title, groups)
    VALUES (gen_random_uuid(),
            (SELECT id FROM "user" WHERE email = 'cdl-author@test.plot'),
            'cdl thread post-membership',
            ARRAY[(SELECT id FROM "group" WHERE name = 'cdl-group')]);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE t.title = 'cdl thread post-membership'),
    0, 'pending peer filings (new thread into group) log nothing');

-- Topic grant: adding a topic_contact classifies the topic back-catalog.
DO $$
DECLARE
    v_author uuid := (SELECT id FROM "user" WHERE email = 'cdl-author@test.plot');
    v_topic  uuid := gen_random_uuid();
    v_peer2  uuid := gen_random_uuid();
    v_peer2_c uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_peer2, 'cdl-peer2@test.plot');
    v_peer2_c := public.upsert_user_contact(v_peer2, 'cdl-peer2@test.plot', 'CDL Peer2', NULL);
    INSERT INTO topic (id, name, created_by) VALUES (v_topic, 'cdl-topic', v_author);
    INSERT INTO thread (id, created_by, title, topic_id)
    VALUES (gen_random_uuid(), v_author, 'cdl topic thread', v_topic);
    INSERT INTO topic_contact (topic_id, contact_id) VALUES (v_topic, v_peer2_c);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer2@test.plot')),
    1, 'topic grant logs one decision');

-- Channel-default re-file: a root-filed thread with a matching channel
-- topic moves to the channel default and logs the move.
DO $$
DECLARE
    v_owner uuid := gen_random_uuid();
    v_owner_c uuid;
    v_twist bigint;
    v_ti    uuid := gen_random_uuid();
    v_ch    bigint;
    v_root  uuid;
    v_rootp ltree;
    v_focus uuid := gen_random_uuid();
    v_t     uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_owner, 'cdl-owner@test.plot');
    v_owner_c := public.upsert_user_contact(v_owner, 'cdl-owner@test.plot', 'CDL Owner', NULL);
    SELECT id, path INTO v_root, v_rootp FROM priority WHERE user_id = v_owner AND nlevel(path) = 1;
    INSERT INTO priority (id, created_by, user_id, title, path)
    VALUES (v_focus, v_owner, v_owner, 'cdl-channel-focus', v_rootp || 'cdlfocus');
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
    VALUES (gen_random_uuid(), v_owner, 'CDL Twist', 'cdl-twist', '1.0') RETURNING id INTO v_twist;
    INSERT INTO twist_instance (id, twist_id, owner_id, name) VALUES (v_ti, v_twist, v_owner, 'CDL Conn');
    INSERT INTO channel (twist_instance_id, channel_id, title, default_priority_id)
    VALUES (v_ti, 'cdl-ch', 'CDL Channel', v_focus) RETURNING id INTO v_ch;
    INSERT INTO thread (id, created_by, twist_id, title, topic)
    VALUES (v_t, v_ti, v_twist, 'cdl channel thread', 'channel:' || v_ch::text);
    -- Normalize the owner filing to root/settled regardless of what the
    -- author-filing trigger did, putting the row in the initial-adoption shape.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved)
    VALUES (v_t, v_owner, v_root, FALSE)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET priority_id = EXCLUDED.priority_id, user_moved = FALSE, classify_at = NULL;
    PERFORM public.apply_channel_default(v_ch);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE t.title = 'cdl channel thread'),
    1, 'apply_channel_default logs one decision for the re-filed thread');

SELECT is(
    (SELECT cd.priority_id FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE t.title = 'cdl channel thread'),
    (SELECT id FROM priority WHERE title = 'cdl-channel-focus'),
    'channel re-file decision targets the channel default focus');

SELECT * FROM finish();
ROLLBACK;
```

Note for the implementer: if a trigger side-effect makes a count assertion fail (e.g. the author-filing trigger behaves differently than assumed), inspect with psql inside a transaction, adjust the *setup* (not the assertion's intent), and keep the five behaviors covered: group add logs / re-join doesn't / pending doesn't / topic grant logs / channel re-file logs with correct target.

- [ ] **Step 8: Run the DB test suite**

Run: `DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/db test`
Expected: all pgTAP files pass, including the new `70-classification-decision-log.sql` (8/8).

- [ ] **Step 9: Commit** (migration + regenerated types + schema + test together):

```bash
git add libs/db/schema/50-tables/32-classification_decision.sql \
  libs/db/schema/95-triggers/23-thread_group_peers.sql \
  libs/db/schema/95-triggers/30-topic_member_change.sql \
  libs/db/schema/60-functions/apply_channel_default.sql \
  libs/db/migrations/ libs/db/src/types.ts \
  libs/db/tests/70-classification-decision-log.sql
git commit -m "feat(db): classification_decision log + SQL trigger-path logging

Append-only, no-FK, non-synced decision log. Trigger paths log only
actually-applied filings (xmax=0 insert check excludes un-revokes;
pending rows log later via the classify worker).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: API worker decision logging (choke point, pre-insert path, user moves)

**Files:**
- Modify: `workers/api/src/state/classify-thread.ts`
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts`
- Modify: `workers/api/src/twist/tools/plot/thread.ts`
- Modify: `workers/api/src/app/sync/priority-moves.ts`
- Test: `workers/api/src/state/classify-thread.test.ts` (new)

- [ ] **Step 1: Write the failing tests** — create `workers/api/src/state/classify-thread.test.ts`. The `testDb` harness is the same real-Kysely-over-stub-driver pattern as `workers/classify/src/handler.test.ts`, extended to record parameters:

```ts
import { describe, expect, it, vi } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import {
  classifyThreadForUser,
  logClassificationDecision,
} from "./classify-thread";
import type { DB } from "../db-types";

const captureException = vi.fn();
vi.mock("posthog-node", () => ({
  PostHog: class {
    captureException = captureException;
    async shutdown() {}
  },
}));

const classify = vi.fn();
vi.mock("@plotday/classifier-runtime", () => ({
  getProductionClassifier: () => ({
    name: "ts:hybrid-llm:production@deadbeef",
    classify: (...args: unknown[]) => classify(...args),
  }),
  classifierContextFromDb: () => ({}),
}));

type Executed = { sql: string; parameters: readonly unknown[] };

function testDb(
  executed: Executed[],
  respond: (sql: string) => Promise<{ rows: unknown[] }>
): Kysely<DB> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) => {
      executed.push({ sql: compiled.sql, parameters: compiled.parameters });
      return (await respond(compiled.sql)) as never;
    },
    streamQuery: () => {
      throw new Error("not implemented");
    },
  };
  return new Kysely<DB>({
    dialect: {
      createAdapter: () => new PostgresAdapter(),
      createDriver: () => ({
        init: async () => {},
        acquireConnection: async () => connection,
        beginTransaction: async () => {},
        commitTransaction: async () => {},
        rollbackTransaction: async () => {},
        releaseConnection: async () => {},
        destroy: async () => {},
      }),
      createIntrospector: (db) => new PostgresIntrospector(db),
      createQueryCompiler: () => new PostgresQueryCompiler(),
    },
  });
}

const ENV = { POSTHOG_API_KEY: "x", POSTHOG_HOST: "x" } as never;

function defaultRespond(overrides?: (sql: string) => { rows: unknown[] } | null) {
  return async (sql: string) => {
    const hit = overrides?.(sql);
    if (hit) return hit;
    if (sql.includes("FROM public.thread t")) {
      return {
        rows: [
          {
            title: "T",
            topic: null,
            contacts: [],
            groups: [],
            embedding: null,
            created_by: null,
            facets: null,
            author_id: null,
            twist_id: null,
          },
        ],
      };
    }
    if (sql.includes("classification_decision")) return { rows: [] };
    if (sql.includes('from "priority"')) return { rows: [{ id: "root-1" }] };
    throw new Error(`unexpected SQL in test: ${sql}`);
  };
}

const RESULT = {
  priorityId: "p-1",
  stage: "scoring",
  scores: { perPrioritySorted: [] },
  durationMs: 12.5,
  llmCalls: 1,
  cacheHits: 2,
  budgetExhausted: false,
};

describe("classifyThreadForUser decision logging", () => {
  it("logs the applied decision when a threadId is present", async () => {
    classify.mockResolvedValueOnce(RESULT);
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    const out = await classifyThreadForUser(db, ENV, { userId: "u-1", threadId: "t-1" });
    expect(out).toEqual({ priorityId: "p-1", pending: false });
    const log = executed.find((e) => e.sql.includes("classification_decision"));
    expect(log).toBeDefined();
    expect(log!.parameters).toEqual(
      expect.arrayContaining(["t-1", "u-1", "p-1", "scoring", "ts:hybrid-llm:production@deadbeef"])
    );
  });

  it("logs stage 'none' with NULL priority and returns root on no-match", async () => {
    classify.mockResolvedValueOnce({ ...RESULT, priorityId: null, stage: "none" });
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    const out = await classifyThreadForUser(db, ENV, { userId: "u-1", threadId: "t-1" });
    expect(out).toEqual({ priorityId: "root-1", pending: false });
    const log = executed.find((e) => e.sql.includes("classification_decision"));
    expect(log).toBeDefined();
    expect(log!.parameters).toEqual(expect.arrayContaining(["none"]));
    expect(log!.parameters).not.toEqual(expect.arrayContaining(["root-1"]));
  });

  it("pre-insert (no threadId): nothing logged, pendingLog returned", async () => {
    classify.mockResolvedValueOnce(RESULT);
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    const out = await classifyThreadForUser(db, ENV, { userId: "u-1" });
    expect(out.priorityId).toBe("p-1");
    expect(out.pendingLog).toMatchObject({
      userId: "u-1",
      priorityId: "p-1",
      stage: "scoring",
      classifier: "ts:hybrid-llm:production@deadbeef",
    });
    expect(executed.some((e) => e.sql.includes("classification_decision"))).toBe(false);
  });

  it("a failed log insert is captured and does not fail the filing", async () => {
    classify.mockResolvedValueOnce(RESULT);
    captureException.mockClear();
    const executed: Executed[] = [];
    const db = testDb(
      executed,
      defaultRespond((sql) =>
        sql.includes("classification_decision") ? (() => { throw new Error("insert failed"); })() : null
      )
    );
    const out = await classifyThreadForUser(db, ENV, { userId: "u-1", threadId: "t-1" });
    expect(out).toEqual({ priorityId: "p-1", pending: false });
    expect(captureException).toHaveBeenCalled();
  });
});

describe("logClassificationDecision", () => {
  it("writes all columns with defaults applied", async () => {
    const executed: Executed[] = [];
    const db = testDb(executed, async () => ({ rows: [] }));
    await logClassificationDecision(db, ENV, {
      threadId: "t-9",
      userId: "u-9",
      priorityId: "p-9",
      stage: "user_move",
      scores: {},
      classifier: "user",
    });
    expect(executed).toHaveLength(1);
    expect(executed[0]!.sql).toContain("classification_decision");
    expect(executed[0]!.parameters).toEqual(
      expect.arrayContaining(["t-9", "u-9", "p-9", "user_move", "user", 0, false])
    );
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @plotday/api exec vitest run src/state/classify-thread.test.ts`
Expected: FAIL — `logClassificationDecision` not exported; no decision insert occurs.

- [ ] **Step 3: Implement in `workers/api/src/state/classify-thread.ts`**

Add the types and helper (below `ClassifyResult`):

```ts
export type PendingDecision = {
  userId: string;
  priorityId: string | null;
  stage: string;
  scores: Record<string, unknown>;
  classifier: string;
  llmCalls?: number;
  cacheHits?: number;
  budgetExhausted?: boolean;
  durationMs?: number | null;
};

export type ClassificationDecisionLog = PendingDecision & { threadId: string };

/**
 * Append a classification_decision row (spec B2). Best-effort: a logging
 * failure must never fail or delay a filing — failures are captured to
 * PostHog and swallowed.
 */
export async function logClassificationDecision(
  db: Kysely<DB>,
  env: Bindings,
  entry: ClassificationDecisionLog
): Promise<void> {
  try {
    await sql`
      INSERT INTO public.classification_decision
        (thread_id, user_id, priority_id, stage, scores, classifier,
         llm_calls, cache_hits, budget_exhausted, duration_ms)
      VALUES
        (${entry.threadId}::uuid, ${entry.userId}::uuid,
         ${entry.priorityId}::uuid, ${entry.stage},
         ${JSON.stringify(entry.scores)}::jsonb, ${entry.classifier},
         ${entry.llmCalls ?? 0}, ${entry.cacheHits ?? 0},
         ${entry.budgetExhausted ?? false}, ${entry.durationMs ?? null})
    `.execute(db);
  } catch (err) {
    capture(env, err, entry.userId, entry.threadId);
  }
}
```

Extend `ClassifyResult`:

```ts
export type ClassifyResult = {
  /** The user's resolved priority filing. Always non-null. */
  priorityId: string;
  /** True when the classifier threw (transient failure); see above. */
  pending: boolean;
  /**
   * Present only for pre-insert callers (no threadId yet): the decision
   * entry to log via logClassificationDecision once the thread row exists.
   * Callers that passed a threadId never see this — the decision was
   * already logged here.
   */
  pendingLog?: PendingDecision;
};
```

Rewrite `classifyThreadForUser`'s try block (the catch path is unchanged — a transient failure is not a decision and is not logged):

```ts
  try {
    const classifier = getProductionClassifier(envWithClassifierBindings(env));
    const ctx = classifierContextFromDb(db, args.userId);
    const candidate = await buildCandidate(db, args);
    const result = await classifier.classify(ctx, candidate);
    // Log the decision verbatim — for stage 'none', priority_id stays NULL
    // (the root filing below is a caller-side fallback, not the decision).
    const entry: PendingDecision = {
      userId: args.userId,
      priorityId: result.priorityId,
      stage: result.stage,
      scores: result.scores ?? {},
      classifier: classifier.name,
      llmCalls: result.llmCalls,
      cacheHits: result.cacheHits,
      budgetExhausted: result.budgetExhausted,
      durationMs: result.durationMs,
    };
    const priorityId = result.priorityId ?? (await rootPriorityId(db, args.userId));
    if (args.threadId) {
      await logClassificationDecision(db, env, { ...entry, threadId: args.threadId });
      return { priorityId, pending: false };
    }
    return { priorityId, pending: false, pendingLog: entry };
  } catch (err) {
```

Add the needed imports if missing (`Kysely` type is already imported; `sql` is already imported).

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @plotday/api exec vitest run src/state/classify-thread.test.ts`
Expected: PASS (all 5).

- [ ] **Step 5: Thread `pendingLog` through the twist pre-insert path**

In `workers/api/src/twist/tools/plot/thread-helpers.ts`:

1. Find the `PreparedThread` type definition and add:

```ts
  /** Decision-log entry from the pre-insert classification, if one ran. */
  pendingDecision?: PendingDecision;
```

(import `PendingDecision` from `../../../state/classify-thread` — the file already imports `classifyThreadForUser` from there).

2. In `prepareThreadForDb`, declare `let pendingDecision: PendingDecision | undefined;` next to `let targetPriorityId: string;`, and change the classify call (~line 1259) to:

```ts
    const matched = await classifyThreadForUser(plot.db, plot.env, {
      userId: ownerUserId,
      embedding: embeddingJson ?? null,
      facets:
        ("facets" in activity ? ((activity as any).facets as Record<string, string> | null) : null) ?? null,
      connectionId: plot.twistInstanceId,
    });
    targetPriorityId = matched.priorityId;
    pendingDecision = matched.pendingLog;
```

3. Add `pendingDecision,` to BOTH returned `PreparedThread` object literals at the end of `prepareThreadForDb` (one for the insert shape, one for the upsert shape — search for `priorityId: targetPriorityId`).

In `workers/api/src/twist/tools/plot/thread.ts`:

4. Import: `import { logClassificationDecision } from "../../../state/classify-thread";` (match the relative depth of existing state imports in that file).

5. Add a local helper near the top of the file:

```ts
/**
 * upsert_thread can merge into an existing thread (source match); only a
 * freshly-created row carries this call's pre-insert classification
 * decision. created_at within 10s of now ⇒ created by this call.
 */
function isFreshlyCreated(createdAt: string | Date): boolean {
  return Math.abs(Date.now() - new Date(createdAt).getTime()) < 10_000;
}
```

6. In `createThread`, change the destructure to `const { priorityId, authorId, pendingDecision, ...prep } = prepared;` and after `dbResult` is assigned (after the insert/upsert if/else), add:

```ts
    if (pendingDecision && isFreshlyCreated(dbResult.created_at)) {
      await logClassificationDecision(plot.db, plot.env, {
        ...pendingDecision,
        threadId: dbResult.id,
      });
    }
```

7. In `createThreads`, after the `await Promise.all(...)` that fills `dbActivities`, add:

```ts
    // Log pre-insert classification decisions now that thread ids exist.
    await Promise.all(
      preparedActivities.map((prepared, index) =>
        limit(async () => {
          const row = dbActivities[index];
          if (!prepared.pendingDecision || !row) return;
          if (!isFreshlyCreated(row.created_at)) return;
          await logClassificationDecision(plot.db, plot.env, {
            ...prepared.pendingDecision,
            threadId: row.id,
          });
        })
      )
    );
```

(`created_at` is already part of the `DbActivity` type there.)

- [ ] **Step 6: Log user moves** — in `workers/api/src/app/sync/priority-moves.ts`, import `logClassificationDecision` alongside the existing `enqueueJobs` import from `../../state/classify-thread`, and inside the `withUserDb` callback, after the upsert statement, add:

```ts
    // Decision history: record the correction so an earlier auto-decision
    // with a different priority becomes a labeled misclassification.
    await logClassificationDecision(trx, c.env, {
      threadId,
      userId,
      priorityId,
      stage: "user_move",
      scores: {},
      classifier: "user",
    });
```

- [ ] **Step 7: Lint + full API test suite**

Run: `pnpm --filter @plotday/api lint && pnpm --filter @plotday/api test`
Expected: PASS. If existing tests that stub `classifyThreadForUser`'s DB queries now fail on the unexpected `classification_decision` insert, add a `{ rows: [] }` response for SQL containing `classification_decision` to their stubs.

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/state/classify-thread.ts workers/api/src/state/classify-thread.test.ts \
  workers/api/src/twist/tools/plot/thread-helpers.ts workers/api/src/twist/tools/plot/thread.ts \
  workers/api/src/app/sync/priority-moves.ts
git commit -m "feat(api): log classification decisions + user moves

Choke-point logging in classifyThreadForUser; pendingLog threading for
the twist pre-insert path (freshness-guarded for upsert merges);
user_move rows from /sync/priority-moves.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Classify worker decision logging

**Files:**
- Modify: `workers/classify/src/handler.ts`
- Modify: `workers/classify/src/index.ts`
- Test: `workers/classify/src/handler.test.ts` (extend)

- [ ] **Step 1: Write the failing tests** — in `workers/classify/src/handler.test.ts`:

1. Update the classifier-runtime mock's classifier to include a name and the result's missing fields:

```ts
vi.mock("@plotday/classifier-runtime", () => ({
  getProductionClassifier: () => ({
    name: "ts:hybrid-llm:production@deadbeef",
    classify: async () => ({
      priorityId: "target-priority",
      stage: "test",
      scores: {},
      durationMs: 1,
      llmCalls: 0,
      cacheHits: 0,
      budgetExhausted: false,
    }),
  }),
  classifierContextFromDb: () => ({}),
}));
```

2. In `defaultRespond`, add ABOVE the `throw`:

```ts
    if (sql.includes("classification_decision")) {
      return { rows: [] };
    }
```

3. Append a new describe:

```ts
describe("decision logging", () => {
  it("logs the applied decision after a settled update", async () => {
    const events: string[] = [];
    const db = testDb(events, defaultRespond());
    const outcome = await handleClassifyJob(JOB, ENV, db);
    expect(outcome.status).toBe("moved");
    const update = events.findIndex((e) => e.startsWith('update "thread_priority"'));
    const log = events.findIndex((e) => e.includes("classification_decision"));
    expect(log).toBeGreaterThan(update);
  });

  it("does not log when the job is skipped (user_moved)", async () => {
    const events: string[] = [];
    const db = testDb(
      events,
      defaultRespond((sql) => {
        if (sql.includes('from "thread_priority"')) {
          return Promise.resolve({
            rows: [{ priority_id: "old-priority", user_moved: true, classify_at: new Date() }],
          });
        }
        return null;
      })
    );
    const outcome = await handleClassifyJob(JOB, ENV, db);
    expect(outcome.status).toBe("skipped");
    expect(events.some((e) => e.includes("classification_decision"))).toBe(false);
  });

  it("reports a failed log insert via onError and still settles", async () => {
    const events: string[] = [];
    const onError = vi.fn();
    const db = testDb(
      events,
      defaultRespond((sql) => {
        if (sql.includes("classification_decision")) {
          return Promise.reject(new Error("log insert failed"));
        }
        return null;
      })
    );
    const outcome = await handleClassifyJob(JOB, ENV, db, onError);
    expect(outcome.status).toBe("moved");
    expect(onError).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @plotday/classify test`
Expected: the new describe FAILS (no log insert, no `onError` param).

- [ ] **Step 3: Implement in `workers/classify/src/handler.ts`**

Add the fourth parameter:

```ts
export async function handleClassifyJob(
  job: ClassifyJob,
  env: ClassifyEnv,
  db: ClassifyDb,
  onError?: (err: unknown) => void
): Promise<ClassifyOutcome> {
```

After the `telemetry` block, add:

```ts
  // Append-only decision log (spec B2.2): record the applied result
  // verbatim whenever this job's outcome is applied (settled/moved/same).
  // A logging failure must never fail the filing.
  const logDecision = async () => {
    try {
      await sql`
        INSERT INTO public.classification_decision
          (thread_id, user_id, priority_id, stage, scores, classifier,
           llm_calls, cache_hits, budget_exhausted, duration_ms)
        VALUES
          (${job.threadId}::uuid, ${job.userId}::uuid,
           ${result.priorityId}::uuid, ${result.stage},
           ${JSON.stringify(result.scores ?? {})}::jsonb, ${classifier.name},
           ${result.llmCalls}, ${result.cacheHits},
           ${result.budgetExhausted}, ${result.durationMs})
      `.execute(db);
    } catch (err) {
      onError?.(err);
    }
  };
```

Wire it into the three applied branches:

- Case A (`snapshot == null`): replace the return with

```ts
    const applied = updated.numUpdatedRows > 0n;
    if (applied) await logDecision();
    return { status: applied ? "settled" : "skipped", ...telemetry };
```

- Case B–D different result (`target !== snapshot`): same pattern with `"moved"`.
- Same-result branch: add `await logDecision();` before `return { status: "same", ...telemetry };`.

- [ ] **Step 4: Wire `onError` in `workers/classify/src/index.ts`** — change the call:

```ts
            const outcome = await handleClassifyJob(job, env, db, (logErr) =>
              posthog.captureException(logErr as Error, job.userId, {
                threadId: job.threadId,
                context: "classification_decision_log",
              })
            );
```

- [ ] **Step 5: Run the tests**

Run: `pnpm --filter @plotday/classify test && pnpm --filter @plotday/classify lint`
Expected: ALL PASS (existing lock-ordering tests + new describe).

- [ ] **Step 6: Commit**

```bash
git add workers/classify/src/handler.ts workers/classify/src/index.ts workers/classify/src/handler.test.ts
git commit -m "feat(classify): log applied decisions from the queue consumer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Eval CLI default + final sweep

**Files:**
- Modify: `libs/eval/src/cli.ts`
- Modify: `libs/eval/README.md`

- [ ] **Step 1: Flip the default classifier** — in `libs/eval/src/cli.ts`:

```ts
  const classifierNames = (values.classifiers ?? "ts:hybrid-llm:default").split(",");
```

And update the help text line to:

```
  --classifiers <list>      Comma-separated classifier names (default: ts:hybrid-llm:default)
```

- [ ] **Step 2: Update the README** — in `libs/eval/README.md`, replace the paragraph beginning "The classifier under test is the PostgreSQL function…" with:

```markdown
The default classifier under test is `ts:hybrid-llm:default` — the same
TS hybrid-LLM cascade production runs (`libs/classifier`, dispatched via
`workers/api` and `workers/classify`). The historical SQL classifier
`public.classify_thread_for_user` (still used inline by a few DB trigger
paths) remains available as the `sql:current` variant for comparison.
```

- [ ] **Step 3: Full verification sweep**

```bash
pnpm --filter @plotday/classifier lint
pnpm --filter @plotday/classifier-runtime lint
pnpm --filter @plotday/eval lint
pnpm --filter @plotday/api lint
pnpm --filter @plotday/classify lint
DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/eval test
pnpm --filter @plotday/api test
pnpm --filter @plotday/classify test
DATABASE_URL="$DATABASE_URL" pnpm --filter @plotday/db test
pnpm diff-schema-migrations
```

Expected: everything green; no schema diff.

- [ ] **Step 4: Commit**

```bash
git add libs/eval/src/cli.ts libs/eval/README.md
git commit -m "chore(eval): default classifier is now ts:hybrid-llm:default

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Run `/finalize`** (mandatory project rule before declaring done). Notes for it: this is backend/infra work — no `docs/updates.md` entry (not user-noticeable), no `docs/features.md` change, no `public/` submodule involvement, no Flutter changes. New catch blocks call `captureException` via `capture()`/`onError` (verify it agrees).

---

## Out of scope (do not build)

- Routing the SQL trigger paths through the queue (decided against).
- Eval corpus support for facets/connections/negatives; decision-log mining in the seeder; `--params`/sweep/baseline CLI (separate eval workstream).
- Retention cron for `classification_decision`.
- Tuning `originBonus` (needs corpus support first).
- PostHog `classify.handled` enrichment.
