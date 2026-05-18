# Hybrid Thread Classifier — Design

**Status:** Draft
**Date:** 2026-05-18
**Spec for:** A tunable, hybrid alternative to `classify_thread_for_user_explain` (the current SQL classifier) that the eval framework can sweep parameters against. Adds an author signal, fuzzy topic/title matching, tunable kNN aggregation, and optional LLM stages for ambiguous and cold-start cases.

---

## 1. Background

The production classifier today is the PostgreSQL function `classify_thread_for_user_explain` (defined in `libs/db/schema/60-functions/classify_thread_for_user.sql`). It runs a deterministic cascade:

1. **Topic short-circuit** — exact-topic siblings of any `user_moved` thread.
2. **Cross-user keyed priority** — recipient's same-`key`'d priority when another user filed the thread there.
3. **Channel default** — channel's `default_priority_id` when `topic = 'channel:<pk>'`.
4. **Scoring** — kNN over `user_moved` threads. Per-neighbor: `combined = 0.5·sem² + 0.35·con² + 0.15·grp²`. Top-1 wins if `combined ≥ 0.15`. Signals: cosine on the 384-dim embedding, Jaccard on linked-alias-expanded contacts, Jaccard on groups.
5. **`priority:KEY[:…]` prefix.**
6. **Root fallback.**

The classifier is invoked from triggers and the API via `workers/api/src/state/classify-thread.ts`. The eval framework wraps the same function as the `sql:current` classifier.

### Observed gaps

- **No author signal.** `thread.created_by` is never read. Strong predictor in practice (a contact's threads, a twist instance's threads).
- **Source/topic only matches exactly.** `channel:163` and `channel:164` get no credit for being from the same connector or for sharing a connector-prefix pattern.
- **Title text is unused** outside the embedding.
- **Scoring is single-neighbor argmax.** No top-k aggregation; one noisy neighbor can swing the result.
- **Weights and threshold are baked into SQL.** Tuning requires editing a schema function and migrating.
- **No cold-start handling.** New users (zero `user_moved` examples) fall straight through to `root_fallback`.

Baseline on the `kris` corpus: **40% expected accuracy, 18 regressions / 30 cases.**

---

## 2. Goals and non-goals

### Goals

- A new TS-side classifier `ts:hybrid` registered in `libs/eval/src/classifiers/registry.ts` that:
  - Adds the missing author signal and fuzzy topic/title signals.
  - Supports tunable per-signal weights, nonlinearity, kNN aggregation, and decision thresholds.
  - Is parameterized by a single `params` object so we can register many variants and sweep settings across corpora.
- An LLM-augmented sibling `ts:hybrid-llm` that strictly adds two stages — tie-breaker and cold-start — gated to fire only when scoring is genuinely ambiguous or absent.
- Eval-framework support for measuring LLM call rate alongside accuracy.
- A path to wiring the same classifier into production (`workers/api/src/state/classify-thread.ts`).

### Non-goals (this spec)

- Replacing the production SQL classifier. Production wiring is described but staged behind a flag; cut-over is a follow-up.
- Per-priority prototype models (Option B from brainstorming) — natural follow-up once `ts:hybrid` is established.
- LLM-derived thread tags as a persisted signal (Option 5) — separate project (schema column, async queue).
- Offline LLM labeling at sign-up (Option 4) — separate utility, evaluated on its own corpora.
- Changing the meaning of any existing cascade stage. Topic short-circuit, channel default, keyed priority, `priority:KEY` prefix, root fallback all keep their current behavior.

---

## 3. Architecture

### 3.1 Cascade order (`ts:hybrid` and `ts:hybrid-llm`)

The cascade keeps the deterministic stages up front so the LLM never sees an "easy" thread.

1. **Topic short-circuit** — unchanged from SQL classifier.
2. **Cross-user keyed priority** — unchanged.
3. **Channel default** — unchanged.
4. **`priority:KEY` prefix** — *moved earlier* (was step 5 in SQL). Stamped topics are deterministic intent; they must beat both scoring and the LLM. Ordering rationale: only fires when `topic LIKE 'priority:%'`, so it's free to run before scoring.
5. **Scoring stage** — new signals and aggregation; details in §4.
6. **LLM tie-breaker** *(only in `ts:hybrid-llm`)* — fires when scoring produced a low-confidence winner. Gates in §5.1.
7. **Deterministic cold-start shortcuts** — author/twist mapping, contact-only history, single-priority bypass. §5.2.
8. **LLM cold-start** *(only in `ts:hybrid-llm`)* — last resort before root.
9. **Root fallback.**

