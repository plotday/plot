# Eval Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corpus schema v2 (every production classifier signal expressible), shape-preserving anonymization, prod seeders (refresh / holdout / decision-log / multi-user), local embedding backfill with parity gate, time-replay backtest, statistically honest CLI (params/sweep/baseline/CI/McNemar/cost), synthetic corpora, gold completion, runbook, first tuning pass.

**Spec:** `docs/superpowers/specs/2026-06-11-eval-framework-design.md` — read it first; it is the authority on WHY. This plan is the authority on WHAT/HOW. The spec's adversarial-review decisions (self-exclusion guard, topic email rewriting, slug migration, embedding provenance, cache-honesty, statistics reframing) are load-bearing — do not "simplify" them away.

**Architecture:** All work is in `libs/eval` plus additive optional fields in `libs/classifier`. No DB schema changes, no workers changes, no `public/` submodule changes. The YAML corpus is parsed by zod (v1 and v2 both accepted), normalized to an internal superset model, inserted into a transactional pg sandbox, and run through registered classifier variants; seeders extract/refresh corpora from the prod readonly proxy with anonymization + leak checks at a single write choke point.

**Tech stack:** TypeScript (ESM, tsx), zod, yaml, pg, vitest, `@huggingface/transformers` (new devDep), `ai` + `@ai-sdk/google` (existing).

**Environment (every task):**
- Worktree: `/Users/kris.braun/code/plot/.claude/worktrees/eval-framework`
- DB (explicit on EVERY command; the ambient `$DATABASE_URL` is stale):
  `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres"`
