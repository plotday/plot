# Twist Generation Retries + Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multi-turn build-repair retries that keep the spec in context, per-call LLM retry policy for transient/output failures, and migration from deprecated `generateObject` to `streamText` + structured output with a 60K cap and per-file progress.

**Architecture:** `generateTwistInner` keeps a growing `ModelMessage[]` conversation across build attempts; a new `callModelWithRetries` wrapper owns the `streamText` call, the per-file progress from `partialOutputStream`, and the transient/output retry budgets, emitting a new additive `llm_retry` telemetry event. The harness counts retries per spec and the classifier learns the new error name the streaming API throws.

**Tech Stack:** ai@7 `streamText` + `Output.object` (`partialOutputStream`, promise-like `output`/`totalUsage`/`finishReason`/`providerMetadata`), vitest, eval harness.

**Spec:** `docs/superpowers/specs/2026-07-09-twist-gen-retry-streaming-design.md` — read before starting.

**Spec amendment (plan-time discovery):** the streaming API throws `AI_NoOutputGeneratedError` (new name) where `generateObject` threw `AI_NoObjectGeneratedError`. The spec said "classifier unchanged"; Task 3 additively teaches the classifier both names (same truncation/schema split). Everything else in the classifier is untouched.

## Global Constraints

- Branch: `twist-gen-retry-streaming` (off main). Work in the worktree `/Users/kris.braun/code/plot/.claude/worktrees/twist-gen-eval-harness`.
- `resolveGenerationModel`, the provider-conditional `instructions` ternary, `toTwistSource`, `generatedTwistSchema`, and the `Type check failed:`/`Build failed:`/`Failed to install dependencies:` marker handling are UNTOUCHED.
- `MAX_ATTEMPTS = 3` build-repair rounds; per LLM call: ≤2 transient retries (backoff 1s/4s with full jitter), ≤1 output-problem retry. Exhausted budgets rethrow the final error unchanged.
- The spec text of the FIRST user message (spec + Requirements block) is byte-identical to today's attempt-1 `userPrompt`.
- Telemetry stays additive and `safeEmit`-wrapped; omitting `onEvent` keeps behavior identical.
- Live-run spend authorized: one Pro comparison (~$6) + one flash A/B (~$1). **Live runs are executed by the controller session, not implementer subagents** (background processes inside synchronous subagents die with the session).
- Lint gate: `pnpm --filter @plotday/api lint` → 0 errors, no new warnings. Scoped tests: `npx vitest run <path>` from `workers/api`.
- Every commit message ends with: `Co-Authored-By: Claude <noreply@anthropic.com>`

---

### Task 1: streamText migration (behavior-preserving single-turn)

**Files:**
- Modify: `workers/api/src/twist/generator.ts`
- Test: `workers/api/src/twist/generator.test.ts`

**Interfaces:**
- Consumes: ai@7 `streamText`, `Output` (namespace export; `Output.object({ schema, name, description })`).
- Produces (Task 2 builds on): the LLM call consuming `stream.partialOutputStream` then `await stream.output`; `extractUsage({ usage, providerMetadata })` fed from `await stream.totalUsage` / `await stream.providerMetadata`; per-file `onProgress("Writing <path>")` emitted once per file per call; `maxOutputTokens: 60_000`.

- [ ] **Step 1: Rewrite the test mocks**

In `workers/api/src/twist/generator.test.ts`, REPLACE the `vi.mock("ai", ...)` block and the `generateObjectMock` declaration with:

```ts
// Capture streamText params and control its result. streamText returns its
// result object SYNCHRONOUSLY (promises/streams inside), so the mock does too.
const streamTextMock = vi.fn();
vi.mock("ai", () => ({
  streamText: (...args: unknown[]) => streamTextMock(...args),
  Output: {
    object: (opts: unknown) => ({ __outputSpec: opts }),
  },
}));

// Build a fake streamText result. `partials` drives partialOutputStream;
// `error` makes the stream throw mid-iteration and the output promise reject.
function fakeStream(
  object: unknown,
  opts: {
    usage?: unknown;
    providerMetadata?: unknown;
    partials?: unknown[];
    error?: Error;
    finishReason?: string;
  } = {}
) {
  const output = opts.error
    ? Promise.reject(opts.error)
    : Promise.resolve(object);
  output.catch(() => {}); // avoid unhandled rejection when the stream throws first
  return {
    partialOutputStream: (async function* () {
      for (const p of opts.partials ?? [object]) yield p;
      if (opts.error) throw opts.error;
    })(),
    output,
    totalUsage: Promise.resolve(opts.usage ?? {}),
    providerMetadata: Promise.resolve(opts.providerMetadata),
    finishReason: Promise.resolve(opts.finishReason ?? (opts.error ? "error" : "stop")),
  };
}
```

