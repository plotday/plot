# Gemini-Default Twist Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route twist generation by model-id prefix (`gemini-*` → Google via AI Gateway, `claude-*` → Anthropic) and switch the default to `gemini-3-pro-preview`, unblocking the eval baseline.

**Architecture:** A `resolveGenerationModel(env, modelId)` helper inside `generator.ts` mirrors the proven `utils/system-model.ts` gateway wiring for Google and the existing Anthropic wiring; the `instructions` prompt becomes provider-conditional (explicit anthropic cacheControl vs plain string for Gemini's implicit caching). The eval harness becomes model-aware in env validation, CLI validation, and cost rates.

**Tech Stack:** `@ai-sdk/google` ^4.0.6 (already a workers/api dependency), `ai` ^7, Cloudflare AI Gateway `google-ai-studio/v1beta` route, vitest.

**Spec:** `docs/superpowers/specs/2026-07-08-twist-generation-gemini-default-design.md` — read before starting.

## Global Constraints

- Branch: `twist-gen-gemini` (stacked on `twist-gen-eval-harness`). Work in the worktree `/Users/kris.braun/code/plot/.claude/worktrees/twist-gen-eval-harness`.
- `DEFAULT_GENERATION_MODEL = "gemini-3-pro-preview"`; `claude-*` models must keep working via `GenerateTwistOptions.model` exactly as today (SystemModelMessage + anthropic cacheControl preserved).
- Do NOT touch any other `generateObject` call site (channel-router, priority-suggestions, derive-facet-filters have a known separate bug).
- No `thinkingConfig` for generation calls (unlike `SYSTEM_PROVIDER_OPTIONS`).
- Retry-prompt text, zod schema, `maxOutputTokens: 16_000`, and the attempt loop are untouched.
- Eval env still excludes `POSTHOG_API_KEY`.
- Live-run spend authorized for THIS plan: one smoke spec plus a `--runs 2` full baseline on Gemini (~$5–15 total). No other live runs.
- Lint gate: `pnpm --filter @plotday/api lint` → 0 errors, no new warnings. Scoped tests: `npx vitest run <path>` from `workers/api`.
- Every commit message ends with: `Co-Authored-By: Claude <noreply@anthropic.com>`

---

### Task 1: Provider routing in the generator

**Files:**
- Modify: `workers/api/src/twist/generator.ts`
- Test: `workers/api/src/twist/generator.test.ts` (extend/update existing)

**Interfaces:**
- Consumes: `env.GOOGLE_GENERATIVE_AI_API_KEY` (already in `Bindings`, env.ts:266), `createGoogleGenerativeAI` from `@ai-sdk/google`.
- Produces: `DEFAULT_GENERATION_MODEL = "gemini-3-pro-preview"` (Task 2's run.ts/README and Task 3 rely on this value); error messages `"GOOGLE_GENERATIVE_AI_API_KEY is missing"`, `"ANTHROPIC_API_KEY is missing"`, `` `Unsupported generation model: ${modelId}` ``.

- [ ] **Step 1: Update the test file — mocks and env**

In `workers/api/src/twist/generator.test.ts`:

a) After the existing `@ai-sdk/anthropic` mock block, add:

```ts
// Google provider factory — same sentinel pattern as the Anthropic mock.
const googleModelSentinel = { __sentinel: "google-model" };
const createGoogleMock = vi.fn();
const googleModelIdMock = vi.fn();
vi.mock("@ai-sdk/google", () => ({
  createGoogleGenerativeAI: (opts?: unknown) => {
    createGoogleMock(opts);
    return (modelId: string) => {
      googleModelIdMock(modelId);
      return googleModelSentinel;
    };
  },
}));
```

b) In `makeEnv`, add `GOOGLE_GENERATIVE_AI_API_KEY: "gkey",` after `ANTHROPIC_API_KEY: "key",`.

c) In the existing `beforeEach`, add:

```ts
    createGoogleMock.mockClear();
    googleModelIdMock.mockClear();
```

- [ ] **Step 2: Update the two tests the default-switch breaks, add five new ones**