- Run the CLI as `cd libs/eval && pnpm exec tsx src/cli.ts ...` (never `pnpm --filter @plotday/eval eval -- ...` — it mangles args). The CLI exits 1 when there are regressions vs `expected` labels; append `|| true` when capturing JSON.
- Tests: `cd libs/eval && DATABASE_URL=... pnpm exec vitest run [file]` (DB tests are `describe.runIf(!!process.env.DATABASE_URL)` — without the URL they silently skip; that counts as NOT verified).
- LLM key for live runs: `export GOOGLE_GENERATIVE_AI_API_KEY=$(grep '^GOOGLE_GENERATIVE_AI_API_KEY' workers/api/.dev.vars | cut -d= -f2- | tr -d '"')`
- Lint: `cd libs/eval && pnpm lint` and `cd libs/classifier && pnpm lint` when touched.
- Commit after every task (trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`).

---

## Shared interfaces (locked — later tasks depend on these exact names)

### Internal corpus model (corpus/schema.ts exports)

```ts
// Timestamps: YAML gives strings (or Date for some formats); normalize to Date.
export type CorpusTimestamps = Date | null;

export type CorpusTeam = { slug: string; id: number; name: string };

export type CorpusConnection = {
  slug: string;
  id: string;                    // twist_instance uuid
  provider: string;              // 'google' | 'slack' | ... (free string)
  accountContactId: string;      // resolved contact uuid (actor)
  teamId: number | null;         // resolved from team ref
};

export type CorpusSubscription = { plan: string; status: string } | null;

export type CorpusEmbedding = {
  ref: string;
  vector: number[];              // length 384
  source: "thread-title" | "note-content" | "local-title" | null; // null = legacy/unknown
};

export type CorpusThreadBase = {
  id: string;
  title: string;
  topic: string | null;
  contacts: string[];            // resolved uuids
  groups: string[];
  embedding_ref: string | null;
  authorContactId: string | null;   // → thread.author_id
  connectionId: string | null;      // → thread.created_by + thread.twist_id
  createdByOverride: string | null; // v1 compat ONLY (v1 `author` semantics)
  facets: Record<string, string> | null;
  createdAt: Date | null;
};

export type CorpusTrainingThread = CorpusThreadBase & {
  filedToPriority: string;
  movedAt: Date | null;
};

export type CorpusNegative = {
  threadId: string;              // must be a training or negative thread id in the same set
  priorityId: string;
  source: "moved_out" | "deselected";
  createdAt: Date | null;
};

export type CorpusTrainingSet = {
  name: string;
  description: string;
  threads: CorpusTrainingThread[];
  negativeThreads: CorpusThreadBase[];
  negatives: CorpusNegative[];
};

export type CorpusCase = {
  id: string;
  sourceThreadId: string | null;
  tags: string[];
  asOf: Date | null;
  description: string;
  candidate: CorpusThreadBase;   // id = filled by runner (caseIdToUuid), ignore in YAML
  labels: {
    gold: string | null;
    goldRationale: string;
    goldSource: "human" | "llm-proposed" | null;
    expected: string | null;
    expectedStage: string | null;
    expectedRecordedAt: string | null;
  };
  notes: string;
};

export type CorpusPriority = {
  slug: string; id: string; path: string; title: string; key: string | null;
  description: string | null;
  facetFilters: Record<string, unknown> | null;  // jsonb passthrough
};

export type CorpusWorld = {
  name: string;
  description: string;
  schemaVersion: 1 | 2;
  source: { kind: "prod-extract" | "handcrafted"; extracted_at: string | null; anonymized: boolean };
  user: { id: string; email: string; primary_contact_id: string | null;
          subscription: CorpusSubscription };
  teams: CorpusTeam[];
  connections: CorpusConnection[];
  priorities: CorpusPriority[];
  contacts: { slug: string | null; id: string; email: string | null; name: string | null; linked_to_user: boolean }[];
  groups: { slug: string | null; id: string; title: string }[];
  channels: { id: number; connectionId: string | null; default_priority_id: string | null }[]; // connectionId null ⇒ v1 placeholder path
  embeddings: CorpusEmbedding[];
};

export type Corpus = {
  name: string; rootDir: string; world: CorpusWorld;
  trainingSets: CorpusTrainingSet[]; cases: CorpusCase[];
  embeddings: Map<string, CorpusEmbedding>;
};
```

YAML field names stay snake_case (`facet_filters`, `source_thread_id`, `as_of`, `moved_at`, `created_at`, `account_contact`, `gold_source`, `negative_threads`); the internal model is camelCase as above. v1 docs normalize with: `authorContactId=null`, `createdByOverride=<resolved v1 author>`, `connectionId=null`, `facets=null`, timestamps null, `channels[].connectionId=null`, no teams/connections/subscription, `goldSource = gold != null ? "human" : null`.

### Classifier additions (libs/classifier — additive, optional)

```ts
// llm-client.ts
export type LLMUsage = { inputTokens: number; outputTokens: number };
export type LLMOutput = { priorityId: string | null; rationale: string;
  usage?: LLMUsage;        // populated by clients that know it
  fromCache?: boolean };   // set ONLY by cache wrappers

// types.ts — ClassificationResult gains:
llmUsage?: { liveInputTokens: number; liveOutputTokens: number;
             replayedInputTokens: number; replayedOutputTokens: number;
             unknownCalls: number };
```

### Runner additions (runner/run.ts)

```ts
// RunResult gains:
selfExcluded: boolean;          // case's own thread was archived from training
trainingSizeAtCase: number;     // # training threads visible to this case
budgetExhausted: boolean;
llmUsage: ClassificationResult["llmUsage"] | null;
rankOfGold: number | null;      // gold's rank in the scoring explain (1-based)
goldMargin: number | null;      // topScore - goldScore (0 when gold is top)

// RunOptions gains:
mode?: "matrix" | "backtest";   // default "matrix"
excludeTags?: string[];         // cases with any of these tags are skipped
```

### Stats / rank / cost / sweep / baseline

```ts
// scoring/stats.ts
export function wilsonInterval(successes: number, n: number, z?: number): { lo: number; hi: number };
export function mcnemarExact(b: number, c: number): number; // two-sided p; b/c = discordant counts
// scoring/rank.ts
export function rankOfGold(scores: Record<string, unknown>, goldId: string | null):
  { rank: number; margin: number } | null;
// scoring/cost.ts
export const MODEL_COSTS: Record<string, { inPerM: number; outPerM: number }>;
export function estimateCostUsd(model: string, usage: { inputTokens: number; outputTokens: number }): number | null;
// runner/sweep.ts
export function parseSweepSpec(spec: string): { label: string; overrides: Record<string, unknown> }[];
export function deepMergeParams(base: HybridParams, overrides: Record<string, unknown>): HybridParams;
// runner/baseline.ts
export type BaselineFile = { meta: { classifier: string; corpus: string; trainingSet: string; createdAt: string };
  results: Record<string, { predicted: string | null; stage: string }> };
export function compareToBaseline(baseline: BaselineFile, results: RunResult[]):
  { fixed: string[]; broke: string[]; changedNeutral: string[]; same: number; mcnemarP: number | null };
```

### Registry

```ts
export function makeAdhocLlmVariant(overrides: Record<string, unknown>, base?: string): Classifier;
// name: `${base}+params@<8-hex fnv hash of canonical overrides JSON>`
```

### CLI flags (final surface)

```
--corpus / --corpus-dir / --classifiers / --training-sets / --format / --list-classifiers  (existing)
--params <file.json>      --base <variant>      --sweep "<spec>"
--save-baseline <file>    --baseline <file>
--backtest                --exclude-tags a,b    --include-holdout
```
`holdout-move`-tagged cases are excluded by default; `--include-holdout` re-adds them. `--exclude-tags` appends further exclusions.

### Seeder CLI surface

```
from-prod.ts        --user-email --out [--case-count N] [--holdout-recent-moves N]
                    [--timeline-cases N] [--db-url URL] [--list-active-users]
from-decision-log.ts --corpus <name> [--db-url URL]
gen-embeddings.ts   --corpus <name> [--parity-only]
propose-gold.ts     --corpus <name>
leak-check.ts       --corpus <name>
```

---

# Part I — Harness (Tasks 1–11)

### Task 1: Freeze pre-refactor ground truth (fixture + snapshots + LLM cache)

No production code changes. Everything recorded here is the regression oracle for Tasks 3–5.

**Files:**
- Create: `libs/eval/tests/fixtures/kris-v1/` (trimmed corpus copy)
- Create: `libs/eval/tests/fixtures/kris-v1-expected.json` (deterministic predictions)
- Create: `libs/eval/tests/fixtures/kris-v1-llm-expected.json` (LLM predictions; implementation-time gate)

- [ ] **Step 1: Record deterministic predictions on the full kris v1 corpus**

```bash
cd libs/eval
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" \
  pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid:default \
  --training-sets full --format json > /tmp/kris-v1-det.json || true
python3 -c "import json;d=json.load(open('/tmp/kris-v1-det.json'));print(len(d['results']))"
```
Expected: 80 results.

- [ ] **Step 2: Record LLM predictions + populate the file cache**

```bash
export GOOGLE_GENERATIVE_AI_API_KEY=...   # from workers/api/.dev.vars (see header)
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54332/postgres" \
  pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid-llm:default \
  --training-sets full --format json > /tmp/kris-v1-llm.json || true
ls .cache/llm/default | wc -l   # expect > 0 cached responses
```
This is the workstream's first live LLM spend (~80 cases). If a case fails with a transient API error, re-run (cache makes it cheap).

- [ ] **Step 3: Build the trimmed fixture corpus**

Write a throwaway script (do not commit) that copies `corpora/kris/world.yaml` + `trainings/full.yaml` + the FIRST 20 cases of `cases.yaml` into `tests/fixtures/kris-v1/`, pruning `world.embeddings` to refs referenced by those cases/trainings. Keep `trainings/empty.yaml` and `first-day.yaml` too (cheap, exercises matrix). Verify it loads:

```bash
DATABASE_URL=... pnpm exec tsx src/cli.ts --corpus-dir tests/fixtures/kris-v1 \
  --classifiers ts:hybrid:default --training-sets full --format json \
  > /tmp/fixture-det.json || true
```

- [ ] **Step 4: Save expectation snapshots**

Reduce both JSON outputs to `{caseId: {predicted, stage}}` maps (filter trainingSet=full), save as the two fixture JSON files: `kris-v1-expected.json` from `/tmp/fixture-det.json` (20 cases), `kris-v1-llm-expected.json` from `/tmp/kris-v1-llm.json` (80 cases — keep full-corpus, used only for the implementation-time gate in Task 5).

- [ ] **Step 5: Commit**

```bash
git add libs/eval/tests/fixtures
git commit -m "test(eval): freeze v1 kris fixture + prediction snapshots"
```

### Task 2: LLM usage plumbing (libs/classifier + eval clients)

**Files:**
- Modify: `libs/classifier/src/llm-client.ts` (LLMUsage, LLMOutput fields)
- Modify: `libs/classifier/src/types.ts` (ClassificationResult.llmUsage)
- Modify: `libs/classifier/src/ts-hybrid-llm.ts` (aggregate per-call usage)
- Modify: `libs/eval/src/classifiers/llm-client.ts` (populate usage from `ai` result)
- Modify: `libs/eval/src/classifiers/llm-cache.ts` (store usage; replay with fromCache)
- Test: `libs/eval/tests/llm-usage.test.ts`

- [ ] **Step 1: Write failing tests** — in `llm-usage.test.ts`: (a) `cachedLlmClient` stores `usage` in the cache file and replays it with `fromCache: true`; (b) a fake LLM client returning `usage: {inputTokens: 100, outputTokens: 5}` produces, through one `makeHybridLlmClassifier` classification that fires exactly one LLM call, `result.llmUsage = { liveInputTokens: 100, liveOutputTokens: 5, replayedInputTokens: 0, replayedOutputTokens: 0, unknownCalls: 0 }`; (c) a client returning no usage yields `unknownCalls: 1`. Reuse the existing fake-client pattern from `tests/ts-hybrid-llm.test.ts`.
- [ ] **Step 2: Run; verify they fail** (type errors count as failing).
- [ ] **Step 3: Implement.** Types per Shared Interfaces. In `ts-hybrid-llm.ts`, wherever `llmCalls`/`cacheHits` are incremented after a client call, also accumulate: output with `fromCache` → replayed buckets, else live buckets; missing `usage` → `unknownCalls++`. In the eval Gemini client, populate `usage` from `result.usage` (this repo has `ai@6`: fields are `inputTokens`/`outputTokens`; verify with a quick type check and adapt if the installed version differs). In `llm-cache.ts`, persist `{ response }` as today — `usage` rides inside `response`; on hit, return `{...parsed.response, fromCache: true}`.
- [ ] **Step 4: Run tests + lint in both packages; verify pass.** Also `cd libs/eval && DATABASE_URL=... pnpm exec vitest run` (full suite) — nothing else may break.
- [ ] **Step 5: Commit** `feat(classifier,eval): thread LLM token usage through results and cache`

### Task 3: Corpus schema v2 + loader + synthetic-tiny upgrade

**Files:**
- Modify: `libs/eval/src/corpus/schema.ts` (v2 zod schemas + internal types per Shared Interfaces)
- Modify: `libs/eval/src/corpus/load.ts` (version detection, normalization, embeddings.yaml merge, new ref resolution, validation)
- Modify: `libs/eval/corpora/synthetic-tiny/world.yaml` + new `cases.yaml`/`trainings` fields (v2 syntax)
- Test: `libs/eval/tests/corpus-v2.test.ts`

- [ ] **Step 1: Write failing tests** covering: v2 world parse (teams/connections/subscription/facet_filters/description/channels-with-connection); v2 trainings (author/connection/facets/created_at/moved_at, negative_threads, negatives incl. created_at + thread-ref validation: unknown negative thread id throws); v2 cases (source_thread_id, tags, as_of, gold_source, candidate.connection/facets; `expected_stage` accepts `llm_tiebreaker`); v1 doc loads with normalization (createdByOverride = old author resolution incl. `twist:` hashing and arbitrary-UUID passthrough; authorContactId null; goldSource backfilled to `human` when gold set); sibling `embeddings.yaml` merge (duplicate ref across files throws); embedding `source` field optional. Build tiny inline YAML fixtures with `mkdtemp`.
- [ ] **Step 2: Run; verify fail.**
- [ ] **Step 3: Implement.** Keep two zod document schemas (v1 = existing shapes, v2 = new) selected on `schema_version`, both mapping into the internal model. Slug resolution extends to `connections[].account_contact` (contact ref), `connections[].team` (team ref), `channels[].connection`, `negatives[].priority`, `negatives[].thread` (id must be a training/negative thread in the same set). Timestamps: `z.union([z.string(), z.date()])` → `Date`, invalid → throw with context. Loader merges optional `embeddings.yaml`.
- [ ] **Step 4: Upgrade `synthetic-tiny` in place**: set `schema_version: 2`, convert each training/case `author` (they are contact slugs) to the v2 `author` field (same key name in YAML, now meaning author_id — for synthetic-tiny the old behavior difference is irrelevant since its tests assert deterministic outcomes; run the eval suite to confirm nothing flips; if a test flips, keep the thread's behavior with an explicit `created_by_override` field — the v2 YAML schema must therefore also accept `created_by_override` for handcrafted corpora; add it as an optional escape hatch).
- [ ] **Step 5: Full suite + lint; verify pass.**
- [ ] **Step 6: Commit** `feat(eval): corpus schema v2 with v1 normalization`

### Task 4: Sandbox v2

**Files:**
- Modify: `libs/eval/src/sandbox/pg-sandbox.ts`
- Test: `libs/eval/tests/sandbox-v2.test.ts`

- [ ] **Step 1: Write failing tests** (DB-gated): load a v2 world with a team, an org-domain connection (actor contact `anna@lumenforge.com`), a freemail connection (actor `bob@gmail.com`), and a team-only connection (actor email NULL, team set) — assert via `sandbox.rawQuery`: `connection_org_key($conn)` returns `domain:lumenforge.com` / NULL / `team:<offset id>` respectively; subscription row exists with declared plan/status (and no row when subscription null); priorities carry `facet_filters`/`description`; channel's `twist_instance_id` = connection id; training thread insert sets `author_id`, `created_by`=connection id, `twist_id` NOT NULL, `facets`, explicit `created_at`; negative thread + `thread_priority_negative` rows exist; numeric ids offset ≥ 1e9; duplicate-channel-id conflict throws (v2). Plus v1 compat: v1 world loads byte-identically to old behavior (no contact.name set, placeholder channel parent, `ON CONFLICT DO NOTHING`).
- [ ] **Step 2: Run; verify fail.**
- [ ] **Step 3: Implement.** Inside the existing `SET LOCAL session_replication_role = replica` block of `loadWorld`, add in order: `user_subscription` (when declared; `billing_cycle_start='2026-01-01'`, `billing_cycle_end='2027-01-01'`), `team` (id offset `+ 1_000_000_000`, `OVERRIDING SYSTEM VALUE`), one `twist` per distinct provider (`OVERRIDING SYSTEM VALUE`, id = `1_000_000_000 + index`, `twist_package_id` = deterministic uuid from provider via the existing slugToUuid-style hash, `name`/`handle` = provider, `version='0.0.0-eval'`, `environment='personal'`, `user_id` = world user, `publisher_id` NULL), `twist_instance` (id, twist_id, owner_id = world user, team_id = offset team id or NULL, `name` = `eval ${provider} ${slug}`), `twist_instance_connection` (instance, world user, provider, actor_id = accountContactId). v2 contacts insert `name`; v1 does not. Priorities gain `description`, `facet_filters` columns. Channels: v2 → `twist_instance_id = connectionId`, plain INSERT (no ON CONFLICT); v1 → existing placeholder + `ON CONFLICT DO NOTHING`. `loadTrainingSet`: thread insert gains `author_id`, `facets`, `created_at` (explicit when set), `twist_id` + `created_by` from connection (`createdByOverride` wins when set; else `connectionId ?? world.user.id`); after threads, insert `negativeThreads` (same shape, no thread_priority), then `negatives` → `thread_priority_negative (user_id, thread_id, priority_id, source, created_at)`. `stageCandidate` gains the same author/connection/facets columns. Twist bigint ids must be stable per provider across loads (sort providers, index by position).
- [ ] **Step 4: Full suite + lint; verify pass.**
- [ ] **Step 5: Commit** `feat(eval): sandbox inserts connections, negatives, facets, subscription`

### Task 5: Runner wiring + self-exclusion guard + regression gates

**Files:**
- Modify: `libs/eval/src/runner/run.ts`
- Modify: `libs/eval/src/cli.ts` (`--exclude-tags`, `--include-holdout` only; rest comes later)
- Create: `libs/eval/src/scoring/rank.ts`
- Test: `libs/eval/tests/runner-v2.test.ts`, `libs/eval/tests/regression-v1.test.ts`

- [ ] **Step 1: Write failing tests.**
  - `regression-v1.test.ts` (DB-gated): run `tests/fixtures/kris-v1` with `ts:hybrid:default`/full via `runEval`; reduce to `{caseId: {predicted, stage}}`; deep-equal `kris-v1-expected.json`.
  - `runner-v2.test.ts`: (a) self-exclusion: corpus where case X's `source_thread_id` equals training thread T filed at priority P with an identical embedding — assert the result does NOT trivially come from the self-match (concretely: result.selfExcluded === true and T absent from the neighbor explain), and a sibling case without the match has selfExcluded === false; (b) candidate wiring: a v2 case with facets + connection reaches the classifier (fake classifier capturing the Candidate; assert facets/authorContactId/connectionId); (c) tag exclusion: `excludeTags: ["holdout-move"]` skips tagged cases; (d) RunResult carries trainingSizeAtCase / budgetExhausted / llmUsage / rankOfGold (use a fake classifier returning a scores.explain with perPrioritySorted).
- [ ] **Step 2: Run; verify fail.**
- [ ] **Step 3: Implement.** `runOneCase`: inside the case savepoint, before `classify()`, if the case's thread id (sourceThreadId ?? 8-hex prefix from `^\d+-([0-9a-f]{8})$`) matches a training thread in the active set, `UPDATE public.thread SET archived_at = now() WHERE id = $1` and set `selfExcluded`. Candidate fields: `author: createdByOverride ?? connectionId ?? world.user.id` (v1-identical when override set), `authorContactId`, `connectionId`, `facets`. `rankOfGold(scores, goldId)`: walk `scores.explain.perPrioritySorted` (verify the actual payload path in `ts-hybrid-llm.ts` finish() — adapt if nested differently; `sql:current` lacks it → null). `trainingSizeAtCase` = active training thread count minus self-exclusion. CLI: default excludeTags `["holdout-move"]` unless `--include-holdout`.
- [ ] **Step 4: Run the LLM zero-cache-miss gate** (implementation-time, not committed as a test): re-run Step 2 of Task 1's command (kris v1, `ts:hybrid-llm:default`); assert in the JSON summary that `llmCalls/case ≈ 0` misses (cacheHitRate = 100%) and predictions deep-equal `kris-v1-llm-expected.json`. A cache miss here means Tasks 2–5 changed a prompt for v1 corpora — find and fix before proceeding.
- [ ] **Step 5: Full suite + lint; verify pass. Commit** `feat(eval): v2 candidate wiring, self-exclusion guard, v1 regression gates`

### Task 6: Statistics (Wilson + exact McNemar) + rank module tests

**Files:**
- Create: `libs/eval/src/scoring/stats.ts`
- Test: `libs/eval/tests/stats.test.ts`

- [ ] **Step 1: Failing tests** with known values: `wilsonInterval(8, 10)` ≈ {lo: 0.49, hi: 0.943} (±0.01); `wilsonInterval(0, 0)` → {lo: 0, hi: 1}; `mcnemarExact(6, 0)` ≈ 0.03125; `mcnemarExact(8, 1)` ≈ 0.0391; `mcnemarExact(0, 0)` = 1; symmetry `mcnemarExact(b,c) === mcnemarExact(c,b)`; `rankOfGold` fixtures (gold top → rank 1 margin 0; gold 3rd → rank 3, margin = top−gold; absent → null).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.**

```ts
export function wilsonInterval(successes: number, n: number, z = 1.96) {
  if (n === 0) return { lo: 0, hi: 1 };
  const p = successes / n, z2 = z * z;
  const denom = 1 + z2 / n;
  const center = (p + z2 / (2 * n)) / denom;
  const half = (z * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n))) / denom;
  return { lo: Math.max(0, center - half), hi: Math.min(1, center + half) };
}
export function mcnemarExact(b: number, c: number): number {
  const n = b + c;
  if (n === 0) return 1;
  const k = Math.min(b, c);
  // two-sided exact binomial(n, 0.5): 2 * P(X <= k), capped at 1
  let cum = 0;
  for (let i = 0; i <= k; i++) cum += binomPmf(n, i);
  return Math.min(1, 2 * cum);
}
function binomPmf(n: number, k: number): number {
  let logC = 0;
  for (let i = 1; i <= k; i++) logC += Math.log(n - k + i) - Math.log(i);
  return Math.exp(logC + n * Math.log(0.5));
}
```
- [ ] **Step 4: Pass + lint. Commit** `feat(eval): Wilson CI and exact McNemar`

### Task 7: Ad-hoc variants, eval budget neutralization, cost table, `--params`

**Files:**
- Modify: `libs/eval/src/classifiers/registry.ts`
- Create: `libs/eval/src/scoring/cost.ts`
- Create: `libs/eval/src/runner/sweep.ts` (only `deepMergeParams` here; spec parsing in Task 8)
- Modify: `libs/eval/src/cli.ts` (`--params`, `--base`)
- Test: `libs/eval/tests/adhoc-variants.test.ts`

- [ ] **Step 1: Failing tests:** `deepMergeParams(DEFAULTS_LLM, {originBonus: {exact: 0}})` keeps `org: 0.09` and all other fields; merging `{weights: {sem: 0.5}}` throws unless the caller renormalized (assert `assertValidWeights` fires through variant construction); `makeAdhocLlmVariant({originBonus:{exact:0.25}})` registers + returns a classifier named `ts:hybrid-llm:default+params@<8hex>` and the name is stable across calls; eval variants get an unlimited budget (construct the variant, run a fake-LLM classification loop 200× against the same userId with `budgetFree`-level params and assert `budgetExhausted` never true — verify exactly how `makeHybridLlmClassifier` accepts a `consumeBudget` override by reading `libs/classifier/src/ts-hybrid-llm.ts` first; if it doesn't accept one, add an optional `consumeBudget` to its options in `libs/classifier` — additive).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** `deepMergeParams`: recursive plain-object merge (arrays/primitives replace). Registry: all eval-registered LLM variants (default, tight-gates, ad-hoc) pass `consumeBudget: async () => true` (or equivalent) so the in-process budget never gates eval runs. `cost.ts`: `MODEL_COSTS = { "gemini-3-flash-preview": {inPerM: 0.30, outPerM: 2.50}, "gemini-2.5-flash": {inPerM: 0.30, outPerM: 2.50}, "gemini-3.1-flash-lite": {inPerM: 0.10, outPerM: 0.40} }` with a comment marking estimates; unknown model → null. CLI: `--params file.json` reads overrides, `--base` picks the base (default `ts:hybrid-llm:default`), registers the ad-hoc variant, appends its name to the classifier list.
- [ ] **Step 4: Pass + lint + full suite. Commit** `feat(eval): ad-hoc param variants, unlimited eval budget, cost table`

### Task 8: Sweep grids + leaderboard

**Files:**
- Modify: `libs/eval/src/runner/sweep.ts` (parseSweepSpec, weight renormalization)
- Modify: `libs/eval/src/cli.ts` (`--sweep`)
- Modify: `libs/eval/src/scoring/report.ts` (leaderboard renderer)
- Test: `libs/eval/tests/sweep.test.ts`

- [ ] **Step 1: Failing tests:** `parseSweepSpec("originBonus.exact=0:0.2:0.1")` → 3 points (0, 0.1, 0.2) with labels like `originBonus.exact=0.1`; `"a=1|2;b=x|y"` → 4-point cross product; float-step ranges avoid FP drift (use integer step counts); `weights.sem=0.3:0.5:0.1` → each point's overrides contain a FULL renormalized weights object summing to 1 (remaining 5 weights scaled by `(1 - newSem) / (1 - oldSem)`); invalid spec throws with a helpful message.
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** Renormalization needs the base weights — `parseSweepSpec` takes an optional `baseParams` argument (CLI passes the resolved base variant's params) and expands `weights.*` dimensions into full `weights` objects. CLI `--sweep`: build all points, register each as an ad-hoc variant, run them all through `runEval` (one run, multiple classifiers — the existing matrix already supports classifier lists), and print a leaderboard: rows sorted by gold accuracy desc with Wilson CI, discordant-pair McNemar p vs the base variant (computed from per-case goldMatch pairs), live LLM tokens. Mark rows `~noise` when p ≥ 0.05.
- [ ] **Step 4: Pass + lint. Smoke:** `pnpm exec tsx src/cli.ts --corpus synthetic-tiny --sweep "originBonus.exact=0:0.2:0.1" --classifiers ts:hybrid:default` (sweep applies to deterministic base via `--base ts:hybrid:default`). **Commit** `feat(eval): grid sweeps with leaderboard and noise flags`

### Task 9: Baseline snapshots

**Files:**
- Create: `libs/eval/src/runner/baseline.ts`
- Modify: `libs/eval/src/cli.ts` (`--save-baseline`, `--baseline`)
- Test: `libs/eval/tests/baseline.test.ts`

- [ ] **Step 1: Failing tests:** save→load round-trip; `compareToBaseline` classifies fixed (was≠gold, now=gold), broke, changedNeutral (both ≠ gold but different), same; cases missing from baseline are reported separately (`newCases`), not crashed on; mcnemarP from the fixed/broke counts (null when both 0... no: mcnemarExact(0,0)=1 — use that).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement** per Shared Interfaces (single classifier+trainingSet per baseline file; CLI errors if the run matrix has >1 combination when saving). Comparison output goes through the report (console section listing fixed/broke case ids with predicted/gold names).
- [ ] **Step 4: Pass + lint. Commit** `feat(eval): per-case baseline snapshots with fixed/broke comparison`

### Task 10: Report upgrades

**Files:**
- Modify: `libs/eval/src/scoring/report.ts`
- Test: `libs/eval/tests/report.test.ts`

- [ ] **Step 1: Failing tests** (string assertions on `formatReport` output from a hand-built results array): gold accuracy renders with CI (`66.7% [49.0–80.9]` style); per-tag table appears when tags exist; per-gold_source slice appears (human vs llm-proposed); rank-of-gold aggregates (top-3 hit rate, MRR over ranked misses+hits); self-exclusion count line; budgetExhausted warning line when any result has it; live vs replayed token + cost lines; backtest trajectory table (bucket by trainingSizeAtCase: 0, 1–5, 6–15, 16–30, 31+) only when mode=backtest; synthetic vs prod-extract separation header (from `world.source.kind`).
- [ ] **Step 2: Run; fail.** **Step 3: Implement** (extend RunSummary as needed; keep existing sections). **Step 4: Pass + lint + full suite. Commit** `feat(eval): CIs, slices, rank-of-gold, trajectory, cost in reports`

### Task 11: Backtest mode

**Files:**
- Modify: `libs/eval/src/runner/run.ts`
- Modify: `libs/eval/src/sandbox/pg-sandbox.ts` (incremental training insert helper)
- Modify: `libs/eval/src/cli.ts` (`--backtest`)
- Test: `libs/eval/tests/backtest.test.ts`

- [ ] **Step 1: Failing tests** (DB-gated): hand-built v2 corpus with 3 training threads (moved_at T1<T2<T3) + negatives (created_at T2) + 3 cases (as_of between/after) using a fake classifier that records `trainingSizeAtCase` via a probe query (`SELECT count(*) FROM thread_priority WHERE user_moved AND user_id=$1`): case@T1.5 sees 1, case@T2.5 sees 2 (+negative present), case@T4 sees 3; cases missing as_of are skipped with a counted warning; results sorted chronologically; matrix mode untouched (existing tests).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** `loadTrainingSet` refactors its per-thread insert into an exported `insertTrainingThreads(sandbox, corpus, threads, negatives)`; backtest path: sort cases by asOf; maintain cursor over `[...threads, ...negativeThreads]`-driven inserts: insert training threads with `movedAt <= case.asOf` and negatives with `createdAt <= case.asOf` before each case (note: a negative's thread row must insert before the negative row — emit negative threads when their negative's clock fires, or at their own createdAt; keep it simple: insert negative thread + negative row together when `negative.createdAt <= asOf`). No savepoint around training inserts (monotonic); case savepoints unchanged; self-exclusion guard still applies.
- [ ] **Step 4: Pass + lint + full suite. Commit** `feat(eval): chronological backtest mode with cold-start trajectory`

# Part II — Seeders & content (Tasks 12–16)

### Task 12: Anonymizer v2 + leak check

**Files:**
- Rewrite: `libs/eval/src/seeder/anonymize.ts`
- Create: `libs/eval/src/seeder/name-pools.ts`
- Create: `libs/eval/src/seeder/leak-check.ts` (library + CLI)
- Test: `libs/eval/tests/anonymize.test.ts`

- [ ] **Step 1: Failing tests:** determinism (same input → same output, two process simulations via fresh imports not required — pure functions); `anonymizeName("Anna Vendor")` → two-token realistic name, ≠ input, stable; single-token stays single-token; `anonymizeEmail("anna@stripe.com")` → `<fake.local>@<fake-org>.com` with the SAME fake domain as `anonymizeEmail("bob@stripe.com")` (domain equality); `anonymizeEmail("x@gmail.com")` domain ∈ the 6-domain freemail pool; freemail detection covers the list parsed from `libs/db/schema/99-data/10-domains.sql` (test: `hotmail.co.uk` or another seeded domain maps into the pool); `anonymizeTopic("channel:kris@plot.day")` rewrites only the email part, preserves `channel:` prefix, deterministic; `anonymizeTopic("priority:@plot.app")` unchanged (no email shape); name+email coherence: `anonymizePerson({name, email})` gives email local part derived from the fake name; `scrubGroupName("Anna Vendor, Bob", collectedNames)` replaces matched name tokens; leak check: a doc containing a raw collected email outside titles → `violations` non-empty; raw email inside a `title:` value → `warnings` only; org-domain detection (raw domain `stripe.com` in any non-title string → violation).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** Keep `hashShort` (namespace bump to `…-v2`). `name-pools.ts`: ~100 first + ~100 last names, ~80 org-word pairs (`["lumen","forge"]` style) — write them out, plain arrays. Selection = integer from sha256 hex slice mod pool size. Freemail list: parse the SQL seed file at module load (regex `\('([^']+)'`), fallback to a hard-coded core dozen if the file is unreadable. `leakCheck(serializedYamlDocs: {path, text}[], rawPii: {emails, names, domains})` → `{violations, warnings}` where title-line detection = lines matching `^\s*(title|gold_rationale|notes):` are warning-scope (gold_rationale/notes are Kris-authored about his own data; still flag). CLI `leak-check.ts --corpus` runs the heuristic scan (email-regex strings whose domain isn't pool/`.example`/fake-org shaped).
- [ ] **Step 4: Pass + lint. Commit** `feat(eval): shape-preserving anonymizer with leak check`

