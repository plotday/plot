# Twist Generation Eval Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local CLI (`pnpm --filter @plotday/api eval:twist-gen`) that runs a 12-spec corpus through the real spec→twist generation pipeline and reports pass rates, attempts, latency, token cost, and a failure taxonomy.

**Architecture:** The runner imports `generateTwist()` in-process and points its `TWIST_BUILDER` binding at a locally booted twist-builder Docker container (the pattern proven by `workers/api/src/twist/generator.e2e.test.ts`). Corpus specs are markdown files with YAML frontmatter. Results are JSON files plus a stdout scorecard. The only production-code change is additive telemetry on `generateTwist()`.

**Tech Stack:** TypeScript (Node), tsx, vitest, `yaml` (^2.9.0), Docker, node:util `parseArgs`.

**Spec:** `docs/superpowers/specs/2026-07-07-twist-generation-eval-harness-design.md` — read it before starting any task.

**Prior art:** `libs/eval` is the repo's existing (classifier) eval harness — different domain, but we reuse its conventions: yaml corpora, tsx CLI, corpus hashing. Known gotcha documented there: `pnpm --filter X <script> -- --flag` forwards a literal `--` token to the script; our CLI strips it.

## Global Constraints

- With `model` and `onEvent` omitted, `generateTwist()` behavior must be byte-identical to today (existing tests must pass unmodified except where a task explicitly edits them).
- `yaml` and `tsx` are **devDependencies** of `workers/api` only — no new runtime deps for the worker.
- Corpus spec bodies are plain user language: no SDK identifiers, tool names, or method names in the body (frontmatter assertions may reference them).
- `workers/api/evals/results/` is gitignored; never commit results.
- The eval env passed to `generateTwist()` must NOT contain `POSTHOG_API_KEY` (eval failures are data, not incidents — they must not reach PostHog error tracking).
- Never hardcode DB ports or touch any database (this feature needs none).
- All `pnpm --filter @plotday/api …` commands work from the repo root. `pnpm test -- <path>` filters vitest to that file.
- Every commit message ends with: `Co-Authored-By: Claude <noreply@anthropic.com>`

---

### Task 1: Generator telemetry hooks (`model` + `onEvent`)

**Files:**
- Modify: `workers/api/src/twist/generator.ts`
- Test: `workers/api/src/twist/generator.test.ts` (extend existing file)

**Interfaces:**
- Consumes: nothing new.
- Produces (imported by later tasks):
  - `export const DEFAULT_GENERATION_MODEL = "claude-sonnet-4-6"`
  - `export type GenerateAttemptEvent = { type: "attempt_start"; attempt: number } | { type: "llm_complete"; attempt: number; durationMs: number; usage?: { inputTokens?: number; outputTokens?: number; cacheReadInputTokens?: number; cacheCreationInputTokens?: number } } | { type: "build_complete"; attempt: number; durationMs: number; success: boolean; errors?: string[] }`
  - `GenerateTwistOptions` gains `model?: string` and `onEvent?: (event: GenerateAttemptEvent) => void`

- [ ] **Step 1: Write the failing tests**

In `workers/api/src/twist/generator.test.ts`, first update the provider mock so it captures the model id. Replace the existing `@ai-sdk/anthropic` mock block with:

```ts
// Anthropic provider factory — the real one hits the network on construction,
// so we swap it for a callable sentinel. modelIdMock records which model id
// the generator requested.
const anthropicModelSentinel = { __sentinel: "model" };
const createAnthropicMock = vi.fn();
const modelIdMock = vi.fn();
vi.mock("@ai-sdk/anthropic", () => ({
  createAnthropic: (opts?: unknown) => {
    createAnthropicMock(opts);
    return (modelId: string) => {
      modelIdMock(modelId);
      return anthropicModelSentinel;
    };
  },
}));
```

Add `modelIdMock.mockClear();` to the existing `beforeEach`. Import the new type at the top alongside the existing import:

```ts
import { generateTwist, type GenerateAttemptEvent } from "./generator";
```

Then append this describe block at the end of the file:

```ts
describe("generateTwist telemetry hooks", () => {
  it("uses the default model when no override is given", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv() });
    expect(modelIdMock).toHaveBeenCalledWith("claude-sonnet-4-6");
  });

  it("honors the model override", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv(), model: "claude-opus-4-8" });
    expect(modelIdMock).toHaveBeenCalledWith("claude-opus-4-8");
  });

  it("emits attempt_start, llm_complete, build_complete per attempt, in order", async () => {
    buildTwistMock
      .mockResolvedValueOnce({ success: false, errors: ["Build failed:\nboom"] })
      .mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    expect(events.map((e) => `${e.type}:${e.attempt}`)).toEqual([
      "attempt_start:1",
      "llm_complete:1",
      "build_complete:1",
      "attempt_start:2",
      "llm_complete:2",
      "build_complete:2",
    ]);
    const firstBuild = events[2];
    if (firstBuild.type !== "build_complete") throw new Error("expected build_complete");
    expect(firstBuild.success).toBe(false);
    expect(firstBuild.errors).toEqual(["Build failed:\nboom"]);
    const secondBuild = events[5];
    if (secondBuild.type !== "build_complete") throw new Error("expected build_complete");
    expect(secondBuild.success).toBe(true);
    expect(secondBuild.errors).toBeUndefined();
  });

  it("passes token usage through to llm_complete", async () => {
    generateObjectMock.mockResolvedValue({
      object: { ...validSource },
      usage: { inputTokens: 100, outputTokens: 42 },
      providerMetadata: {
        anthropic: { cacheReadInputTokens: 70, cacheCreationInputTokens: 30 },
      },
    });
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    const llm = events.find((e) => e.type === "llm_complete");
    if (!llm || llm.type !== "llm_complete") throw new Error("expected llm_complete");
    expect(llm.usage).toEqual({
      inputTokens: 100,
      outputTokens: 42,
      cacheReadInputTokens: 70,
      cacheCreationInputTokens: 30,
    });
  });

  it("a throwing onEvent listener does not break generation", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const source = await generateTwist({
      spec: "hello",
      env: makeEnv(),
      onEvent: () => {
        throw new Error("listener bug");
      },
    });
    expect(source.files["index.ts"]).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `pnpm --filter @plotday/api test -- src/twist/generator.test.ts`
Expected: the 5 new tests FAIL (`modelIdMock` never called with model id / no events emitted / `model` not an accepted option); all pre-existing tests still PASS.

- [ ] **Step 3: Implement the hooks in generator.ts**

In `workers/api/src/twist/generator.ts`:

Add after the `twistSourceSchema` declaration:

```ts
export const DEFAULT_GENERATION_MODEL = "claude-sonnet-4-6";

/**
 * Structured telemetry emitted during generation. Consumed by the eval
 * harness (workers/api/evals); optional and side-effect free for all other
 * callers.
 */
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

function safeEmit(
  onEvent: ((event: GenerateAttemptEvent) => void) | undefined,
  event: GenerateAttemptEvent
) {
  if (!onEvent) return;
  try {
    onEvent(event);
  } catch {
    // Telemetry listeners must never affect generation.
  }
}

function extractUsage(result: {
  usage?: { inputTokens?: number; outputTokens?: number; cachedInputTokens?: number };
  providerMetadata?: Record<string, Record<string, unknown>>;
}): Extract<GenerateAttemptEvent, { type: "llm_complete" }>["usage"] {
  const usage = result.usage;
  const anthropic = result.providerMetadata?.anthropic ?? {};
  if (!usage && !result.providerMetadata) return undefined;
  return {
    inputTokens: usage?.inputTokens,
    outputTokens: usage?.outputTokens,
    cacheReadInputTokens:
      typeof anthropic.cacheReadInputTokens === "number"
        ? anthropic.cacheReadInputTokens
        : usage?.cachedInputTokens,
    cacheCreationInputTokens:
      typeof anthropic.cacheCreationInputTokens === "number"
        ? anthropic.cacheCreationInputTokens
        : undefined,
  };
}
```

Extend `GenerateTwistOptions`:

```ts
export interface GenerateTwistOptions {
  spec: string;
  env: Bindings;
  onProgress?: (message: string) => void;
  // Optional user for PostHog attribution of generation failures.
  userId?: string | null;
  // Override the generation model (eval harness A/B). Default unchanged.
  model?: string;
  // Structured telemetry (eval harness). Errors in the listener are swallowed.
  onEvent?: (event: GenerateAttemptEvent) => void;
}
```

Thread the options through `generateTwist` → `generateTwistInner` (add `model` and `onEvent` to both signatures and the call site). Inside the while loop make exactly these changes:

1. Right after `onAttempt(attempt);` add:
   ```ts
   safeEmit(onEvent, { type: "attempt_start", attempt });
   ```
2. Replace `const model: any = anthropicProvider("claude-sonnet-4-6");` with:
   ```ts
   const model: any = anthropicProvider(modelId);
   ```
   where `const modelId = options.model ?? DEFAULT_GENERATION_MODEL;` is computed once at the top of `generateTwistInner` (destructure `model: modelOverride` if you prefer; just be consistent).
3. Wrap the `generateObject` call with timing and emit afterwards:
   ```ts
   const llmStart = Date.now();
   const result = await generateObject({ /* unchanged args */ });
   safeEmit(onEvent, {
     type: "llm_complete",
     attempt,
     durationMs: Date.now() - llmStart,
     usage: extractUsage(result),
   });
   ```
4. Wrap the build call:
   ```ts
   const buildStart = Date.now();
   const buildResult = await buildTwist(source, env, onProgress);
   safeEmit(onEvent, {
     type: "build_complete",
     attempt,
     durationMs: Date.now() - buildStart,
     success: buildResult.success,
     errors: buildResult.success ? undefined : buildResult.errors,
   });
   ```

No other logic changes. The retry prompt, schema, caching options, and error paths stay untouched.

- [ ] **Step 4: Run the full generator test file**

Run: `pnpm --filter @plotday/api test -- src/twist/generator.test.ts`
Expected: ALL tests PASS (old and new).

- [ ] **Step 5: Lint and commit**

Run: `pnpm --filter @plotday/api lint` — must pass.

```bash
git add workers/api/src/twist/generator.ts workers/api/src/twist/generator.test.ts
git commit -m "feat(api): add model override + structured onEvent telemetry to generateTwist

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Eval harness scaffolding (paths, types, pool, wiring)

