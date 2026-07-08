# Twist Generation Eval Harness — Design

**Date:** 2026-07-07
**Status:** Approved (brainstorming complete)
**Scope:** Measurement only — no changes to pipeline behavior.

## Purpose

The spec→twist generation pipeline (`POST /v1/twist/generate` → `generateTwist()` →
twist-builder container) has exactly one opt-in E2E test with a trivial spec. There is no
way to measure whether a prompt change, model bump, retry-policy change, or
`@plotday/twister` release helps or hurts. This harness provides that measurement: a
corpus of representative specs plus a local runner that reports pass rate, attempts used,
latency split, token cost, and a failure taxonomy.

Every planned pipeline improvement (typecheck-in-loop, retry fixes, npm-install removal,
prompt curation, model upgrades) should be evaluated with a before/after run of this
harness.

## Decisions (from brainstorming)

1. **Pass bar:** pipeline success + universal static checks + per-spec assertions +
   harness-run `tsc --noEmit`. Checks are pluggable so the bar tightens as pipeline
   improvements land.
2. **Run surface:** local CLI script only (`pnpm --filter @plotday/api eval:twist-gen`).
   No CI in v1.
3. **Corpus:** ~12 specs, one per representative category. ~$2–5 and ~15–30 min per full
   run at today's pipeline.
4. **Instrumentation:** small additive hooks on `generateTwist()` (`model` override +
   structured `onEvent`); defaults leave production behavior byte-identical.
5. **Architecture:** in-process — the runner imports `generateTwist()` directly and stubs
   `TWIST_BUILDER` at a locally booted Docker container, the pattern already proven by
   `workers/api/src/twist/generator.e2e.test.ts`.

## Non-goals

- No CI workflow, scheduling, or result publishing (layer on later if the harness earns it).
- No LLM-as-judge spec-fidelity scoring (pluggable check candidate for later).
- No runtime execution of generated twists (no worker-loader smoke test in v1).
- No changes to generation behavior: retry loop, prompts, container build, and default
  model stay exactly as they are. The harness measures the baseline; fixes are separate PRs.

## File layout

```
workers/api/evals/
  run.ts               # tsx entrypoint (CLI parsing, orchestration)
  lib/
    docker.ts          # build/boot/health-check/teardown twist-builder container
    env.ts             # load .dev.vars → Bindings with local-container TWIST_BUILDER stub
    corpus.ts          # load + validate corpus spec files
    checks.ts          # universal checks, per-spec assertions, tsc typecheck
    classify.ts        # failure taxonomy classifier
    report.ts          # results JSON, stdout scorecard, --compare rendering
    pool.ts            # small promise-pool concurrency helper
  corpus/              # 12 spec .md files (format below)
  results/             # one JSON per run — gitignored
  __tests__/           # unit tests for lib modules (no Docker, no API keys)
  README.md            # how to run, cost expectations, how to add a spec
```

`workers/api/.gitignore` (or repo root) gains `evals/results/`.

`docker.ts`/`env.ts` intentionally duplicate ~40 lines of helper logic from
`generator.e2e.test.ts` (dev-vars parsing, container stub, health wait) rather than
sharing a module across `src/` and `evals/` — zero risk to existing test wiring; a later
refactor can unify them.

## Corpus format

Each spec is one markdown file. YAML frontmatter carries metadata and expectations; the
body is exactly what a user would write in `plot-twist.md` — plain-language intent, never
implementation instructions (no tool names, no SDK identifiers in the body).

```markdown
---
id: scheduled-poll
category: scheduling
difficulty: medium
assertions:
  - match: "runRecurringTask|recurringTask|recurring"
    why: must schedule recurring work
notMatch:
  - pattern: "extends\\s+Connector"
    why: twists extend Twist, not Connector
allowDeps: []            # npm packages acceptable beyond @plotday/twister
---
# Morning news digest

Every morning at 8am, fetch the top five Hacker News stories and create a thread
titled with today's date containing a note that lists each story as a link.
```

- `assertions[].match` / `notMatch[].pattern`: JS regexes (case-sensitive) evaluated
  against the concatenation of all generated source files.