### Task 13: Shared extraction + from-prod v2 (+ add-prod migration)

**Files:**
- Create: `libs/eval/src/seeder/extract.ts`
- Rewrite: `libs/eval/src/seeder/from-prod.ts`
- Modify: `libs/eval/src/seeder/add-prod-cases.ts`, `add-prod-trainings.ts` (emit v2 via extract.ts; same CLI)
- Test: `libs/eval/tests/extract.test.ts`

- [ ] **Step 1: Failing tests** (DB-gated, against the LOCAL worktree DB — insert fixture rows in a transaction, run extraction queries through `extract.ts` functions with the same client, roll back): thread hydration returns author contact (`thread.author_id`, falling back to first note author), connection id (created_by when twist_id not null), facets, created_at, embedding + provenance (`thread-title` when `thread.embedding` present, `note-content` when the note fallback fired); negatives extraction returns rows with real created_at; world collection picks up connections (provider+actor from `twist_instance_connection` with owner remap), subscription, facet_filters, description; case emission writes `source_thread_id`, preserves existing labels by source_thread_id→prefix fallback; slug migration: given an old world.yaml (old slugs) and new slug map, training/case YAML references rewrite by UUID; holdout: the N most recent moved threads land in cases (tag `holdout-move`, gold = target, gold_source human) and NOT in the training set; leak-check wired at the write choke point (a poisoned title-only PII string passes with warning; non-title fails the write).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement `extract.ts`.** Pure functions over a `pg.Client` + plain data: `loadWorldEntities(client, userId)`, `hydrateThreads(client, userId, threadIds | mode)`, `loadNegatives(client, userId)`, `buildAnonymizedCorpusFiles(...)` → `{path, text}[]` (single choke point: applies anonymization to contacts/emails/topics/groups, synthesizes team/instance names, runs `leakCheck`, throws on violations, returns warnings), `writeCorpusFiles(outDir, files)`. Embeddings: emit to `embeddings.yaml` with `source`; `note-content` vectors EXCLUDED unless `allowNoteContentEmbeddings` (true only for kris).
- [ ] **Step 4: Rewrite `from-prod.ts`** on top: flags per Shared Interfaces; refresh mode (existing cases re-hydrated by source_thread_id/prefix; kept verbatim + reported when unresolvable); corpus-wide slug migration (old world.yaml slugs → UUID → new slugs) applied to ALL `trainings/*.yaml`; `--holdout-recent-moves`; `--timeline-cases` (even spread over created_at, replaces stratified sampling for that run); `--list-active-users` (top users by `thread_priority` count with thread counts, no emails printed unless `--show-emails`); templates use anonymized email everywhere. Migrate `add-prod-*` to call extract.ts helpers (their CLI contracts unchanged, output now v2).
- [ ] **Step 5: Pass + lint + full suite. Commit** `feat(eval): v2 prod extraction with refresh, holdout, slug migration`