a) REPLACE the entire test `"uses sonnet 4.6, a reasonable token budget, and caches the system prompt"` with these two tests:

```ts
  it("defaults to Gemini with a plain-string system prompt via instructions", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({ spec: "anything", env: makeEnv() });

    expect(createGoogleMock).toHaveBeenCalledTimes(1);
    expect(createAnthropicMock).not.toHaveBeenCalled();
    // Routed through the AI Gateway's Google AI Studio endpoint.
    const providerOpts = createGoogleMock.mock.calls[0][0] as { baseURL: string };
    expect(providerOpts.baseURL).toContain("/google-ai-studio/v1beta");

    const call = generateObjectMock.mock.calls[0][0];
    expect(call.maxOutputTokens).toBeGreaterThanOrEqual(16_000);
    // Gemini 2.5+/3 caches large repeated prefixes implicitly — no provider
    // options needed, so instructions is a plain string.
    expect(typeof call.instructions).toBe("string");
    expect(call.instructions).toContain("<SDK_DOCS>");
    expect(call.instructions).toContain("<TWIST_GUIDE>");
    // messages must contain ONLY the user message — a system entry here
    // would make ai@7's generateObject throw before any network call.
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");
  });

  it("keeps the anthropic cacheControl instructions shape for claude models", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({
      spec: "anything",
      env: makeEnv(),
      model: "claude-sonnet-4-6",
    });

    expect(createAnthropicMock).toHaveBeenCalledTimes(1);
    expect(createGoogleMock).not.toHaveBeenCalled();

    const call = generateObjectMock.mock.calls[0][0];
    // ai@7 forbids system-role entries in `messages` — the system prompt goes
    // through the `instructions` option as a SystemModelMessage, which is the
    // only shape that still carries the anthropic cacheControl marker.
    expect(call.instructions).toEqual(
      expect.objectContaining({
        role: "system",
        providerOptions: {
          anthropic: { cacheControl: { type: "ephemeral" } },
        },
      })
    );
    expect(call.instructions.content).toContain("<SDK_DOCS>");
    expect(call.instructions.content).toContain("<TWIST_GUIDE>");
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");
  });
```

b) In the `"generateTwist telemetry hooks"` describe, REPLACE the test `"uses the default model when no override is given"` with:

```ts
  it("uses the default model when no override is given", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv() });
    expect(googleModelIdMock).toHaveBeenCalledWith("gemini-3-pro-preview");
    expect(modelIdMock).not.toHaveBeenCalled();
  });
```

(The `"honors the model override"` test with `claude-opus-4-8` stays exactly as-is — it now also proves cross-provider routing.)

c) Append a new describe at the end of the file:

```ts
describe("generateTwist provider routing", () => {
  it("rejects an unsupported model id", async () => {
    await expect(
      generateTwist({ spec: "hello", env: makeEnv(), model: "gpt-4o" })
    ).rejects.toThrow(/Unsupported generation model: gpt-4o/);
  });

  it("rejects a gemini model when GOOGLE_GENERATIVE_AI_API_KEY is missing", async () => {
    await expect(
      generateTwist({
        spec: "hello",
        env: makeEnv({ GOOGLE_GENERATIVE_AI_API_KEY: undefined }),
      })
    ).rejects.toThrow(/GOOGLE_GENERATIVE_AI_API_KEY is missing/);
  });

  it("rejects a claude model when ANTHROPIC_API_KEY is missing", async () => {
    await expect(
      generateTwist({
        spec: "hello",
        env: makeEnv({ ANTHROPIC_API_KEY: undefined }),
        model: "claude-sonnet-4-6",
      })
    ).rejects.toThrow(/ANTHROPIC_API_KEY is missing/);
  });

  it("maps google cached-content metadata into llm_complete usage", async () => {
    generateObjectMock.mockResolvedValue({
      object: { ...validSource },
      usage: { inputTokens: 100, outputTokens: 42 },
      providerMetadata: { google: { cachedContentTokenCount: 55 } },
    });
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    const llm = events.find((e) => e.type === "llm_complete");
    if (!llm || llm.type !== "llm_complete") throw new Error("expected llm_complete");
    expect(llm.usage).toEqual({
      inputTokens: 100,
      outputTokens: 42,
      cacheReadInputTokens: 55,
      cacheCreationInputTokens: undefined,
    });
  });
});
```