In `beforeEach`, replace the generateObject default with:

```ts
    streamTextMock.mockReset();
    streamTextMock.mockReturnValue(fakeStream({ ...validGenerated }));
```

Then port every existing test mechanically: `generateObjectMock` → `streamTextMock`; per-test custom results become `streamTextMock.mockReturnValueOnce(fakeStream(objectOrGenerated, { usage, providerMetadata }))`; assertions on `generateObjectMock.mock.calls[0][0]` become `streamTextMock.mock.calls[0][0]` (the options object still carries `instructions`, `messages`, `maxOutputTokens`). Update the token-budget assertion to `expect(call.maxOutputTokens).toBe(60_000);` and the schema assertions to `expect(call.output).toEqual({ __outputSpec: expect.objectContaining({ name: "TwistSource" }) });`. For error-path tests (e.g. usage/google-metadata tests), pass usage via `fakeStream(validGenerated, { usage: {...}, providerMetadata: {...} })`.

Add one new test:

```ts
  it("announces each generated file once via onProgress while streaming", async () => {
    streamTextMock.mockReturnValueOnce(
      fakeStream(
        {
          displayName: "P",
          files: [
            { path: "index.ts", content: "a" },
            { path: "lib/util.ts", content: "b" },
          ],
          dependencies: [],
        },
        {
          partials: [
            { files: [{ path: "index.ts" }] },
            { files: [{ path: "index.ts" }, { path: "lib/util.ts" }] },
            { files: [{ path: "index.ts", content: "a" }, { path: "lib/util.ts", content: "b" }] },
          ],
        }
      )
    );
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const onProgress = vi.fn();
    await generateTwist({ spec: "hello", env: makeEnv(), onProgress });
    const writes = onProgress.mock.calls.map((c) => c[0]).filter((m: string) => m.startsWith("Writing "));
    expect(writes).toEqual(["Writing index.ts", "Writing lib/util.ts"]);
  });
```

- [ ] **Step 2: Run to verify failures**

Run from `workers/api`: `npx vitest run src/twist/generator.test.ts`
Expected: broad FAIL (generator still calls generateObject; `ai` mock no longer exports it).

- [ ] **Step 3: Implement the migration in generator.ts**

a) Imports: replace `import { generateObject, type LanguageModel } from "ai";` with `import { streamText, Output, type LanguageModel } from "ai";`

b) Replace the `generateObject` call block (from `const llmStart = Date.now();` through the `});` that closes the call) with:

```ts
    const llmStart = Date.now();
    // streamText returns synchronously; results arrive via streams/promises.
    // Streaming (a) lifts the output cap safely to 60K — the old 16K cap
    // existed only to stay under non-streaming HTTP timeouts and truncated
    // half of all flash generations — and (b) lets us surface per-file
    // progress while the model writes.
    const stream = streamText({
      model,
      maxOutputTokens: 60_000,
      output: Output.object({
        schema: generatedTwistSchema,
        name: "TwistSource",
        description:
          'Twist source code: a files array (each entry has a path like "index.ts" and the full file content) plus an npm dependencies array (name + version).',
      }),
      instructions: modelId.startsWith("claude")
        ? {
            role: "system",
            content: systemPrompt,
            providerOptions: {
              anthropic: { cacheControl: { type: "ephemeral" } },
            },
          }
        : systemPrompt,
      messages: [{ role: "user", content: userPrompt }],
    });

    // Announce each file path once as it appears in the partial output.
    const announced = new Set<string>();
    for await (const partial of stream.partialOutputStream) {
      const files = (partial as { files?: Array<{ path?: string }> })?.files ?? [];
      for (const file of files) {
        if (file?.path && !announced.has(file.path)) {
          announced.add(file.path);
          onProgress?.(`Writing ${file.path}`);
        }
      }
    }

    const generated = await stream.output;
    safeEmit(onEvent, {
      type: "llm_complete",
      attempt,
      durationMs: Date.now() - llmStart,
      usage: extractUsage({
        usage: await stream.totalUsage,
        providerMetadata: (await stream.providerMetadata) as
          | Record<string, Record<string, unknown>>
          | undefined,
      }),
    });
```