### Task 14: Decision-log mining

**Files:**
- Create: `libs/eval/src/seeder/from-decision-log.ts`
- Test: `libs/eval/tests/decision-log-mining.test.ts`

- [ ] **Step 1: Failing tests** (DB-gated, local DB fixtures in a rolled-back transaction): seed `classification_decision` rows — auto row (stage `scoring`, priority A) then `user_move` to B ⇒ mined (gold B, expected A, tag `decision-log`, as_of = auto.created_at, gold_source human); auto row with NULL priority (stage `none`) then user_move ⇒ mined with expected null + note about the low-confidence bucket; user_move with SAME priority ⇒ not mined; user_move with no prior auto row ⇒ not mined; missing table ⇒ friendly message, exit 0 (test the exported `mineDecisionLog` returns `{tableMissing: true}` on SQLSTATE 42P01).
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** Query: for the corpus user, latest auto decision per thread followed by a later `user_move` with different (or null-vs-set) priority:

```sql
SELECT a.thread_id, a.priority_id AS auto_priority, a.stage, a.classifier,
       a.created_at AS decided_at, m.priority_id AS moved_to
FROM public.classification_decision m
JOIN LATERAL (
  SELECT * FROM public.classification_decision a
  WHERE a.thread_id = m.thread_id AND a.user_id = m.user_id
    AND a.stage <> 'user_move' AND a.created_at < m.created_at
  ORDER BY a.created_at DESC LIMIT 1
) a ON TRUE
WHERE m.user_id = $1 AND m.stage = 'user_move'
  AND m.priority_id IS DISTINCT FROM a.priority_id
```
Hydrate mined threads via extract.ts (same anonymization; world merge appends any new contacts/groups/connections to world.yaml). Append as cases via the same emission path (`source_thread_id` set). Skip threads already present as cases (by source_thread_id). Empty result or missing table ⇒ informative message.
- [ ] **Step 4: Pass + lint. Commit** `feat(eval): mine classification_decision into labeled cases`