**Files:**
- Create: `workers/api/evals/lib/paths.ts`
- Create: `workers/api/evals/lib/types.ts`
- Create: `workers/api/evals/lib/pool.ts`
- Test: `workers/api/evals/__tests__/pool.test.ts`
- Modify: `workers/api/vitest.config.ts` (include evals tests)
- Modify: `workers/api/package.json` (script + devDeps)
- Modify: `workers/api/.gitignore` (results dir)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `paths.ts`: `EVALS_DIR`, `API_ROOT`, `REPO_ROOT`, `CORPUS_DIR`, `RESULTS_DIR`, `CONTAINER_DIR`, `TWISTER_DIST`, `TSCONFIG_BASE`, `TSC_BIN` (all `string` absolute paths)
  - `types.ts`: `CorpusSpec`, `SpecStatus`, `FailureClass`, `Classification`, `TokenTotals`, `SpecResult`, `RunResults`, `EvalInfraError`, `EvalTimeoutError` (exact code below)
  - `pool.ts`: `runPool<T, R>(items: readonly T[], limit: number, fn: (item: T, index: number) => Promise<R>): Promise<R[]>`

- [ ] **Step 1: Write the failing pool test**

`workers/api/evals/__tests__/pool.test.ts`:

```ts
import { describe, it, expect } from "vitest";

import { runPool } from "../lib/pool";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("runPool", () => {
  it("preserves result order", async () => {
    const results = await runPool([3, 1, 2], 2, async (n) => {
      await sleep(n * 10);
      return n * 2;
    });
    expect(results).toEqual([6, 2, 4]);
  });

  it("never exceeds the concurrency limit", async () => {
    let active = 0;
    let peak = 0;
    await runPool([1, 2, 3, 4, 5, 6], 2, async () => {
      active++;
      peak = Math.max(peak, active);
      await sleep(20);
      active--;
    });
    expect(peak).toBe(2);
  });

  it("handles an empty list", async () => {
    expect(await runPool([], 3, async () => 1)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/pool.test.ts`
Expected: FAIL — either "no test files found" (config not yet updated) or module-not-found. Both count; the config change in Step 3 makes the file discoverable and the implementation makes it pass.

- [ ] **Step 3: Implement scaffolding**

`workers/api/evals/lib/paths.ts`:

```ts
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url)); // workers/api/evals/lib

export const EVALS_DIR = join(here, "..");
export const API_ROOT = join(EVALS_DIR, "..");
export const REPO_ROOT = join(API_ROOT, "..", "..");
export const CORPUS_DIR = join(EVALS_DIR, "corpus");
export const RESULTS_DIR = join(EVALS_DIR, "results");
export const CONTAINER_DIR = join(API_ROOT, "containers", "twist-builder");
export const TWISTER_DIST = join(REPO_ROOT, "public", "twister", "dist");
export const TSCONFIG_BASE = join(
  REPO_ROOT,
  "public",
  "twister",
  "tsconfig.base.json"
);
export const TSC_BIN = join(API_ROOT, "node_modules", ".bin", "tsc");
```

`workers/api/evals/lib/types.ts`:

```ts
export type Difficulty = "easy" | "medium" | "hard";

export interface SpecAssertion {
  match: string; // JS regex source, case-sensitive
  why: string;
}

export interface SpecNotMatch {
  pattern: string; // JS regex source, case-sensitive
  why: string;
}

export interface CorpusSpec {
  id: string;
  category: string;
  difficulty: Difficulty;
  assertions: SpecAssertion[];
  notMatch: SpecNotMatch[];
  allowDeps: string[];
  body: string; // the markdown spec a user would write
  corpusHash: string; // sha256 hex of the full file content
  filePath: string;
}

export type SpecStatus =
  | "pass"
  | "assertion_failed"
  | "typecheck_failed"
  | "generation_failed"
  | "timeout"
  | "infra";

export type FailureClass =
  | "api_error"
  | "output_truncated"
  | "schema_mismatch"
  | "build_npm_install"
  | "build_bundle"
  | "build_container_infra"
  | "max_attempts_exhausted"
  | "assertion_failed"
  | "typecheck_failed"
  | "timeout"
  | "infra";

export type BuildFailureClass =
  | "build_npm_install"
  | "build_bundle"
  | "build_container_infra";

export interface Classification {
  failureClass: FailureClass;
  finalBuildClass?: BuildFailureClass;
  detail: string; // trimmed to 500 chars
}

export interface TokenTotals {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
}

export interface SpecResult {
  id: string;
  category: string;
  difficulty: Difficulty;
  corpusHash: string;
  run: number; // 1-based --runs iteration
  status: SpecStatus;
  failureClass: FailureClass | null;
  finalBuildClass: BuildFailureClass | null;
  failureDetail: string | null;
  assertionFailures: string[];
  attemptsUsed: number;
  durations: { totalMs: number; llmMs: number[]; buildMs: number[] };
  tokens: TokenTotals;
  estimatedCostUsd: number;
  extraDeps: string[];
  files: string[];
}

export interface RunResults {
  schemaVersion: 1;
  startedAt: string; // ISO
  label: string;
  model: string;
  flags: { concurrency: number; runs: number; only: string | null };
  specs: SpecResult[];
  aggregates: {
    pipelinePassRate: number | null; // generation resolved / counted (infra excluded)
    fullPassRate: number | null; // all check levels passed / counted
    meanAttempts: number | null;
    latencyMs: { median: number | null; p95: number | null };
    totalCostUsd: number;
    taxonomy: Record<string, number>;
  };
}

/** Local environment/setup problem — excluded from pass-rate math. */
export class EvalInfraError extends Error {}

/** Per-spec wall-clock cap exceeded. */
export class EvalTimeoutError extends Error {
  constructor(ms: number) {
    super(`no result within ${Math.round(ms / 1000)}s`);
  }
}
```

`workers/api/evals/lib/pool.ts`:

```ts
/**
 * Run `fn` over `items` with at most `limit` concurrent executions.
 * Results keep the input order. `fn` must handle its own errors — a
 * rejection from `fn` rejects the whole pool (the eval runner catches
 * per-spec errors inside `fn`).
 */
export async function runPool<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from(
    { length: Math.max(1, Math.min(limit, items.length)) },
    async () => {
      for (;;) {
        const i = next++;
        if (i >= items.length) return;
        results[i] = await fn(items[i], i);
      }
    }
  );
  await Promise.all(workers);
  return results;
}
```

`workers/api/vitest.config.ts` — change the `include` line only:

```ts
    include: ["src/**/*.test.ts", "evals/**/*.test.ts"],
```

`workers/api/package.json` — add to `scripts`:

```json
    "eval:twist-gen": "tsx evals/run.ts",
```

and add to `devDependencies` (keep alphabetical order within the block):

```json
    "tsx": "^4.19.2",
    "yaml": "^2.9.0",
```

Then run `pnpm install` at the repo root.

`workers/api/.gitignore` — append:

```
# Eval harness output
evals/results/
```

- [ ] **Step 4: Run the pool test**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/pool.test.ts`
Expected: 3 tests PASS.

Also run: `pnpm --filter @plotday/api test` — the full unit suite must still pass (config change must not break discovery of existing tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals workers/api/vitest.config.ts workers/api/package.json workers/api/.gitignore pnpm-lock.yaml
git commit -m "chore(api): scaffold twist-generation eval harness (paths, types, pool)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Corpus loader + the 12-spec corpus

**Files:**
- Create: `workers/api/evals/lib/corpus.ts`
- Create: `workers/api/evals/corpus/01-hello-thread.md` … `12-deactivate-cleanup.md` (12 files, exact contents below)
- Test: `workers/api/evals/__tests__/corpus.test.ts`

**Interfaces:**
- Consumes: `types.ts` (`CorpusSpec`, `Difficulty`), `paths.ts` (`CORPUS_DIR`), `yaml` package.
- Produces:
  - `parseSpecFile(raw: string, filePath: string): CorpusSpec`
  - `loadCorpus(dir?: string): Promise<CorpusSpec[]>` — sorted by filename, throws on duplicate ids

- [ ] **Step 1: Write the failing test**

`workers/api/evals/__tests__/corpus.test.ts`:

```ts
import { describe, it, expect } from "vitest";

import { loadCorpus, parseSpecFile } from "../lib/corpus";

const FIXTURE = `---
id: sample-spec
category: smoke
difficulty: easy
assertions:
  - match: 'createThread'
    why: must create a thread
notMatch:
  - pattern: 'extends\\s+Connector'
    why: twists extend Twist
allowDeps: []
---
# Sample

Do a thing.
`;