and change the mapping line to `const source: TwistSource = toTwistSource(generated);`. Keep the comment above it. Update the stale comment block above the call (the "Output limit: non-streaming…" paragraph) to the streaming rationale shown inline above. If `stream.providerMetadata` does not exist on the installed `StreamTextResult` type, drop that field and pass only `{ usage: await stream.totalUsage }` — `extractUsage` already falls back to `usage.cachedInputTokens`; note the adjustment in your report.

- [ ] **Step 4: Run the full test file**

Run: `npx vitest run src/twist/generator.test.ts`
Expected: ALL tests pass (ported + new progress test). Also `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/generator.ts workers/api/src/twist/generator.test.ts
git commit -m "feat(api): migrate twist generation to streamText with 60K cap + per-file progress

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Multi-turn conversation + per-call LLM retry wrapper

**Files:**
- Modify: `workers/api/src/twist/generator.ts`
- Test: `workers/api/src/twist/generator.test.ts`

**Interfaces:**
- Consumes: Task 1's streaming call shape.
- Produces: `GenerateAttemptEvent` union gains `{ type: "llm_retry"; attempt: number; reason: "transient" | "output"; retry: number }` (Task 3 counts these); exported-for-test helpers `isTransientLlmError(error: unknown): boolean` and `isOutputProblemError(error: unknown): boolean`.

- [ ] **Step 1: Write the failing tests**

Append to `workers/api/src/twist/generator.test.ts` (uses `fakeStream` and mocks from Task 1). Also add `import { setTimeout as realSetTimeout } from "node:timers";` is NOT needed — the sleep is injected via module state; tests use fake timers instead:

```ts
function namedError(name: string, message: string, extra: Record<string, unknown> = {}) {
  const err = new Error(message);
  err.name = name;
  Object.assign(err, extra);
  return err;
}

describe("multi-turn build-repair conversation", () => {
  it("keeps the spec in every attempt and appends assistant/error turns", async () => {
    buildTwistMock
      .mockResolvedValueOnce({ success: false, errors: ["Type check failed:\nTS2304"] })
      .mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({ spec: "my spec text", env: makeEnv() });

    expect(streamTextMock).toHaveBeenCalledTimes(2);
    const first = streamTextMock.mock.calls[0][0].messages;
    const second = streamTextMock.mock.calls[1][0].messages;
    // Attempt 1: single user message containing the spec.
    expect(first).toHaveLength(1);
    expect(first[0].role).toBe("user");
    expect(first[0].content).toContain("my spec text");
    // Attempt 2: spec turn + assistant's prior output + error feedback.
    expect(second).toHaveLength(3);
    expect(second[0]).toEqual(first[0]);
    expect(second[1].role).toBe("assistant");
    expect(second[1].content).toContain('"index.ts"'); // array-shaped prior output
    expect(second[2].role).toBe("user");
    expect(second[2].content).toContain("Type check failed:");
    expect(second[2].content).toContain("Fix these and return the complete corrected twist.");
  });
});