### Task 15: Local embeddings + parity gate

**Files:**
- Create: `libs/eval/src/seeder/gen-embeddings.ts`
- Modify: `libs/eval/package.json` (devDep `@huggingface/transformers`)
- Test: `libs/eval/tests/gen-embeddings.test.ts`

- [ ] **Step 1: Failing tests** (no model download in tests — unit-level): cosine helper (1 for identical, 0 for orthogonal); ref allocation `embl-<hashShort(threadId|caseId,10)>`; fill planning: given a corpus, the planner lists exactly the cases/training threads with `embedding_ref: null` and a non-empty title; parity selection picks only `source: thread-title` entries; the no-mixing rule: when parity fails, plan rejects writing into a corpus containing `emb-` refs.
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** `pnpm --filter @plotday/eval add -D @huggingface/transformers`. Embedder: `pipeline("feature-extraction", "Xenova/bge-small-en-v1.5")`, called with `{ pooling: "cls", normalize: true }`; embed raw title text (prod passes raw text to Workers AI). CLI: `--parity-only` runs the gate (5 random `thread-title` vectors, prints per-text cosine, PASS/FAIL at 0.99); default run = gate then fill (`embeddings.yaml` append with `source: local-title`, case/training `embedding_ref` updates). If the gate fails: print the cosines, write nothing into mixed corpora, exit 2.
- [ ] **Step 4: Pass + lint. Live verification deferred to Task 17 (model download).** **Commit** `feat(eval): local bge-small embedding backfill with parity gate`