- [ ] **Step 3: Run tests to verify the new/updated ones fail**

Run from `workers/api`: `npx vitest run src/twist/generator.test.ts`
Expected: the replaced/new tests FAIL (google mock never called; unsupported model does not reject); pre-existing untouched tests still pass.

- [ ] **Step 4: Implement in generator.ts**

a) Imports — add:

```ts
import { createGoogleGenerativeAI } from "@ai-sdk/google";
```

and extend the `ai` import to include the type: `import { generateObject, type LanguageModel } from "ai";`

b) Change the default:

```ts
export const DEFAULT_GENERATION_MODEL = "gemini-3-pro-preview";
```

c) Add after `extractUsage`:

```ts
/**
 * Resolve the LanguageModel for a generation model id, routed through the
 * Cloudflare AI Gateway. Providers are selected by model-id prefix so
 * callers (notably the eval harness's --model flag) can A/B across vendors:
 *   gemini-* → Google AI Studio (same wiring as utils/system-model.ts)
 *   claude-* → Anthropic
 */
function resolveGenerationModel(env: Bindings, modelId: string): LanguageModel {
  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  if (modelId.startsWith("gemini")) {
    if (!env.GOOGLE_GENERATIVE_AI_API_KEY) {
      throw new Error("GOOGLE_GENERATIVE_AI_API_KEY is missing");
    }
    const google = createGoogleGenerativeAI({
      baseURL: `${gatewayBaseUrl}/google-ai-studio/v1beta`,
      apiKey: env.GOOGLE_GENERATIVE_AI_API_KEY,
      headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
    });
    return google(modelId);
  }
  if (modelId.startsWith("claude")) {
    if (!env.ANTHROPIC_API_KEY) {
      throw new Error("ANTHROPIC_API_KEY is missing");
    }
    const anthropic = createAnthropic({
      baseURL: `${gatewayBaseUrl}/anthropic`,
      apiKey: env.ANTHROPIC_API_KEY,
      headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
    });
    return anthropic(modelId);
  }
  throw new Error(`Unsupported generation model: ${modelId}`);
}
```

d) In `generateTwistInner`, DELETE the inline provider block (the `// Configure Anthropic provider with AI Gateway` comment, `const gatewayBaseUrl = ...`, and the `const anthropicProvider = createAnthropic({...});` statement) and, right after `const modelId = modelOverride ?? DEFAULT_GENERATION_MODEL;`, add:

```ts
  const model = resolveGenerationModel(env, modelId);
```

e) At the `generateObject` call: remove the now-redundant `const model: any = anthropicProvider(modelId);` line, and make `instructions` provider-conditional:

```ts
      instructions: modelId.startsWith("claude")
        ? {
            role: "system",
            content: systemPrompt,
            providerOptions: {
              anthropic: { cacheControl: { type: "ephemeral" } },
            },
          }
        : systemPrompt,
```

Update the comment block above the call: replace "Call Claude API via Vercel AI SDK and Cloudflare AI Gateway." with "Call the model (Gemini by default, Claude via override) through the Cloudflare AI Gateway." and replace the caching paragraph's Anthropic-specific wording with: "Prompt caching: the system prompt is large and identical across retries and callers. Anthropic needs the explicit cache_control ephemeral marker (attached only for claude-* models); Gemini 2.5+/3 applies implicit context caching to large repeated prefixes, so a plain string suffices." Also change "Sonnet 4.6 supports up to 64K output" to "current models support far larger outputs". If `tsc` reports TS2589 (excessively deep instantiation) at the `generateObject` call after removing `any`, restore `const model: any = resolveGenerationModel(env, modelId);` with a `// @ts-ignore`-free cast — the repo hint permits `any` here.

f) In `extractUsage`, add a google branch — replace the function body's return with:

```ts
  const google = result.providerMetadata?.google ?? {};
  return {
    inputTokens: usage?.inputTokens,
    outputTokens: usage?.outputTokens,
    cacheReadInputTokens:
      typeof anthropic.cacheReadInputTokens === "number"
        ? anthropic.cacheReadInputTokens
        : typeof google.cachedContentTokenCount === "number"
          ? google.cachedContentTokenCount
          : usage?.cachedInputTokens,
    cacheCreationInputTokens:
      typeof anthropic.cacheCreationInputTokens === "number"
        ? anthropic.cacheCreationInputTokens
        : undefined,
  };
```

(declare `const google = ...` alongside the existing `const anthropic = ...`).

- [ ] **Step 5: Run the full test file**

Run: `npx vitest run src/twist/generator.test.ts`
Expected: ALL tests pass (including the untouched retry-prompt, event-order, usage-passthrough, and throwing-listener tests).

- [ ] **Step 6: Lint and commit**

Run: `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

```bash
git add workers/api/src/twist/generator.ts workers/api/src/twist/generator.test.ts
git commit -m "feat(api): route twist generation by model prefix, default to Gemini

gemini-* models go through the AI Gateway's Google AI Studio route (same
wiring as utils/system-model.ts) with a plain-string system prompt (implicit
caching); claude-* keeps the explicit anthropic cacheControl instructions.
Default becomes gemini-3-pro-preview, removing the dev-time dependency on
Anthropic credits.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Model-aware eval harness

**Files:**
- Modify: `workers/api/evals/lib/env.ts`
- Modify: `workers/api/evals/lib/cli.ts`
- Modify: `workers/api/evals/lib/report.ts`
- Modify: `workers/api/evals/run.ts` (one call site)
- Modify: `workers/api/evals/README.md`
- Modify: `workers/api/src/twist/generator.e2e.test.ts` (required-vars list + env)
- Test: `workers/api/evals/__tests__/env.test.ts`, `workers/api/evals/__tests__/cli.test.ts`, `workers/api/evals/__tests__/report.test.ts`

**Interfaces:**
- Consumes: `DEFAULT_GENERATION_MODEL` (`"gemini-3-pro-preview"`) from Task 1.
- Produces: `assertRequiredVars(vars: Record<string, string>, model: string): void` (run.ts calls it with the resolved model); `parseCliArgs` rejects `--model` values not starting with `gemini` or `claude`.

- [ ] **Step 1: Update the failing tests first**

a) `workers/api/evals/__tests__/env.test.ts` — REPLACE the `assertRequiredVars` describe with:

```ts
describe("assertRequiredVars", () => {
  it("names every missing var for a gemini model", () => {
    expect(() =>
      assertRequiredVars({ GOOGLE_GENERATIVE_AI_API_KEY: "g" }, "gemini-3-pro-preview")
    ).toThrow(/AI_GATEWAY_ACCOUNT_ID.*AI_GATEWAY_ID.*AI_GATEWAY_TOKEN/s);
  });

  it("does not require ANTHROPIC_API_KEY for gemini models", () => {
    expect(() =>
      assertRequiredVars(
        {
          GOOGLE_GENERATIVE_AI_API_KEY: "g",
          AI_GATEWAY_ACCOUNT_ID: "a",
          AI_GATEWAY_ID: "i",
          AI_GATEWAY_TOKEN: "t",
        },
        "gemini-3-pro-preview"
      )
    ).not.toThrow();
  });

  it("requires ANTHROPIC_API_KEY for claude models", () => {
    expect(() =>
      assertRequiredVars(
        {
          GOOGLE_GENERATIVE_AI_API_KEY: "g",
          AI_GATEWAY_ACCOUNT_ID: "a",
          AI_GATEWAY_ID: "i",
          AI_GATEWAY_TOKEN: "t",
        },
        "claude-sonnet-4-6"
      )
    ).toThrow(/ANTHROPIC_API_KEY/);
  });
});
```

b) In the same file's `buildEvalEnv` describe: add `GOOGLE_GENERATIVE_AI_API_KEY: "g",` to the `vars` fixture and extend the first test:

```ts
    expect(env.GOOGLE_GENERATIVE_AI_API_KEY).toBe("g");
```

(the existing `POSTHOG_API_KEY` exclusion assertion stays).