`ts:hybrid` is `ts:hybrid-llm` minus stages 6 and 8.

### 3.2 What runs where

- **Classifier definition:** `libs/eval/src/classifiers/ts-hybrid.ts` (and `ts-hybrid-llm.ts`).
- **Registration:** `libs/eval/src/classifiers/registry.ts`.
- **Production entry point** (later): `workers/api/src/state/classify-thread.ts` grows a feature-flagged path that calls the TS classifier instead of `classify_thread_for_user`. The flag is per-user and defaults off until eval results justify it.
- **LLM prompts:** `libs/eval/src/classifiers/prompts/<name>-v<n>.txt`, referenced by id from params for reproducibility.

### 3.3 Data access

Both classifiers consume `ClassifierContext.db` (the per-run sandbox Kysely handle in evals; a request-scoped Kysely handle in production). All queries use parameterized statements; no raw SQL injected from candidate text.

The classifier needs read access to:

- `public.thread_priority` (the `user_moved` examples)
- `public.thread` (text, embedding, topic, contacts, groups, `created_by`)
- `public.priority` (titles, paths, keys, archived state)
- `public.contact` (for author identity lookup)
- `public.channel` (already used by channel-default stage)

In evals these are all available in the sandbox schema. In production the request-scoped Kysely handle from `withUserDb` is the canonical caller.

---

## 4. Scoring stage (§3.1 step 5)

### 4.1 Signals

For each `user_moved` thread `n` and the candidate `c`, compute six per-signal scores in `[0, 1]`:

| Signal | Definition |
|---|---|
| `sem` | `max(0, cosineSim(n.embedding, c.embedding) − 0.5) · 2`, falling back to `0` if either embedding is missing. |
| `con` | Jaccard on linked-alias-expanded contact sets. Reuses `public.expand_contacts()`. |
| `grp` | Jaccard on group sets. |
| `author` | `1.0` if `n.created_by = c.created_by`, else `0`. (Future: contact-linked alias expansion of authors.) |
| `topic_fuzzy` | `1.0` if topics equal; `α_prefix` (default `0.6`) if topics share at least the leading colon-segment (e.g. `channel:164` and `channel:163` both start with `channel:` — score `α_prefix`; `slack:foo` and `gmail:bar` share no leading segment — score `0`); `0` otherwise. The exact-match case is also a hard short-circuit upstream — this signal is for *neighbor scoring*, not for the short-circuit stage. |
| `title` | Jaccard on lowercased character trigrams of titles (cheap, language-agnostic, no embedding required). |

Each signal is passed through a configurable **nonlinearity** (`identity` \| `square` \| `sigmoid`). The current SQL classifier uses `square`; that's the default for backward parity.

### 4.2 Per-neighbor combined score

```
combined(n) = Σ_s weights[s] · nonlin(signal_s(n, c))
```

Weights sum to 1 (enforced at construction). Default weights, biased toward the current SQL behavior plus the new signals at modest starting values:

```
sem = 0.40,  con = 0.25,  grp = 0.10,
author = 0.10,  topic_fuzzy = 0.10,  title = 0.05
```

### 4.3 Aggregation across neighbors → per-priority score

The SQL classifier picks `argmax_n combined(n)` and returns `n.priority_id`. The TS classifier aggregates neighbors per priority before picking:

- `top1` — current behavior; pick the priority of the single highest-scoring neighbor.
- `topk_mean` — for each priority `p`, take the mean of its top `k` neighbors' `combined` scores; pick the priority with the highest mean.
- `softmax` — weight each neighbor's contribution by `exp(combined / T)` and sum per priority; pick the highest sum. `T` is a tunable temperature.

`k` and `T` are params. Default: `topk_mean` with `k = 3` (smoothing without flattening). When a priority has fewer than `k` neighbors, average over what's available.

### 4.4 Decision

Let `top1_score` and `top2_score` be the top two per-priority scores after aggregation. The scoring stage returns a winner if:

```
top1_score >= scoreThreshold
```

Default `scoreThreshold = 0.15` (matches SQL classifier).

The `scores` JSON returned for debugging includes:

```json
{
  "perPrioritySorted": [{ "priorityId", "score", "neighborCount" }, ...],
  "topNeighbors": [{ "priorityId", "threadId", "sem", "con", "grp", "author", "topic_fuzzy", "title", "combined" }, ...]
}
```

