# Hybrid Thread Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tunable TS-side thread classifier (`ts:hybrid`) and an LLM-augmented sibling (`ts:hybrid-llm`) in the eval framework, with new signals (author, topic_fuzzy, title), kNN aggregation, deterministic cold-start shortcuts, and gated LLM tie-breaker / cold-start stages.

**Architecture:** Two new classifiers registered in `libs/eval/src/classifiers/`. Each classifier is parameterized by a `HybridParams` object so we can register many tuned variants. Cascade stages are TS reimplementations of the deterministic SQL stages plus new scoring and (optionally) LLM stages. LLM client is injected via params with a file-backed cache for eval reproducibility. Corpus schema gains an optional `author` field. Eval runner propagates LLM call counts and cache hit rates into the run summary.

**Tech Stack:** TypeScript, Vitest, Kysely/pg (sandbox DB queries), `@ai-sdk/anthropic` + `ai` package for LLM calls (codebase convention).

**Spec:** `docs/superpowers/specs/2026-05-18-hybrid-thread-classifier-design.md`

**Scope:** This plan covers everything inside `libs/eval/`. Production wiring in `workers/api/src/state/classify-thread.ts` is explicitly out of scope per spec §2 and §8.

---

## File Structure

New files (paths relative to repo root):

- `libs/eval/.gitignore` — adds `.cache/`.
- `libs/eval/src/classifiers/ts-hybrid.defaults.ts` — `HybridParams` type + `DEFAULTS`, `DEFAULTS_LLM` constants.
- `libs/eval/src/classifiers/ts-hybrid.ts` — scoring stage + non-LLM cascade. Exports `makeHybridClassifier(params)`.
- `libs/eval/src/classifiers/ts-hybrid-llm.ts` — adds tie-breaker + cold-start stages. Exports `makeHybridLlmClassifier(params, llmClient?)`.
- `libs/eval/src/classifiers/llm-client.ts` — `LLMClient` interface + default Anthropic-backed implementation.
- `libs/eval/src/classifiers/llm-cache.ts` — file-backed cache that wraps any `LLMClient`.
- `libs/eval/src/classifiers/prompts/tiebreaker-v1.txt` — tie-breaker prompt template.
- `libs/eval/src/classifiers/prompts/coldstart-v1.txt` — cold-start prompt template.
- `libs/eval/src/classifiers/prompts/index.ts` — typed exports + filesystem reads.
- `libs/eval/tests/ts-hybrid-signals.test.ts` — unit tests for per-signal functions.
- `libs/eval/tests/ts-hybrid-aggregation.test.ts` — unit tests for aggregation modes.
- `libs/eval/tests/ts-hybrid-cascade.test.ts` — cascade ordering tests against synthetic-tiny.
- `libs/eval/tests/ts-hybrid-llm.test.ts` — LLM stage tests with a stub client.
- `libs/eval/tests/llm-cache.test.ts` — cache key stability + persistence tests.
- `libs/eval/corpora/kris/trainings/empty.yaml` — zero training threads.
- `libs/eval/corpora/kris/trainings/first-day.yaml` — 1–2 training threads.

Modified files:

- `libs/eval/src/classifiers/types.ts` — extend `ClassificationResult` with `llmCalls`, `cacheHits`.
- `libs/eval/src/classifiers/registry.ts` — `registerVariant` helper + register new variants.
- `libs/eval/src/runner/run.ts` — propagate LLM counts into `RunResult` and `RunSummary`.
- `libs/eval/src/scoring/report.ts` — render LLM-call columns.
- `libs/eval/src/corpus/schema.ts` — optional `author` on candidate + training thread.
- `libs/eval/src/corpus/load.ts` — resolve `author` slugs.
- `libs/eval/src/sandbox/pg-sandbox.ts` — use resolved `author` for `thread.created_by`.
- `libs/eval/src/index.ts` — re-export new public types.
- `libs/eval/package.json` — add `@ai-sdk/anthropic` and `ai` deps.

---

## Conventions

- TypeScript ESM; no `.js` extension on relative imports (matches existing eval code).
- `Classifier` consumes `ClassifierContext.rawQuery` for SQL (mirrors `sql-current.ts`).
- All UUIDs are passed as `$N::uuid` and arrays as `$N::uuid[]` in parameterized queries.
- One `pnpm --filter @plotday/eval lint` run at the end of the plan (Task 24). Individual tasks commit at logical boundaries; do not lint after every step.
- Test files reuse `describe.runIf(!!process.env.DATABASE_URL)` for integration tests that hit Postgres; unit tests have no such guard.

---

## Task 1: Extend `ClassificationResult` with LLM counters

**Why:** Every downstream piece (runner, report) needs these fields on the result. Add them first so later tasks compile against the extended shape.

**Files:**
- Modify: `libs/eval/src/classifiers/types.ts`
- Modify: `libs/eval/src/classifiers/sql-current.ts:21-26` (set new fields to `0`)

- [ ] **Step 1: Add new fields to `ClassificationResult`**

Edit `libs/eval/src/classifiers/types.ts`, replacing the existing `ClassificationResult` interface:

```ts
export interface ClassificationResult {
  priorityId: string | null;
  stage: string;
  scores?: Record<string, unknown>;
  durationMs: number;
  /** Number of LLM calls executed during this classification (default 0). */
  llmCalls: number;
  /** Number of LLM cache hits during this classification (default 0). */
  cacheHits: number;
}
```

- [ ] **Step 2: Update `sql-current.ts` to set the new fields**

Edit the returned object in `libs/eval/src/classifiers/sql-current.ts`:

```ts
    return {
      priorityId: row?.priority_id ?? null,
      stage: row?.stage ?? "none",
      scores: row?.scores ?? {},
      durationMs,
      llmCalls: 0,
      cacheHits: 0,
    };
```

- [ ] **Step 3: Lint-quick check**

Run: `cd libs/eval && pnpm exec tsc --noEmit`
Expected: no errors related to `ClassificationResult` fields.

- [ ] **Step 4: Commit**

```bash
git add libs/eval/src/classifiers/types.ts libs/eval/src/classifiers/sql-current.ts
git commit -m "Add llmCalls and cacheHits fields to ClassificationResult"
```

---

## Task 2: Extend corpus schema with optional `author`

**Why:** The author signal (§4.1) needs a way for corpora to label authors. Without this, every thread defaults to the eval user and the signal is uniform 1.0 across all neighbors.

**Files:**
- Modify: `libs/eval/src/corpus/schema.ts`
- Modify: `libs/eval/src/corpus/load.ts`
- Create: `libs/eval/tests/corpus-author.test.ts`

- [ ] **Step 1: Add `author` to schemas**

Edit `libs/eval/src/corpus/schema.ts`. In `TrainingThreadSchema` (around line 36-44) add:

```ts
  author: z.string().nullable().default(null),
```

In the inner `candidate` object of `CorpusCaseSchema` (lines 87-93) add:

```ts
    author: z.string().nullable().default(null),
```

- [ ] **Step 2: Add author resolution helper to loader**

Edit `libs/eval/src/corpus/load.ts`. After `resolveRef` (around line 126) add a helper that converts an author token to a UUID:

```ts
function resolveAuthor(
  author: string | null,
  lookups: SlugLookups,
  context: string
): string | null {
  if (author === null) return null;
  if (UUID_RE.test(author)) return author;
  if (author.startsWith("twist:")) {
    // Twist authors are not represented in the eval sandbox. Hash the slug
    // into a deterministic UUID so equality comparisons across neighbors and
    // the candidate still work; the value will never match a real
    // twist_instance row, which is fine — the twist-author shortcut
    // gracefully no-ops when nothing matches.
    return slugToUuid(author);
  }
  // Otherwise: contact slug.
  const contactId = lookups.contact.get(author);
  if (!contactId) {
    throw new Error(
      `${context}: unknown author "${author}". Declare it as a contact slug in world.yaml, prefix with "twist:" for twist authors, or use a UUID.`
    );
  }
  return contactId;
}

function slugToUuid(slug: string): string {
  // Deterministic 32-bit FNV-1a per byte, replicated across the UUID space.
  let h1 = 0x811c9dc5;
  let h2 = 0xdeadbeef;
  for (let i = 0; i < slug.length; i++) {
    h1 = Math.imul(h1 ^ slug.charCodeAt(i), 16777619) >>> 0;
    h2 = Math.imul(h2 ^ slug.charCodeAt(i), 2654435761) >>> 0;
  }
  const a = h1.toString(16).padStart(8, "0");
  const b = (h2 >>> 16).toString(16).padStart(4, "0");
  const c = ((h1 ^ h2) >>> 16).toString(16).padStart(4, "0");
  const d = (h2 & 0xffff).toString(16).padStart(4, "0");
  const e = (
    (Math.imul(h1, h2) >>> 0).toString(16) +
    (Math.imul(h1 ^ h2, 0x9e3779b1) >>> 0).toString(16)
  )
    .padStart(12, "0")
    .slice(0, 12);
  return `${a}-${b}-4${c.slice(1)}-8${d.slice(1)}-${e}`;
}
```

- [ ] **Step 3: Wire author resolution into `resolveTrainingSetRefs` and `resolveCasesRefs`**

In `resolveTrainingSetRefs` (line 129-158), inside the `.map((t, i) => ({...}))`, add to the returned object:

```ts
          author:
            typeof t.author === "string"
              ? resolveAuthor(
                  t.author,
                  lookups,
                  `${file}#threads[${i}].author`
                )
              : (t.author ?? null),
```

In `resolveCasesRefs` (line 161-203), inside the `candidate` field, add:

```ts
          author:
            typeof candidate.author === "string"
              ? resolveAuthor(
                  candidate.author,
                  lookups,
                  `${caseRef}.candidate.author`
                )
              : (candidate.author ?? null),
```

- [ ] **Step 4: Write a unit test for author resolution**

Create `libs/eval/tests/corpus-author.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { loadCorpus } from "../src/corpus/load";

const WORLD = `
name: t
schema_version: 1
user: { id: "00000000-0000-4000-8000-000000000001", email: "u@e.test" }
priorities:
  - { slug: root, id: "00000000-0000-4000-8000-000000000010", path: "root", title: Root }
contacts:
  - { slug: alice, id: "00000000-0000-4000-8000-000000000020", email: "a@e.test", name: Alice }
`;

const TRAININGS_FULL = `
threads:
  - id: "00000000-0000-4000-8000-000000000100"
    title: t1
    filed_to_priority: root
    author: alice
  - id: "00000000-0000-4000-8000-000000000101"
    title: t2
    filed_to_priority: root
    author: "twist:gmail"
`;

const CASES = `
cases:
  - id: "001"
    candidate: { title: x, author: alice }
    labels: { gold: root }
`;

describe("corpus author resolution", () => {
  it("resolves contact slugs, twist:* slugs, and absent values", async () => {
    const dir = await mkdtemp(join(tmpdir(), "eval-corpus-"));
    await writeFile(join(dir, "world.yaml"), WORLD);
    await mkdir(join(dir, "trainings"));
    await writeFile(join(dir, "trainings", "full.yaml"), TRAININGS_FULL);
    await writeFile(join(dir, "cases.yaml"), CASES);

    const corpus = await loadCorpus(dir);
    const threads = corpus.trainingSets[0]!.threads;

    expect(threads[0]!.author).toBe("00000000-0000-4000-8000-000000000020");
    expect(threads[1]!.author).toMatch(/^[0-9a-f]{8}-/);
    expect(threads[1]!.author).not.toBe("00000000-0000-4000-8000-000000000020");
    expect(corpus.cases[0]!.candidate.author).toBe("00000000-0000-4000-8000-000000000020");
  });
});
```

- [ ] **Step 5: Run the test**

Run: `cd libs/eval && pnpm exec vitest run tests/corpus-author.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add libs/eval/src/corpus/schema.ts libs/eval/src/corpus/load.ts libs/eval/tests/corpus-author.test.ts
git commit -m "Add optional author field to corpus candidate and training threads"
```

---

## Task 3: Wire `author` through the sandbox

**Why:** The classifier reads `thread.created_by`. The sandbox currently sets it to `world.user.id` for every thread; we need it to honor the resolved author when provided.

**Files:**
- Modify: `libs/eval/src/sandbox/pg-sandbox.ts:188-227` (`loadTrainingSet`)
- Modify: `libs/eval/src/sandbox/pg-sandbox.ts:235-264` (`stageCandidate`)
- Modify: `libs/eval/src/runner/run.ts:96-135` (pass through `cs.candidate.author`)

- [ ] **Step 1: Update `loadTrainingSet` to pass author when present**

In `loadTrainingSet`, replace the INSERT INTO public.thread for each training thread. Find:

```ts
    await rawQuery(
      `INSERT INTO public.thread
         (id, created_by, title, topic, contacts, groups, embedding)
       VALUES ($1, $2, $3, $4, $5::uuid[], $6::uuid[], $7::halfvec)`,
      [
        t.id,
        world.user.id,
        t.title,
        t.topic,
        t.contacts,
        t.groups,
        embLiteral,
      ]
    );