c) `workers/api/evals/__tests__/cli.test.ts` — add to the describe:

```ts
  it("rejects a model id with an unknown provider prefix", () => {
    expect(() => parseCliArgs(["--model", "gpt-4o"])).toThrow(
      /--model must start with "gemini" or "claude"/
    );
  });
```

d) `workers/api/evals/__tests__/report.test.ts` — add inside the `estimateCostUsd` describe:

```ts
  it("prices gemini pro tokens", () => {
    // 1M fresh input at $2 + 1M output at $12 = $14
    expect(
      estimateCostUsd(
        { input: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 1_000_000 },
        "gemini-3-pro-preview"
      )
    ).toBeCloseTo(14, 5);
  });
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run evals/__tests__/env.test.ts evals/__tests__/cli.test.ts evals/__tests__/report.test.ts`
Expected: FAIL — `assertRequiredVars` arity, missing cli validation, missing gemini rate.

- [ ] **Step 3: Implement**

a) `workers/api/evals/lib/env.ts`:

```ts
export const REQUIRED_VARS = [
  "GOOGLE_GENERATIVE_AI_API_KEY",
  "AI_GATEWAY_ACCOUNT_ID",
  "AI_GATEWAY_ID",
  "AI_GATEWAY_TOKEN",
] as const;

export function assertRequiredVars(
  vars: Record<string, string>,
  model: string
): void {
  const required: string[] = [...REQUIRED_VARS];
  // Anthropic is only needed when a claude model is explicitly selected.
  if (model.startsWith("claude")) required.push("ANTHROPIC_API_KEY");
  const missing = required.filter((key) => !vars[key]);
  if (missing.length > 0) {
    throw new Error(
      `Missing in workers/api/.dev.vars: ${missing.join(", ")} — ` +
        `run 'pnpm --filter @plotday/api get-env' (or 'pnpm cp-env <main-repo>' in a worktree)`
    );
  }
}
```

and in `buildEvalEnv`'s returned object add, after `ANTHROPIC_API_KEY: vars.ANTHROPIC_API_KEY,`:

```ts
    GOOGLE_GENERATIVE_AI_API_KEY: vars.GOOGLE_GENERATIVE_AI_API_KEY,
```

b) `workers/api/evals/lib/cli.ts` — in `parseCliArgs`, before the `return`, add:

```ts
  if (values.model && !/^(gemini|claude)/.test(values.model)) {
    throw new Error('--model must start with "gemini" or "claude"');
  }
```

c) `workers/api/evals/lib/report.ts` — replace the `MODEL_RATES` map and fallback:

```ts
const MODEL_RATES: Record<
  string,
  { input: number; output: number; cacheRead: number; cacheWrite: number }
> = {
  "claude-sonnet-4-6": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  // Gemini list prices (estimates as of 2026-07). Implicit caching bills
  // cached input at ~25% of the input rate; there is no separate write
  // charge, so cacheWrite mirrors the input rate (and is always 0 tokens
  // for gemini in practice — extractUsage only sets it for anthropic).
  "gemini-3-pro-preview": { input: 2, output: 12, cacheRead: 0.5, cacheWrite: 2 },
  "gemini-3-flash-preview": { input: 0.3, output: 2.5, cacheRead: 0.075, cacheWrite: 0.3 },
};
const DEFAULT_RATES = MODEL_RATES["gemini-3-pro-preview"];
```

d) `workers/api/evals/run.ts` — change the preflight call `assertRequiredVars(vars);` to:

```ts
  assertRequiredVars(vars, opts.model ?? DEFAULT_GENERATION_MODEL);
```

e) `workers/api/evals/README.md` — in Prerequisites, replace the `.dev.vars` bullet with:

```markdown
- `workers/api/.dev.vars` with `GOOGLE_GENERATIVE_AI_API_KEY`,
  `AI_GATEWAY_ACCOUNT_ID`, `AI_GATEWAY_ID`, `AI_GATEWAY_TOKEN`
  (`pnpm --filter @plotday/api get-env`, or `pnpm cp-env <main-repo>` in a
  worktree). `ANTHROPIC_API_KEY` is additionally required only for
  `--model claude-*` runs.
```

