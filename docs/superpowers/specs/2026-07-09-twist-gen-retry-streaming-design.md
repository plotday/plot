# Twist Generation: Multi-Turn Retries + Streaming Output — Design

**Date:** 2026-07-09
**Status:** Approved (brainstorming complete)
**Branch:** `twist-gen-retry-streaming` (off main, post core#643)

## Purpose

The generation loop's two remaining structural defects, plus the streaming
migration that removes the output-size cliff:

1. **Retries drop the spec.** Attempt 2+ sends only the previous JSON and
   build errors — repairs drift from intent, and the previous source is
   shown in the obsolete record shape while the schema demands arrays.
2. **LLM-level failures are fatal.** Truncation, schema mismatches, and
   transient 429/529s abort the whole generation (this made
   `gemini-3-flash-preview` score 0/24: 12 truncations at the 16K cap, 12
   schema failures, zero retries).
3. **`generateObject` is deprecated in ai@7** ("Use `generateText` with an
   `output` setting instead") and its non-streaming nature is why the
   output cap sits at 16K.

Measured against the post-PR-A reference
(`evals/results/20260708-230257-pr-a.json`).

## Decisions (from brainstorming)

1. **Multi-turn retry conversation.** Attempt 2+ sends the growing
   conversation: user(spec + requirements) → assistant(prior generated
   output, serialized in the array shape) → user(merged build errors + fix
   instruction). Fixes the dropped-spec bug and the record-shape gap;
   monotonic prefix keeps provider prompt-caching effective. Rejected:
   fresh single-turn with spec re-included (worse caching; prior output as
   quoted text rather than the model's own turn).
2. **Budgets: 3 build attempts + per-call LLM retries.** `MAX_ATTEMPTS = 3`
   build-repair rounds unchanged. Within each round the LLM call gets: ≤2
   retries with jittered exponential backoff for transient errors
   (429/5xx/network), and 1 retry for output problems (schema mismatch or
   truncation) with the failure appended to the conversation. Worst case
   ~9 LLM calls; typical unchanged. Rejected: flat total budget (transient
   bursts starve repair rounds); transient-only retries (leaves the
   biggest measured killer unhandled).
3. **API: `streamText` + structured `output`** (the non-deprecated ai@7
   surface), `maxOutputTokens` 16_000 → **60_000**. The partial-output
   stream drives per-file progress messages through the existing
   `onProgress`/SSE plumbing.
4. **Expectations by model tier (measurement framing).** On
   `gemini-3.1-pro-preview` the remaining failures are assertion-level
   (invisible to the pipeline), so full-pass is expected ~flat — the gate
   is NO REGRESSION plus retry telemetry visibility. The headline metric
   is the flash A/B: `gemini-3-flash-preview` scored 0/24 pre-PR-B
   (truncation + schema, both now retried/repaired at a 60K cap), so
   material improvement there demonstrates the change.

## Non-goals

- No prompt-content changes (docs curation, exemplars — PR C).
- No changed-files-only repair mode (measure full-regeneration repair first).
- No provider additions; the gemini/claude routing and provider-conditional
  instructions from core#635 are untouched.
- No builder/container changes (PR A shipped those).
- No SSE protocol changes — progress messages ride the existing
  `onProgress` → `SSEStream.sendProgress` path.

## Changes (all in `workers/api/src/twist/generator.ts` unless noted)

### Conversation state

- `generateTwistInner` builds `const conversation: ModelMessage[]` starting
  with the single user message (spec + requirements — text unchanged).
- After each successful parse, push an assistant turn whose content is the
  generated object serialized as JSON in the ARRAY shape (what the model
  actually produced), and on build failure push a user turn:
  `"The twist failed to build. Errors:\n\n<merged errors>\n\nFix these and return the complete corrected twist."`
  (exact copy in the plan). The retry prompt constant that exists today is
  replaced by this turn structure; requirements text stays only in the
  first user message.

### LLM call: `streamText` + output

- Replace `generateObject` with the ai@7 `streamText` + structured-output
  call (exact import/property names — `Output.object`-style helper, the
  partial/element stream, final output accessor, usage promise — pinned at
  plan time from the installed d.ts).
- `maxOutputTokens: 60_000`.
- Consume the partial-output stream: when a new `files[i].path` first
  appears, emit `onProgress(\`Writing ${path}\`)` (once per file per
  attempt). Stream consumption must not double-await the final result.
- Provider-conditional `instructions` and `resolveGenerationModel` are
  unchanged.

### Retry wrapper (new, small, unit-tested)

```
callModelWithRetries(conversation, attempt, onEvent, deps) →
  { object, usage } | throws
```

- **Transient** (HTTP 429/5xx, network/socket errors — classified by
  error name/statusCode duck-typing): retry ≤2 with backoff
  1s/4s + full jitter; emit `llm_retry {attempt, reason: "transient", retry: n}`.
- **Output problem** (structured-output parse/validation failure or
  `finishReason === "length"`): 1 retry after appending a user turn
  describing the malformed output ("Your previous response was not a valid
  twist object (<reason>). Return the complete twist again, matching the
  schema exactly."); emit `llm_retry {reason: "output"}`. The appended turn
  stays in the conversation for subsequent build attempts (it is part of
  history).
- Exhausted budgets rethrow the final error — downstream classification
  (`captureGenerationFailure`, harness classifier) sees the same error
  classes as today, now only after retries.

### Telemetry (additive)

- `GenerateAttemptEvent` gains
  `{ type: "llm_retry"; attempt: number; reason: "transient" | "output"; retry: number }`.
- `llm_complete.usage` extraction ported to the streamText result surface
  (total usage across the call; provider cache fields as before).
- All emissions via the existing `safeEmit`.

### Eval harness (additive)

- `SpecResult` gains `llmRetries: number` (count of `llm_retry` events);
  scorecard gains a `retries` column; results stay `schemaVersion: 1`
  (optional field). Classifier unchanged.

## Error handling

- Backoff sleeps are plain `setTimeout` promises; no timers leak on throw.
- A stream that errors mid-flight is treated as the underlying error class
  (transient vs output) — never a partial object.
- The 10-minute harness timeout and the SSE heartbeat already cover the
  longer worst case (~9 calls); no changes needed, but the plan verifies
  the arithmetic (9 × ~30-60s generation < heartbeat-kept SSE and < eval
  timeout is NOT guaranteed for the eval timeout — the harness per-spec
  timeout stays 10 min and worst-case budget exhaustion may hit it;
  acceptable, classified as `timeout`).

## Verification

1. Unit (`generator.test.ts`, mocked streamText): conversation growth
   across attempts (spec present in every call; assistant turns in array
   shape; error turns appended); transient retry (fake 529 → success) with
   backoff-called evidence and `llm_retry` emission; output-problem retry;
   budget exhaustion rethrows; per-file progress emitted once per file;
   60K cap passed through.
2. Harness unit: `llmRetries` summation + scorecard column.
3. **Pro comparison** (~$6): `--label pr-b --runs 2 --compare
   evals/results/20260708-230257-pr-a.json`. Gates: full-pass ≥ PR-A's 67%
   minus noise (>8pp drop = stop), pipeline 100%, no new taxonomy classes.
4. **Flash A/B** (~$1): `--model gemini-3-flash-preview --label pr-b-flash
   --runs 2` vs the flash baseline (0/24). Gate: material full-pass
   improvement (headline metric); truncation class ≈ eliminated at 60K.

## Success criteria

- Retries always see the original spec and their own prior output in the
  correct shape.
- Transient/output LLM failures are retried within budget; only exhausted
  budgets abort.
- Deprecated API gone; output cap 60K; per-file progress visible over SSE.
- Both measurement gates pass.