```

Replace `world.user.id` with `(t.author ?? world.user.id)`. Also wire the contact so `thread.created_by` referencing a contact has a corresponding row (already inserted in `loadWorld`).

- [ ] **Step 2: Update `stageCandidate` signature and implementation**

Replace `stageCandidate`:

```ts
export async function stageCandidate(
  sandbox: SandboxHandle,
  corpus: Corpus,
  caseCandidate: {
    threadId: string;
    title: string;
    topic: string | null;
    contacts: string[];
    groups: string[];
    embedding: number[] | null;
    author: string | null;
  }
): Promise<void> {
  const embLiteral = caseCandidate.embedding
    ? toHalfvecLiteral(caseCandidate.embedding)
    : null;
  await sandbox.rawQuery(
    `INSERT INTO public.thread
       (id, created_by, title, topic, contacts, groups, embedding)
     VALUES ($1, $2, $3, $4, $5::uuid[], $6::uuid[], $7::halfvec)`,
    [
      caseCandidate.threadId,
      caseCandidate.author ?? corpus.world.user.id,
      caseCandidate.title,
      caseCandidate.topic,
      caseCandidate.contacts,
      caseCandidate.groups,
      embLiteral,
    ]
  );
}
```

- [ ] **Step 3: Pass `cs.candidate.author` from runner**

In `libs/eval/src/runner/run.ts:109-117` and the corresponding `classifier.classify(ctx, {...})` call (lines 127-134), add `author: cs.candidate.author` to both objects:

```ts
    await stageCandidate(sandbox, corpus, {
      threadId,
      title: cs.candidate.title,
      topic: cs.candidate.topic,
      contacts: cs.candidate.contacts,
      groups: cs.candidate.groups,
      embedding: emb?.vector ?? null,
      author: cs.candidate.author,
    });
```

- [ ] **Step 4: Extend `Candidate` interface to carry author**

In `libs/eval/src/classifiers/types.ts`, add to `Candidate`:

```ts
  /** Resolved created_by for the candidate thread (UUID or null). */
  author: string | null;
```

Then in `run.ts:128-134`, add `author: cs.candidate.author` to the second object passed to `classifier.classify`.

- [ ] **Step 5: Run existing sql-current integration tests to confirm parity**

Run: `cd libs/eval && DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres pnpm exec vitest run tests/sql-current.test.ts`
(Use the worktree's `$DATABASE_URL`. If `.worktree-db` exists, source it first.)

Expected: PASS. If your worktree DB isn't running, run `bash scripts/worktree-db` first.

- [ ] **Step 6: Commit**

```bash
git add libs/eval/src/sandbox/pg-sandbox.ts libs/eval/src/runner/run.ts libs/eval/src/classifiers/types.ts
git commit -m "Wire candidate and training-thread author through the eval sandbox"
```

---

## Task 4: `.gitignore` + add LLM SDK dependencies

**Why:** Later tasks need the Anthropic SDK and a place for the LLM cache; do the housekeeping now.

**Files:**
- Create: `libs/eval/.gitignore`
- Modify: `libs/eval/package.json`

- [ ] **Step 1: Create `.gitignore`**

```
.cache/
```

- [ ] **Step 2: Add dependencies**

Edit `libs/eval/package.json`, adding to `dependencies`:

```json
    "@ai-sdk/anthropic": "^2.0.33",
    "ai": "^4.3.16",
```

Use the same versions already declared in `workers/api/package.json` to keep the lockfile clean (`@ai-sdk/anthropic` is `^2.0.33` there; match `ai`'s version exactly — `grep '"ai":' workers/api/package.json` to find it).

- [ ] **Step 3: Install**

Run: `pnpm install`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add libs/eval/.gitignore libs/eval/package.json pnpm-lock.yaml
git commit -m "Add LLM SDK deps and .gitignore for eval cache"
```

---

## Task 5: `HybridParams` defaults file

**Why:** Pins the param surface so later tasks can import a stable type. Also documents the defaults.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid.defaults.ts`

- [ ] **Step 1: Write the file**

```ts
export type SignalWeights = {
  sem: number;
  con: number;
  grp: number;
  author: number;
  topic_fuzzy: number;
  title: number;
};

export type Nonlinearity = "identity" | "square" | "sigmoid";

export type AggregationMode =
  | { mode: "top1" }
  | { mode: "topk_mean"; k: number }
  | { mode: "softmax"; temperature: number };

export type LlmParams = {
  model: "claude-haiku-4-5-20251001" | "claude-sonnet-4-6" | "off";
  tieBreaker: { enabled: boolean; maxCandidates: number; promptId: string };
  coldStart: { enabled: boolean; maxPrioritiesInPrompt: number; promptId: string };
  dailyBudgetPerUser: number;
  /** Subdirectory of libs/eval/.cache/llm/ where cached responses live. */
  cacheNamespace: string;
};

export type HybridParams = {
  // Scoring stage
  weights: SignalWeights;
  /** Multiplier (α_prefix in spec §4.1) for shared leading colon-segment. */
  topicFuzzyPrefixWeight: number;
  nonlinearity: Nonlinearity;
  aggregation: AggregationMode;
  scoreThreshold: number;

  // Tie-breaker gates (only consulted by ts:hybrid-llm)
  highConfidenceFloor: number;
  marginFloor: number;
  nSupportingNeighbors: number;
  supportingFloor: number;

  // Deterministic cold-start shortcuts
  shortcuts: {
    twistAuthor: { enabled: boolean; minSamples: number; agreement: number };
    contactHistory: { enabled: boolean; minSamples: number };
    singlePriorityBypass: { enabled: boolean };
  };

  // LLM (only consulted by ts:hybrid-llm)
  llm?: LlmParams;
};

export const DEFAULTS: HybridParams = {
  weights: {
    sem: 0.40,
    con: 0.25,
    grp: 0.10,
    author: 0.10,
    topic_fuzzy: 0.10,
    title: 0.05,
  },
  topicFuzzyPrefixWeight: 0.6,
  nonlinearity: "square",
  aggregation: { mode: "topk_mean", k: 3 },
  scoreThreshold: 0.15,

  highConfidenceFloor: 0.45,
  marginFloor: 0.08,
  nSupportingNeighbors: 2,
  supportingFloor: 0.25,

  shortcuts: {
    twistAuthor: { enabled: true, minSamples: 3, agreement: 0.8 },
    contactHistory: { enabled: true, minSamples: 2 },
    singlePriorityBypass: { enabled: true },
  },
};

export const DEFAULTS_LLM: HybridParams = {
  ...DEFAULTS,
  llm: {
    model: "claude-haiku-4-5-20251001",
    tieBreaker: { enabled: true, maxCandidates: 3, promptId: "tiebreaker-v1" },
    coldStart: { enabled: true, maxPrioritiesInPrompt: 30, promptId: "coldstart-v1" },
    dailyBudgetPerUser: 50,
    cacheNamespace: "default",
  },
};