describe("LLM retry policy", () => {
  it("retries transient errors with backoff and emits llm_retry", async () => {
    vi.useFakeTimers();
    try {
      streamTextMock
        .mockReturnValueOnce(fakeStream(null, { error: namedError("AI_APICallError", "overloaded", { statusCode: 529 }) }))
        .mockReturnValueOnce(fakeStream({ ...validGenerated }));
      buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
      const events: GenerateAttemptEvent[] = [];
      const done = generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
      await vi.runAllTimersAsync();
      await done;
      expect(streamTextMock).toHaveBeenCalledTimes(2);
      expect(events).toContainEqual({ type: "llm_retry", attempt: 1, reason: "transient", retry: 1 });
      // Only ONE llm_complete (the successful call).
      expect(events.filter((e) => e.type === "llm_complete")).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("gives up after two transient retries", async () => {
    vi.useFakeTimers();
    try {
      const boom = namedError("AI_APICallError", "overloaded", { statusCode: 529 });
      streamTextMock.mockReturnValue(fakeStream(null, { error: boom }));
      const done = generateTwist({ spec: "hello", env: makeEnv() });
      const assertion = expect(done).rejects.toThrow(/overloaded/);
      await vi.runAllTimersAsync();
      await assertion;
      expect(streamTextMock).toHaveBeenCalledTimes(3); // initial + 2 retries
    } finally {
      vi.useRealTimers();
    }
  });

  it("retries an output problem once with a corrective turn", async () => {
    streamTextMock
      .mockReturnValueOnce(
        fakeStream(null, {
          error: namedError("AI_NoOutputGeneratedError", "no output generated"),
          finishReason: "length",
        })
      )
      .mockReturnValueOnce(fakeStream({ ...validGenerated }));
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    expect(streamTextMock).toHaveBeenCalledTimes(2);
    const secondMessages = streamTextMock.mock.calls[1][0].messages;
    expect(secondMessages[secondMessages.length - 1].role).toBe("user");
    expect(secondMessages[secondMessages.length - 1].content).toMatch(/not a valid twist object/);
    expect(events).toContainEqual({ type: "llm_retry", attempt: 1, reason: "output", retry: 1 });
  });

  it("gives up after one output-problem retry", async () => {
    const bad = namedError("AI_NoOutputGeneratedError", "no output generated");
    streamTextMock.mockReturnValue(fakeStream(null, { error: bad }));
    await expect(generateTwist({ spec: "hello", env: makeEnv() })).rejects.toThrow(/no output generated/);
    expect(streamTextMock).toHaveBeenCalledTimes(2); // initial + 1 retry
  });
});
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `npx vitest run src/twist/generator.test.ts`
Expected: the 5 new tests FAIL (single-turn retry prompt today; errors abort immediately); ported Task 1 tests still pass.

- [ ] **Step 3: Implement**

In `workers/api/src/twist/generator.ts`:

a) Extend the event union:

```ts
  | {
      type: "llm_retry";
      attempt: number;
      reason: "transient" | "output";
      retry: number;
    }
```

b) Add classification helpers (export for tests) after `safeEmit`:

```ts
export function isTransientLlmError(error: unknown): boolean {
  const status = (error as { statusCode?: number })?.statusCode;
  if (typeof status === "number") return status === 429 || status >= 500;
  const name = (error as Error)?.name ?? "";
  if (name === "AI_RetryError") return true;
  const message = (error as Error)?.message ?? "";
  return /ECONNRESET|ETIMEDOUT|fetch failed|network/i.test(message);
}

export function isOutputProblemError(error: unknown): boolean {
  const name = (error as Error)?.name ?? "";
  return name === "AI_NoObjectGeneratedError" || name === "AI_NoOutputGeneratedError";
}
```

c) In `generateTwistInner`, replace the attempt-1/retry `userPrompt` branching with a conversation. Before the while loop:

```ts
  // The conversation grows across build-repair attempts: the spec stays in
  // the first user turn, each attempt's output becomes an assistant turn,
  // and build errors arrive as user feedback turns. Retries therefore never
  // lose the original intent (they previously saw only the prior JSON).
  const conversation: ModelMessage[] = [
    {
      role: "user",
      content: `Generate a Plot twist based on this specification:

${spec}

Requirements:
- "displayName" must be a concise, human-readable title for the twist (e.g., "Google Calendar Sync", "Task Manager")
- Extract the displayName from the specification based on the twist's purpose
- "files" must include an entry whose path is "index.ts" — the entry point
- The index.ts file must export a default class extending Twist
`,
    },
  ];
```

(import `type ModelMessage` from `"ai"`; the Requirements text is byte-identical to today's attempt-1 prompt.) Delete the `previousSource`/`previousErrors` variables and the retry-prompt string.

d) Extract the Task 1 streaming call into a wrapper placed after `extractUsage` (module scope):