This is the same shape as the SQL classifier's existing `top` array, extended with the new signals and the per-priority view.

---

## 5. LLM stages (only in `ts:hybrid-llm`)

### 5.1 Tie-breaker

**Fires when:** scoring produced a winner *and* the win is ambiguous. Both gates must trip:

- `top1_score ∈ [scoreThreshold, highConfidenceFloor]` — soft band, **and**
- `top1_score − top2_score < marginFloor` — close call.

Optional third gate: `top1 priority has < nSupportingNeighbors at floor combined ≥ supportingFloor` — single-noisy-neighbor wins are interrogated even at higher absolute scores.

**Default params:** `highConfidenceFloor = 0.45`, `marginFloor = 0.08`, `nSupportingNeighbors = 2`, `supportingFloor = 0.25`.

**Prompt:** the candidate (title, topic, contact display names, first ~500 chars of any attached note) plus the top-`k` candidate priorities, each with one or two exemplar `user_moved` threads (title + topic + contacts). Output: chosen `priority_id` and a one-sentence rationale.

`k` (candidates in prompt) is tunable; default 3.

### 5.2 Deterministic cold-start shortcuts (§3.1 step 7)

These run when scoring returned nothing, **before** the LLM cold-start. Each is cheap and individually toggle-able.

- **Twist-author mapping** — if `c.created_by` belongs to a twist instance whose recent threads have consistently landed in one priority (`≥ minTwistSamples` examples with `≥ twistAgreement` fraction), predict that priority. Default `minTwistSamples = 3`, `twistAgreement = 0.8`.
- **Contact-only history** — if every prior thread sharing a contact with `c` landed in the same priority (`≥ minContactSamples`, default 2), predict that priority.
- **Single-priority user** — if the user has only a root priority (or one non-root priority), return it directly; the LLM has no useful choice to make.

### 5.3 LLM cold-start

**Fires when:** scoring returned nothing, all deterministic shortcuts in §5.2 missed, and the user has at least two non-root priorities.

**Prompt:** the user's priority tree (`title`, `path` rendered as breadcrumbs, optional `key`, optional priority description if we add one in a later spec) plus the candidate. Output: chosen `priority_id` and rationale.

**Truncation:** if the priority tree exceeds `maxPrioritiesInPrompt` (default 30), pre-filter to candidates whose path-segment titles share a token with the candidate title/topic, plus all depth-1 priorities. (This is a cheap heuristic; we can sharpen it later.)

### 5.4 Caching, budget, batching

- **Response cache.** Key: `sha256(JSON({ model, promptTemplateId, normalizedInputs }))`. `normalizedInputs` includes title, topic, sorted contact UUIDs, sorted candidate priority IDs (for tie-breaker), and the first 500 chars of attached note text. Value: chosen `priority_id` + rationale + model + timestamp.
  - In evals: persisted to `libs/eval/.cache/llm/` (gitignored). First eval run populates; subsequent runs are free and deterministic.
  - In production: Workers KV with 30-day TTL. Avoids re-cost on retries and replays.