export function assertValidWeights(w: SignalWeights): void {
  const total = w.sem + w.con + w.grp + w.author + w.topic_fuzzy + w.title;
  if (Math.abs(total - 1) > 1e-6) {
    throw new Error(
      `HybridParams.weights must sum to 1 (got ${total.toFixed(4)}). Adjust the weights so they total 1.`
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid.defaults.ts
git commit -m "Add HybridParams type and default tuning surface"
```

---

## Task 6: Per-signal scoring functions (sem, con, grp)

**Why:** Three of the six signals port directly from the SQL classifier. Implement them as pure helpers so they can be unit-tested without a database.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-signals.ts`
- Create: `libs/eval/tests/ts-hybrid-signals.test.ts`

- [ ] **Step 1: Write failing tests**

Create `libs/eval/tests/ts-hybrid-signals.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  jaccard,
  sem,
  con,
  grp,
} from "../src/classifiers/ts-hybrid-signals";

describe("ts-hybrid signals: sem", () => {
  it("returns 0 when either embedding is null", () => {
    expect(sem(null, [0.1, 0.2])).toBe(0);
    expect(sem([0.1, 0.2], null)).toBe(0);
  });

  it("returns 0 when cosine similarity is below the 0.5 floor", () => {
    const a = [1, 0, 0];
    const b = [0, 1, 0]; // cos = 0 → below floor
    expect(sem(a, b)).toBe(0);
  });

  it("scales (cos - 0.5) * 2 to [0, 1]", () => {
    const a = [1, 0, 0];
    expect(sem(a, a)).toBeCloseTo(1, 6); // cos=1 → (1-0.5)*2 = 1
  });
});

describe("ts-hybrid signals: con / grp / jaccard", () => {
  it("jaccard handles empty sets as 0", () => {
    expect(jaccard([], [])).toBe(0);
    expect(jaccard(["a"], [])).toBe(0);
    expect(jaccard([], ["a"])).toBe(0);
  });

  it("jaccard computes intersection / union for non-empty sets", () => {
    expect(jaccard(["a", "b"], ["a", "c"])).toBeCloseTo(1 / 3, 6);
    expect(jaccard(["a", "b"], ["a", "b"])).toBe(1);
  });

  it("con and grp are thin wrappers around jaccard", () => {
    expect(con(["c1", "c2"], ["c1"])).toBeCloseTo(1 / 2, 6);
    expect(grp(["g1"], ["g2"])).toBe(0);
  });
});
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-signals.test.ts`
Expected: FAIL with "Cannot find module" or similar import error.

- [ ] **Step 3: Implement**

Create `libs/eval/src/classifiers/ts-hybrid-signals.ts`:

```ts
export function jaccard(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const setA = new Set(a);
  const setB = new Set(b);
  let inter = 0;
  for (const x of setA) if (setB.has(x)) inter++;
  const union = setA.size + setB.size - inter;
  if (union === 0) return 0;
  return inter / union;
}

export function sem(a: number[] | null, b: number[] | null): number {
  if (a === null || b === null) return 0;
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i]! * b[i]!;
    normA += a[i]! * a[i]!;
    normB += b[i]! * b[i]!;
  }
  if (normA === 0 || normB === 0) return 0;
  const cos = dot / (Math.sqrt(normA) * Math.sqrt(normB));
  return Math.max(0, (cos - 0.5) * 2);
}

export function con(a: string[], b: string[]): number {
  return jaccard(a, b);
}

export function grp(a: string[], b: string[]): number {
  return jaccard(a, b);
}
```

- [ ] **Step 4: Run to confirm passing**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-signals.test.ts`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-signals.ts libs/eval/tests/ts-hybrid-signals.test.ts
git commit -m "Add sem/con/grp signal functions for ts:hybrid classifier"
```

---

## Task 7: New signals (author, topic_fuzzy, title)

**Why:** These are the three signals the SQL classifier lacks. Implement and unit-test them in isolation before plugging them into the cascade.

**Files:**
- Modify: `libs/eval/src/classifiers/ts-hybrid-signals.ts`
- Modify: `libs/eval/tests/ts-hybrid-signals.test.ts`

- [ ] **Step 1: Add failing tests**

Append to `libs/eval/tests/ts-hybrid-signals.test.ts`:

```ts
import {
  author as authorSignal,
  topicFuzzy,
  titleTrigramJaccard,
} from "../src/classifiers/ts-hybrid-signals";

describe("ts-hybrid signals: author", () => {
  it("returns 1 when both sides have the same author", () => {
    expect(authorSignal("u1", "u1")).toBe(1);
  });
  it("returns 0 when either side is null", () => {
    expect(authorSignal(null, "u1")).toBe(0);
    expect(authorSignal("u1", null)).toBe(0);
  });
  it("returns 0 when authors differ", () => {
    expect(authorSignal("u1", "u2")).toBe(0);
  });
});

describe("ts-hybrid signals: topicFuzzy", () => {
  it("returns 1 for exact match", () => {
    expect(topicFuzzy("channel:1", "channel:1", 0.6)).toBe(1);
  });
  it("returns prefix weight for shared leading colon-segment", () => {
    expect(topicFuzzy("channel:1", "channel:2", 0.6)).toBeCloseTo(0.6, 6);
  });
  it("returns 0 when leading segments differ", () => {
    expect(topicFuzzy("slack:foo", "gmail:bar", 0.6)).toBe(0);
  });
  it("returns 0 when either side is null", () => {
    expect(topicFuzzy(null, "channel:1", 0.6)).toBe(0);
    expect(topicFuzzy("channel:1", null, 0.6)).toBe(0);
  });
  it("returns 0 when a topic has no colon and they differ", () => {
    expect(topicFuzzy("foo", "bar", 0.6)).toBe(0);
    expect(topicFuzzy("foo", "foo", 0.6)).toBe(1);
  });
});

describe("ts-hybrid signals: titleTrigramJaccard", () => {
  it("returns 1 for identical titles", () => {
    expect(titleTrigramJaccard("hello world", "hello world")).toBe(1);
  });
  it("returns 0 for disjoint short titles", () => {
    expect(titleTrigramJaccard("abc", "xyz")).toBe(0);
  });
  it("is case-insensitive", () => {
    expect(titleTrigramJaccard("Hello", "hello")).toBe(1);
  });
  it("returns 0 when either is empty or too short for any trigram", () => {
    expect(titleTrigramJaccard("", "abc")).toBe(0);
    expect(titleTrigramJaccard("ab", "ab")).toBe(0);
  });
  it("partial overlap is between 0 and 1", () => {
    const v = titleTrigramJaccard("hello world", "world hello");
    expect(v).toBeGreaterThan(0);
    expect(v).toBeLessThan(1);
  });
});
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-signals.test.ts`
Expected: FAIL (the new imports don't exist).

- [ ] **Step 3: Implement**

Append to `libs/eval/src/classifiers/ts-hybrid-signals.ts`:

```ts
export function author(a: string | null, b: string | null): number {
  if (a === null || b === null) return 0;
  return a === b ? 1 : 0;
}

export function topicFuzzy(
  a: string | null,
  b: string | null,
  prefixWeight: number
): number {
  if (a === null || b === null) return 0;
  if (a === b) return 1;
  const segA = a.split(":")[0] ?? "";
  const segB = b.split(":")[0] ?? "";
  if (segA === "" || segB === "") return 0;
  if (!a.includes(":") || !b.includes(":")) return 0;
  return segA === segB ? prefixWeight : 0;
}

export function titleTrigramJaccard(a: string, b: string): number {
  const tA = trigrams(a.toLowerCase());
  const tB = trigrams(b.toLowerCase());
  if (tA.size === 0 || tB.size === 0) return 0;
  let inter = 0;
  for (const t of tA) if (tB.has(t)) inter++;
  const union = tA.size + tB.size - inter;
  if (union === 0) return 0;
  return inter / union;
}

function trigrams(s: string): Set<string> {
  const out = new Set<string>();
  if (s.length < 3) return out;
  for (let i = 0; i <= s.length - 3; i++) {
    out.add(s.slice(i, i + 3));
  }
  return out;
}
```

- [ ] **Step 4: Run to confirm passing**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-signals.test.ts`
Expected: PASS (all 19+ tests).

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-signals.ts libs/eval/tests/ts-hybrid-signals.test.ts
git commit -m "Add author/topic_fuzzy/title signals for ts:hybrid classifier"
```

---

## Task 8: Nonlinearity + combine

**Why:** The combine step plus the configurable nonlinearity sits between per-signal scoring and aggregation. Isolate it.

**Files:**
- Modify: `libs/eval/src/classifiers/ts-hybrid-signals.ts`
- Create: `libs/eval/tests/ts-hybrid-combine.test.ts`

- [ ] **Step 1: Write failing tests**

Create `libs/eval/tests/ts-hybrid-combine.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  applyNonlinearity,
  combineSignals,
} from "../src/classifiers/ts-hybrid-signals";

describe("applyNonlinearity", () => {
  it("identity passes through", () => {
    expect(applyNonlinearity(0.5, "identity")).toBe(0.5);
  });
  it("square squares", () => {
    expect(applyNonlinearity(0.5, "square")).toBeCloseTo(0.25, 6);
  });
  it("sigmoid maps to (0, 1)", () => {
    const v = applyNonlinearity(0, "sigmoid");
    expect(v).toBeCloseTo(0.5, 6);
    const high = applyNonlinearity(1, "sigmoid");
    expect(high).toBeGreaterThan(0.5);
    expect(high).toBeLessThan(1);
  });
});

describe("combineSignals", () => {
  const weights = {
    sem: 0.4,
    con: 0.25,
    grp: 0.1,
    author: 0.1,
    topic_fuzzy: 0.1,
    title: 0.05,
  };

  it("returns weighted sum with identity nonlinearity", () => {
    const v = combineSignals(
      { sem: 1, con: 1, grp: 1, author: 1, topic_fuzzy: 1, title: 1 },
      weights,
      "identity"
    );
    expect(v).toBeCloseTo(1, 6);
  });

  it("applies the nonlinearity per signal", () => {
    const v = combineSignals(
      { sem: 0.5, con: 0.5, grp: 0.5, author: 0.5, topic_fuzzy: 0.5, title: 0.5 },
      weights,
      "square"
    );
    expect(v).toBeCloseTo(0.25, 6);
  });
});
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-combine.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

Append to `libs/eval/src/classifiers/ts-hybrid-signals.ts`:

```ts
import type { Nonlinearity, SignalWeights } from "./ts-hybrid.defaults";

export type SignalValues = {
  sem: number;
  con: number;
  grp: number;
  author: number;
  topic_fuzzy: number;
  title: number;
};

export function applyNonlinearity(x: number, mode: Nonlinearity): number {
  switch (mode) {
    case "identity":
      return x;
    case "square":
      return x * x;
    case "sigmoid":
      return 1 / (1 + Math.exp(-x));
  }
}

export function combineSignals(
  values: SignalValues,
  weights: SignalWeights,
  nl: Nonlinearity
): number {
  const keys: (keyof SignalValues)[] = [
    "sem",
    "con",
    "grp",
    "author",
    "topic_fuzzy",
    "title",
  ];
  let total = 0;
  for (const k of keys) {
    total += weights[k] * applyNonlinearity(values[k], nl);
  }
  return total;
}
```

Also export these new symbols from the file (they're top-level exports already).

- [ ] **Step 4: Run to confirm passing**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-combine.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-signals.ts libs/eval/tests/ts-hybrid-combine.test.ts
git commit -m "Add nonlinearity and combine helpers for ts:hybrid signals"
```

---

## Task 9: Aggregation modes (top1, topk_mean, softmax)

**Why:** Aggregation across neighbors per priority is the new behavior vs the SQL classifier. Unit-test the three modes against canonical inputs.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-aggregate.ts`
- Create: `libs/eval/tests/ts-hybrid-aggregation.test.ts`

- [ ] **Step 1: Write failing tests**

Create `libs/eval/tests/ts-hybrid-aggregation.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  aggregateNeighbors,
  type ScoredNeighbor,
} from "../src/classifiers/ts-hybrid-aggregate";

const neighbors: ScoredNeighbor[] = [
  { priorityId: "P1", threadId: "T1", combined: 0.9 },
  { priorityId: "P1", threadId: "T2", combined: 0.3 },
  { priorityId: "P1", threadId: "T3", combined: 0.2 },
  { priorityId: "P2", threadId: "T4", combined: 0.6 },
  { priorityId: "P2", threadId: "T5", combined: 0.55 },
];

describe("aggregateNeighbors: top1", () => {
  it("picks the priority of the single highest-scoring neighbor", () => {
    const out = aggregateNeighbors(neighbors, { mode: "top1" });
    expect(out[0]!.priorityId).toBe("P1");
    expect(out[0]!.score).toBe(0.9);
    expect(out[0]!.neighborCount).toBe(3);
  });
});

describe("aggregateNeighbors: topk_mean", () => {
  it("means the top k neighbors per priority", () => {
    const out = aggregateNeighbors(neighbors, { mode: "topk_mean", k: 2 });
    const p1 = out.find((r) => r.priorityId === "P1")!;
    const p2 = out.find((r) => r.priorityId === "P2")!;
    expect(p1.score).toBeCloseTo((0.9 + 0.3) / 2, 6);
    expect(p2.score).toBeCloseTo((0.6 + 0.55) / 2, 6);
    expect(out[0]!.priorityId).toBe("P2"); // sorted desc by score
  });

  it("averages over what's available when a priority has < k neighbors", () => {
    const sparse: ScoredNeighbor[] = [
      { priorityId: "P1", threadId: "T1", combined: 0.5 },
    ];
    const out = aggregateNeighbors(sparse, { mode: "topk_mean", k: 3 });
    expect(out[0]!.score).toBe(0.5);
  });
});

describe("aggregateNeighbors: softmax", () => {
  it("sums exp(combined / T) per priority", () => {
    const out = aggregateNeighbors(neighbors, {
      mode: "softmax",
      temperature: 1,
    });
    const p1 = out.find((r) => r.priorityId === "P1")!;
    const expected =
      Math.exp(0.9) + Math.exp(0.3) + Math.exp(0.2);
    expect(p1.score).toBeCloseTo(expected, 6);
  });
});
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-aggregation.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `libs/eval/src/classifiers/ts-hybrid-aggregate.ts`:

```ts
import type { AggregationMode } from "./ts-hybrid.defaults";

export type ScoredNeighbor = {
  priorityId: string;
  threadId: string;
  combined: number;
};

export type AggregatedPriority = {
  priorityId: string;
  score: number;
  neighborCount: number;
};

export function aggregateNeighbors(
  neighbors: ScoredNeighbor[],
  mode: AggregationMode
): AggregatedPriority[] {
  const byPriority = new Map<string, number[]>();
  for (const n of neighbors) {
    const list = byPriority.get(n.priorityId);
    if (list) list.push(n.combined);
    else byPriority.set(n.priorityId, [n.combined]);
  }

  const out: AggregatedPriority[] = [];
  for (const [priorityId, combinedValues] of byPriority) {
    combinedValues.sort((a, b) => b - a);
    let score: number;
    switch (mode.mode) {
      case "top1":
        score = combinedValues[0]!;
        break;
      case "topk_mean": {
        const k = Math.max(1, mode.k);
        const take = combinedValues.slice(0, k);
        score = take.reduce((a, b) => a + b, 0) / take.length;
        break;
      }
      case "softmax": {
        const T = mode.temperature > 0 ? mode.temperature : 1;
        score = combinedValues.reduce((a, c) => a + Math.exp(c / T), 0);
        break;
      }
    }
    out.push({ priorityId, score, neighborCount: combinedValues.length });
  }
  out.sort((a, b) => b.score - a.score);
  return out;
}
```

- [ ] **Step 4: Run to confirm passing**

Run: `cd libs/eval && pnpm exec vitest run tests/ts-hybrid-aggregation.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-aggregate.ts libs/eval/tests/ts-hybrid-aggregation.test.ts
git commit -m "Add top1/topk_mean/softmax aggregation modes"
```

---

## Task 10: Deterministic stage helpers (TS reimplementation)

**Why:** Stages 1–4 (topic short-circuit, keyed-priority, channel-default, priority:KEY prefix) plus root fallback. These run before scoring and are deterministic. Reimplement in TS so the cascade is a single readable function.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-stages.ts`

- [ ] **Step 1: Write stages module**

Create `libs/eval/src/classifiers/ts-hybrid-stages.ts`:

```ts
import type { ClassifierContext } from "./types";

type StageResult = { priorityId: string; stage: string; scores: Record<string, unknown> } | null;

export async function topicShortCircuit(
  ctx: ClassifierContext,
  topic: string | null
): Promise<StageResult> {
  if (topic === null) return null;
  const res = await ctx.rawQuery(
    `SELECT tp.priority_id
       FROM public.thread_priority tp
       JOIN public.thread mt ON mt.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND mt.archived_at IS NULL
        AND mt.topic = $2
      GROUP BY tp.priority_id
      ORDER BY COUNT(*) DESC, MAX(tp.updated_at) DESC
      LIMIT 1`,
    [ctx.userId, topic]
  );
  const row = res.rows[0] as { priority_id: string } | undefined;
  if (!row) return null;
  return {
    priorityId: row.priority_id,
    stage: "topic_shortcircuit",
    scores: { topic },
  };
}

export async function keyedPriority(
  ctx: ClassifierContext,
  threadId: string
): Promise<StageResult> {
  const res = await ctx.rawQuery(
    `SELECT p.id AS priority_id, p.key
       FROM public.thread_priority tp
       JOIN public.priority src ON src.id = tp.priority_id
       JOIN public.priority p
         ON p.user_id = $1::uuid
        AND p.key = src.key
        AND p.archived_at IS NULL
      WHERE tp.thread_id = $2::uuid
        AND tp.user_id <> $1::uuid
        AND src.key IS NOT NULL
        AND src.archived_at IS NULL
      ORDER BY tp.created_at ASC
      LIMIT 1`,
    [ctx.userId, threadId]
  );
  const row = res.rows[0] as { priority_id: string; key: string } | undefined;
  if (!row) return null;
  return {
    priorityId: row.priority_id,
    stage: "keyed_priority",
    scores: { key: row.key },
  };
}

export async function channelDefault(
  ctx: ClassifierContext,
  topic: string | null
): Promise<StageResult> {
  if (topic === null || !topic.startsWith("channel:")) return null;
  const tail = topic.slice("channel:".length);
  if (tail === "") return null;
  const channelPk = Number(tail);
  if (!Number.isInteger(channelPk)) return null;
  const res = await ctx.rawQuery(
    `SELECT c.default_priority_id
       FROM public.channel c
       JOIN public.priority p ON p.id = c.default_priority_id
      WHERE c.id = $1::bigint
        AND c.default_priority_id IS NOT NULL
        AND p.user_id = $2::uuid
        AND p.archived_at IS NULL`,
    [channelPk, ctx.userId]
  );
  const row = res.rows[0] as { default_priority_id: string | null } | undefined;
  if (!row?.default_priority_id) return null;
  return {
    priorityId: row.default_priority_id,
    stage: "channel_default",
    scores: { channel_id: channelPk },
  };
}

export async function priorityPrefix(
  ctx: ClassifierContext,
  topic: string | null
): Promise<StageResult> {
  if (topic === null || !topic.startsWith("priority:")) return null;
  const key = topic.split(":")[1] ?? "";
  if (key === "") return null;
  const res = await ctx.rawQuery(
    `SELECT id
       FROM public.priority
      WHERE user_id = $1::uuid
        AND key = $2
        AND archived_at IS NULL
      LIMIT 1`,
    [ctx.userId, key]
  );
  const row = res.rows[0] as { id: string } | undefined;
  if (!row) return null;
  return {
    priorityId: row.id,
    stage: "priority_prefix",
    scores: { key },
  };
}

export async function rootFallback(
  ctx: ClassifierContext
): Promise<StageResult> {
  const res = await ctx.rawQuery(
    `SELECT id
       FROM public.priority
      WHERE user_id = $1::uuid
        AND nlevel(path) = 1
        AND archived_at IS NULL
      ORDER BY created_at ASC
      LIMIT 1`,
    [ctx.userId]
  );
  const row = res.rows[0] as { id: string } | undefined;
  if (!row) return null;
  return {
    priorityId: row.id,
    stage: "root_fallback",
    scores: {},
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-stages.ts
git commit -m "Add TS reimplementations of deterministic classifier stages"
```

---

## Task 11: Scoring stage (DB query + combine + aggregate + decision)

**Why:** This is the new scoring pipeline in §4. It loads neighbors, scores each, aggregates per priority, and applies the threshold.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-scoring.ts`

- [ ] **Step 1: Write the scoring stage**

```ts
import type { Candidate, ClassifierContext } from "./types";
import {
  combineSignals,
  con,
  grp,
  sem,
  author as authorSignal,
  titleTrigramJaccard,
  topicFuzzy,
} from "./ts-hybrid-signals";
import { aggregateNeighbors, type ScoredNeighbor } from "./ts-hybrid-aggregate";
import type { HybridParams } from "./ts-hybrid.defaults";

type NeighborRow = {
  priority_id: string;
  thread_id: string;
  title: string | null;
  topic: string | null;
  created_by: string | null;
  contacts_expanded: string[];
  groups: string[];
  embedding: number[] | null;
};

export type ScoringExplain = {
  perPrioritySorted: { priorityId: string; score: number; neighborCount: number }[];
  topNeighbors: {
    priorityId: string;
    threadId: string;
    sem: number;
    con: number;
    grp: number;
    author: number;
    topic_fuzzy: number;
    title: number;
    combined: number;
  }[];
};

export type ScoringOutcome =
  | { matched: true; priorityId: string; explain: ScoringExplain; top1: number; top2: number }
  | { matched: false; explain: ScoringExplain; top1: number | null; top2: number | null };

export async function scoringStage(
  ctx: ClassifierContext,
  candidate: Candidate,
  params: HybridParams
): Promise<ScoringOutcome> {
  const res = await ctx.rawQuery(
    `SELECT tp.priority_id,
            tp.thread_id,
            mt.title,
            mt.topic,
            mt.created_by,
            public.expand_contacts(mt.contacts) AS contacts_expanded,
            mt.groups,
            CASE WHEN mt.embedding IS NULL THEN NULL ELSE mt.embedding::text END AS embedding
       FROM public.thread_priority tp
       JOIN public.thread mt ON mt.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND mt.archived_at IS NULL`,
    [ctx.userId]
  );

  const rows = (res.rows as Array<{
    priority_id: string;
    thread_id: string;
    title: string | null;
    topic: string | null;
    created_by: string | null;
    contacts_expanded: string[];
    groups: string[];
    embedding: string | null;
  }>).map<NeighborRow>((r) => ({
    priority_id: r.priority_id,
    thread_id: r.thread_id,
    title: r.title,
    topic: r.topic,
    created_by: r.created_by,
    contacts_expanded: r.contacts_expanded ?? [],
    groups: r.groups ?? [],
    embedding: parseEmbedding(r.embedding),
  }));

  const expandedCandidateContacts = await expandContacts(ctx, candidate.contacts);

  const scored: ScoredNeighbor[] = [];
  const debugTop: ScoringExplain["topNeighbors"] = [];

  for (const n of rows) {
    const values = {
      sem: sem(n.embedding, candidate.embedding),
      con: con(n.contacts_expanded, expandedCandidateContacts),
      grp: grp(n.groups, candidate.groups),
      author: authorSignal(n.created_by, candidate.author),
      topic_fuzzy: topicFuzzy(n.topic, candidate.topic, params.topicFuzzyPrefixWeight),
      title: titleTrigramJaccard(n.title ?? "", candidate.title),
    };
    const combined = combineSignals(values, params.weights, params.nonlinearity);
    scored.push({
      priorityId: n.priority_id,
      threadId: n.thread_id,
      combined,
    });
    debugTop.push({
      priorityId: n.priority_id,
      threadId: n.thread_id,
      sem: round(values.sem),
      con: round(values.con),
      grp: round(values.grp),
      author: round(values.author),
      topic_fuzzy: round(values.topic_fuzzy),
      title: round(values.title),
      combined: round(combined),
    });
  }

  debugTop.sort((a, b) => b.combined - a.combined);
  const topNeighbors = debugTop.slice(0, 10);

  const perPriority = aggregateNeighbors(scored, params.aggregation);
  const explain: ScoringExplain = {
    perPrioritySorted: perPriority.slice(0, 5).map((p) => ({
      priorityId: p.priorityId,
      score: round(p.score),
      neighborCount: p.neighborCount,
    })),
    topNeighbors,
  };

  if (perPriority.length === 0) {
    return { matched: false, explain, top1: null, top2: null };
  }
  const top1 = perPriority[0]!.score;
  const top2 = perPriority[1]?.score ?? -Infinity;
  if (top1 < params.scoreThreshold) {
    return { matched: false, explain, top1, top2: perPriority[1]?.score ?? null };
  }
  return {
    matched: true,
    priorityId: perPriority[0]!.priorityId,
    explain,
    top1,
    top2,
  };
}

async function expandContacts(
  ctx: ClassifierContext,
  contacts: string[]
): Promise<string[]> {
  if (contacts.length === 0) return [];
  const res = await ctx.rawQuery(
    `SELECT public.expand_contacts($1::uuid[]) AS expanded`,
    [contacts]
  );
  return ((res.rows[0] as { expanded: string[] | null } | undefined)?.expanded ??
    []) as string[];
}

function parseEmbedding(s: string | null): number[] | null {
  if (s === null) return null;
  const trimmed = s.replace(/^\[/, "").replace(/\]$/, "");
  if (trimmed === "") return null;
  return trimmed.split(",").map((x) => Number(x));
}

function round(x: number): number {
  return Math.round(x * 10000) / 10000;
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-scoring.ts
git commit -m "Add scoring stage that loads neighbors, scores, aggregates, decides"
```

---

## Task 12: `ts:hybrid` classifier + `registerVariant` helper

**Why:** First end-to-end classifier wiring stages 1–5 + scoring + root fallback. No LLM yet.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid.ts`
- Modify: `libs/eval/src/classifiers/registry.ts`
- Modify: `libs/eval/src/index.ts`

- [ ] **Step 1: Write `makeHybridClassifier`**

Create `libs/eval/src/classifiers/ts-hybrid.ts`:

```ts
import type {
  Candidate,
  ClassificationResult,
  Classifier,
  ClassifierContext,
} from "./types";
import { scoringStage } from "./ts-hybrid-scoring";
import {
  channelDefault,
  keyedPriority,
  priorityPrefix,
  rootFallback,
  topicShortCircuit,
} from "./ts-hybrid-stages";
import { assertValidWeights, type HybridParams } from "./ts-hybrid.defaults";

export function makeHybridClassifier(name: string, params: HybridParams): Classifier {
  assertValidWeights(params.weights);
  return {
    name,
    async classify(ctx: ClassifierContext, candidate: Candidate): Promise<ClassificationResult> {
      const start = performance.now();

      // Stage 1: topic short-circuit
      const ts = await topicShortCircuit(ctx, candidate.topic);
      if (ts) return done(ts, start);

      // Stage 2: cross-user keyed priority
      const kp = await keyedPriority(ctx, candidate.threadId);
      if (kp) return done(kp, start);

      // Stage 3: channel default
      const cd = await channelDefault(ctx, candidate.topic);
      if (cd) return done(cd, start);

      // Stage 4: priority:KEY prefix (moved earlier vs SQL classifier per spec §3.1)
      const pp = await priorityPrefix(ctx, candidate.topic);
      if (pp) return done(pp, start);

      // Stage 5: scoring
      const score = await scoringStage(ctx, candidate, params);
      if (score.matched) {
        return done(
          { priorityId: score.priorityId, stage: "scoring", scores: score.explain },
          start
        );
      }

      // Stage 9: root fallback
      const rf = await rootFallback(ctx);
      if (rf) {
        return done(
          { priorityId: rf.priorityId, stage: "root_fallback", scores: rf.scores },
          start
        );
      }

      return {
        priorityId: null,
        stage: "none",
        scores: {},
        durationMs: performance.now() - start,
        llmCalls: 0,
        cacheHits: 0,
      };
    },
  };
}

function done(
  r: { priorityId: string; stage: string; scores: Record<string, unknown> },
  start: number
): ClassificationResult {
  return {
    priorityId: r.priorityId,
    stage: r.stage,
    scores: r.scores,
    durationMs: performance.now() - start,
    llmCalls: 0,
    cacheHits: 0,
  };
}
```

- [ ] **Step 2: Add `registerVariant` and register default variant**

Replace `libs/eval/src/classifiers/registry.ts` with:

```ts
import { sqlCurrentClassifier } from "./sql-current";
import { makeHybridClassifier } from "./ts-hybrid";
import { DEFAULTS } from "./ts-hybrid.defaults";
import type { Classifier } from "./types";

const REGISTRY: Map<string, Classifier> = new Map();

export function registerClassifier(c: Classifier): void {
  REGISTRY.set(c.name, c);
}

export function registerVariant(name: string, classifier: Classifier): void {
  if (classifier.name !== name) {
    throw new Error(
      `registerVariant: classifier.name "${classifier.name}" must equal name "${name}"`
    );
  }
  REGISTRY.set(name, classifier);
}

export function getClassifier(name: string): Classifier {
  const c = REGISTRY.get(name);
  if (!c) {
    throw new Error(
      `Unknown classifier: ${name}. Registered: ${[...REGISTRY.keys()].join(", ")}`
    );
  }
  return c;
}

export function listClassifiers(): string[] {
  return [...REGISTRY.keys()];
}

// Built-in registrations
registerClassifier(sqlCurrentClassifier);
registerVariant("ts:hybrid:default", makeHybridClassifier("ts:hybrid:default", DEFAULTS));
```

- [ ] **Step 3: Re-export new public types from `index.ts`**

In `libs/eval/src/index.ts`, append:

```ts
export type {
  HybridParams,
  SignalWeights,
  Nonlinearity,
  AggregationMode,
  LlmParams,
} from "./classifiers/ts-hybrid.defaults";
export { DEFAULTS, DEFAULTS_LLM } from "./classifiers/ts-hybrid.defaults";
export { makeHybridClassifier } from "./ts-hybrid";
```

(Correct path: `from "./classifiers/ts-hybrid"`.)

- [ ] **Step 4: Smoke test against synthetic-tiny**

If your worktree DB isn't running: `bash scripts/worktree-db && source .worktree-db`.

Run:
```
cd libs/eval && pnpm exec vitest run tests/sql-current.test.ts
```
Expected: still PASS (sanity — the registry refactor didn't break the existing classifier).

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid.ts libs/eval/src/classifiers/registry.ts libs/eval/src/index.ts
git commit -m "Add ts:hybrid classifier and registerVariant helper"
```

---

## Task 13: Integration tests for `ts:hybrid` against synthetic-tiny

**Why:** Lock in cascade ordering and the matched stage names. Mirrors the existing `sql-current.test.ts`.

**Files:**
- Create: `libs/eval/tests/ts-hybrid-cascade.test.ts`

- [ ] **Step 1: Write the integration test**

```ts
import { describe, expect, it } from "vitest";
import { resolve } from "node:path";

import { runEval } from "../src/runner/run";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

describe.runIf(!!process.env.DATABASE_URL)("ts:hybrid classifier", () => {
  it("matches sql:current on synthetic-tiny stages with full training set", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("002-root-fallback")?.stage).toBe("root_fallback");
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe("topic_shortcircuit");
    expect(byCase.get("004-scoring-contacts")?.stage).toBe("scoring");
    // 005-scoring-no-match has signal below threshold — ts:hybrid should fall back to root.
    expect(byCase.get("005-scoring-no-match")?.stage).toBe("root_fallback");
  }, 60_000);

  it("falls back to non-scoring stages with empty training", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["empty"],
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("002-root-fallback")?.stage).toBe("root_fallback");
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe("root_fallback");
    expect(byCase.get("004-scoring-contacts")?.stage).toBe("root_fallback");
    expect(byCase.get("005-scoring-no-match")?.stage).toBe("root_fallback");
  }, 60_000);

  it("emits scoring explain JSON when scoring matches", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
      caseFilter: (id) => id === "004-scoring-contacts",
    });
    expect(results).toHaveLength(1);
    const r = results[0]!;
    expect(r.stage).toBe("scoring");
    expect(r.scores).toHaveProperty("perPrioritySorted");
    expect(r.scores).toHaveProperty("topNeighbors");
  }, 60_000);

  it("reports zero LLM calls (no LLM stages in ts:hybrid)", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
    });
    for (const r of results) {
      // The runner only forwards counts once Task 19 lands. Until then we just
      // verify that the eval ran end-to-end and a stage was attributed.
      expect(r.stage).not.toBe("none");
    }
  }, 60_000);
});
```

- [ ] **Step 2: Run**

```
cd libs/eval && pnpm exec vitest run tests/ts-hybrid-cascade.test.ts
```
Expected: PASS (DB-dependent — ensure `$DATABASE_URL` is set).

- [ ] **Step 3: Commit**

```bash
git add libs/eval/tests/ts-hybrid-cascade.test.ts
git commit -m "Add integration tests for ts:hybrid against synthetic-tiny"
```

---

## Task 14: LLM client interface + Anthropic-backed default

**Why:** Tie-breaker and cold-start need a place to call. Define the interface so tests can inject a stub.

**Files:**
- Create: `libs/eval/src/classifiers/llm-client.ts`

- [ ] **Step 1: Write the file**

```ts
import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { z } from "zod";

export type LLMInputs = {
  /** System prompt (deterministic per template id). */
  system: string;
  /** User content — case-specific. */
  user: string;
  /** Allowed priority IDs that the model may return. */
  allowedPriorityIds: string[];
};

export type LLMOutput = {
  priorityId: string | null;
  rationale: string;
};

export interface LLMClient {
  /** Stable identifier (used in cache key — include model + provider). */
  id: string;
  classify(inputs: LLMInputs): Promise<LLMOutput>;
}

const ResponseSchema = z.object({
  priority_id: z.string().nullable(),
  rationale: z.string().default(""),
});

export function makeAnthropicClient(model: string): LLMClient {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    throw new Error(
      "makeAnthropicClient: ANTHROPIC_API_KEY env var is required to call the real Anthropic API."
    );
  }
  const anthropic = createAnthropic({ apiKey });
  return {
    id: `anthropic:${model}`,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      const allowed = new Set(inputs.allowedPriorityIds);
      const result = await generateObject({
        model: anthropic(model),
        schema: ResponseSchema,
        system: inputs.system,
        prompt: inputs.user,
        temperature: 0,
      });
      const obj = result.object;
      const pid = obj.priority_id;
      if (pid !== null && !allowed.has(pid)) {
        // Model returned an out-of-set id — treat as no answer.
        return { priorityId: null, rationale: `out-of-set priorityId returned: ${pid}` };
      }
      return { priorityId: pid, rationale: obj.rationale };
    },
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/llm-client.ts
git commit -m "Add LLMClient interface and Anthropic-backed implementation"
```

---

## Task 15: File-backed LLM cache

**Why:** Eval iteration must not pay per-token costs every run. Cache responses keyed on `(model, promptTemplateId, normalized inputs)`.

**Files:**
- Create: `libs/eval/src/classifiers/llm-cache.ts`
- Create: `libs/eval/tests/llm-cache.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
import { describe, expect, it } from "vitest";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { cachedLlmClient, hashInputs } from "../src/classifiers/llm-cache";
import type { LLMClient, LLMInputs } from "../src/classifiers/llm-client";

const baseInputs: LLMInputs = {
  system: "sys",
  user: "user",
  allowedPriorityIds: ["P2", "P1"],
};

describe("hashInputs", () => {
  it("is stable across allowed-priority order", () => {
    const a = hashInputs("model", "tmpl", baseInputs);
    const b = hashInputs("model", "tmpl", {
      ...baseInputs,
      allowedPriorityIds: ["P1", "P2"],
    });
    expect(a).toBe(b);
  });
  it("differs when prompt id changes", () => {
    expect(hashInputs("model", "t1", baseInputs)).not.toBe(
      hashInputs("model", "t2", baseInputs)
    );
  });
  it("differs when model changes", () => {
    expect(hashInputs("m1", "t", baseInputs)).not.toBe(
      hashInputs("m2", "t", baseInputs)
    );
  });
});

describe("cachedLlmClient", () => {
  it("returns cached response on second call and persists to disk", async () => {
    const dir = await mkdtemp(join(tmpdir(), "llm-cache-"));
    let calls = 0;
    const stub: LLMClient = {
      id: "stub",
      async classify() {
        calls++;
        return { priorityId: "P1", rationale: "r" };
      },
    };
    const wrapped = cachedLlmClient({
      client: stub,
      cacheDir: dir,
      namespace: "test",
      promptTemplateId: "tiebreaker-v1",
    });

    const a = await wrapped.classify(baseInputs);
    const b = await wrapped.classify(baseInputs);
    expect(a).toEqual(b);
    expect(calls).toBe(1);
    expect(wrapped.stats.misses).toBe(1);
    expect(wrapped.stats.hits).toBe(1);

    const hash = hashInputs(stub.id, "tiebreaker-v1", baseInputs);
    const file = join(dir, "test", `${hash}.json`);
    const text = await readFile(file, "utf-8");
    expect(JSON.parse(text)).toMatchObject({
      response: { priorityId: "P1", rationale: "r" },
      promptTemplateId: "tiebreaker-v1",
    });
  });
});
```

- [ ] **Step 2: Run to confirm failure**

```
cd libs/eval && pnpm exec vitest run tests/llm-cache.test.ts
```
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `libs/eval/src/classifiers/llm-cache.ts`:

```ts
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { LLMClient, LLMInputs, LLMOutput } from "./llm-client";

export type CachedLlmClient = LLMClient & {
  stats: { hits: number; misses: number };
};

export function hashInputs(
  model: string,
  promptTemplateId: string,
  inputs: LLMInputs
): string {
  const normalized = {
    model,
    promptTemplateId,
    system: inputs.system,
    user: inputs.user,
    allowedPriorityIds: [...inputs.allowedPriorityIds].sort(),
  };
  return createHash("sha256").update(JSON.stringify(normalized)).digest("hex");
}

export type CacheOpts = {
  client: LLMClient;
  cacheDir: string;
  namespace: string;
  promptTemplateId: string;
};

export function cachedLlmClient(opts: CacheOpts): CachedLlmClient {
  const stats = { hits: 0, misses: 0 };
  const nsDir = join(opts.cacheDir, opts.namespace);
  return {
    id: opts.client.id,
    stats,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      const h = hashInputs(opts.client.id, opts.promptTemplateId, inputs);
      const path = join(nsDir, `${h}.json`);
      try {
        const text = await readFile(path, "utf-8");
        const parsed = JSON.parse(text) as { response: LLMOutput };
        stats.hits++;
        return parsed.response;
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
      }
      const response = await opts.client.classify(inputs);
      stats.misses++;
      await mkdir(nsDir, { recursive: true });
      await writeFile(
        path,
        JSON.stringify(
          {
            inputHash: h,
            model: opts.client.id,
            promptTemplateId: opts.promptTemplateId,
            response,
            timestamp: new Date().toISOString(),
          },
          null,
          2
        )
      );
      return response;
    },
  };
}
```

- [ ] **Step 4: Run to confirm passing**

```
cd libs/eval && pnpm exec vitest run tests/llm-cache.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/classifiers/llm-cache.ts libs/eval/tests/llm-cache.test.ts
git commit -m "Add file-backed LLM response cache"
```

---

## Task 16: Prompt templates + loader

**Why:** Versioned prompts live in text files. Provide a typed loader.

**Files:**
- Create: `libs/eval/src/classifiers/prompts/tiebreaker-v1.txt`
- Create: `libs/eval/src/classifiers/prompts/coldstart-v1.txt`
- Create: `libs/eval/src/classifiers/prompts/index.ts`

- [ ] **Step 1: Tie-breaker prompt**

Write `libs/eval/src/classifiers/prompts/tiebreaker-v1.txt`:

```
You are a thread classifier. Given one candidate thread and a short list of
candidate priorities (each with one or two exemplar threads), pick the priority
that best matches the candidate.

Inputs:
- The candidate thread (title, topic, contact names, optional note preview).
- The candidate priorities, each with id, title, path, and one or two
  exemplars (title, topic, contacts).

Output JSON only, matching this shape:
{
  "priority_id": "<one of the listed priority ids, or null if none fit>",
  "rationale": "<one sentence>"
}

Rules:
- Return EXACTLY one of the listed priority ids, or null. Do not invent ids.
- If none of the priorities is a reasonable fit, return null.
- Keep the rationale to one short sentence.
```

- [ ] **Step 2: Cold-start prompt**

Write `libs/eval/src/classifiers/prompts/coldstart-v1.txt`:

```
You are a thread classifier. The user has just started using the product and
has not yet filed any threads themselves. Given a candidate thread and the
user's priority tree, pick the priority that best matches.

Inputs:
- The user's priority tree as a list of (id, title, path, optional key).
- The candidate thread (title, topic, contact names, optional note preview).

Output JSON only, matching this shape:
{
  "priority_id": "<one of the listed priority ids, or null if none fit>",
  "rationale": "<one sentence>"
}

Rules:
- Return EXACTLY one of the listed priority ids, or null. Do not invent ids.
- If none of the priorities is a reasonable fit, return null.
- Prefer specific child priorities over generic root priorities when the topic
  obviously narrows the scope.
- Keep the rationale to one short sentence.
```

- [ ] **Step 3: Loader**

Write `libs/eval/src/classifiers/prompts/index.ts`:

```ts
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const PROMPT_DIR = dirname(fileURLToPath(import.meta.url));

const cache = new Map<string, string>();

export async function loadPrompt(id: string): Promise<string> {
  const cached = cache.get(id);
  if (cached) return cached;
  const path = join(PROMPT_DIR, `${id}.txt`);
  const text = await readFile(path, "utf-8");
  cache.set(id, text);
  return text;
}
```

- [ ] **Step 4: Commit**

```bash
git add libs/eval/src/classifiers/prompts/
git commit -m "Add tie-breaker and cold-start prompt templates"
```

---

## Task 17: Tie-breaker stage

**Why:** Scoring-ambiguous cases hand off to the LLM. Gates are spec §5.1.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-tiebreaker.ts`

- [ ] **Step 1: Write the module**

```ts
import type { Candidate, ClassifierContext } from "./types";
import type { LLMClient, LLMOutput } from "./llm-client";
import { loadPrompt } from "./prompts";
import type { ScoringOutcome } from "./ts-hybrid-scoring";
import type { HybridParams } from "./ts-hybrid.defaults";

export type TieBreakerInputs = {
  ctx: ClassifierContext;
  candidate: Candidate;
  scoring: Extract<ScoringOutcome, { matched: true }>;
  params: HybridParams;
  llmClient: LLMClient;
};

export type TieBreakerResult =
  | { fired: false }
  | { fired: true; output: LLMOutput };

export function shouldRunTieBreaker(
  scoring: Extract<ScoringOutcome, { matched: true }>,
  params: HybridParams,
  supportingNeighborCount: number
): boolean {
  const inSoftBand =
    scoring.top1 >= params.scoreThreshold &&
    scoring.top1 <= params.highConfidenceFloor;
  const closeCall =
    scoring.top1 - (scoring.top2 ?? -Infinity) < params.marginFloor;
  const fewSupporting = supportingNeighborCount < params.nSupportingNeighbors;
  // Spec §5.1: both soft-band AND close-call must trip, OR the third "few
  // supporting neighbors" guard fires at any absolute score.
  return (inSoftBand && closeCall) || fewSupporting;
}

export async function runTieBreaker(
  inputs: TieBreakerInputs
): Promise<TieBreakerResult> {
  const { ctx, candidate, scoring, params, llmClient } = inputs;
  if (!params.llm?.tieBreaker.enabled) return { fired: false };
  const supporting = scoring.explain.topNeighbors.filter(
    (n) =>
      n.priorityId === scoring.priorityId && n.combined >= params.supportingFloor
  ).length;
  if (!shouldRunTieBreaker(scoring, params, supporting)) {
    return { fired: false };
  }

  const candidates = scoring.explain.perPrioritySorted.slice(
    0,
    params.llm.tieBreaker.maxCandidates
  );
  if (candidates.length === 0) return { fired: false };

  const allowedPriorityIds = candidates.map((c) => c.priorityId);
  const system = await loadPrompt(params.llm.tieBreaker.promptId);
  const user = await buildTieBreakerPrompt(
    ctx,
    candidate,
    candidates.map((c) => c.priorityId),
    scoring.explain.topNeighbors
  );

  const output = await llmClient.classify({ system, user, allowedPriorityIds });
  return { fired: true, output };
}

async function buildTieBreakerPrompt(
  ctx: ClassifierContext,
  candidate: Candidate,
  candidatePriorityIds: string[],
  topNeighbors: { priorityId: string; threadId: string; combined: number }[]
): Promise<string> {
  const priorities = await fetchPriorities(ctx, candidatePriorityIds);
  const exemplarsByPriority = await fetchExemplars(ctx, topNeighbors);
  const contactNames = await fetchContactNames(ctx, candidate.contacts);

  const lines: string[] = [];
  lines.push(`Candidate thread:`);
  lines.push(`  title: ${candidate.title}`);
  lines.push(`  topic: ${candidate.topic ?? "(none)"}`);
  lines.push(`  contacts: ${contactNames.join(", ") || "(none)"}`);
  lines.push("");
  lines.push(`Candidate priorities:`);
  for (const p of priorities) {
    lines.push(`- id: ${p.id}`);
    lines.push(`  title: ${p.title}`);
    lines.push(`  path: ${p.path}`);
    if (p.key) lines.push(`  key: ${p.key}`);
    const exemplars = (exemplarsByPriority.get(p.id) ?? []).slice(0, 2);
    if (exemplars.length > 0) {
      lines.push(`  exemplars:`);
      for (const e of exemplars) {
        lines.push(`    - title: ${e.title ?? "(no title)"}`);
        if (e.topic) lines.push(`      topic: ${e.topic}`);
      }
    }
  }
  return lines.join("\n");
}

async function fetchPriorities(
  ctx: ClassifierContext,
  ids: string[]
): Promise<{ id: string; title: string; path: string; key: string | null }[]> {
  if (ids.length === 0) return [];
  const res = await ctx.rawQuery(
    `SELECT id, title, path::text AS path, key
       FROM public.priority
      WHERE id = ANY($1::uuid[])
        AND archived_at IS NULL`,
    [ids]
  );
  return res.rows as { id: string; title: string; path: string; key: string | null }[];
}

async function fetchExemplars(
  ctx: ClassifierContext,
  topNeighbors: { priorityId: string; threadId: string }[]
): Promise<Map<string, { title: string | null; topic: string | null }[]>> {
  const ids = [...new Set(topNeighbors.map((n) => n.threadId))];
  if (ids.length === 0) return new Map();
  const res = await ctx.rawQuery(
    `SELECT t.id, t.title, t.topic, tp.priority_id
       FROM public.thread t
       JOIN public.thread_priority tp ON tp.thread_id = t.id
      WHERE t.id = ANY($1::uuid[])
        AND tp.user_id = $2::uuid`,
    [ids, ctx.userId]
  );
  const out = new Map<string, { title: string | null; topic: string | null }[]>();
  for (const r of res.rows as {
    id: string;
    title: string | null;
    topic: string | null;
    priority_id: string;
  }[]) {
    const list = out.get(r.priority_id) ?? [];
    list.push({ title: r.title, topic: r.topic });
    out.set(r.priority_id, list);
  }
  return out;
}

async function fetchContactNames(
  ctx: ClassifierContext,
  contactIds: string[]
): Promise<string[]> {
  if (contactIds.length === 0) return [];
  const res = await ctx.rawQuery(
    `SELECT COALESCE(name, email, id::text) AS display
       FROM public.contact
      WHERE id = ANY($1::uuid[])`,
    [contactIds]
  );
  return (res.rows as { display: string }[]).map((r) => r.display);
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-tiebreaker.ts
git commit -m "Add LLM tie-breaker stage with gating and prompt assembly"
```

---

## Task 18: Deterministic cold-start shortcuts

**Why:** Before the LLM cold-start, try cheap signals (twist-author mapping, contact-only history, single-priority bypass).

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-shortcuts.ts`

- [ ] **Step 1: Write the module**

```ts
import type { Candidate, ClassifierContext } from "./types";
import type { HybridParams } from "./ts-hybrid.defaults";

type ShortcutHit = { priorityId: string; stage: string; scores: Record<string, unknown> } | null;

export async function twistAuthorShortcut(
  ctx: ClassifierContext,
  candidate: Candidate,
  params: HybridParams
): Promise<ShortcutHit> {
  if (!params.shortcuts.twistAuthor.enabled) return null;
  if (candidate.author === null) return null;

  // Confirm the author is a twist_instance. We don't store that mapping in
  // the eval sandbox; this query is a graceful no-op when nothing matches.
  const isTwist = await ctx.rawQuery(
    `SELECT 1 FROM public.twist_instance WHERE id = $1::uuid LIMIT 1`,
    [candidate.author]
  );
  if (isTwist.rows.length === 0) return null;

  const res = await ctx.rawQuery(
    `SELECT tp.priority_id, COUNT(*)::int AS n
       FROM public.thread_priority tp
       JOIN public.thread t ON t.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND t.created_by = $2::uuid
        AND t.archived_at IS NULL
      GROUP BY tp.priority_id`,
    [ctx.userId, candidate.author]
  );
  const rows = res.rows as { priority_id: string; n: number }[];
  const total = rows.reduce((a, r) => a + r.n, 0);
  if (total < params.shortcuts.twistAuthor.minSamples) return null;
  rows.sort((a, b) => b.n - a.n);
  const top = rows[0]!;
  if (top.n / total < params.shortcuts.twistAuthor.agreement) return null;
  return {
    priorityId: top.priority_id,
    stage: "twist_author_shortcut",
    scores: { samples: total, agreement: top.n / total },
  };
}

export async function contactHistoryShortcut(
  ctx: ClassifierContext,
  candidate: Candidate,
  params: HybridParams
): Promise<ShortcutHit> {
  if (!params.shortcuts.contactHistory.enabled) return null;
  if (candidate.contacts.length === 0) return null;
  const res = await ctx.rawQuery(
    `SELECT DISTINCT tp.priority_id, COUNT(*)::int AS n
       FROM public.thread_priority tp
       JOIN public.thread t ON t.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND t.archived_at IS NULL
        AND t.contacts && $2::uuid[]
      GROUP BY tp.priority_id`,
    [ctx.userId, candidate.contacts]
  );
  const rows = res.rows as { priority_id: string; n: number }[];
  if (rows.length !== 1) return null;
  if (rows[0]!.n < params.shortcuts.contactHistory.minSamples) return null;
  return {
    priorityId: rows[0]!.priority_id,
    stage: "contact_history_shortcut",
    scores: { samples: rows[0]!.n },
  };
}

export async function singlePriorityBypass(
  ctx: ClassifierContext,
  params: HybridParams
): Promise<ShortcutHit> {
  if (!params.shortcuts.singlePriorityBypass.enabled) return null;
  const res = await ctx.rawQuery(
    `SELECT id, path::text AS path
       FROM public.priority
      WHERE user_id = $1::uuid
        AND archived_at IS NULL
      ORDER BY nlevel(path), created_at`,
    [ctx.userId]
  );
  const rows = res.rows as { id: string; path: string }[];
  if (rows.length === 0) return null;
  // "Only a root priority, or one non-root priority" — i.e. at most 2 rows
  // with exactly one root.
  if (rows.length > 2) return null;
  return {
    priorityId: rows[rows.length - 1]!.id,
    stage: "single_priority_bypass",
    scores: { priorityCount: rows.length },
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-shortcuts.ts
git commit -m "Add deterministic cold-start shortcuts (twist-author, contact-history, single-priority)"
```

---

## Task 19: LLM cold-start stage

**Why:** Last resort before root fallback. Loads the user's priority tree, optionally truncates, prompts the LLM.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-coldstart.ts`

- [ ] **Step 1: Write the module**

```ts
import type { Candidate, ClassifierContext } from "./types";
import type { LLMClient, LLMOutput } from "./llm-client";
import { loadPrompt } from "./prompts";
import type { HybridParams } from "./ts-hybrid.defaults";

export type ColdStartInputs = {
  ctx: ClassifierContext;
  candidate: Candidate;
  params: HybridParams;
  llmClient: LLMClient;
};

export type ColdStartResult =
  | { fired: false }
  | { fired: true; output: LLMOutput; consideredPriorityCount: number };

export async function runColdStart(
  inputs: ColdStartInputs
): Promise<ColdStartResult> {
  const { ctx, candidate, params, llmClient } = inputs;
  if (!params.llm?.coldStart.enabled) return { fired: false };

  const priorities = await fetchPriorityTree(ctx);
  if (priorities.length < 3) {
    // Spec §5.3: skip when fewer than two non-root priorities exist (root + 1).
    return { fired: false };
  }

  const candidatePool = truncatePriorities(
    priorities,
    candidate,
    params.llm.coldStart.maxPrioritiesInPrompt
  );
  const allowedPriorityIds = candidatePool.map((p) => p.id);

  const system = await loadPrompt(params.llm.coldStart.promptId);
  const user = renderColdStartPrompt(candidate, candidatePool);
  const output = await llmClient.classify({ system, user, allowedPriorityIds });
  return { fired: true, output, consideredPriorityCount: candidatePool.length };
}

type PriorityNode = {
  id: string;
  title: string;
  path: string;
  key: string | null;
  depth: number;
};

async function fetchPriorityTree(ctx: ClassifierContext): Promise<PriorityNode[]> {
  const res = await ctx.rawQuery(
    `SELECT id, title, path::text AS path, key, nlevel(path) AS depth
       FROM public.priority
      WHERE user_id = $1::uuid
        AND archived_at IS NULL
      ORDER BY nlevel(path), created_at`,
    [ctx.userId]
  );
  return (res.rows as {
    id: string;
    title: string;
    path: string;
    key: string | null;
    depth: number;
  }[]).map((r) => ({ ...r, depth: Number(r.depth) }));
}

function truncatePriorities(
  priorities: PriorityNode[],
  candidate: Candidate,
  max: number
): PriorityNode[] {
  if (priorities.length <= max) return priorities;
  const candidateTokens = tokenize(candidate.title + " " + (candidate.topic ?? ""));
  const scored = priorities.map((p) => {
    const pathTokens = tokenize(p.path.replace(/\./g, " ") + " " + p.title);
    let overlap = 0;
    for (const t of candidateTokens) if (pathTokens.has(t)) overlap++;
    return { p, overlap };
  });
  const depthOne = scored.filter((s) => s.p.depth === 1).map((s) => s.p);
  const tokenMatched = scored
    .filter((s) => s.overlap > 0 && s.p.depth > 1)
    .sort((a, b) => b.overlap - a.overlap)
    .map((s) => s.p);
  const out: PriorityNode[] = [];
  const seen = new Set<string>();
  for (const p of [...depthOne, ...tokenMatched]) {
    if (seen.has(p.id)) continue;
    seen.add(p.id);
    out.push(p);
    if (out.length >= max) break;
  }
  return out;
}

function tokenize(s: string): Set<string> {
  return new Set(
    s
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t.length >= 3)
  );
}

function renderColdStartPrompt(
  candidate: Candidate,
  pool: PriorityNode[]
): string {
  const lines: string[] = [];
  lines.push(`Candidate thread:`);
  lines.push(`  title: ${candidate.title}`);
  lines.push(`  topic: ${candidate.topic ?? "(none)"}`);
  lines.push("");
  lines.push(`Priority tree (${pool.length} priorities):`);
  for (const p of pool) {
    const breadcrumbs = p.path.replace(/\./g, " > ");
    lines.push(
      `- id: ${p.id}  title: ${p.title}  path: ${breadcrumbs}${p.key ? `  key: ${p.key}` : ""}`
    );
  }
  return lines.join("\n");
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-coldstart.ts
git commit -m "Add LLM cold-start stage with priority-tree truncation"
```

---

## Task 20: `ts:hybrid-llm` classifier + variants

**Why:** Compose the cascade with LLM stages 6 and 8 and per-user budget tracking. Register variants.

**Files:**
- Create: `libs/eval/src/classifiers/ts-hybrid-llm.ts`
- Modify: `libs/eval/src/classifiers/registry.ts`
- Modify: `libs/eval/src/index.ts`

- [ ] **Step 1: Write the LLM classifier**

```ts
import { join } from "node:path";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import type { Candidate, ClassificationResult, Classifier, ClassifierContext } from "./types";
import type { LLMClient } from "./llm-client";
import { makeAnthropicClient } from "./llm-client";
import { cachedLlmClient } from "./llm-cache";
import { runTieBreaker } from "./ts-hybrid-tiebreaker";
import {
  contactHistoryShortcut,
  singlePriorityBypass,
  twistAuthorShortcut,
} from "./ts-hybrid-shortcuts";
import { runColdStart } from "./ts-hybrid-coldstart";
import { scoringStage } from "./ts-hybrid-scoring";
import {
  channelDefault,
  keyedPriority,
  priorityPrefix,
  rootFallback,
  topicShortCircuit,
} from "./ts-hybrid-stages";
import { assertValidWeights, type HybridParams } from "./ts-hybrid.defaults";

const ROOT = dirname(fileURLToPath(import.meta.url));
const CACHE_DIR = join(ROOT, "..", "..", ".cache", "llm");

export type MakeHybridLlmOpts = {
  params: HybridParams;
  /** Inject for tests. When omitted, builds an Anthropic-backed client wrapped in the file cache. */
  llmClient?: LLMClient;
  /** Override cache dir for tests. */
  cacheDir?: string;
};

const budget = new Map<string, { date: string; count: number }>();

function consumeBudget(userId: string, dailyMax: number): boolean {
  const today = new Date().toISOString().slice(0, 10);
  const cur = budget.get(userId);
  if (!cur || cur.date !== today) {
    budget.set(userId, { date: today, count: 1 });
    return 1 <= dailyMax;
  }
  cur.count++;
  return cur.count <= dailyMax;
}

export function makeHybridLlmClassifier(
  name: string,
  opts: MakeHybridLlmOpts
): Classifier {
  assertValidWeights(opts.params.weights);
  if (!opts.params.llm) {
    throw new Error(`makeHybridLlmClassifier: params.llm is required for "${name}"`);
  }

  const llm = opts.params.llm;
  const cacheDir = opts.cacheDir ?? CACHE_DIR;

  const tieBreakerClient: LLMClient =
    opts.llmClient ??
    cachedLlmClient({
      client: makeAnthropicClient(llm.model),
      cacheDir,
      namespace: llm.cacheNamespace,
      promptTemplateId: llm.tieBreaker.promptId,
    });

  const coldStartClient: LLMClient =
    opts.llmClient ??
    cachedLlmClient({
      client: makeAnthropicClient(llm.model),
      cacheDir,
      namespace: llm.cacheNamespace,
      promptTemplateId: llm.coldStart.promptId,
    });

  return {
    name,
    async classify(ctx: ClassifierContext, candidate: Candidate): Promise<ClassificationResult> {
      const start = performance.now();
      let llmCalls = 0;
      let cacheHits = 0;
      const observe = (client: LLMClient) => {
        const stats = (client as { stats?: { hits: number; misses: number } }).stats;
        if (!stats) return;
        llmCalls += stats.misses;
        cacheHits += stats.hits;
        stats.hits = 0;
        stats.misses = 0;
      };

      // Deterministic stages 1-4
      const ts = await topicShortCircuit(ctx, candidate.topic);
      if (ts) return finish(ts);
      const kp = await keyedPriority(ctx, candidate.threadId);
      if (kp) return finish(kp);
      const cd = await channelDefault(ctx, candidate.topic);
      if (cd) return finish(cd);
      const pp = await priorityPrefix(ctx, candidate.topic);
      if (pp) return finish(pp);

      // Stage 5: scoring
      const score = await scoringStage(ctx, candidate, opts.params);

      // Stage 6: tie-breaker — only when scoring matched but ambiguously
      if (score.matched) {
        if (llm.tieBreaker.enabled && consumeBudget(ctx.userId, llm.dailyBudgetPerUser)) {
          const tb = await runTieBreaker({
            ctx,
            candidate,
            scoring: score,
            params: opts.params,
            llmClient: tieBreakerClient,
          });
          observe(tieBreakerClient);
          if (tb.fired && tb.output.priorityId !== null) {
            return finish({
              priorityId: tb.output.priorityId,
              stage: "llm_tiebreaker",
              scores: { rationale: tb.output.rationale, scoring: score.explain },
            });
          }
        }
        return finish({
          priorityId: score.priorityId,
          stage: "scoring",
          scores: score.explain,
        });
      }

      // Stage 7: deterministic cold-start shortcuts
      const ts1 = await twistAuthorShortcut(ctx, candidate, opts.params);
      if (ts1) return finish(ts1);
      const ts2 = await contactHistoryShortcut(ctx, candidate, opts.params);
      if (ts2) return finish(ts2);
      const ts3 = await singlePriorityBypass(ctx, opts.params);
      if (ts3) return finish(ts3);

      // Stage 8: LLM cold-start
      if (llm.coldStart.enabled && consumeBudget(ctx.userId, llm.dailyBudgetPerUser)) {
        const cs = await runColdStart({
          ctx,
          candidate,
          params: opts.params,
          llmClient: coldStartClient,
        });
        observe(coldStartClient);
        if (cs.fired && cs.output.priorityId !== null) {
          return finish({
            priorityId: cs.output.priorityId,
            stage: "llm_coldstart",
            scores: { rationale: cs.output.rationale, considered: cs.consideredPriorityCount },
          });
        }
      }

      // Stage 9: root fallback
      const rf = await rootFallback(ctx);
      if (rf) return finish({ priorityId: rf.priorityId, stage: "root_fallback", scores: rf.scores });
      return finish({ priorityId: null, stage: "none", scores: {} });

      function finish(r: {
        priorityId: string | null;
        stage: string;
        scores: Record<string, unknown>;
      }): ClassificationResult {
        return {
          priorityId: r.priorityId,
          stage: r.stage,
          scores: r.scores,
          durationMs: performance.now() - start,
          llmCalls,
          cacheHits,
        };
      }
    },
  };
}
```

- [ ] **Step 2: Register variants**

Edit `libs/eval/src/classifiers/registry.ts`, append at the bottom (after the existing registrations):

```ts
import { makeHybridLlmClassifier } from "./ts-hybrid-llm";
import { DEFAULTS_LLM } from "./ts-hybrid.defaults";

registerVariant(
  "ts:hybrid-llm:default",
  makeHybridLlmClassifier("ts:hybrid-llm:default", { params: DEFAULTS_LLM })
);
registerVariant(
  "ts:hybrid-llm:tight-gates",
  makeHybridLlmClassifier("ts:hybrid-llm:tight-gates", {
    params: {
      ...DEFAULTS_LLM,
      highConfidenceFloor: 0.55,
      marginFloor: 0.12,
    },
  })
);
```

Move both imports to the top of the file with the existing imports.

- [ ] **Step 3: Re-export from `index.ts`**

Append to `libs/eval/src/index.ts`:

```ts
export { makeHybridLlmClassifier } from "./classifiers/ts-hybrid-llm";
export type { LLMClient, LLMInputs, LLMOutput } from "./classifiers/llm-client";
```

- [ ] **Step 4: Commit**

```bash
git add libs/eval/src/classifiers/ts-hybrid-llm.ts libs/eval/src/classifiers/registry.ts libs/eval/src/index.ts
git commit -m "Add ts:hybrid-llm classifier with tie-breaker, shortcuts, and cold-start"
```

---

## Task 21: LLM-stage unit tests with stub client

**Why:** Exercise the gates and the cascade ordering without touching the network.

**Files:**
- Create: `libs/eval/tests/ts-hybrid-llm.test.ts`

- [ ] **Step 1: Write the test file**

```ts
import { describe, expect, it } from "vitest";

import { shouldRunTieBreaker } from "../src/classifiers/ts-hybrid-tiebreaker";
import { DEFAULTS_LLM } from "../src/classifiers/ts-hybrid.defaults";
import type { LLMClient, LLMInputs } from "../src/classifiers/llm-client";

const baseScoring = {
  matched: true as const,
  priorityId: "P1",
  explain: {
    perPrioritySorted: [
      { priorityId: "P1", score: 0.3, neighborCount: 2 },
      { priorityId: "P2", score: 0.25, neighborCount: 1 },
    ],
    topNeighbors: [
      {
        priorityId: "P1",
        threadId: "T1",
        sem: 0.3,
        con: 0,
        grp: 0,
        author: 0,
        topic_fuzzy: 0,
        title: 0,
        combined: 0.3,
      },
      {
        priorityId: "P1",
        threadId: "T2",
        sem: 0.3,
        con: 0,
        grp: 0,
        author: 0,
        topic_fuzzy: 0,
        title: 0,
        combined: 0.3,
      },
    ],
  },
  top1: 0.3,
  top2: 0.25,
};

describe("shouldRunTieBreaker gates", () => {
  it("fires in the soft band with a close call", () => {
    expect(
      shouldRunTieBreaker(baseScoring, DEFAULTS_LLM, /* supporting */ 2)
    ).toBe(true);
  });

  it("does NOT fire above highConfidenceFloor with enough supporting neighbors", () => {
    const high = { ...baseScoring, top1: 0.6, top2: 0.4 };
    expect(shouldRunTieBreaker(high, DEFAULTS_LLM, 2)).toBe(false);
  });

  it("fires whenever supporting neighbors below threshold (third gate)", () => {
    const confident = { ...baseScoring, top1: 0.7, top2: 0.1 };
    expect(shouldRunTieBreaker(confident, DEFAULTS_LLM, /* supporting */ 0)).toBe(true);
  });

  it("does NOT fire on a wide margin even in the soft band", () => {
    const wide = { ...baseScoring, top1: 0.3, top2: 0.05 };
    expect(shouldRunTieBreaker(wide, DEFAULTS_LLM, 2)).toBe(false);
  });
});

describe("LLM stub client interface", () => {
  it("can be wired without making network calls", async () => {
    const calls: LLMInputs[] = [];
    const stub: LLMClient = {
      id: "stub",
      async classify(inputs) {
        calls.push(inputs);
        return { priorityId: inputs.allowedPriorityIds[0] ?? null, rationale: "stub" };
      },
    };
    const out = await stub.classify({
      system: "sys",
      user: "u",
      allowedPriorityIds: ["P1", "P2"],
    });
    expect(out.priorityId).toBe("P1");
    expect(calls).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run**

```
cd libs/eval && pnpm exec vitest run tests/ts-hybrid-llm.test.ts
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add libs/eval/tests/ts-hybrid-llm.test.ts
git commit -m "Add unit tests for tie-breaker gates and LLM stub interface"
```

---

## Task 22: Propagate LLM counts into `RunResult` and `RunSummary`

**Why:** The eval framework needs the per-cell counters. Spec §7.1.

**Files:**
- Modify: `libs/eval/src/runner/run.ts`

- [ ] **Step 1: Add fields to `RunResult` and `RunSummary`**

Edit `libs/eval/src/runner/run.ts`. In `RunResult`, add:

```ts
  llmCalls: number;
  cacheHits: number;
```

In `RunSummary.perClassifierTraining[]`, add:

```ts
    llmCallsPerCase: number;
    llmCacheHitRate: number | null;
```

- [ ] **Step 2: Read counts from classifier result**

In `runOneCase`, change the returned object to include:

```ts
    llmCalls: result.llmCalls,
    cacheHits: result.cacheHits,
```

- [ ] **Step 3: Compute summary fields**

In `summarize`, after computing `regressions`, add:

```ts
      const totalLlm = rows.reduce((s, r) => s + r.llmCalls, 0);
      const totalHits = rows.reduce((s, r) => s + r.cacheHits, 0);
      const totalAttempts = totalLlm + totalHits;
      perClassifierTraining.push({
        classifier: c,
        trainingSet: ts.name,
        goldAccuracy:
          goldEval.length > 0
            ? goldEval.filter((r) => r.goldMatch).length / goldEval.length
            : null,
        expectedAccuracy:
          expectedEval.length > 0
            ? expectedEval.filter((r) => r.expectedMatch).length / expectedEval.length
            : null,
        regressions: expectedEval.filter((r) => r.expectedMatch === false).length,
        avgDurationMs:
          rows.length > 0
            ? rows.reduce((sum, r) => sum + r.durationMs, 0) / rows.length
            : 0,
        llmCallsPerCase: rows.length > 0 ? totalLlm / rows.length : 0,
        llmCacheHitRate: totalAttempts > 0 ? totalHits / totalAttempts : null,
      });
```

(Replace the entire existing `perClassifierTraining.push({...})` block with this.)

- [ ] **Step 4: Verify existing tests still pass**

Run: `cd libs/eval && DATABASE_URL=$DATABASE_URL pnpm exec vitest run tests/sql-current.test.ts tests/ts-hybrid-cascade.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/eval/src/runner/run.ts
git commit -m "Propagate LLM call counts and cache hit rate into RunSummary"
```

---

## Task 23: Render LLM columns in the report

**Why:** Spec §7.1 Pareto view. Add columns to markdown and console.

**Files:**
- Modify: `libs/eval/src/scoring/report.ts`

- [ ] **Step 1: Update markdown table**

In `renderMarkdown`, replace the header / row lines:

```ts
  lines.push(
    "| Classifier | Training set | Gold acc. | Expected acc. | Regressions | LLM calls / case | Cache hit rate | Avg ms |"
  );
  lines.push("| --- | --- | --- | --- | --- | --- | --- | --- |");
  for (const c of summary.perClassifierTraining) {
    lines.push(
      `| \`${c.classifier}\` | \`${c.trainingSet}\` | ${pct(c.goldAccuracy)} | ${pct(
        c.expectedAccuracy
      )} | ${c.regressions} | ${c.llmCallsPerCase.toFixed(2)} | ${pct(
        c.llmCacheHitRate
      )} | ${c.avgDurationMs.toFixed(1)} |`
    );
  }
```

- [ ] **Step 2: Update console table**

In `renderConsole`, replace the header / row lines:

```ts
  lines.push(
    "Classifier           Training         Gold     Expected  Regress  LLM/case  Hit%   AvgMs"
  );
  lines.push(
    "-------------------- ---------------  -------  --------  -------  --------  -----  -----"
  );
  for (const c of summary.perClassifierTraining) {
    lines.push(
      [
        c.classifier.padEnd(20),
        c.trainingSet.padEnd(15),
        pct(c.goldAccuracy).padStart(7),
        pct(c.expectedAccuracy).padStart(8),
        String(c.regressions).padStart(7),
        c.llmCallsPerCase.toFixed(2).padStart(8),
        pct(c.llmCacheHitRate).padStart(5),
        c.avgDurationMs.toFixed(1).padStart(5),
      ].join("  ")
    );
  }
```

- [ ] **Step 3: Smoke test the CLI**

```
cd libs/eval && DATABASE_URL=$DATABASE_URL pnpm exec tsx src/cli.ts --corpus synthetic-tiny --classifiers sql:current,ts:hybrid:default
```
Expected: prints a console-formatted table with the new columns.

- [ ] **Step 4: Commit**

```bash
git add libs/eval/src/scoring/report.ts
git commit -m "Render LLM-call and cache-hit columns in eval report"
```

---

## Task 24: Cold-start training sets for `kris`

**Why:** Spec §7.3 — add `empty` and `first-day` to exercise the cold-start path.

**Files:**
- Create: `libs/eval/corpora/kris/trainings/empty.yaml`
- Create: `libs/eval/corpora/kris/trainings/first-day.yaml`

- [ ] **Step 1: empty.yaml**

```yaml
name: empty
description: |
  No training threads. Exercises the classifier's behavior with zero
  user_moved signals — priority_prefix, channel_default, and root_fallback
  stages can still fire; topic_shortcircuit and scoring cannot.

threads: []
```

- [ ] **Step 2: first-day.yaml**

Pick the two earliest training threads from `kris/trainings/full.yaml` (top of the file) and copy them here verbatim. The goal is "1–2 user_moved examples". Open `libs/eval/corpora/kris/trainings/full.yaml`, take the first two `threads:` entries (including their `id`, `title`, `topic`, `contacts`, `groups`, `embedding_ref`, `filed_to_priority`), and write:

```yaml
name: first-day
description: |
  One or two user_moved threads. Exercises the regime where the scoring
  stage is sparse and an LLM-or-shortcut stage should fill in.

threads:
  - id: <id-from-full.yaml-thread-1>
    title: <title>
    topic: <topic>
    contacts: [<...>]
    groups: [<...>]
    embedding_ref: <ref-or-null>
    filed_to_priority: <priority-slug>
  - id: <id-from-full.yaml-thread-2>
    ...
```

If you find any thread in `full.yaml` that demonstrates a clearly distinct priority (different filed_to_priority slug), prefer that pair so the cold-start regime is non-trivial.

- [ ] **Step 3: Verify the corpus loads**

```
cd libs/eval && pnpm exec vitest run tests/corpus.test.ts
```
Expected: still PASS.

```
cd libs/eval && pnpm exec tsx src/cli.ts --corpus kris --classifiers sql:current --training-sets empty,first-day,full
```
Expected: prints a console table with three training rows; no errors.

- [ ] **Step 4: Commit**

```bash
git add libs/eval/corpora/kris/trainings/empty.yaml libs/eval/corpora/kris/trainings/first-day.yaml
git commit -m "Add empty and first-day training sets to kris corpus"
```

---

## Task 25: Integration smoke for `ts:hybrid-llm` with stub client

**Why:** End-to-end sanity that the classifier respects gates and emits non-zero `llmCalls` only when expected. Uses the public test surface: register a stub variant.

**Files:**
- Create: `libs/eval/tests/ts-hybrid-llm-cascade.test.ts`

- [ ] **Step 1: Write the test**

```ts
import { describe, expect, it } from "vitest";
import { resolve } from "node:path";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runEval } from "../src/runner/run";
import { makeHybridLlmClassifier } from "../src/classifiers/ts-hybrid-llm";
import { registerVariant } from "../src/classifiers/registry";
import { DEFAULTS_LLM } from "../src/classifiers/ts-hybrid.defaults";
import type { LLMClient } from "../src/classifiers/llm-client";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

function stubLlm(): LLMClient {
  return {
    id: "stub:always-first",
    async classify(inputs) {
      return {
        priorityId: inputs.allowedPriorityIds[0] ?? null,
        rationale: "stub",
      };
    },
  };
}

describe.runIf(!!process.env.DATABASE_URL)("ts:hybrid-llm cascade", () => {
  it("does NOT call the LLM when scoring is confident on synthetic-tiny", async () => {
    const cacheDir = await mkdtemp(join(tmpdir(), "llm-cache-"));
    registerVariant(
      "test:hybrid-llm:stub",
      makeHybridLlmClassifier("test:hybrid-llm:stub", {
        params: DEFAULTS_LLM,
        llmClient: stubLlm(),
        cacheDir,
      })
    );

    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["test:hybrid-llm:stub"],
      trainingSets: ["full"],
    });
    // 003 and 004 are confidently classified by topic_shortcircuit / scoring
    // — the LLM tie-breaker should NOT fire on them.
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("003-topic-shortcircuit")?.llmCalls).toBe(0);
    expect(byCase.get("004-scoring-contacts")?.llmCalls).toBe(0);
    // 005 falls through to root_fallback (no scoring match, no shortcuts).
    // The stub never calls the network, but its observation path still bumps
    // llmCalls — we just verify the stage is well-formed.
    expect(byCase.get("005-scoring-no-match")?.stage).toMatch(
      /(root_fallback|llm_coldstart|single_priority_bypass)/
    );
  }, 60_000);
});
```

- [ ] **Step 2: Run**

```
cd libs/eval && DATABASE_URL=$DATABASE_URL pnpm exec vitest run tests/ts-hybrid-llm-cascade.test.ts
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add libs/eval/tests/ts-hybrid-llm-cascade.test.ts
git commit -m "Add integration smoke for ts:hybrid-llm with stub LLM client"
```

---

## Task 26: Lint and finalize

**Why:** Lint cleanly across the package before declaring done.

- [ ] **Step 1: Run lint**

```
pnpm --filter @plotday/eval lint
```
Expected: zero errors. Fix any issues found, commit fixes if any.

- [ ] **Step 2: Run the full test suite**

```
cd libs/eval && DATABASE_URL=$DATABASE_URL pnpm exec vitest run
```
Expected: all tests pass.

- [ ] **Step 3: Full eval smoke on both corpora**

```
cd libs/eval && DATABASE_URL=$DATABASE_URL pnpm exec tsx src/cli.ts --corpus synthetic-tiny --classifiers sql:current,ts:hybrid:default
cd libs/eval && DATABASE_URL=$DATABASE_URL pnpm exec tsx src/cli.ts --corpus kris --classifiers sql:current,ts:hybrid:default
```
Expected: both runs complete; the new report columns are visible.

- [ ] **Step 4: Final commit (if any cleanup was needed)**

```bash
git status
# If files changed:
git add -A
git commit -m "Final lint and test cleanup for hybrid classifier"
```

---

## Self-review

- **Spec §1 (Background):** N/A — context only.
- **Spec §2 (Goals/non-goals):** Goals 1–4 covered by Tasks 5–13, 14–21, 22, and Tasks out-of-scope (production wiring) explicitly listed.
- **Spec §3.1 (Cascade order):** Stages 1–5, 7, 9 implemented in `ts:hybrid` (Tasks 10–12); stages 6, 8 added in `ts:hybrid-llm` (Tasks 17–20). priority:KEY prefix moved earlier per spec — see Task 12 step 1, `pp` between channel default and scoring.
- **Spec §3.2 (What runs where):** TS files under `libs/eval/src/classifiers/`. Prompts under `prompts/`. No production wiring (out-of-scope per spec §8).
- **Spec §3.3 (Data access):** All queries use `ctx.rawQuery` with parameterized arguments. No raw concatenation of candidate text.
- **Spec §4 (Scoring):** signals (Tasks 6, 7), nonlinearity (Task 8), aggregation (Task 9), decision (Task 11). Score JSON shape matches spec §4.4.
- **Spec §5 (LLM stages):** tie-breaker (Task 17), shortcuts (Task 18), cold-start (Task 19), caching (Task 15), budget + batching: budget covered in Task 20; batching is not implemented (the per-classifier interface is one-call-per-candidate; batching is a follow-up — flagged here).
- **Spec §6 (HybridParams):** Task 5.
- **Spec §7.1 (Run summary):** Task 22 + Task 23.
- **Spec §7.2 (LLM cache):** Task 15.
- **Spec §7.3 (Cold-start training sets):** Task 24.
- **Spec §7.4 (Author labels):** Tasks 2 + 3.
- **Spec §8 (Production wiring):** Out of scope — covered by spec §2 non-goals.
- **Spec §9 (Implementation surface):** File list matches.
- **Spec §10 (Testing):** Unit tests in Tasks 6, 7, 8, 9, 15, 21; cascade tests in Tasks 13, 25.
- **Spec §11 (Risks):** Author signal weakness acknowledged via `weights.author = 0.10` default and the corpus enrichment being out of scope (call it out in PR description).

**Open items / known gaps:**
- Batching across multiple candidates in a single LLM cold-start call (spec §5.4) is not implemented — the classifier interface is one-candidate-at-a-time. Treating this as a follow-up.
- The twist-author shortcut depends on `twist_instance` rows existing in the sandbox; with current corpora it gracefully no-ops.