### Task 16: propose-gold

**Files:**
- Create: `libs/eval/src/seeder/propose-gold.ts`
- Test: `libs/eval/tests/propose-gold.test.ts`

- [ ] **Step 1: Failing tests:** prompt builder includes priority tree (titles+paths+descriptions), ≤30 training exemplars, candidate fields; promptId is `propose-gold-v1` (cache key separation); YAML update only touches `gold: null` cases (a case with gold set is byte-identical after run); proposals write `gold` + `gold_rationale` + `gold_source: llm-proposed`; an LLM "null" answer leaves the case unlabeled with a note. Use a fake LLMClient.
- [ ] **Step 2: Run; fail.** **Step 3: Implement** (reuse `cachedLlmClient` + `makeGeminiClient`; the response must name a priority id from the world or null — reuse `LLMResponseSchema` allowed-set guard pattern from `llm-client.ts`). **Step 4: Pass + lint. Commit** `feat(eval): LLM gold-label proposals with provenance`

# Part III — Operations (orchestrator-run; Tasks 17–22)

These tasks run against prod (readonly proxy) and live LLM. Exact commands; judgment calls documented in the final report.

### Task 17: kris corpus v2 refresh + backfill + gold completion

- [ ] Start proxy: `pnpm prod-db-connect` (background; verify `psql postgres://readonly@127.0.0.1:5433/plot -c 'select 1'`).
- [ ] `pnpm exec tsx src/seeder/from-prod.ts --user-email kris@plot.day --out kris --case-count 80 --holdout-recent-moves 12` (refresh mode auto-detects existing cases.yaml; verify: existing gold labels preserved byte-for-byte — `git diff` audit on labels; slug migration applied to `first-day.yaml`; leak-check warnings reviewed and recorded).
- [ ] Load check: run `ts:hybrid:default` on the refreshed corpus; record the v1→v2 prediction delta for the report (expected: some shifts from created_by fidelity + new signals).
- [ ] `pnpm exec tsx src/seeder/gen-embeddings.ts --corpus kris --parity-only` → record cosines. If PASS: full run (fills nulls). If FAIL: record, skip kris fill (spec D fallback).
- [ ] `pnpm exec tsx src/seeder/propose-gold.ts --corpus kris` → audit list into the report.
- [ ] Full LLM baseline: `--classifiers ts:hybrid-llm:default --save-baseline baselines/kris-v2-default.json` (commit baselines/ directory; gitignore check — baselines are committed deliberately).
- [ ] Commit corpus + baselines.