and update the A/B example to compare against Claude:

```markdown
# A/B a model, then compare:
pnpm --filter @plotday/api eval:twist-gen --label baseline
pnpm --filter @plotday/api eval:twist-gen --model claude-sonnet-4-6 \
  --compare evals/results/<baseline-file>.json
```

f) `workers/api/src/twist/generator.e2e.test.ts`: in the required-vars loop, replace `"ANTHROPIC_API_KEY",` with `"GOOGLE_GENERATIVE_AI_API_KEY",`; in the `env = {...}` construction add `GOOGLE_GENERATIVE_AI_API_KEY: vars.GOOGLE_GENERATIVE_AI_API_KEY,` (keep the ANTHROPIC line — harmless passthrough); update the header comment listing required vars to name the google key.

- [ ] **Step 4: Run the harness suite**

Run: `npx vitest run evals/`
Expected: ALL pass (including untouched corpus/checks/classify/pool tests).

- [ ] **Step 5: Lint and commit**

Run: `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

```bash
git add workers/api/evals workers/api/src/twist/generator.e2e.test.ts
git commit -m "feat(api): model-aware eval harness env, CLI validation, gemini rates

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Live verification — Gemini smoke, then full baseline

**Files:** none created (results land in gitignored `evals/results/`); possibly a one-line default flip (contingency below).

**Interfaces:**
- Consumes: everything from Tasks 1–2; Docker; `workers/api/.dev.vars` (google key present — verify, else `pnpm cp-env /Users/kris.braun/code/plot`).

- [ ] **Step 1: Preflight**

Run from the worktree root: `docker info >/dev/null && grep -c GOOGLE_GENERATIVE_AI_API_KEY workers/api/.dev.vars`
Expected: no docker error; count ≥ 1. Also `ls public/twister/dist/index.d.ts` (build with `cd public/twister && pnpm build` if missing).

- [ ] **Step 2: Gemini smoke (access check for gemini-3-pro-preview)**

Run: `pnpm --filter @plotday/api eval:twist-gen --only hello-thread --label gemini-smoke`
Expected: a real LLM round trip — scorecard row with nonzero `llm s` and `out tok`. Any check status (`pass`, `typecheck_failed`, …) is valid data. Record the scorecard in your report.

**Contingency — model not available:** if the failure detail shows the gateway/Google rejecting the MODEL ID itself (e.g. 404 / "not found for API version" / "is not supported"), flip the default: in `generator.ts` set `DEFAULT_GENERATION_MODEL = "gemini-3-flash-preview"`, update the one test expecting `"gemini-3-pro-preview"` (Task 1 Step 2b) accordingly, re-run `npx vitest run src/twist/generator.test.ts`, commit as `fix(api): fall back to gemini-3-flash-preview (pro-preview unavailable on gateway)` with the standard trailer, and re-run the smoke. Any OTHER failure (auth, quota, network): retry once; if it persists, STOP and report the exact error — do not burn further spend.

- [ ] **Step 3: Validate token/cost columns**

From the smoke scorecard/results JSON: `tokens.input`/`output` and `estimatedCostUsd` must be nonzero (first live validation of `extractUsage`→`sumTokens`→`estimateCostUsd` for Google metadata). If cacheRead is 0 on a first call that's expected (nothing cached yet). If input/output tokens are 0 while the run clearly hit the API, STOP and report — the google usage mapping needs investigation before the baseline is worth paying for.

- [ ] **Step 4: Full baseline**

Run: `pnpm --filter @plotday/api eval:twist-gen --label baseline-gemini --runs 2`
Expected: completes (30–60+ min; failures are data, not errors), results JSON written. Record in your report: both pass rates, mean attempts, median/p95 latency, taxonomy histogram, total cost, and the results filename.

- [ ] **Step 5: Commit (only if the contingency fired) and report**

No commit needed if Steps 2–4 ran on pro-preview. Append the smoke + baseline scorecards and the results filenames to your report file.

---

## Final verification (after all tasks)