```ts
const TRANSIENT_MAX_RETRIES = 2;
const OUTPUT_MAX_RETRIES = 1;
const TRANSIENT_BACKOFF_MS = [1_000, 4_000];

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

async function callModelWithRetries(params: {
  model: LanguageModel;
  modelId: string;
  systemPrompt: string;
  conversation: ModelMessage[];
  attempt: number;
  onProgress?: (message: string) => void;
  onEvent?: (event: GenerateAttemptEvent) => void;
}): Promise<{
  generated: z.infer<typeof generatedTwistSchema>;
  usage: Extract<GenerateAttemptEvent, { type: "llm_complete" }>["usage"];
}> {
  const { model, modelId, systemPrompt, conversation, attempt, onProgress, onEvent } = params;
  let transientRetries = 0;
  let outputRetries = 0;
  for (;;) {
    try {
      const stream = streamText({
        model,
        maxOutputTokens: 60_000,
        output: Output.object({
          schema: generatedTwistSchema,
          name: "TwistSource",
          description:
            'Twist source code: a files array (each entry has a path like "index.ts" and the full file content) plus an npm dependencies array (name + version).',
        }),
        instructions: modelId.startsWith("claude")
          ? {
              role: "system",
              content: systemPrompt,
              providerOptions: {
                anthropic: { cacheControl: { type: "ephemeral" } },
              },
            }
          : systemPrompt,
        messages: conversation,
      });

      const announced = new Set<string>();
      for await (const partial of stream.partialOutputStream) {
        const files = (partial as { files?: Array<{ path?: string }> })?.files ?? [];
        for (const file of files) {
          if (file?.path && !announced.has(file.path)) {
            announced.add(file.path);
            onProgress?.(`Writing ${file.path}`);
          }
        }
      }

      const generated = await stream.output;
      const usage = extractUsage({
        usage: await stream.totalUsage,
        providerMetadata: (await stream.providerMetadata) as
          | Record<string, Record<string, unknown>>
          | undefined,
      });
      return { generated, usage };
    } catch (error) {
      if (isTransientLlmError(error) && transientRetries < TRANSIENT_MAX_RETRIES) {
        const backoff = TRANSIENT_BACKOFF_MS[transientRetries];
        transientRetries++;
        safeEmit(onEvent, { type: "llm_retry", attempt, reason: "transient", retry: transientRetries });
        await sleep(backoff * (0.5 + Math.random() * 0.5)); // full jitter
        continue;
      }
      if (isOutputProblemError(error) && outputRetries < OUTPUT_MAX_RETRIES) {
        outputRetries++;
        safeEmit(onEvent, { type: "llm_retry", attempt, reason: "output", retry: outputRetries });
        conversation.push({
          role: "user",
          content:
            "Your previous response was not a valid twist object (it was truncated or failed schema validation). Return the complete twist again, matching the schema exactly.",
        });
        continue;
      }
      throw error;
    }
  }
}
```

e) The while-loop body becomes: emit `attempt_start`; time the wrapper; on success emit `llm_complete` with the returned usage; then:

```ts
    const llmStart = Date.now();
    const { generated, usage } = await callModelWithRetries({
      model,
      modelId,
      systemPrompt,
      conversation,
      attempt,
      onProgress,
      onEvent,
    });
    safeEmit(onEvent, {
      type: "llm_complete",
      attempt,
      durationMs: Date.now() - llmStart,
      usage,
    });

    conversation.push({ role: "assistant", content: JSON.stringify(generated) });

    const source: TwistSource = toTwistSource(generated);
    // ... (unchanged: twister dep merge, index.ts guard, build, build_complete emit)
```

and on build failure (replacing the previousSource/previousErrors bookkeeping):

```ts
    conversation.push({
      role: "user",
      content: `The twist failed to build. Errors:\n\n${buildResult.errors.join("\n\n")}\n\nFix these and return the complete corrected twist.`,
    });
```

The `systemPrompt` construction moves above the loop (it is loop-invariant). The MAX_ATTEMPTS throw and logging stay as they are (log `buildResult.errors` directly).

- [ ] **Step 4: Run the full test file + lint**