### Task 18: Multi-user + decision-log corpora

- [ ] `from-prod.ts --list-active-users` → pick 2–3 most active non-kris users (record counts, not emails, in the report).
- [ ] Extract `prod-u2`, `prod-u3` (and `prod-u4` if the third user has ≥15 gold-able moves) with `--holdout-recent-moves 10`; leak-check output reviewed per corpus; `note-content` embeddings verified absent (`grep 'source: note-content'` → none).
- [ ] `from-decision-log.ts --corpus kris` against prod ⇒ expect "table missing/empty" message (prod not deployed) — record graceful behavior. Then smoke the mining path against the local DB by inserting two fixture decision rows for a scratch corpus (or rely on Task 14's tests) — already covered; just record.
- [ ] Baselines for each new corpus (deterministic + LLM). Commit.

### Task 19: Synthetic personas (G)

- [ ] Author `corpora/synthetic-newsletter-flood` (facet_filters incl. trustedSendersOnly, trusted-sender bypass cases, gate-drops-winner), `corpora/synthetic-two-hats` (two connections org+freemail, origin exact/org/none discrimination, account-hierarchy), `corpora/synthetic-groups` (group-heavy, ambiguous topics, tie-breaker pressure). ~10–15 priorities, ~15–25 trainings, ~15–25 cases each; every case gold-labeled by construction (`gold_source: human`, rationale = construction note); tags for slices.
- [ ] Embeddings: `gen-embeddings.ts --corpus <each>` (uniformly `local-title` — no mixing concern).
- [ ] Verify: corpus loads; `ts:hybrid:default` + `ts:hybrid-llm:default` run clean; cases exercise intended stages (check stage breakdown; iterate until the facet-gate corpus actually triggers `facetGated`, the two-hats corpus actually produces nonzero origin terms — verify via scores explain).
- [ ] Commit per corpus.

### Task 20: Runbook + hygiene (I)

- [ ] Write `libs/eval/AGENTS.md`: quick start; corpus authoring (v2 reference); seeding rituals (refresh, holdout, mining, leak check, anonymization notes); embedding backfill + parity; running evals (CLI flags, explicit DATABASE_URL, exit-code caveat); sweeps + cache-honesty table (which params are cache-stable); statistics guidance (CI reading, McNemar, multiplicity, pre-registration, holdout discipline incl. `--include-holdout` being the only path in); cost accounting; troubleshooting (vitest runIf, stale env, pnpm filter arg mangling).
- [ ] Fix `libs/eval/README.md` (layout: cases.yaml + trainings/ + embeddings.yaml; current default classifier; pointer to AGENTS.md).
- [ ] Regenerate `corpora/kris/baseline-report.md` from the current CLI (markdown format) or replace with a pointer into `baselines/` + the workstream report. Commit.

### Task 21: First tuning pass (J)

Protocol (spec J is binding):
- [ ] Tuning surface: kris (holdout excluded by default), synthetic ×3, prod-u3(+u4). Final holdout: kris `holdout-move` cases + ALL of prod-u2 (never run before the final step).
- [ ] Broad deterministic sweeps (ranking params: originBonus, weights renorm, k, negativePenaltyWeight, accountHierarchyBonusWeight) → shortlist; LLM-cascade sweeps for floors/threshold (cache-friendly) and for the shortlist (live spend — record).
- [ ] Pre-register ≤3 candidate configs (write them + rationale into the report BEFORE any holdout run).
- [ ] Final: pooled real-corpora paired McNemar (candidates vs default), then ONE `--include-holdout` evaluation of the chosen candidate (+ prod-u2 full run). "No change proposed" is an acceptable, first-class outcome.
- [ ] Register `ts:hybrid-llm:tuned-2026-06` in `registry.ts` with the chosen (or best-found, if not proposed for prod) params + comment pointing at the evidence report. Commit.

### Task 22: Finalization (separate session-level work)

- [ ] Final whole-branch integration review (subagent; spec compliance + code quality over the full diff).
- [ ] `/finalize` checklist (lint repo-wide for touched packages; no docs/updates.md — internal infra; no submodule changes; error-capture rule N/A to eval scripts — console is fine for CLI tools, but `captureException` rule applies to none of this since nothing runs in workers).
- [ ] Merge to local main per `superpowers:finishing-a-development-branch` (option: merge, no push): from the MAIN checkout `git merge --no-ff eval-framework`; re-run eval + classifier + classifier-runtime suites on merged main against the MAIN repo DB (54322; eval tests are sandboxed/rolled back — safe); remove worktree (`echo '{"path": "..."}' | bash scripts/worktree-remove`), delete branch.
- [ ] Write `docs/superpowers/reports/2026-06-11-eval-framework-report.md` (per workstream prompt: per-deliverable status, corpus inventory, baseline vs post-tuning metrics with CIs incl. untouched holdout, proposed HybridParams diff + evidence, fork decisions, open questions incl. gold-proposal audit + anonymization spot-check, exact follow-up commands).
- [ ] Update memory `project_eval_classifier_review.md` + MEMORY.md index.

---

## Plan self-review notes

- Spec coverage: A→Tasks 3–5,11; B→12; C→13–14; D→15; E→11; F→2,6–10; G→19; H→16; I→20; J→21. Privacy enforcement lives in 12–13 and is exercised in 17–18.
- Type/name consistency: internal model + RunResult fields defined once above; Tasks 5/8/9/10/11 all reference those exact names.
- Known judgment points left to implementers ON PURPOSE (each calls for reading the current code first): exact `scores.explain` payload path (Task 5), `consumeBudget` option shape (Task 7), `ai` SDK usage field names (Task 2). Each is flagged inline.