describe("parseSpecFile", () => {
  it("parses frontmatter and body", () => {
    const spec = parseSpecFile(FIXTURE, "sample.md");
    expect(spec.id).toBe("sample-spec");
    expect(spec.category).toBe("smoke");
    expect(spec.difficulty).toBe("easy");
    expect(spec.assertions).toEqual([
      { match: "createThread", why: "must create a thread" },
    ]);
    expect(spec.notMatch).toEqual([
      { pattern: "extends\\s+Connector", why: "twists extend Twist" },
    ]);
    expect(spec.body).toContain("Do a thing.");
    expect(spec.body).not.toContain("---");
    expect(spec.corpusHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("rejects a file without frontmatter", () => {
    expect(() => parseSpecFile("# no frontmatter", "bad.md")).toThrow(
      /frontmatter/
    );
  });

  it("rejects an invalid regex", () => {
    const bad = FIXTURE.replace("createThread", "((unclosed");
    expect(() => parseSpecFile(bad, "bad.md")).toThrow(/regex/i);
  });

  it("rejects an unknown difficulty", () => {
    const bad = FIXTURE.replace("difficulty: easy", "difficulty: brutal");
    expect(() => parseSpecFile(bad, "bad.md")).toThrow(/difficulty/);
  });
});

describe("shipped corpus", () => {
  it("loads all 12 specs with unique ids and non-empty bodies", async () => {
    const corpus = await loadCorpus();
    expect(corpus).toHaveLength(12);
    const ids = new Set(corpus.map((s) => s.id));
    expect(ids.size).toBe(12);
    for (const spec of corpus) {
      expect(spec.body.length).toBeGreaterThan(40);
      expect(spec.assertions.length).toBeGreaterThan(0);
    }
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/corpus.test.ts`
Expected: FAIL — cannot find module `../lib/corpus`.

- [ ] **Step 3: Implement the loader**

`workers/api/evals/lib/corpus.ts`:

```ts
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

import { parse as parseYaml } from "yaml";

import { CORPUS_DIR } from "./paths";
import type { CorpusSpec, Difficulty, SpecAssertion, SpecNotMatch } from "./types";

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;
const DIFFICULTIES: readonly Difficulty[] = ["easy", "medium", "hard"];

function fail(filePath: string, message: string): never {
  throw new Error(`${filePath}: ${message}`);
}

function requireString(
  filePath: string,
  meta: Record<string, unknown>,
  key: string
): string {
  const value = meta[key];
  if (typeof value !== "string" || !value.trim()) {
    fail(filePath, `frontmatter field "${key}" must be a non-empty string`);
  }
  return value.trim();
}

function compileOrFail(filePath: string, source: string, where: string): void {
  try {
    new RegExp(source);
  } catch (e) {
    fail(filePath, `invalid regex in ${where}: /${source}/ (${String(e)})`);
  }
}

export function parseSpecFile(raw: string, filePath: string): CorpusSpec {
  const match = raw.match(FRONTMATTER);
  if (!match) fail(filePath, "missing YAML frontmatter (--- ... ---)");
  const meta = (parseYaml(match[1]) ?? {}) as Record<string, unknown>;

  const id = requireString(filePath, meta, "id");
  const category = requireString(filePath, meta, "category");
  const difficulty = requireString(filePath, meta, "difficulty") as Difficulty;
  if (!DIFFICULTIES.includes(difficulty)) {
    fail(filePath, `difficulty must be one of ${DIFFICULTIES.join("/")}`);
  }

  const rawAssertions = (meta.assertions ?? []) as Array<Record<string, unknown>>;
  const assertions: SpecAssertion[] = rawAssertions.map((a, i) => {
    if (typeof a?.match !== "string" || typeof a?.why !== "string") {
      fail(filePath, `assertions[${i}] needs string "match" and "why"`);
    }
    compileOrFail(filePath, a.match, `assertions[${i}].match`);
    return { match: a.match, why: a.why };
  });

  const rawNotMatch = (meta.notMatch ?? []) as Array<Record<string, unknown>>;
  const notMatch: SpecNotMatch[] = rawNotMatch.map((n, i) => {
    if (typeof n?.pattern !== "string" || typeof n?.why !== "string") {
      fail(filePath, `notMatch[${i}] needs string "pattern" and "why"`);
    }
    compileOrFail(filePath, n.pattern, `notMatch[${i}].pattern`);
    return { pattern: n.pattern, why: n.why };
  });

  const allowDeps = ((meta.allowDeps ?? []) as unknown[]).map((d) => String(d));

  const body = raw.slice(match[0].length).trim();
  if (!body) fail(filePath, "spec body is empty");

  return {
    id,
    category,
    difficulty,
    assertions,
    notMatch,
    allowDeps,
    body,
    corpusHash: createHash("sha256").update(raw).digest("hex"),
    filePath,
  };
}

export async function loadCorpus(dir: string = CORPUS_DIR): Promise<CorpusSpec[]> {
  const files = (await readdir(dir)).filter((f) => f.endsWith(".md")).sort();
  const specs: CorpusSpec[] = [];
  for (const file of files) {
    const full = join(dir, file);
    specs.push(parseSpecFile(await readFile(full, "utf-8"), full));
  }
  const seen = new Set<string>();
  for (const spec of specs) {
    if (seen.has(spec.id)) throw new Error(`duplicate corpus id: ${spec.id}`);
    seen.add(spec.id);
  }
  return specs;
}
```

- [ ] **Step 4: Create the 12 corpus files**

Create each file exactly as follows. (YAML note: single-quoted strings keep backslashes literal — `'extends\s+Connector'` is the regex `extends\s+Connector`.)

`workers/api/evals/corpus/01-hello-thread.md`:

```markdown
---
id: hello-thread
category: smoke
difficulty: easy
assertions:
  - match: 'createThread'
    why: must create a thread
notMatch:
  - pattern: 'extends\s+Connector'
    why: twists extend Twist, not Connector
allowDeps: []
---
# Welcome thread

When this twist is added to a priority, create a single thread titled
"Welcome to my twist" with one note containing a short, friendly markdown
greeting. That is all it should do.
```

`workers/api/evals/corpus/02-scheduled-poll.md`:

```markdown
---
id: scheduled-poll
category: scheduling
difficulty: medium
assertions:
  - match: 'scheduleRecurring|scheduleTask|runTask'
    why: must schedule recurring background work
  - match: 'fetch\('
    why: must fetch from the Hacker News API
  - match: 'createThread'
    why: must create the digest thread
allowDeps: []
---
# Morning Hacker News digest

Every morning at 8am, fetch the current top five stories from the public
Hacker News API (https://hacker-news.firebaseio.com/v0/topstories.json gives
story ids; https://hacker-news.firebaseio.com/v0/item/<id>.json gives each
story's title and url) and create one thread titled "HN digest for <date>"
whose note lists each story title as a markdown link to the story url.
```

`workers/api/evals/corpus/03-webhook-handler.md`:

```markdown
---
id: webhook-handler
category: webhook
difficulty: medium
assertions:
  - match: 'createWebhook'
    why: must register a webhook endpoint
  - match: 'createThread'
    why: each push becomes a thread
allowDeps: []
---
# GitHub push notifications

I want to see GitHub pushes in Plot. Set up an HTTPS endpoint I can paste
into a GitHub repository's webhook settings (it will receive standard GitHub
push event JSON). For each push received, create a thread titled with the
repository name and branch, whose note lists the commit messages in that
push.
```

`workers/api/evals/corpus/04-ai-intents.md`:

```markdown
---
id: ai-intents
category: ai
difficulty: medium
assertions:
  - match: 'onNoteCreated'
    why: must react to new notes
  - match: '\bai\b|\bAI\b'
    why: must use the AI tool for the summary
  - match: 'createNote'
    why: must reply with a note in the same thread
allowDeps: []
---
# Thread summarizer

When someone writes a note in a thread that asks for a summary (for example
"summarize this thread" or "tl;dr"), reply in that same thread with a new
note containing a concise summary of the thread's notes so far. Use AI to
write the summary. Do not react to notes that this twist wrote itself.
```

`workers/api/evals/corpus/05-auth-integration.md`:

```markdown
---
id: auth-integration
category: integration
difficulty: hard
assertions:
  - match: 'Integrations|integrations'
    why: must use the integrations/auth tooling
  - match: 'createThread|saveLink'
    why: issues must land as threads
allowDeps: []
---
# My GitHub issues

Connect to my GitHub account (I'll authorize access when prompted). Once
connected, bring in the open issues assigned to me as task threads — one
thread per issue, titled with the issue title, with a note containing the
issue body and a link to it on GitHub. Check for newly assigned issues
periodically and add them as they appear.
```

`workers/api/evals/corpus/06-batch-sync.md`:

```markdown
---
id: batch-sync
category: batching
difficulty: hard
assertions:
  - match: 'runTask'
    why: long imports must be batched into fresh executions
  - match: 'store|this\.set\(|this\.get\('
    why: progress must persist between batches
allowDeps: []
---
# Open Library reading list import

Import science-fiction books from the Open Library search API
(https://openlibrary.org/search.json?q=subject:science_fiction — it is
paginated and can return thousands of results). Import them in the
background without timing out, keeping track of progress so an interrupted
import picks up where it left off instead of starting over. Each book
becomes a thread titled with the book title, with a note naming the author
and year.
```

`workers/api/evals/corpus/07-note-reaction.md`:

```markdown
---
id: note-reaction
category: events
difficulty: easy
assertions:
  - match: 'onNoteCreated'
    why: must react to new notes
  - match: 'TODO'
    why: must look for the TODO marker
  - match: 'createThread'
    why: must create the task thread
allowDeps: []
---
# TODO catcher

Whenever a note is added anywhere in this priority that contains the text
"TODO:", create a new task thread whose title is the text that follows
"TODO:" on that line, with a note linking back to the thread where it was
written.
```

`workers/api/evals/corpus/08-store-lifecycle.md`:

```markdown
---
id: store-lifecycle
category: state
difficulty: medium
assertions:
  - match: 'this\.set\(|store\.set\(|setMany'
    why: the count must be persisted, not kept in memory
  - match: 'this\.get\(|store\.get\('
    why: the count must be read back across executions
  - match: 'scheduleRecurring|scheduleTask|runTask'
    why: the weekly report must be scheduled
allowDeps: []
---
# Weekly report counter

Every Monday morning, create a thread titled "Weekly report #<n>" where n
starts at 1 and increases by one each week. The note should say how many
weekly reports have been posted so far. The counter must survive restarts —
if the twist is restarted mid-week, numbering must not reset.
```

`workers/api/evals/corpus/09-multi-file.md`:

```markdown
---
id: multi-file
category: structure
difficulty: medium
assertions:
  - match: 'from\s+["'']\.\/'
    why: entry point must import from a sibling module
  - match: 'onNoteCreated'
    why: must react to new notes
allowDeps: []
---
# Date distance replies

Watch for notes containing an ISO date like 2026-07-07. When one appears,
reply in the same thread with a note saying how many days away that date is
(past dates count backwards). Please structure the code well: put the
date-finding and day-counting logic in its own module, separate from the
main entry point, so the logic could be unit tested on its own.
```

`workers/api/evals/corpus/10-external-dep.md`:

```markdown
---
id: external-dep
category: deps
difficulty: medium
assertions:
  - match: 'zod|valibot|ajv'
    why: must use a schema-validation library
  - match: 'createWebhook'
    why: must expose a webhook endpoint
allowDeps:
  - zod
---
# Home automation events

My home automation system can POST JSON to a URL. Give me an endpoint for
it. Each payload should look like {"device": string, "event": string,
"at": ISO-8601 timestamp}. Validate incoming payloads strictly with a
schema-validation library (zod is fine) — create a thread titled
"<device>: <event>" only for valid payloads, and silently ignore anything
malformed.
```

`workers/api/evals/corpus/11-thread-actions.md`:

```markdown
---
id: thread-actions
category: actions
difficulty: medium
assertions:
  - match: 'ActionType\.callback|type:\s*["'']callback["'']'
    why: buttons must be callback actions
  - match: 'scheduleRecurring|scheduleTask|runTask'
    why: the standup thread must be scheduled each weekday
allowDeps: []
---
# Daily standup check-in

Every weekday morning, create a thread titled "Standup <date>" containing a
note that asks "How's it going?" with two buttons: "On track" and
"Blocked". When I press one, add a note to the thread recording my choice
(for example "Marked: Blocked").
```

`workers/api/evals/corpus/12-deactivate-cleanup.md`:

```markdown
---
id: deactivate-cleanup
category: lifecycle
difficulty: medium
assertions:
  - match: 'deactivate'
    why: must override the deactivate lifecycle hook
  - match: 'deleteWebhook|cancelAllTasks|cancelScheduledTask|deleteCallback|clearAll'
    why: deactivate must actually clean up registered resources
  - match: 'createWebhook'
    why: must register the webhook it later cleans up
allowDeps: []
---
# Tidy ping monitor

Register a webhook endpoint that external services can ping; each ping adds
a note to a single "Pings" thread. Also post a short daily status thread
each morning. When this twist is removed from the priority, everything it
set up must be cleaned up: the webhook endpoint, the scheduled daily work,
and any stored state.
```

- [ ] **Step 5: Run the corpus tests**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/corpus.test.ts`
Expected: all tests PASS (parse fixtures + 12 shipped specs load).

- [ ] **Step 6: Commit**

```bash
git add workers/api/evals/lib/corpus.ts workers/api/evals/corpus workers/api/evals/__tests__/corpus.test.ts
git commit -m "feat(api): eval corpus loader + 12-spec twist-generation corpus

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Checks — universal, assertions, typecheck

**Files:**
- Create: `workers/api/evals/lib/checks.ts`
- Test: `workers/api/evals/__tests__/checks.test.ts`

**Interfaces:**
- Consumes: `types.ts` (`CorpusSpec`, `EvalInfraError`), `paths.ts` (`TWISTER_DIST`, `TSCONFIG_BASE`, `TSC_BIN`), `TwistSource` from `../../src/twist/types`.
- Produces:
  - `runUniversalChecks(source: TwistSource): string[]` (failure descriptions; empty = pass)
  - `runAssertions(spec: CorpusSpec, source: TwistSource): string[]`
  - `typecheckSource(source: TwistSource): Promise<{ ok: boolean; errors: string[] }>` (throws `EvalInfraError` on local npm-install failure)
  - `runChecks(spec: CorpusSpec, source: TwistSource): Promise<CheckOutcome>` where `CheckOutcome = { status: "pass" | "assertion_failed" | "typecheck_failed"; assertionFailures: string[]; typecheckErrors: string[] }`

- [ ] **Step 1: Write the failing tests**

`workers/api/evals/__tests__/checks.test.ts`:

```ts
import { existsSync } from "node:fs";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import { runAssertions, runUniversalChecks, typecheckSource } from "../lib/checks";
import { parseSpecFile } from "../lib/corpus";
import { TWISTER_DIST } from "../lib/paths";
import type { TwistSource } from "../../src/twist/types";

function source(files: Record<string, string>, deps: Record<string, string> = {}): TwistSource {
  return { displayName: "T", files, dependencies: { "@plotday/twister": "latest", ...deps } };
}

const VALID_INDEX = `import { Twist, type ToolBuilder } from "@plotday/twister";

export default class EvalSample extends Twist<EvalSample> {
  build(_build: ToolBuilder) {
    return {};
  }
}
`;

const SPEC = parseSpecFile(
  `---
id: t
category: smoke
difficulty: easy
assertions:
  - match: 'createThread'
    why: must create a thread
notMatch:
  - pattern: 'extends\\s+Connector'
    why: no connectors
allowDeps: []
---
Body long enough to satisfy the loader checks for this fixture file.
`,
  "fixture.md"
);

describe("runUniversalChecks", () => {
  it("passes a default-exported Twist subclass", () => {
    expect(runUniversalChecks(source({ "index.ts": VALID_INDEX }))).toEqual([]);
  });

  it("fails when index.ts does not default-export a Twist subclass", () => {
    const failures = runUniversalChecks(
      source({ "index.ts": "export class NotDefault {}" })
    );
    expect(failures).toHaveLength(1);
    expect(failures[0]).toMatch(/default-export/);
  });
});

describe("runAssertions", () => {
  it("reports missing matches and forbidden patterns", () => {
    const failures = runAssertions(
      SPEC,
      source({ "index.ts": "export default class X extends Connector {}" })
    );
    expect(failures.some((f) => f.includes("createThread"))).toBe(true);
    expect(failures.some((f) => f.includes("no connectors"))).toBe(true);
  });

  it("passes when all assertions hold", () => {
    const failures = runAssertions(
      SPEC,
      source({ "index.ts": "plot.createThread({}) // extends Twist" })
    );
    expect(failures).toEqual([]);
  });
});

// Real tsc against the built twister types — needs public/twister/dist.
describe.skipIf(!existsSync(join(TWISTER_DIST, "index.d.ts")))(
  "typecheckSource",
  () => {
    it("accepts a well-typed twist", async () => {
      const result = await typecheckSource(source({ "index.ts": VALID_INDEX }));
      expect(result.errors).toEqual([]);
      expect(result.ok).toBe(true);
    }, 60_000);

    it("rejects a type error with diagnostics", async () => {
      const bad = VALID_INDEX + `\nconst n: number = "not a number";\n`;
      const result = await typecheckSource(source({ "index.ts": bad }));
      expect(result.ok).toBe(false);
      expect(result.errors.join("\n")).toMatch(/TS2322|not assignable/);
    }, 60_000);
  }
);
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/checks.test.ts`
Expected: FAIL — cannot find module `../lib/checks`.

- [ ] **Step 3: Implement checks.ts**

```ts
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { TSC_BIN, TSCONFIG_BASE, TWISTER_DIST } from "./paths";
import { EvalInfraError } from "./types";
import type { CorpusSpec } from "./types";
import type { TwistSource } from "../../src/twist/types";

export interface CheckOutcome {
  status: "pass" | "assertion_failed" | "typecheck_failed";
  assertionFailures: string[];
  typecheckErrors: string[];
}

const DEFAULT_CLASS_RE = /export\s+default\s+class\s+\w+\s+extends\s+Twist\b/;

export function runUniversalChecks(source: TwistSource): string[] {
  const index = source.files["index.ts"];
  if (!index) return ["universal: files must include index.ts"];
  const failures: string[] = [];
  if (!DEFAULT_CLASS_RE.test(index)) {
    failures.push(
      "universal: index.ts must default-export a class extending Twist"
    );
  }
  return failures;
}

export function runAssertions(spec: CorpusSpec, source: TwistSource): string[] {
  const all = Object.values(source.files).join("\n\n");
  const failures: string[] = [];
  for (const a of spec.assertions) {
    if (!new RegExp(a.match).test(all)) {
      failures.push(`missing /${a.match}/ — ${a.why}`);
    }
  }
  for (const n of spec.notMatch) {
    if (new RegExp(n.pattern).test(all)) {
      failures.push(`forbidden /${n.pattern}/ — ${n.why}`);
    }
  }
  return failures;
}

/**
 * Type-check generated sources against the real @plotday/twister type
 * declarations (public/twister/dist), without installing twister. Extra
 * model-chosen deps are npm-installed into the temp dir first (they already
 * installed successfully inside the builder container, so a local failure is
 * an infra problem, not a generation failure).
 */
export async function typecheckSource(
  source: TwistSource
): Promise<{ ok: boolean; errors: string[] }> {
  const dir = await mkdtemp(join(tmpdir(), "twist-eval-tsc-"));
  try {
    const srcDir = join(dir, "src");
    await mkdir(srcDir, { recursive: true });
    for (const [name, content] of Object.entries(source.files)) {
      await writeFile(join(srcDir, name), content, "utf-8");
    }

    const extraDeps = Object.fromEntries(
      Object.entries(source.dependencies).filter(
        ([name]) => name !== "@plotday/twister"
      )
    );
    if (Object.keys(extraDeps).length > 0) {
      await writeFile(
        join(dir, "package.json"),
        JSON.stringify(
          { name: "twist-eval-typecheck", private: true, dependencies: extraDeps },
          null,
          2
        ),
        "utf-8"
      );
      const install = spawnSync(
        "npm",
        ["install", "--no-audit", "--no-fund", "--silent"],
        { cwd: dir, timeout: 120_000, encoding: "utf-8" }
      );
      if (install.status !== 0) {
        throw new EvalInfraError(
          `npm install for typecheck failed:\n${install.stderr || install.stdout}`
        );
      }
    }

    await writeFile(
      join(dir, "tsconfig.json"),
      JSON.stringify(
        {
          extends: TSCONFIG_BASE,
          compilerOptions: {
            noEmit: true,
            declaration: false,
            declarationMap: false,
            sourceMap: false,
            baseUrl: ".",
            types: [],
            paths: {
              "@plotday/twister": [join(TWISTER_DIST, "index.d.ts")],
              "@plotday/twister/*": [join(TWISTER_DIST, "*")],
            },
          },
          include: ["src/*.ts"],
        },
        null,
        2
      ),
      "utf-8"
    );

    const tsc = spawnSync(TSC_BIN, ["-p", dir], {
      timeout: 60_000,
      encoding: "utf-8",
    });
    if (tsc.status === 0) return { ok: true, errors: [] };
    const errors = (tsc.stdout || tsc.stderr || "unknown tsc failure")
      .split("\n")
      .filter((line) => line.trim())
      .slice(0, 50);
    return { ok: false, errors };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export async function runChecks(
  spec: CorpusSpec,
  source: TwistSource
): Promise<CheckOutcome> {
  const assertionFailures = [
    ...runUniversalChecks(source),
    ...runAssertions(spec, source),
  ];
  if (assertionFailures.length > 0) {
    return { status: "assertion_failed", assertionFailures, typecheckErrors: [] };
  }
  const typecheck = await typecheckSource(source);
  if (!typecheck.ok) {
    return {
      status: "typecheck_failed",
      assertionFailures: [],
      typecheckErrors: typecheck.errors,
    };
  }
  return { status: "pass", assertionFailures: [], typecheckErrors: [] };
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/checks.test.ts`
Expected: PASS. If the two typecheck tests are skipped, build the SDK first (`cd public/twister && pnpm build`) and rerun — they must actually run and pass before this task is done.

If "accepts a well-typed twist" fails on the fixture itself (not the harness): mirror the imports/shape of `twists/twist-creator/src/index.ts`, the known-good minimal twist, and adjust `VALID_INDEX` until tsc accepts it. Do not weaken the harness to make the fixture pass.

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals/lib/checks.ts workers/api/evals/__tests__/checks.test.ts
git commit -m "feat(api): eval checks — universal structure, per-spec assertions, tsc typecheck

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Failure taxonomy classifier

**Files:**
- Create: `workers/api/evals/lib/classify.ts`
- Test: `workers/api/evals/__tests__/classify.test.ts`

**Interfaces:**
- Consumes: `types.ts` (`Classification`, `BuildFailureClass`), `GenerateAttemptEvent` from `../../src/twist/generator`.
- Produces:
  - `classifyBuildErrors(errors: string[]): BuildFailureClass`
  - `classifyGenerationError(error: unknown, events: GenerateAttemptEvent[]): Classification`

The marker strings below are the exact strings production emits — sources: `workers/api/containers/twist-builder/server/src/server.ts` ("Failed to install dependencies:", "Build failed:"), `workers/api/src/twist/builder.ts` ("Container build request failed with status", "Build failed with exception:", "Sandbox (Container) binding is not configured"), `workers/api/src/twist/generator.ts` ("Failed to generate valid twist after", "missing required 'index.ts'", "AI Gateway configuration is missing").

- [ ] **Step 1: Write the failing tests**

`workers/api/evals/__tests__/classify.test.ts`:

```ts
import { describe, it, expect } from "vitest";

import { classifyBuildErrors, classifyGenerationError } from "../lib/classify";
import type { GenerateAttemptEvent } from "../../src/twist/generator";

function namedError(name: string, message: string, extra: Record<string, unknown> = {}) {
  const err = new Error(message);
  err.name = name;
  Object.assign(err, extra);
  return err;
}

describe("classifyBuildErrors", () => {
  it("detects npm install failures", () => {
    expect(
      classifyBuildErrors(["Failed to install dependencies:\nnpm ERR! 404"])
    ).toBe("build_npm_install");
  });

  it("detects container infra failures", () => {
    expect(
      classifyBuildErrors(["Container build request failed with status 500:\nboom"])
    ).toBe("build_container_infra");
    expect(classifyBuildErrors(["Build failed with exception: fetch failed"])).toBe(
      "build_container_infra"
    );
  });

  it("defaults to bundle failures", () => {
    expect(classifyBuildErrors(["Build failed:\nesbuild: Expected ';'"])).toBe(
      "build_bundle"
    );
  });
});

describe("classifyGenerationError", () => {
  it("classifies truncation", () => {
    const c = classifyGenerationError(
      namedError("AI_NoObjectGeneratedError", "could not parse", {
        finishReason: "length",
      }),
      []
    );
    expect(c.failureClass).toBe("output_truncated");
  });

  it("classifies schema mismatches", () => {
    const c = classifyGenerationError(
      namedError("AI_NoObjectGeneratedError", "schema validation failed", {
        finishReason: "stop",
      }),
      []
    );
    expect(c.failureClass).toBe("schema_mismatch");
  });

  it("classifies a missing index.ts as schema mismatch", () => {
    const c = classifyGenerationError(
      new Error("Generated connector is missing required 'index.ts' file"),
      []
    );
    expect(c.failureClass).toBe("schema_mismatch");
  });

  it("classifies exhausted retries and refines with the final build error", () => {
    const events: GenerateAttemptEvent[] = [
      { type: "attempt_start", attempt: 3 },
      { type: "llm_complete", attempt: 3, durationMs: 1 },
      {
        type: "build_complete",
        attempt: 3,
        durationMs: 1,
        success: false,
        errors: ["Failed to install dependencies:\nnpm ERR! 404 left-pad"],
      },
    ];
    const c = classifyGenerationError(
      new Error("Failed to generate valid twist after 3 attempts. Final errors:\n..."),
      events
    );
    expect(c.failureClass).toBe("max_attempts_exhausted");
    expect(c.finalBuildClass).toBe("build_npm_install");
  });

  it("classifies API call errors", () => {
    const c = classifyGenerationError(
      namedError("AI_APICallError", "overloaded", { statusCode: 529 }),
      []
    );
    expect(c.failureClass).toBe("api_error");
  });

  it("classifies missing gateway config as infra", () => {
    const c = classifyGenerationError(
      new Error("AI Gateway configuration is missing"),
      []
    );
    expect(c.failureClass).toBe("infra");
  });

  it("truncates detail to 500 chars and falls back to api_error", () => {
    const c = classifyGenerationError(new Error("x".repeat(2000)), []);
    expect(c.failureClass).toBe("api_error");
    expect(c.detail.length).toBe(500);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/classify.test.ts`
Expected: FAIL — cannot find module `../lib/classify`.

- [ ] **Step 3: Implement classify.ts**

```ts
import type { GenerateAttemptEvent } from "../../src/twist/generator";
import type { BuildFailureClass, Classification } from "./types";

export function classifyBuildErrors(errors: string[]): BuildFailureClass {
  const joined = errors.join("\n");
  if (joined.includes("Failed to install dependencies")) {
    return "build_npm_install";
  }
  if (
    joined.includes("Container build request failed") ||
    joined.includes("Build failed with exception") ||
    joined.includes("Sandbox (Container) binding is not configured")
  ) {
    return "build_container_infra";
  }
  return "build_bundle";
}

/**
 * Map a generateTwist() rejection (plus collected telemetry events) to a
 * taxonomy class. Prefers structured evidence (error name, finishReason,
 * build_complete events); message matching is the fallback and lives ONLY
 * here. Unknown errors default to api_error — everything else in the LLM
 * path is explicitly recognized above it.
 */
export function classifyGenerationError(
  error: unknown,
  events: GenerateAttemptEvent[]
): Classification {
  const err = error instanceof Error ? error : new Error(String(error ?? "unknown"));
  const name = err.name ?? "";
  const message = err.message ?? "";
  const detail = message.slice(0, 500);

  if (name === "AI_NoObjectGeneratedError") {
    const finishReason = (err as { finishReason?: string }).finishReason;
    return {
      failureClass: finishReason === "length" ? "output_truncated" : "schema_mismatch",
      detail,
    };
  }
  if (message.includes("missing required 'index.ts'")) {
    return { failureClass: "schema_mismatch", detail };
  }
  if (message.startsWith("Failed to generate valid twist after")) {
    const lastFailedBuild = [...events]
      .reverse()
      .find(
        (e): e is Extract<GenerateAttemptEvent, { type: "build_complete" }> =>
          e.type === "build_complete" && !e.success
      );
    return {
      failureClass: "max_attempts_exhausted",
      finalBuildClass: classifyBuildErrors(lastFailedBuild?.errors ?? [message]),
      detail,
    };
  }
  if (message.includes("AI Gateway configuration is missing")) {
    return { failureClass: "infra", detail };
  }
  return { failureClass: "api_error", detail };
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/classify.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals/lib/classify.ts workers/api/evals/__tests__/classify.test.ts
git commit -m "feat(api): eval failure-taxonomy classifier

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Results, cost estimation, scorecard + compare rendering

**Files:**
- Create: `workers/api/evals/lib/report.ts`
- Test: `workers/api/evals/__tests__/report.test.ts`

**Interfaces:**
- Consumes: `types.ts` (`RunResults`, `SpecResult`, `TokenTotals`), `GenerateAttemptEvent` from `../../src/twist/generator`.
- Produces:
  - `sumTokens(events: GenerateAttemptEvent[]): TokenTotals`
  - `estimateCostUsd(tokens: TokenTotals, model: string): number`
  - `computeAggregates(specs: SpecResult[]): RunResults["aggregates"]`
  - `buildRunResults(input: { label: string; model: string; startedAt: string; flags: RunResults["flags"]; specs: SpecResult[] }): RunResults`
  - `renderScorecard(results: RunResults): string`
  - `renderCompare(current: RunResults, baseline: RunResults): string`

- [ ] **Step 1: Write the failing tests**

`workers/api/evals/__tests__/report.test.ts`:

```ts
import { describe, it, expect } from "vitest";

import {
  buildRunResults,
  computeAggregates,
  estimateCostUsd,
  renderCompare,
  renderScorecard,
  sumTokens,
} from "../lib/report";
import type { SpecResult } from "../lib/types";

function spec(overrides: Partial<SpecResult>): SpecResult {
  return {
    id: "s",
    category: "smoke",
    difficulty: "easy",
    corpusHash: "h",
    run: 1,
    status: "pass",
    failureClass: null,
    finalBuildClass: null,
    failureDetail: null,
    assertionFailures: [],
    attemptsUsed: 1,
    durations: { totalMs: 60_000, llmMs: [50_000], buildMs: [10_000] },
    tokens: { input: 1000, cacheRead: 0, cacheWrite: 0, output: 500 },
    estimatedCostUsd: 0.01,
    extraDeps: [],
    files: ["index.ts"],
    ...overrides,
  };
}

describe("sumTokens", () => {
  it("sums usage across llm_complete events", () => {
    expect(
      sumTokens([
        { type: "attempt_start", attempt: 1 },
        {
          type: "llm_complete",
          attempt: 1,
          durationMs: 1,
          usage: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 7 },
        },
        {
          type: "llm_complete",
          attempt: 2,
          durationMs: 1,
          usage: { inputTokens: 20, outputTokens: 5, cacheCreationInputTokens: 3 },
        },
      ])
    ).toEqual({ input: 30, cacheRead: 7, cacheWrite: 3, output: 10 });
  });
});

describe("estimateCostUsd", () => {
  it("prices sonnet tokens per MTok with cache rates", () => {
    // 1M fresh input at $3 + 1M output at $15 = $18
    expect(
      estimateCostUsd(
        { input: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 1_000_000 },
        "claude-sonnet-4-6"
      )
    ).toBeCloseTo(18, 5);
    // input fully cache-read: 1M at $0.30
    expect(
      estimateCostUsd(
        { input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0, output: 0 },
        "claude-sonnet-4-6"
      )
    ).toBeCloseTo(0.3, 5);
  });
});

describe("computeAggregates", () => {
  it("computes pass rates excluding infra, taxonomy, latency", () => {
    const a = computeAggregates([
      spec({ id: "a", status: "pass" }),
      spec({ id: "b", status: "typecheck_failed", failureClass: "typecheck_failed" }),
      spec({
        id: "c",
        status: "generation_failed",
        failureClass: "max_attempts_exhausted",
      }),
      spec({ id: "d", status: "infra", failureClass: "infra" }),
    ]);
    expect(a.pipelinePassRate).toBeCloseTo(2 / 3, 5); // a + b resolved; c did not; d excluded
    expect(a.fullPassRate).toBeCloseTo(1 / 3, 5);
    expect(a.taxonomy).toEqual({
      typecheck_failed: 1,
      max_attempts_exhausted: 1,
      infra: 1,
    });
    expect(a.latencyMs.median).toBe(60_000);
  });

  it("returns nulls for an empty run", () => {
    const a = computeAggregates([]);
    expect(a.pipelinePassRate).toBeNull();
    expect(a.fullPassRate).toBeNull();
    expect(a.latencyMs.median).toBeNull();
  });
});

describe("rendering", () => {
  const results = buildRunResults({
    label: "test",
    model: "claude-sonnet-4-6",
    startedAt: "2026-07-07T00:00:00Z",
    flags: { concurrency: 3, runs: 1, only: null },
    specs: [spec({ id: "a" }), spec({ id: "b", status: "typecheck_failed", failureClass: "typecheck_failed" })],
  });

  it("scorecard includes per-spec rows and aggregate lines", () => {
    const out = renderScorecard(results);
    expect(out).toContain("| a | 1 | pass |");
    expect(out).toContain("| b | 1 | typecheck_failed |");
    expect(out).toContain("pipeline pass rate: 100%");
    expect(out).toContain("full pass rate: 50%");
  });

  it("compare flags regressions and corpus drift", () => {
    const baseline = buildRunResults({
      label: "base",
      model: "claude-sonnet-4-6",
      startedAt: "2026-07-06T00:00:00Z",
      flags: { concurrency: 3, runs: 1, only: null },
      specs: [spec({ id: "a" }), spec({ id: "b", corpusHash: "other" })],
    });
    const out = renderCompare(results, baseline);
    expect(out).toContain("REGRESSIONS: b (pass → typecheck_failed)");
    expect(out).toContain("CHANGED"); // b's corpusHash differs
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/report.test.ts`
Expected: FAIL — cannot find module `../lib/report`.

- [ ] **Step 3: Implement report.ts**

```ts
import type { GenerateAttemptEvent } from "../../src/twist/generator";
import type { RunResults, SpecResult, TokenTotals } from "./types";

// USD per million tokens. Estimates for reporting only — update as pricing
// moves; unknown models fall back to Sonnet rates.
const MODEL_RATES: Record<
  string,
  { input: number; output: number; cacheRead: number; cacheWrite: number }
> = {
  "claude-sonnet-4-6": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
};
const DEFAULT_RATES = MODEL_RATES["claude-sonnet-4-6"];

export function sumTokens(events: GenerateAttemptEvent[]): TokenTotals {
  const totals: TokenTotals = { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 };
  for (const event of events) {
    if (event.type !== "llm_complete" || !event.usage) continue;
    totals.input += event.usage.inputTokens ?? 0;
    totals.output += event.usage.outputTokens ?? 0;
    totals.cacheRead += event.usage.cacheReadInputTokens ?? 0;
    totals.cacheWrite += event.usage.cacheCreationInputTokens ?? 0;
  }
  return totals;
}

export function estimateCostUsd(tokens: TokenTotals, model: string): number {
  const rates = MODEL_RATES[model] ?? DEFAULT_RATES;
  const freshInput = Math.max(0, tokens.input - tokens.cacheRead - tokens.cacheWrite);
  return (
    (freshInput * rates.input +
      tokens.cacheRead * rates.cacheRead +
      tokens.cacheWrite * rates.cacheWrite +
      tokens.output * rates.output) /
    1_000_000
  );
}

function percentile(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null;
  const index = Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1);
  return sorted[Math.max(0, index)];
}

const PIPELINE_RESOLVED: ReadonlySet<SpecResult["status"]> = new Set([
  "pass",
  "assertion_failed",
  "typecheck_failed",
]);

export function computeAggregates(specs: SpecResult[]): RunResults["aggregates"] {
  const counted = specs.filter((s) => s.status !== "infra");
  const latencies = counted.map((s) => s.durations.totalMs).sort((a, b) => a - b);
  const attempts = counted.filter((s) => s.attemptsUsed > 0);
  const taxonomy: Record<string, number> = {};
  for (const s of specs) {
    if (s.failureClass) taxonomy[s.failureClass] = (taxonomy[s.failureClass] ?? 0) + 1;
  }
  return {
    pipelinePassRate: counted.length
      ? counted.filter((s) => PIPELINE_RESOLVED.has(s.status)).length / counted.length
      : null,
    fullPassRate: counted.length
      ? counted.filter((s) => s.status === "pass").length / counted.length
      : null,
    meanAttempts: attempts.length
      ? attempts.reduce((sum, s) => sum + s.attemptsUsed, 0) / attempts.length
      : null,
    latencyMs: { median: percentile(latencies, 0.5), p95: percentile(latencies, 0.95) },
    totalCostUsd: specs.reduce((sum, s) => sum + s.estimatedCostUsd, 0),
    taxonomy,
  };
}

export function buildRunResults(input: {
  label: string;
  model: string;
  startedAt: string;
  flags: RunResults["flags"];
  specs: SpecResult[];
}): RunResults {
  return {
    schemaVersion: 1,
    startedAt: input.startedAt,
    label: input.label,
    model: input.model,
    flags: input.flags,
    specs: input.specs,
    aggregates: computeAggregates(input.specs),
  };
}

const secs = (ms: number | null) => (ms == null ? "n/a" : (ms / 1000).toFixed(1));
const secsList = (list: number[]) => list.map((ms) => (ms / 1000).toFixed(1)).join("+");
const pct = (x: number | null) => (x == null ? "n/a" : `${Math.round(x * 100)}%`);

export function renderScorecard(r: RunResults): string {
  const lines: string[] = [];
  lines.push(`# Twist generation eval — ${r.label}`);
  lines.push(`model: ${r.model} · started: ${r.startedAt} · specs: ${r.specs.length}`);
  lines.push("");
  lines.push(
    "| spec | run | status | fail class | attempts | total s | llm s | build s | out tok | cost $ |"
  );
  lines.push("|---|---|---|---|---|---|---|---|---|---|");
  for (const s of r.specs) {
    lines.push(
      `| ${s.id} | ${s.run} | ${s.status} | ${s.failureClass ?? ""} | ${s.attemptsUsed} | ${secs(
        s.durations.totalMs
      )} | ${secsList(s.durations.llmMs)} | ${secsList(s.durations.buildMs)} | ${
        s.tokens.output
      } | ${s.estimatedCostUsd.toFixed(2)} |`
    );
  }
  const a = r.aggregates;
  lines.push("");
  lines.push(
    `pipeline pass rate: ${pct(a.pipelinePassRate)} · full pass rate: ${pct(a.fullPassRate)}`
  );
  lines.push(
    `mean attempts: ${a.meanAttempts?.toFixed(2) ?? "n/a"} · latency median: ${secs(
      a.latencyMs.median
    )}s · p95: ${secs(a.latencyMs.p95)}s`
  );
  lines.push(`total est. cost: $${a.totalCostUsd.toFixed(2)}`);
  lines.push(
    `taxonomy: ${
      Object.entries(a.taxonomy)
        .map(([k, v]) => `${k}=${v}`)
        .join(", ") || "none"
    }`
  );
  return lines.join("\n");
}

export function renderCompare(current: RunResults, baseline: RunResults): string {
  const key = (s: SpecResult) => `${s.id}#${s.run}`;
  const base = new Map(baseline.specs.map((s) => [key(s), s]));
  const lines: string[] = [];
  const regressions: string[] = [];
  lines.push(`# Compare vs ${baseline.label} (${baseline.startedAt})`);
  lines.push("");
  lines.push("| spec | run | status | baseline | Δ total s | corpus |");
  lines.push("|---|---|---|---|---|---|");
  for (const s of current.specs) {
    const b = base.get(key(s));
    const drift = b && b.corpusHash !== s.corpusHash ? "CHANGED" : "";
    const delta = b ? ((s.durations.totalMs - b.durations.totalMs) / 1000).toFixed(1) : "";
    lines.push(`| ${s.id} | ${s.run} | ${s.status} | ${b?.status ?? "—"} | ${delta} | ${drift} |`);
    if (b && b.status === "pass" && s.status !== "pass") {
      regressions.push(`${s.id} (${b.status} → ${s.status})`);
    }
  }
  lines.push("");
  lines.push(regressions.length ? `REGRESSIONS: ${regressions.join(", ")}` : "No regressions.");
  const deltaPp = (x: number | null, y: number | null) =>
    x != null && y != null ? `${((x - y) * 100).toFixed(0)}pp` : "n/a";
  lines.push(
    `pipeline pass: ${pct(current.aggregates.pipelinePassRate)} (Δ ${deltaPp(
      current.aggregates.pipelinePassRate,
      baseline.aggregates.pipelinePassRate
    )}) · full pass: ${pct(current.aggregates.fullPassRate)} (Δ ${deltaPp(
      current.aggregates.fullPassRate,
      baseline.aggregates.fullPassRate
    )})`
  );
  return lines.join("\n");
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/report.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals/lib/report.ts workers/api/evals/__tests__/report.test.ts
git commit -m "feat(api): eval results aggregation, cost estimate, scorecard + compare

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Env + Docker helpers

**Files:**
- Create: `workers/api/evals/lib/env.ts`
- Create: `workers/api/evals/lib/docker.ts`
- Test: `workers/api/evals/__tests__/env.test.ts`

**Interfaces:**
- Consumes: `paths.ts` (`API_ROOT`).
- Produces:
  - `env.ts`: `loadDevVars(path?: string): Record<string, string>`, `assertRequiredVars(vars: Record<string, string>): void`, `buildEvalEnv(vars: Record<string, string>, containerPort: number): Record<string, unknown>` (runner casts to `Bindings`), `REQUIRED_VARS: readonly string[]`
  - `docker.ts`: `assertDockerAvailable(): void`, `buildImage(): void`, `findFreePort(): Promise<number>`, `startContainer(port: number): string` (returns container name), `waitForHealth(port: number, timeoutMs?: number): Promise<void>`, `stopContainer(name: string): void`, `IMAGE_TAG: string`

Docker functions are deliberately not unit-tested (they shell out); the smoke run in Task 8 exercises them. The `.dev.vars` parser and env construction are unit-tested.

- [ ] **Step 1: Write the failing env test**

`workers/api/evals/__tests__/env.test.ts`:

```ts
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import { assertRequiredVars, buildEvalEnv, loadDevVars } from "../lib/env";

describe("loadDevVars", () => {
  it("parses assignments, quotes, and comments", () => {
    const dir = mkdtempSync(join(tmpdir(), "eval-env-"));
    const file = join(dir, ".dev.vars");
    writeFileSync(
      file,
      [
        "# comment",
        "PLAIN=value",
        'QUOTED="with spaces"',
        "SINGLE='single'",
        "",
        "WITH_EQ=a=b",
      ].join("\n")
    );
    expect(loadDevVars(file)).toEqual({
      PLAIN: "value",
      QUOTED: "with spaces",
      SINGLE: "single",
      WITH_EQ: "a=b",
    });
  });
});

describe("assertRequiredVars", () => {
  it("names every missing var", () => {
    expect(() => assertRequiredVars({ ANTHROPIC_API_KEY: "x" })).toThrow(
      /AI_GATEWAY_ACCOUNT_ID.*AI_GATEWAY_ID.*AI_GATEWAY_TOKEN/s
    );
  });
});

describe("buildEvalEnv", () => {
  const vars = {
    ANTHROPIC_API_KEY: "k",
    AI_GATEWAY_ACCOUNT_ID: "a",
    AI_GATEWAY_ID: "g",
    AI_GATEWAY_TOKEN: "t",
    POSTHOG_API_KEY: "MUST_NOT_LEAK",
  };

  it("includes only the generation vars plus the container stub", () => {
    const env = buildEvalEnv(vars, 12345);
    expect(env.ANTHROPIC_API_KEY).toBe("k");
    expect(env.POSTHOG_API_KEY).toBeUndefined();
    expect(env.TWIST_BUILDER).toBeDefined();
  });

  it("stub routes fetches to the local container port", () => {
    const env = buildEvalEnv(vars, 12345) as {
      TWIST_BUILDER: { idFromName: (n: string) => unknown; get: (id: unknown) => { fetch: Function } };
    };
    const stub = env.TWIST_BUILDER.get(env.TWIST_BUILDER.idFromName("builder"));
    expect(typeof stub.fetch).toBe("function");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/env.test.ts`
Expected: FAIL — cannot find module `../lib/env`.

- [ ] **Step 3: Implement env.ts and docker.ts**

`workers/api/evals/lib/env.ts` (parser mirrors `generator.e2e.test.ts` `loadDevVars`):

```ts
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { API_ROOT } from "./paths";

export const REQUIRED_VARS = [
  "ANTHROPIC_API_KEY",
  "AI_GATEWAY_ACCOUNT_ID",
  "AI_GATEWAY_ID",
  "AI_GATEWAY_TOKEN",
] as const;

export function loadDevVars(
  path: string = join(API_ROOT, ".dev.vars")
): Record<string, string> {
  const out: Record<string, string> = {};
  const raw = readFileSync(path, "utf-8");
  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

export function assertRequiredVars(vars: Record<string, string>): void {
  const missing = REQUIRED_VARS.filter((key) => !vars[key]);
  if (missing.length > 0) {
    throw new Error(
      `Missing in workers/api/.dev.vars: ${missing.join(", ")} — ` +
        `run 'pnpm --filter @plotday/api get-env' (or 'pnpm cp-env <main-repo>' in a worktree)`
    );
  }
}

/**
 * Minimal TWIST_BUILDER stand-in matching the subset @cloudflare/containers
 * uses: getContainer() reads idFromName() + get() off the namespace and
 * calls fetch() on the returned stub.
 */
function containerBinding(port: number) {
  const stub = {
    fetch(_url: string, init?: RequestInit) {
      return fetch(`http://127.0.0.1:${port}/build`, init);
    },
  };
  return { idFromName: () => ({}), get: () => stub };
}

/**
 * Deliberately minimal: ONLY what generateTwist() reads. In particular no
 * POSTHOG_API_KEY — eval failures are intentional data, not production
 * incidents, and must never reach PostHog error tracking.
 */
export function buildEvalEnv(
  vars: Record<string, string>,
  containerPort: number
): Record<string, unknown> {
  return {
    ANTHROPIC_API_KEY: vars.ANTHROPIC_API_KEY,
    AI_GATEWAY_ACCOUNT_ID: vars.AI_GATEWAY_ACCOUNT_ID,
    AI_GATEWAY_ID: vars.AI_GATEWAY_ID,
    AI_GATEWAY_TOKEN: vars.AI_GATEWAY_TOKEN,
    TWIST_BUILDER: containerBinding(containerPort),
  };
}
```

`workers/api/evals/lib/docker.ts`:

```ts
import { execFileSync, spawnSync } from "node:child_process";
import { createServer } from "node:net";

import { CONTAINER_DIR } from "./paths";
import { EvalInfraError } from "./types";

export const IMAGE_TAG = "plot-twist-builder-eval";

export function assertDockerAvailable(): void {
  const result = spawnSync("docker", ["info"], { stdio: "ignore" });
  if (result.status !== 0) {
    throw new EvalInfraError(
      "Docker daemon not reachable — start Docker Desktop and retry."
    );
  }
}

export function buildImage(): void {
  execFileSync("docker", ["build", "-t", IMAGE_TAG, CONTAINER_DIR], {
    stdio: "inherit",
  });
}

export async function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on("error", reject);
    server.listen(0, () => {
      const address = server.address();
      if (typeof address === "object" && address) {
        const port = address.port;
        server.close(() => resolve(port));
      } else {
        server.close(() => reject(new Error("could not allocate a port")));
      }
    });
  });
}

export function startContainer(port: number): string {
  const name = `plot-twist-eval-${Date.now().toString(36)}`;
  execFileSync(
    "docker",
    ["run", "-d", "--rm", "--name", name, "-p", `${port}:3000`, IMAGE_TAG],
    { stdio: "ignore" }
  );
  return name;
}

export async function waitForHealth(port: number, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) return;
    } catch (e) {
      lastError = e;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new EvalInfraError(
    `twist-builder container not healthy within ${timeoutMs}ms: ${String(lastError)}`
  );
}

export function stopContainer(name: string): void {
  spawnSync("docker", ["stop", name], { stdio: "ignore" });
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/env.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals/lib/env.ts workers/api/evals/lib/docker.ts workers/api/evals/__tests__/env.test.ts
git commit -m "feat(api): eval env + docker helpers for local twist-builder container

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Runner CLI, README, smoke run

**Files:**
- Create: `workers/api/evals/lib/cli.ts`
- Create: `workers/api/evals/run.ts`
- Create: `workers/api/evals/README.md`
- Test: `workers/api/evals/__tests__/cli.test.ts`

**Interfaces:**
- Consumes: everything produced by Tasks 1–7, plus `generateTwist`, `DEFAULT_GENERATION_MODEL`, `GenerateAttemptEvent` from `../src/twist/generator` and `TwistSource` from `../src/twist/types`, `Bindings` (type-only) from `../src/env`.
- Produces: the `pnpm --filter @plotday/api eval:twist-gen` entrypoint (already wired in Task 2).

- [ ] **Step 1: Write the failing CLI-parsing test**

`workers/api/evals/__tests__/cli.test.ts`:

```ts
import { describe, it, expect } from "vitest";

import { parseCliArgs } from "../lib/cli";

describe("parseCliArgs", () => {
  it("returns defaults with no args", () => {
    expect(parseCliArgs([])).toEqual({
      only: null,
      model: null,
      runs: 1,
      concurrency: 3,
      label: null,
      compare: null,
      keepOutput: false,
      list: false,
    });
  });

  it("parses all flags and strips the pnpm-forwarded double dash", () => {
    const opts = parseCliArgs([
      "--",
      "--only",
      "hello-thread,webhook",
      "--model",
      "claude-opus-4-8",
      "--runs",
      "2",
      "--concurrency",
      "1",
      "--label",
      "baseline",
      "--compare",
      "results/x.json",
      "--keep-output",
      "--list",
    ]);
    expect(opts).toEqual({
      only: "hello-thread,webhook",
      model: "claude-opus-4-8",
      runs: 2,
      concurrency: 1,
      label: "baseline",
      compare: "results/x.json",
      keepOutput: true,
      list: true,
    });
  });

  it("rejects non-positive integers", () => {
    expect(() => parseCliArgs(["--runs", "0"])).toThrow(/positive integer/);
    expect(() => parseCliArgs(["--concurrency", "nope"])).toThrow(/positive integer/);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/cli.test.ts`
Expected: FAIL — cannot find module `../lib/cli`.

- [ ] **Step 3: Implement cli.ts**

`workers/api/evals/lib/cli.ts`:

```ts
import { parseArgs } from "node:util";

export interface CliOptions {
  only: string | null;
  model: string | null;
  runs: number;
  concurrency: number;
  label: string | null;
  compare: string | null;
  keepOutput: boolean;
  list: boolean;
}

export function parseCliArgs(argv: string[]): CliOptions {
  // pnpm forwards a literal "--" token when invoked as
  // `pnpm --filter @plotday/api eval:twist-gen -- --flag` — strip it.
  const args = argv.filter((a) => a !== "--");
  const { values } = parseArgs({
    args,
    allowPositionals: false,
    options: {
      only: { type: "string" },
      model: { type: "string" },
      runs: { type: "string" },
      concurrency: { type: "string" },
      label: { type: "string" },
      compare: { type: "string" },
      "keep-output": { type: "boolean" },
      list: { type: "boolean" },
    },
  });
  const positiveInt = (value: string | undefined, dflt: number, name: string) => {
    if (value === undefined) return dflt;
    const n = Number.parseInt(value, 10);
    if (!Number.isFinite(n) || n < 1 || String(n) !== value.trim()) {
      throw new Error(`--${name} must be a positive integer`);
    }
    return n;
  };
  return {
    only: values.only ?? null,
    model: values.model ?? null,
    runs: positiveInt(values.runs, 1, "runs"),
    concurrency: positiveInt(values.concurrency, 3, "concurrency"),
    label: values.label ?? null,
    compare: values.compare ?? null,
    keepOutput: values["keep-output"] ?? false,
    list: values.list ?? false,
  };
}
```

- [ ] **Step 4: Run the CLI test**

Run: `pnpm --filter @plotday/api test -- evals/__tests__/cli.test.ts`
Expected: PASS.

- [ ] **Step 5: Implement run.ts**

`workers/api/evals/run.ts`:

```ts
/* eslint-disable no-console */
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import {
  DEFAULT_GENERATION_MODEL,
  generateTwist,
  type GenerateAttemptEvent,
} from "../src/twist/generator";
import type { Bindings } from "../src/env";
import type { TwistSource } from "../src/twist/types";
import { runChecks } from "./lib/checks";
import { classifyGenerationError } from "./lib/classify";
import { parseCliArgs, type CliOptions } from "./lib/cli";
import { loadCorpus } from "./lib/corpus";
import {
  assertDockerAvailable,
  buildImage,
  findFreePort,
  startContainer,
  stopContainer,
  waitForHealth,
} from "./lib/docker";
import { assertRequiredVars, buildEvalEnv, loadDevVars } from "./lib/env";
import { runPool } from "./lib/pool";
import { RESULTS_DIR, TWISTER_DIST } from "./lib/paths";
import { buildRunResults, estimateCostUsd, renderCompare, renderScorecard, sumTokens } from "./lib/report";
import {
  EvalInfraError,
  EvalTimeoutError,
  type CorpusSpec,
  type FailureClass,
  type RunResults,
  type SpecResult,
  type SpecStatus,
} from "./lib/types";

const SPEC_TIMEOUT_MS = 10 * 60_000;

const log = (message: string) => console.log(`[eval] ${message}`);

async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new EvalTimeoutError(ms)), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

interface SpecExecution {
  result: SpecResult;
  source?: TwistSource;
}

async function runSpec(
  spec: CorpusSpec,
  runIndex: number,
  env: Bindings,
  model: string
): Promise<SpecExecution> {
  const events: GenerateAttemptEvent[] = [];
  const startedAt = Date.now();
  let source: TwistSource | undefined;
  let status: SpecStatus;
  let failureClass: FailureClass | null = null;
  let finalBuildClass: SpecResult["finalBuildClass"] = null;
  let failureDetail: string | null = null;
  let assertionFailures: string[] = [];

  try {
    source = await withTimeout(
      generateTwist({ spec: spec.body, env, model, onEvent: (e) => events.push(e) }),
      SPEC_TIMEOUT_MS
    );
    const outcome = await runChecks(spec, source);
    status = outcome.status;
    if (outcome.status === "assertion_failed") {
      failureClass = "assertion_failed";
      assertionFailures = outcome.assertionFailures;
      failureDetail = outcome.assertionFailures.join("; ").slice(0, 500);
    } else if (outcome.status === "typecheck_failed") {
      failureClass = "typecheck_failed";
      failureDetail = outcome.typecheckErrors.join("\n").slice(0, 500);
    }
  } catch (error) {
    if (error instanceof EvalTimeoutError) {
      status = "timeout";
      failureClass = "timeout";
      failureDetail = error.message;
    } else if (error instanceof EvalInfraError) {
      status = "infra";
      failureClass = "infra";
      failureDetail = error.message.slice(0, 500);
    } else {
      const c = classifyGenerationError(error, events);
      status = c.failureClass === "infra" ? "infra" : "generation_failed";
      failureClass = c.failureClass;
      finalBuildClass = c.finalBuildClass ?? null;
      failureDetail = c.detail;
    }
  }

  const tokens = sumTokens(events);
  return {
    source,
    result: {
      id: spec.id,
      category: spec.category,
      difficulty: spec.difficulty,
      corpusHash: spec.corpusHash,
      run: runIndex,
      status,
      failureClass,
      finalBuildClass,
      failureDetail,
      assertionFailures,
      attemptsUsed: events.filter((e) => e.type === "attempt_start").length,
      durations: {
        totalMs: Date.now() - startedAt,
        llmMs: events.filter((e) => e.type === "llm_complete").map((e) => e.durationMs),
        buildMs: events.filter((e) => e.type === "build_complete").map((e) => e.durationMs),
      },
      tokens,
      estimatedCostUsd: estimateCostUsd(tokens, model),
      extraDeps: source
        ? Object.keys(source.dependencies).filter((d) => d !== "@plotday/twister")
        : [],
      files: source ? Object.keys(source.files) : [],
    },
  };
}

function selectSpecs(corpus: CorpusSpec[], only: string | null): CorpusSpec[] {
  if (!only) return corpus;
  const wanted = new Set(only.split(",").map((s) => s.trim()).filter(Boolean));
  const selected = corpus.filter((s) => wanted.has(s.id) || wanted.has(s.category));
  if (selected.length === 0) {
    throw new EvalInfraError(
      `--only matched nothing. Available: ${corpus
        .map((s) => `${s.id} (${s.category})`)
        .join(", ")}`
    );
  }
  return selected;
}

function timestamp(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
}

async function saveOutputs(
  results: RunResults,
  executions: SpecExecution[],
  opts: CliOptions,
  stamp: string
): Promise<string> {
  await mkdir(RESULTS_DIR, { recursive: true });
  const basename = `${stamp}-${results.label}`;
  const resultsPath = join(RESULTS_DIR, `${basename}.json`);
  await writeFile(resultsPath, JSON.stringify(results, null, 2), "utf-8");
  if (opts.keepOutput) {
    for (const execution of executions) {
      if (!execution.source) continue;
      const dir = join(
        RESULTS_DIR,
        `${basename}.sources`,
        `${execution.result.id}.run${execution.result.run}`
      );
      await mkdir(dir, { recursive: true });
      for (const [name, content] of Object.entries(execution.source.files)) {
        await writeFile(join(dir, name), content, "utf-8");
      }
    }
  }
  return resultsPath;
}

async function main(): Promise<void> {
  const opts = parseCliArgs(process.argv.slice(2));
  const corpus = await loadCorpus();

  if (opts.list) {
    for (const spec of corpus) {
      console.log(`${spec.id}\t${spec.category}\t${spec.difficulty}`);
    }
    return;
  }

  // Preflight — fail fast with actionable messages.
  assertDockerAvailable();
  const vars = loadDevVars();
  assertRequiredVars(vars);
  if (!existsSync(join(TWISTER_DIST, "index.d.ts"))) {
    throw new EvalInfraError(
      "public/twister/dist is missing — run 'cd public/twister && pnpm build'"
    );
  }
  const selected = selectSpecs(corpus, opts.only);
  const model = opts.model ?? DEFAULT_GENERATION_MODEL;
  const label = opts.label ?? model;

  log(`building container image…`);
  buildImage();
  const port = await findFreePort();
  const containerName = startContainer(port);
  const cleanup = () => stopContainer(containerName);
  process.on("SIGINT", () => {
    cleanup();
    process.exit(130);
  });

  try {
    await waitForHealth(port);
    log(`container ready on :${port} — ${selected.length} spec(s) × ${opts.runs} run(s), model ${model}`);
    const env = buildEvalEnv(vars, port) as unknown as Bindings;
    const startedAt = new Date().toISOString();
    const stamp = timestamp();
    const executions: SpecExecution[] = [];

    for (let run = 1; run <= opts.runs; run++) {
      let remaining = [...selected];
      if (run === 1 && remaining.length > 1) {
        // Warm the Anthropic prompt cache with one solo spec so concurrent
        // first calls don't all pay the cache write.
        const [first, ...rest] = remaining;
        log(`warmup: ${first.id}`);
        const execution = await runSpec(first, run, env, model);
        log(`done: ${first.id} → ${execution.result.status}`);
        executions.push(execution);
        remaining = rest;
      }
      const results = await runPool(remaining, opts.concurrency, async (spec) => {
        log(`running: ${spec.id} (run ${run})`);
        const execution = await runSpec(spec, run, env, model);
        log(`done: ${spec.id} → ${execution.result.status}`);
        return execution;
      });
      executions.push(...results);
    }

    const results = buildRunResults({
      label,
      model,
      startedAt,
      flags: { concurrency: opts.concurrency, runs: opts.runs, only: opts.only },
      specs: executions.map((e) => e.result),
    });
    const resultsPath = await saveOutputs(results, executions, opts, stamp);

    console.log("");
    console.log(renderScorecard(results));
    console.log("");
    log(`results written to ${resultsPath}`);

    if (opts.compare) {
      const baseline = JSON.parse(await readFile(opts.compare, "utf-8")) as RunResults;
      console.log("");
      console.log(renderCompare(results, baseline));
    }
  } finally {
    cleanup();
  }
}

main().catch((error: unknown) => {
  console.error(`[eval] FATAL: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
```

- [ ] **Step 6: Write the README**

`workers/api/evals/README.md`:

```markdown
# Twist generation eval harness

Measures the spec→twist generation pipeline (`generateTwist()` +
twist-builder container) against a fixed corpus of natural-language specs.
Run it before/after any change to the generation prompt, retry policy,
model, or `@plotday/twister` release, and compare.

Spec: `docs/superpowers/specs/2026-07-07-twist-generation-eval-harness-design.md`.

## Prerequisites

- Docker running (the twist-builder container is built and booted locally).
- `workers/api/.dev.vars` with `ANTHROPIC_API_KEY`, `AI_GATEWAY_ACCOUNT_ID`,
  `AI_GATEWAY_ID`, `AI_GATEWAY_TOKEN` (`pnpm --filter @plotday/api get-env`,
  or `pnpm cp-env <main-repo>` in a worktree).
- Built SDK types: `cd public/twister && pnpm build`.

## Usage

```bash
# Full corpus (≈$2–5 in API tokens, 15–30 min):
pnpm --filter @plotday/api eval:twist-gen

# One spec (≈$0.15–0.40):
pnpm --filter @plotday/api eval:twist-gen --only hello-thread

# A/B a model, then compare:
pnpm --filter @plotday/api eval:twist-gen --label baseline
pnpm --filter @plotday/api eval:twist-gen --model claude-opus-4-8 \
  --compare evals/results/<baseline-file>.json
```

Flags: `--only <ids|categories>` · `--model <id>` · `--runs <n>` ·
`--concurrency <n>` (default 3) · `--label <name>` · `--compare <json>` ·
`--keep-output` (save generated sources) · `--list`.

Results land in `evals/results/<stamp>-<label>.json` (gitignored). Exit code
0 = run completed (failing specs are data); 1 = infra problem.

## Pass bar (per spec)

1. `generateTwist()` resolves (pipeline).
2. `index.ts` default-exports a class extending `Twist` (universal).
3. Frontmatter `assertions`/`notMatch` regexes hold (per-spec).
4. `tsc --noEmit` against the real twister types passes (typecheck).

## Adding a spec

Add `evals/corpus/NN-your-id.md` with YAML frontmatter (`id`, `category`,
`difficulty`, `assertions`, optional `notMatch`/`allowDeps`) and a body
written the way a real user would describe the twist — plain language, no
SDK identifiers. `pnpm --filter @plotday/api test -- evals/__tests__/corpus.test.ts`
validates it (update the expected count).

## Caveats

- A timed-out spec's container build may still be running in the background;
  it only skews that one measurement.
- Cost figures are estimates from a hardcoded rate table in `lib/report.ts`.
```

- [ ] **Step 7: Verify — unit suite, lint, --list**

Run: `pnpm --filter @plotday/api test`
Expected: full unit suite PASSES (all evals tests + all pre-existing tests).

Run: `pnpm --filter @plotday/api lint`
Expected: PASS. If eslint flags the evals files (e.g. `no-console` despite the disable comment, or import ordering), fix the code to conform — do not change eslint config.

Run: `pnpm --filter @plotday/api eval:twist-gen --list`
Expected: 12 lines, `hello-thread` first, no Docker or API keys needed.

- [ ] **Step 8: Smoke run (one spec, real pipeline)**

Requires Docker + populated `.dev.vars` (in a worktree: `pnpm cp-env <main-repo-path>` first). Costs ≈$0.15–0.40 and takes 2–5 min:

Run: `pnpm --filter @plotday/api eval:twist-gen --only hello-thread --label smoke`
Expected: container builds and boots, spec runs, scorecard prints with 1 row (any non-infra status is acceptable — `pass` is likely), results JSON written under `evals/results/`, container stopped afterwards (`docker ps` shows no `plot-twist-eval-*`).

If Docker or credentials are unavailable in the execution environment, stop and report to the human partner instead of faking the verification.

- [ ] **Step 9: Commit**

```bash
git add workers/api/evals/lib/cli.ts workers/api/evals/run.ts workers/api/evals/README.md workers/api/evals/__tests__/cli.test.ts
git commit -m "feat(api): twist-generation eval runner CLI + README

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

1. `pnpm --filter @plotday/api test` — everything green.
2. `pnpm --filter @plotday/api lint` — clean.
3. `git status` — no untracked files except `evals/results/` artifacts (gitignored).
4. Optional but recommended: a full baseline run
   `pnpm --filter @plotday/api eval:twist-gen --label baseline-sonnet-4-6`
   (~$2–5, 15–30 min) so the branch lands with a committed-nowhere,
   locally-stored baseline to compare future pipeline changes against.