Run: `npx vitest run src/twist/generator.test.ts` — ALL pass. `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/generator.ts workers/api/src/twist/generator.test.ts
git commit -m "feat(api): multi-turn build-repair retries + LLM transient/output retry policy

Retries now keep the original spec and the model's own prior output in a
growing conversation (previously only the prior JSON + errors were sent),
and LLM-level failures retry within budget — 2 transient with jittered
backoff, 1 output problem with a corrective turn — instead of aborting the
generation. New additive llm_retry telemetry event.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Harness — retry counting + new error name

**Files:**
- Modify: `workers/api/evals/lib/types.ts`, `workers/api/evals/run.ts`, `workers/api/evals/lib/report.ts`, `workers/api/evals/lib/classify.ts`
- Test: `workers/api/evals/__tests__/classify.test.ts`, `workers/api/evals/__tests__/report.test.ts`

**Interfaces:**
- Consumes: `llm_retry` events (Task 2).
- Produces: `SpecResult.llmRetries: number`; scorecard `retries` column; classifier recognizes `AI_NoOutputGeneratedError`.

- [ ] **Step 1: Failing tests**

a) `classify.test.ts`, add to the generation-error describe:

```ts
  it("classifies the streaming API's truncation error name", () => {
    const c = classifyGenerationError(
      namedError("AI_NoOutputGeneratedError", "no output generated", { finishReason: "length" }),
      []
    );
    expect(c.failureClass).toBe("output_truncated");
  });

  it("classifies the streaming API's schema error name", () => {
    const c = classifyGenerationError(
      namedError("AI_NoOutputGeneratedError", "response did not match schema", { finishReason: "stop" }),
      []
    );
    expect(c.failureClass).toBe("schema_mismatch");
  });
```

b) `report.test.ts`: add `llmRetries: 0,` to the `spec()` fixture factory, and add inside the rendering describe:

```ts
  it("scorecard shows the retries column", () => {
    const out = renderScorecard(
      buildRunResults({
        label: "t",
        model: "m",
        startedAt: "2026-07-09T00:00:00Z",
        flags: { concurrency: 1, runs: 1, only: null },
        specs: [spec({ id: "r", llmRetries: 2 })],
      })
    );
    expect(out).toContain("| retries |");
    expect(out).toContain("| r | 1 | pass |  | 1 | 2 |");
  });
```

(The exact row prefix must match your column order — put `retries` immediately after `attempts` and update the header/divider accordingly; adjust the expected string to the real rendering, without weakening the two assertions: header contains `retries`, and the row contains the value 2 for spec r.)

- [ ] **Step 2: Run to verify failures**

Run: `npx vitest run evals/__tests__/classify.test.ts evals/__tests__/report.test.ts`
Expected: FAIL — unknown error name → api_error; llmRetries not a field; no retries column.

- [ ] **Step 3: Implement**

- `types.ts`: `SpecResult` gains `llmRetries: number;` (after `attemptsUsed`).
- `classify.ts`: the NoObjectGeneratedError branch condition becomes `if (name === "AI_NoObjectGeneratedError" || name === "AI_NoOutputGeneratedError") {` (same finishReason split inside).
- `run.ts`: in `runSpec`'s result construction add `llmRetries: events.filter((e) => e.type === "llm_retry").length,`.
- `report.ts`: scorecard header/divider/row gain a `retries` column right after `attempts` rendering `s.llmRetries`.

- [ ] **Step 4: Verify**

Run: `npx vitest run evals/` — all pass. `pnpm --filter @plotday/api lint` — clean.

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals
git commit -m "feat(api): eval harness counts LLM retries + recognizes streaming error name

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Measurement runs (CONTROLLER-EXECUTED)

No implementer subagent — the controller runs these from its own session (background Bash), per the process lesson in the ledger. Prereqs: Docker up, `.dev.vars`, `public/twister/dist` built.

- [ ] **Step 1: Pro comparison (~$6)**

`pnpm --filter @plotday/api eval:twist-gen --label pr-b --runs 2 --compare evals/results/20260708-230257-pr-a.json`
Gates: full-pass ≥ 67% − noise (>8pp drop = stop and investigate), pipeline 100%, no new taxonomy classes, `retries` column populated (0s are fine — Pro rarely errors).

- [ ] **Step 2: Flash A/B (~$1) — the headline**

`pnpm --filter @plotday/api eval:twist-gen --model gemini-3-flash-preview --label pr-b-flash --runs 2`
Compare manually against the flash baseline (`20260708-134632-baseline-gemini.json`: 0/24 — 12 output_truncated, 12 schema_mismatch). Gate: material full-pass improvement; truncation class ≈ eliminated at the 60K cap; `retries` column shows the output-retry policy working.

- [ ] **Step 3: Record**

Append both scorecards + the verdicts to `.superpowers/sdd/progress.md`.

---

## Final verification (after all tasks)

1. `npx vitest run evals/ src/twist/generator.test.ts` — green; `pnpm --filter @plotday/api lint` — clean.
2. Both measurement runs recorded with gates evaluated honestly.
3. `git log --oneline` shows 3 implementation commits + docs commits.