- `allowDeps`: informational allowlist; deps outside it don't fail the spec but are
  reported (the dependency-choice signal matters, hard failure doesn't).
- Loader validation: unique `id`s, valid regexes, non-empty body. `corpusHash` (sha256 of
  the full file) is recorded per spec in results so `--compare` can flag edited specs.

## The 12 corpus specs

| id | category | difficulty | body intent (implementer writes full text) | key assertions |
|---|---|---|---|---|
| hello-thread | smoke | easy | On activation, create one thread with a short markdown note | `createThread`, `extends Twist` |
| scheduled-poll | scheduling | medium | Every morning, fetch HN top stories, create a dated digest thread | recurring-task usage, `fetch\|network` |
| webhook-handler | webhook | medium | Receive GitHub push webhooks; one thread per push with commit list | webhook/url-callback registration |
| ai-intents | ai | medium | When a user writes a note asking for a summary, reply with an AI-written summary note | intent/AI tool usage, `onNoteCreated\|intents` |
| auth-integration | integration | hard | Connect to GitHub with the user's account; sync issues assigned to them as task threads | integrations/auth usage, source/key upsert |
| batch-sync | batching | hard | Import a large paginated dataset (thousands of items) without hitting execution limits | `runTask`, store-based cursor |
| note-reaction | events | easy | When any note contains "TODO:", create a task thread referencing it | `onNoteCreated`, guard against own/automated notes |
| store-lifecycle | state | medium | Keep a running counter of threads created; include it in each new thread | `store` get/set, no instance-variable state (notMatch on class fields for state) |
| multi-file | structure | medium | Spec explicitly asks for parsing logic separated from the entry point | ≥2 files in `files`, import between them |
| external-dep | deps | medium | Validate an inbound JSON payload against a schema, rejecting malformed items | dependency beyond twister (e.g. zod) in `dependencies` |
| thread-actions | actions | medium | Post a thread with Approve/Reject buttons; record the choice as a note | action definitions + callback wiring |
| deactivate-cleanup | lifecycle | medium | Twist that registers a webhook + recurring task, and cleans up everything when removed | `deactivate` override deleting callbacks/tasks |

Difficulty is descriptive only (reported, not weighted). Hard categories are expected to
fail at today's baseline — that is the point of measuring.

## Generator hooks (only production-code change)

In `workers/api/src/twist/generator.ts`, additive and backward-compatible:

```ts
export type GenerateAttemptEvent =
  | { type: "attempt_start"; attempt: number }
  | {
      type: "llm_complete";
      attempt: number;
      durationMs: number;
      usage?: {
        inputTokens?: number;
        outputTokens?: number;
        cacheReadInputTokens?: number;
        cacheCreationInputTokens?: number;
      };
    }
  | {
      type: "build_complete";
      attempt: number;
      durationMs: number;
      success: boolean;
      errors?: string[];
    };

export interface GenerateTwistOptions {
  // ...existing fields...
  model?: string;                                  // default "claude-sonnet-4-6" (unchanged)
  onEvent?: (event: GenerateAttemptEvent) => void; // structured telemetry
}
```

- `usage` populated from `generateObject`'s `result.usage` plus
  `result.providerMetadata?.anthropic` cache fields when present; all optional.
- Every `onEvent` call goes through a try/catch wrapper — a throwing listener must never
  affect generation.
- When both options are omitted, behavior is byte-identical to today (verified by
  existing tests; new unit tests in `generator.test.ts` cover event emission order,
  model override passthrough, and listener-throw safety).

## Runner flow

1. **Preflight:** Docker daemon reachable; `.dev.vars` contains `ANTHROPIC_API_KEY`,
   `AI_GATEWAY_ACCOUNT_ID`, `AI_GATEWAY_ID`, `AI_GATEWAY_TOKEN`; `public/twister/dist`
   exists (else instruct `cd public/twister && pnpm build`). Fail fast with a clear
   message naming the missing piece.
2. **Container:** `docker build` the twist-builder image (tag `plot-twist-builder-eval`),
   run with `--rm`, random name suffix, free host port; poll `/health` up to 60s.
   Teardown in `finally` and on SIGINT.
3. **Corpus:** load, validate, apply `--only` filter.
4. **Cache warmup:** run the first selected spec solo (concurrent first calls would each
   pay the prompt-cache write); then run the remainder through the promise pool at
   `--concurrency` (default 3).
5. **Per spec** (repeated `--runs` times): call `generateTwist()` with `model` override
   (if `--model`), an `onEvent` collector, the local-container env, and a **10-minute
   timeout** via `Promise.race` (the underlying call isn't abortable; a timed-out build
   may finish in the background — acceptable for a measurement tool, noted in README).
   On resolve, run checks in order: universal → assertions → typecheck. First failing
   level determines status.
6. **Write results JSON, print scorecard** (and compare table when `--compare` given).
7. **Exit code:** 0 when the run completed and results were written (failing specs are
   data, not errors); 1 on infra failure (Docker/env/corpus problems).

### CLI flags

| flag | default | meaning |
|---|---|---|
| `--only <list>` | all | comma-separated spec ids or categories |
| `--model <id>` | pipeline default | override generation model |
| `--runs <n>` | 1 | repeat the corpus n times, aggregate across runs |
| `--concurrency <n>` | 3 | parallel specs after warmup |
| `--label <name>` | model id | tag embedded in the results filename + JSON |
| `--compare <path>` | — | baseline results JSON to diff against |
| `--keep-output` | off | save generated twist sources under `results/<run>/sources/` |
| `--list` | — | print corpus ids/categories and exit |

## Checks

1. **Pipeline:** `generateTwist()` resolved.
2. **Universal:** `index.ts` present; a default-exported class matching
   `export default class \w+ extends Twist` (whitespace-tolerant regex).
3. **Per-spec assertions:** frontmatter regexes vs concatenated sources.
4. **Typecheck:** write `files` to a temp dir (`src/`), plus a `tsconfig.json`:
   `extends` → absolute path to `public/twister/tsconfig.base.json`;
   `compilerOptions.noEmit: true`, `baseUrl: "."`, and `paths` mapping
   `"@plotday/twister"` → `["<repo>/public/twister/dist/index.d.ts"]` and
   `"@plotday/twister/*"` → `["<repo>/public/twister/dist/*"]`.
   If `dependencies` includes packages beyond `@plotday/twister`, write a minimal
   `package.json` with those deps and run `npm install --no-audit --no-fund` (120s
   timeout) first — they already installed successfully inside the container build, so
   local failure is classified `infra`. Run `tsc` resolved from the repo's installed
   `typescript` package (60s timeout). Record up to the first 50 errors.

## Failure taxonomy

`classify.ts` maps (caught error, collected events, check results) → one class. Prefer
structured evidence (events, typed AI-SDK errors) over message matching; message
matching is the fallback and lives only in this module.

| class | trigger |
|---|---|
| `api_error` | Anthropic/AI-Gateway HTTP errors, timeouts from the SDK |
| `output_truncated` | `NoObjectGeneratedError` with `finishReason: "length"` |
| `schema_mismatch` | `NoObjectGeneratedError` from parse/validation |
| `build_npm_install` | build errors containing the container's install-failure marker |
| `build_bundle` | other container build failures (esbuild) |
| `build_container_infra` | container HTTP non-OK / unreachable |
| `max_attempts_exhausted` | 3 attempts used; also records the final attempt's build class |
| `assertion_failed` | harness check level 2–3 failed (which assertion, in detail) |
| `typecheck_failed` | harness check level 4 failed |
| `timeout` | 10-minute per-spec cap hit |
| `infra` | Docker/env/local-install problems — excluded from pass-rate math |

## Results JSON (schemaVersion 1)

```jsonc
{
  "schemaVersion": 1,
  "startedAt": "2026-07-07T18:00:00Z",
  "label": "baseline-sonnet-4-6",
  "model": "claude-sonnet-4-6",
  "flags": { "concurrency": 3, "runs": 1, "only": null },
  "specs": [
    {
      "id": "scheduled-poll",
      "category": "scheduling",
      "difficulty": "medium",
      "corpusHash": "sha256…",
      "run": 1,
      "status": "pass",            // pass | assertion_failed | typecheck_failed |
                                    // generation_failed | timeout | infra
      "failureClass": null,         // taxonomy class when not pass. status is the coarse
                                    // outcome; failureClass refines it (generation_failed →
                                    // api_error/output_truncated/schema_mismatch/build_*/
                                    // max_attempts_exhausted; universal-check and per-spec
                                    // assertion failures both use assertion_failed)
      "failureDetail": null,        // first 500 chars
      "assertionFailures": [],
      "attemptsUsed": 1,
      "durations": { "totalMs": 74000, "llmMs": [52000], "buildMs": [21000] },
      "tokens": { "input": 74812, "cacheRead": 71400, "cacheWrite": 0, "output": 2914 },
      "estimatedCostUsd": 0.09,
      "extraDeps": [],
      "files": ["index.ts"]
    }
  ],
  "aggregates": {
    "pipelinePassRate": 0.83,      // check level 1 only (generateTwist resolved)
    "fullPassRate": 0.58,          // all 4 check levels
    "meanAttempts": 1.4,
    "latencyMs": { "median": 81000, "p95": 210000 },
    "totalCostUsd": 2.4,
    "taxonomy": { "typecheck_failed": 3, "build_bundle": 1 }
  }
}
```

Filename: `results/<yyyyMMdd-HHmmss>-<label>.json`. Cost estimation uses a small
hardcoded per-model rate table in `report.ts` (labelled "estimate"; unknown models fall
back to Sonnet rates).

## Scorecard (stdout)

Markdown table, one row per spec: id · status · fail class · attempts · total s ·
LLM s · build s · tokens out · cost. Followed by the aggregates block (both pass rates,
mean attempts, median/p95 latency, taxonomy histogram, total cost). With `--compare`:
delta columns and an explicit "regressions" list (pass → non-pass), plus a warning for
any spec whose `corpusHash` differs from the baseline.

## Testing the harness

Unit tests only, wired into the workers/api node-side vitest config; no Docker, no API
keys, always green in the normal suite:

- `classify.test.ts` — fixture errors/events per taxonomy class, incl. precedence.
- `checks.test.ts` — canned sources vs universal checks + assertions; typecheck helper
  exercised against a tiny valid + invalid source pair using the real twister dist
  (skip with a clear message if dist is missing).
- `corpus.test.ts` — all 12 shipped specs parse, unique ids, valid regexes.
- `report.test.ts` — scorecard + compare snapshots from a fixture results object.
- `generator.test.ts` (existing file) — new cases: event emission order, model
  passthrough, throwing listener doesn't break generation.

## Success criteria

- One command (`pnpm --filter @plotday/api eval:twist-gen`) runs the full corpus against
  the real pipeline and prints the scorecard, with Docker as the only local prerequisite
  beyond `.dev.vars`.
- A full run completes even when every spec fails — failures are data.
- Two consecutive baseline runs produce comparable JSON usable with `--compare`.
- Harness unit tests run in the standard vitest suite with no external dependencies.
- `generateTwist()` behavior with default options is unchanged (existing tests prove it).