1. `npx vitest run evals/ src/twist/generator.test.ts` — green.
2. `pnpm --filter @plotday/api lint` — clean.
3. `evals/results/` contains the smoke and baseline JSONs (gitignored, not staged).
4. `git log --oneline` on `twist-gen-gemini` shows the spec commit + 2 (or 3 with contingency) implementation commits.

---

### Task 4 (addendum): Gemini-compatible generation schema + eval gateway cache bypass

Added after live baselines showed 0/24 on both Gemini tiers — Gemini's
structured-output schema cannot express `z.record`, so `files` comes back
empty. See the spec's Addendum section.

**Files:**
- Modify: `workers/api/src/twist/generator.ts`
- Modify: `workers/api/evals/run.ts` (one line in `runSpec`)
- Test: `workers/api/src/twist/generator.test.ts`

**Interfaces:**
- Consumes: existing `TwistSource` type (unchanged), `GenerateTwistOptions`.
- Produces: `GenerateTwistOptions.skipGatewayCache?: boolean` (harness sets it); `TwistSource` return shape unchanged for all downstream consumers.

- [ ] **Step 1: Update tests first**

In `workers/api/src/twist/generator.test.ts`:

a) Add a generated-shape fixture after `validSource` and change the `beforeEach` default mock to use it:

```ts
// What the MODEL now returns (array-shaped, Gemini-compatible); generateTwist
// maps it back into the Record-shaped TwistSource (`validSource` above).
const validGenerated = {
  displayName: "Sample Twist",
  dependencies: [] as Array<{ name: string; version: string }>,
  files: [
    { path: "index.ts", content: "export default class SampleTwist {}" },
  ],
};
```

In `beforeEach`, change `generateObjectMock.mockResolvedValue({ object: { ...validSource } });` to `generateObjectMock.mockResolvedValue({ object: { ...validGenerated } });`

b) Any test that calls `generateObjectMock.mockResolvedValue` with an inline object (the usage-passthrough test and the google-metadata test) must switch its `object:` payload from `{ ...validSource }` to `{ ...validGenerated }`. Assertions on the RETURNED source (`result.files["index.ts"]` etc.) stay unchanged — the mapping must make them pass.

c) Append two new describes at the end of the file:

```ts
describe("generated-shape mapping", () => {
  it("maps files and dependencies arrays into TwistSource records", async () => {
    generateObjectMock.mockResolvedValue({
      object: {
        displayName: "Mapper",
        files: [
          { path: "index.ts", content: "export default class M {}" },
          { path: "lib/util.ts", content: "export const x = 1;" },
        ],
        dependencies: [{ name: "zod", version: "^4.0.0" }],
      },
    });
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const source = await generateTwist({ spec: "hello", env: makeEnv() });
    expect(source.files["index.ts"]).toContain("class M");
    expect(source.files["lib/util.ts"]).toBe("export const x = 1;");
    expect(source.dependencies).toEqual({
      zod: "^4.0.0",
      "@plotday/twister": "latest",
    });
  });

  it("still rejects when no files entry has path index.ts", async () => {
    generateObjectMock.mockResolvedValue({
      object: {
        displayName: "NoEntry",
        files: [{ path: "main.ts", content: "export {}" }],
        dependencies: [],
      },
    });
    await expect(
      generateTwist({ spec: "hello", env: makeEnv() })
    ).rejects.toThrow(/missing required 'index.ts'/);
  });
});

describe("gateway cache bypass", () => {
  it("adds cf-aig-skip-cache when skipGatewayCache is set", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv(), skipGatewayCache: true });
    const opts = createGoogleMock.mock.calls[0][0] as {
      headers: Record<string, string>;
    };
    expect(opts.headers["cf-aig-skip-cache"]).toBe("true");
  });

  it("omits cf-aig-skip-cache by default", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv() });
    const opts = createGoogleMock.mock.calls[0][0] as {
      headers: Record<string, string>;
    };
    expect(opts.headers["cf-aig-skip-cache"]).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run to verify failures**

Run from `workers/api`: `npx vitest run src/twist/generator.test.ts`
Expected: mapping/bypass tests FAIL (skipGatewayCache not an option; source not mapped); tests whose default mock now returns the array shape FAIL until the implementation maps it.

- [ ] **Step 3: Implement in generator.ts**

a) REPLACE the `twistSourceSchema` declaration with:

```ts
/**
 * Model-facing schema. Gemini's structured-output schema (an OpenAPI subset)
 * cannot express dynamic-key objects (z.record) — models return empty
 * objects for such fields — so files and dependencies are arrays of named
 * entries here and are mapped back to the Record-shaped TwistSource
 * immediately after generation. Claude handles the array shape equally well.
 */
