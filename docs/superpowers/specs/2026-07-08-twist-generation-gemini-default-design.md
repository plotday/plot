# Twist Generation on Gemini (Provider Routing) — Design

**Date:** 2026-07-08
**Status:** Approved (brainstorming complete)
**Branch:** `twist-gen-gemini`, stacked on `twist-gen-eval-harness` (core#629)

## Purpose

Switch the spec→twist generation pipeline's default model from Anthropic
(`claude-sonnet-4-6`) to Gemini (`gemini-3-pro-preview`), routed by model-id
prefix so any supported model remains selectable per call. Motivation: the
development Anthropic account is out of credits, blocking the eval harness's
baseline run; the Google AI Studio key has ample quota and is already
deployed (`GOOGLE_GENERATIVE_AI_API_KEY`, used by every system LLM call and
the production classifier). This is the precursor PR to the
builder/generator/prompt improvement PRs — the baseline all of them will be
measured against runs on Gemini.

## Decisions (from brainstorming)

1. **Default model:** `gemini-3-pro-preview` — Pro-class for whole-program
   code generation. It is not yet used anywhere in the repo, so the first
   smoke run doubles as the access check; if the gateway/key rejects the
   model id, the fallback is a one-line default change to
   `gemini-3-flash-preview` (known-good on this gateway).
2. **Routing:** by model-id prefix inside the generator (`gemini-*` →
   Google, `claude-*` → Anthropic, else error). Rejected alternatives:
   reusing `createSystemModel` (pinned to one Flash model with
   minimal-thinking config — wrong knobs for codegen, no A/B) and a general
   provider-registry util (YAGNI for one call site; promote later if needed).
3. **Caching:** Claude keeps the explicit `SystemModelMessage` +
   `anthropic.cacheControl` instructions; Gemini gets a plain-string
   `instructions` (Gemini 2.5+/3 applies implicit context caching; no
   provider options required).
4. **Thinking:** no `thinkingConfig` override for generation — unlike the
   classifier's minimal-thinking `SYSTEM_PROVIDER_OPTIONS`, codegen gets the
   model's default reasoning budget.
5. **Branch strategy:** stacked branch in the existing worktree; PR based on
   `twist-gen-eval-harness` (re-based to `main` after core#629 merges).

## Non-goals

- No retry-loop, streaming, prompt-content, or builder changes (those are
  the follow-up PRs this one unblocks).
- No new API surface: the HTTP route does not expose model selection; only
  `GenerateTwistOptions.model` (used by the eval harness `--model`) does.
- No removal of the Anthropic path — cross-provider A/B is a goal of the
  harness once credits exist.

## Changes

### `workers/api/src/twist/generator.ts`

- `DEFAULT_GENERATION_MODEL = "gemini-3-pro-preview"`.
- New internal helper:

  ```ts
  function resolveGenerationModel(env: Bindings, modelId: string): LanguageModel
  ```

  - Requires the AI Gateway trio (`AI_GATEWAY_ACCOUNT_ID`, `AI_GATEWAY_ID`,
    `AI_GATEWAY_TOKEN`) — existing "AI Gateway configuration is missing"
    guard stays.
  - `modelId.startsWith("gemini")` → `createGoogleGenerativeAI` with
    `baseURL: <gateway>/google-ai-studio/v1beta`, `apiKey:
    env.GOOGLE_GENERATIVE_AI_API_KEY`, `cf-aig-authorization` header —
    byte-consistent with `utils/system-model.ts`. Missing key → throw
    `"GOOGLE_GENERATIVE_AI_API_KEY is missing"`.
  - `modelId.startsWith("claude")` → existing `createAnthropic` gateway
    wiring. Missing key → throw `"ANTHROPIC_API_KEY is missing"`.
  - Anything else → throw `` `Unsupported generation model: ${modelId}` ``.
- Provider-conditional prompt construction: for `claude-*`, `instructions`
  is the existing `SystemModelMessage` with `anthropic.cacheControl`
  ephemeral; for `gemini-*`, `instructions: systemPrompt` (plain string).
  The user-message `messages` array and retry-prompt text are unchanged.
- `extractUsage` gains a Google branch: cache reads from
  `providerMetadata.google.cachedContentTokenCount` (number) when present,
  falling back to the already-read normalized `usage.cachedInputTokens`;
  `cacheCreationInputTokens` stays Anthropic-only (Gemini implicit caching
  has no write-token concept surfaced here).
- Tests (`generator.test.ts`): mock `@ai-sdk/google` alongside
  `@ai-sdk/anthropic` (factory records baseURL/model id); assert
  (a) default model routes to the Google factory with the
  `google-ai-studio/v1beta` gateway baseURL and plain-string instructions,
  (b) `model: "claude-..."` routes to Anthropic with the SystemModelMessage
  + cacheControl shape (port existing assertions),
  (c) unknown model id rejects with `Unsupported generation model`,
  (d) missing GOOGLE key with a gemini model rejects with the key error,
  (e) google usage metadata maps into `llm_complete.usage`.

### `workers/api/evals/` (harness)

- `lib/env.ts`: `assertRequiredVars(vars, model)` — gateway trio +
  `GOOGLE_GENERATIVE_AI_API_KEY` always required; `ANTHROPIC_API_KEY`
  required only when `model.startsWith("claude")`. `buildEvalEnv` passes
  both provider keys through when present (still no `POSTHOG_API_KEY`).
- `lib/cli.ts`: reject `--model` values not starting with `gemini` or
  `claude` at parse time (fail fast, before Docker/build work).
- `lib/report.ts`: add `MODEL_RATES` entries for `gemini-3-pro-preview` and
  `gemini-3-flash-preview` (USD per MTok, public list prices, labelled
  estimates like the existing entry); unknown-model fallback becomes the
  `gemini-3-pro-preview` entry.
- `run.ts`: pass the resolved model into `assertRequiredVars`.
- `README.md`: prerequisites now name `GOOGLE_GENERATIVE_AI_API_KEY`
  (always) and `ANTHROPIC_API_KEY` (only for `--model claude-*`); model A/B
  example updated to show a claude model as the comparison run.
- `generator.e2e.test.ts` (opt-in): required-vars list updated to match
  (google key required; anthropic key only if the test is pointed at a
  claude model — default: google).

### Failure classification note

An unsupported model id or missing provider key throws before any attempt;
the harness classifies unknown errors as `api_error`. The CLI-level
validation and preflight `assertRequiredVars` exist precisely so these never
reach `generateTwist` in harness runs; no classifier changes needed.

## Verification

1. Unit: `generator.test.ts` + `evals/__tests__/*` green; lint clean.
2. Smoke (access check): `pnpm --filter @plotday/api eval:twist-gen --only
   hello-thread --label gemini-smoke`. Success = a real LLM round trip
   (nonzero llm ms/tokens); any downstream check status is valid data. If
   the gateway rejects `gemini-3-pro-preview`, flip the default to
   `gemini-3-flash-preview` (one line + tests) and note it in the PR.
3. Confirm token/cost scorecard columns are populated (first live-call
   validation of `sumTokens`/`estimateCostUsd` — an outstanding item from
   the harness review).
4. Full baseline: `eval:twist-gen --label baseline-gemini-3-pro --runs 2`
   (~$5–10) — the baseline for the follow-up improvement PRs.

## Success criteria

- Default `/v1/twist/generate` path generates via Gemini through the AI
  Gateway with no Anthropic dependency.
- `--model claude-sonnet-4-6` still routes to Anthropic unchanged (verified
  by unit tests; live run deferred until credits exist).
- Baseline results JSON exists and the scorecard shows real token/cost data.

## Addendum (2026-07-08, post-baseline): Gemini-compatible generation schema

Live measurement invalidated one spec assumption: Gemini cannot produce the
record-shaped `twistSourceSchema` at all. Both `gemini-3-flash-preview`
(0/24: 12 output_truncated, 12 schema_mismatch) and `gemini-3.1-pro-preview`
(0/24: all schema_mismatch, "missing required 'index.ts'") return an
effectively empty `files` object — Gemini's structured-output schema is an
OpenAPI subset that cannot express dynamic-key maps (`z.record`), so the
model never sees what belongs inside `files`/`dependencies`. (Also found:
`gemini-3-pro-preview` was retired upstream; the default is now
`gemini-3.1-pro-preview`.)

Approved additions to this feature:

1. **Model-facing schema reshape (provider-neutral).** `generateObject` now
   uses `files: Array<{path, content}>` and
   `dependencies: Array<{name, version}>`, mapped back to the existing
   Record-shaped `TwistSource` immediately after generation
   (`toTwistSource`). Nothing downstream of `generateTwist` changes; Claude
   handles the array shape equally well. Duplicate paths: last entry wins.
2. **Gateway cache bypass for evals.** AI Gateway response-caching served
   identical cached responses for `--runs 2` second passes (near-zero
   latency, byte-identical tokens), defeating variance measurement.
   `GenerateTwistOptions` gains additive `skipGatewayCache?: boolean`
   (default false — production keeps gateway caching), which adds the
   `cf-aig-skip-cache: true` header on both providers; the eval harness
   always sets it.

Verification for the addendum: unit tests for the mapping and the header;
re-smoke + re-baseline on `gemini-3.1-pro-preview` (additional ~$6
authorized; total feature spend ~$12).