- **Per-user daily budget.** Soft cap (default 50 LLM calls/user/day, tunable). When exceeded, the LLM stages no-op and the cascade falls through to root_fallback (or whatever scoring's best guess was). Cap and usage are logged.
- **Batching.** When N candidate threads arrive for the same user within a short window, the cold-start prompt can hold the priority tree once and ask the model to classify all N. The tie-breaker doesn't batch (each call has different candidate priorities).

### 5.5 Models and determinism

- **Model:** default `claude-haiku-4-5-20251001` (fast, cheap, good enough for short-context classification). `model: 'off'` disables the LLM stages entirely — useful for ablation.
- **Temperature:** `0`. Determinism matters for eval reproducibility; the cache key includes the model id so a model upgrade invalidates the cache cleanly.
- **Prompt versioning.** Prompts live in versioned files (`coldstart-v1.txt`, `tiebreaker-v1.txt`). The classifier params reference them by id. Editing a prompt means bumping the id and a new cache namespace.

---

## 6. Classifier params (the tuning surface)

```ts
type HybridParams = {
  // Scoring stage
  weights: {
    sem: number; con: number; grp: number;
    author: number; topic_fuzzy: number; title: number;
  };
  topicFuzzyPrefixWeight: number;          // α_prefix in §4.1
  nonlinearity: "identity" | "square" | "sigmoid";
  aggregation:
    | { mode: "top1" }
    | { mode: "topk_mean"; k: number }
    | { mode: "softmax"; temperature: number };
  scoreThreshold: number;

  // Gates (only used by ts:hybrid-llm)
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

  // LLM (only used by ts:hybrid-llm)
  llm?: {
    model: "claude-haiku-4-5-20251001" | "claude-sonnet-4-6" | "off";
    tieBreaker: { enabled: boolean; maxCandidates: number; promptId: string };
    coldStart: { enabled: boolean; maxPrioritiesInPrompt: number; promptId: string };
    dailyBudgetPerUser: number;
    cacheNamespace: string;                // override for ablation runs
  };
};
```

Defaults live in `libs/eval/src/classifiers/ts-hybrid.defaults.ts` so they're version-controlled and citable from eval reports.

### Variant registration

`registerClassifier` takes a `Classifier` instance. We add a helper to register named variants:

```ts
registerVariant("ts:hybrid:default", makeHybrid(DEFAULTS));
registerVariant("ts:hybrid:no-author", makeHybrid({ ...DEFAULTS, weights: { ...DEFAULTS.weights, author: 0 } }));
registerVariant("ts:hybrid-llm:default", makeHybridLlm(DEFAULTS_LLM));
registerVariant("ts:hybrid-llm:tight-gates", makeHybridLlm({ ...DEFAULTS_LLM, highConfidenceFloor: 0.55, marginFloor: 0.12 }));
```

CLI usage stays unchanged — `pnpm --filter @plotday/eval eval -- --corpus kris --classifiers ts:hybrid:default,sql:current` runs both side by side.

---

## 7. Eval framework changes

### 7.1 Run summary

Extend `RunSummary.perClassifierTraining` with two fields:

```ts
{
  // ... existing
  llmCallsPerCase: number;        // total LLM calls / total cases evaluated
  llmCacheHitRate: number | null; // hits / (hits + misses), null if no LLM
}
```

These wire into `scoring/report.ts` so the existing Markdown table grows two columns:

| Classifier | Gold acc | Expected acc | Regressions | LLM calls / case | Cache hit rate | Avg ms |
|---|---|---|---|---|---|---|

This is the visible "Pareto" view — tightening gates should drive LLM calls down while watching whether accuracy moves.

### 7.2 LLM response cache

- Location: `libs/eval/.cache/llm/<cacheNamespace>/<sha>.json`. Gitignored.
- Format: `{ inputHash, model, promptTemplateId, response: { priorityId, rationale }, timestamp }`.
- Eviction: none (manual `rm -rf` if a prompt or model is retired).
- Cache misses in tests/CI: configurable. Local dev defaults to hit-the-API. CI defaults to **fail on miss** so PRs don't accidentally rely on uncached LLM calls — the contributor is expected to populate the cache locally and commit it (or run a recorded fixture step).

### 7.3 Cold-start training sets

Add two training-set files alongside `full.yaml`:

- `trainings/empty.yaml` — zero `user_moved` threads. Exercises pure cold-start.
- `trainings/first-day.yaml` — 1–2 `user_moved` threads. Exercises the "scoring stage is sparse, LLM-or-shortcut should fill in" regime.

The runner already loads multiple training sets in series (`run.ts:75-85`), so this is purely a corpus addition. The existing `synthetic-tiny` corpus already has `empty.yaml`; we mirror it in `kris`.

### 7.4 Author labels in corpora

`CorpusCase.candidate` and the training thread shape gain an optional `author` field — a slug into `world.contacts` (for human-authored threads) or a literal `"twist:<slug>"` (for twist-authored threads). Existing corpora load fine with the field absent; the classifier just sees `created_by = null` and skips the author signal. Adding labels to `kris` and `synthetic-tiny` is a low-effort follow-up.

---

## 8. Production wiring

**Out of scope for this spec to flip the switch**, but the design supports it:

`workers/api/src/state/classify-thread.ts` already wraps the SQL function behind a typed entry point. We add a parallel `classifyThreadForUserHybrid()` that constructs `ts:hybrid` (or `ts:hybrid-llm`) with production-default params, runs it against `c.var.db`, and returns the same `ClassifyExplanation` shape. Call-site replacement is gated by a per-user feature flag (`hybridClassifier`) so we can ramp by user and roll back without a deploy.

LLM calls in production use the Anthropic SDK already present in workers. Cache lives in Workers KV under namespace `llm-classify:<promptId>`. Budget is tracked in the same KV namespace (`llm-budget:<userId>:<yyyymmdd>`).

No schema changes are required for this spec. (The existing `thread.created_by` is sufficient for the author signal.)

---

## 9. Implementation surface

New files:

- `libs/eval/src/classifiers/ts-hybrid.ts` — scoring stage and cascade, no LLM.
- `libs/eval/src/classifiers/ts-hybrid-llm.ts` — extends ts-hybrid with stages 6 & 8.
- `libs/eval/src/classifiers/ts-hybrid.defaults.ts` — typed default params.
- `libs/eval/src/classifiers/llm-cache.ts` — file-backed cache for evals.
- `libs/eval/src/classifiers/prompts/tiebreaker-v1.txt`
- `libs/eval/src/classifiers/prompts/coldstart-v1.txt`
- `libs/eval/corpora/kris/trainings/empty.yaml`
- `libs/eval/corpora/kris/trainings/first-day.yaml`

Modified files:

- `libs/eval/src/classifiers/registry.ts` — register new variants; add `registerVariant` helper.
- `libs/eval/src/runner/run.ts` — propagate LLM-call counts into `RunSummary`.
- `libs/eval/src/scoring/report.ts` — render new columns.
- `libs/eval/src/classifiers/types.ts` — extend `ClassificationResult` with `llmCalls: number` and `cacheHits: number`.
- `libs/eval/src/corpus/schema.ts` — optional `author` field on case candidates and training threads.
- `libs/eval/.gitignore` — add `.cache/`.

Out of scope for this spec (follow-ups):

- `workers/api/src/state/classify-thread.ts` — production wiring behind a flag.
- Workers KV bindings for the production LLM cache and budget.
- Migration of `kris` corpus cases to include author labels.

---

## 10. Testing

- **Unit tests** (`libs/eval/tests/ts-hybrid.test.ts`): each signal computed correctly given canonical inputs; aggregation modes produce expected per-priority scores; gates trip exactly at their boundaries.
- **Cascade tests**: each stage produces the expected stage label on a hand-crafted candidate.
- **LLM-stage tests** use a stub `LLMClient` injected via params; no network calls. Cache key stability is its own test.
- **Vitest smoke** against `synthetic-tiny` mirrors the existing `sql-current.test.ts`.
- **Regression check**: `pnpm --filter @plotday/eval eval -- --corpus kris --classifiers sql:current,ts:hybrid:default,ts:hybrid-llm:default` produces a report the eyeball test (and CI) reviews against baseline.

---

## 11. Risks and open questions

- **LLM cache hit rate in evals.** If cache misses are routine, eval iteration becomes slow and costly. The first eval run after any prompt or input change will pay full cost. Mitigation: prompt versioning, mock client for unit tests, an option to fall back to a recorded fixture in CI.
- **Author signal weakness in current corpora.** `kris` cases don't carry author labels yet. Until they do, `weights.author = 0` is the honest default for that corpus; eval results understate the new classifier's potential. Mitigation: a follow-up to enrich the corpus is small and well-scoped.
- **Production latency.** Even with deterministic gating, the LLM stages add tens of ms in the median (cache hits) and seconds in the tail (cache miss). The trigger-driven path can't tolerate seconds. Mitigation: move classification off the trigger and into the API/queue path before flipping the production flag.
- **The "soft band" for tie-breaker is a guess.** Defaults are placeholders; the eval framework is exactly the right tool to pick real numbers, and that's the first thing we'll do with this classifier.

---

## 12. Plan for first run

Once implemented:

1. `pnpm --filter @plotday/eval eval -- --corpus synthetic-tiny --classifiers sql:current,ts:hybrid:default` — sanity.
2. `pnpm --filter @plotday/eval eval -- --corpus kris --classifiers sql:current,ts:hybrid:default,ts:hybrid-llm:default` — baseline vs. new.
3. Sweep `weights.author`, `topicFuzzyPrefixWeight`, `aggregation.mode`, `scoreThreshold` against `kris`. Pick the Pareto frontier.
4. Sweep `highConfidenceFloor` and `marginFloor` against `kris`+`empty`/`first-day` training sets. Goal: LLM calls/case ≤ 0.15 while accuracy stays at or above the no-LLM hybrid.
5. Pick a single production default. Wire it in `workers/api/src/state/classify-thread.ts` behind the `hybridClassifier` flag.