const generatedTwistSchema = z.object({
  displayName: z.string(),
  files: z.array(
    z.object({
      path: z.string(),
      content: z.string(),
    })
  ),
  dependencies: z.array(
    z.object({
      name: z.string(),
      version: z.string(),
    })
  ),
});

function toTwistSource(
  generated: z.infer<typeof generatedTwistSchema>
): TwistSource {
  const files: Record<string, string> = {};
  for (const file of generated.files) {
    files[file.path] = file.content; // duplicate paths: last entry wins
  }
  const dependencies: Record<string, string> = {};
  for (const dep of generated.dependencies) {
    dependencies[dep.name] = dep.version;
  }
  return { displayName: generated.displayName, files, dependencies };
}
```

b) `GenerateTwistOptions` gains (after `onEvent`):

```ts
  // Bypass AI Gateway response caching (cf-aig-skip-cache) so repeat runs
  // measure real generations. Set by the eval harness; default false —
  // production keeps gateway caching.
  skipGatewayCache?: boolean;
```

Thread `skipGatewayCache` through `generateTwist` → `generateTwistInner` (destructure + inner param type), like `model`/`onEvent`.

c) `resolveGenerationModel` gains a third parameter and shared headers:

```ts
function resolveGenerationModel(
  env: Bindings,
  modelId: string,
  skipCache: boolean
): LanguageModel {
  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const headers: Record<string, string> = {
    "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}`,
    ...(skipCache ? { "cf-aig-skip-cache": "true" } : {}),
  };
  // ...both provider branches pass `headers` instead of their inline object
}
```

Call site becomes `const model = resolveGenerationModel(env, modelId, skipGatewayCache ?? false);`

d) At the `generateObject` call: `schema: generatedTwistSchema` (schemaName stays `"TwistSource"`); `schemaDescription: "Twist source code: a files array (each entry has a path like \"index.ts\" and the full file content) plus an npm dependencies array (name + version)."`

e) Replace `const source: TwistSource = result.object;` with `const source: TwistSource = toTwistSource(result.object);` (the comment above it should now say the mapping normalizes the array shape; zod already validated it).

f) In the first-attempt `userPrompt` requirements list, change `- "files" must include "index.ts" as the entry point` to `- "files" must include an entry whose path is "index.ts" — the entry point`.

g) Known accepted gap (do NOT change): the retry prompt embeds `previousSource` in Record shape while the model must answer in array shape — the schema drives the output shape, and the retry loop is a separate planned PR.

- [ ] **Step 4: Wire the harness**

In `workers/api/evals/run.ts`, in `runSpec`'s `generateTwist(...)` call, add `skipGatewayCache: true,` alongside `model`/`onEvent`.

- [ ] **Step 5: Verify**

Run: `npx vitest run src/twist/generator.test.ts evals/` — ALL pass.
Run: `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/twist/generator.ts workers/api/src/twist/generator.test.ts workers/api/evals/run.ts
git commit -m "fix(api): array-shaped generation schema for Gemini structured output + eval gateway cache bypass

Gemini's structured-output schema (an OpenAPI subset) cannot express
z.record dynamic-key maps — both Gemini tiers returned an empty files
object on every corpus spec (0/24). The model-facing schema now uses
files/dependencies entry arrays, mapped back to the Record-shaped
TwistSource right after generation; downstream consumers are unchanged.
Also adds GenerateTwistOptions.skipGatewayCache (cf-aig-skip-cache) so the
eval harness's repeat runs stop being served cached gateway responses.

Co-Authored-By: Claude <noreply@anthropic.com>"
```
