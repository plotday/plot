import { describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULTS, DEFAULTS_LLM, makeHybridLlmClassifier } from "@plotday/classifier";
import type {
  Candidate,
  ClassifierContext,
  HybridParams,
  LLMClient,
  LLMInputs,
  LLMOutput,
  SandboxDb,
} from "@plotday/classifier";

import {
  evalUnlimitedBudget,
  getClassifier,
  makeAdhocLlmVariant,
  makeAdhocVariantFromFile,
} from "../src/classifiers/registry";
import { deepMergeParams } from "../src/runner/sweep";
import { estimateCostUsd, MODEL_COSTS } from "../src/scoring/cost";

/**
 * Fake ClassifierContext that drives the LLM cascade down the
 * topic-ambiguity path with exactly one LLM call per classify (same shape
 * as llm-usage.test.ts): topicTrainingSummary returns a single priority
 * with n=1 (single-sample fragility ⇒ ambiguous); every other query
 * (scoring, subscriptions, ...) returns no rows.
 */
function fakeCtx(): ClassifierContext {
  return {
    db: {} as unknown as SandboxDb,
    rawQuery: async (text: string) => {
      if (text.includes("mt.topic = $2")) {
        return {
          rows: [
            { priority_id: "P1", n: 1, overlap: false, titles: ["Old thread"] },
          ],
        };
      }
      return { rows: [] };
    },
    userId: randomUUID(),
    schemaName: "eval_test",
    corpusName: "adhoc-variants-test",
  };
}

/** Context where every query returns no rows (deterministic cascade → none). */
function emptyCtx(): ClassifierContext {
  return {
    db: {} as unknown as SandboxDb,
    rawQuery: async () => ({ rows: [] }),
    userId: randomUUID(),
    schemaName: "eval_test",
    corpusName: "adhoc-variants-test",
  };
}

const candidate: Candidate = {
  threadId: "",
  title: "Quarterly planning notes",
  topic: "shared:topic",
  contacts: [],
  groups: [],
  embedding: null,
  author: null,
  facets: null,
  authorContactId: null,
  connectionId: null,
};

function countingClient(): LLMClient & { calls: () => number } {
  let calls = 0;
  return {
    id: "stub",
    calls: () => calls,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      calls++;
      return {
        priorityId: inputs.allowedPriorityIds[0] ?? null,
        rationale: "stub",
      };
    },
  };
}

/** DEFAULTS_LLM with a budget so tiny the second call already exhausts it. */
function tinyBudgetParams(): HybridParams {
  return deepMergeParams(DEFAULTS_LLM, {
    llm: {
      budgetFree: { monthlyMax: 1, dailyMax: 1 },
      budgetPaid: { monthlyMax: 1, dailyMax: 1 },
    },
  });
}

describe("deepMergeParams", () => {
  it("merges nested objects, preserving sibling fields, without mutating base", () => {
    const merged = deepMergeParams(DEFAULTS_LLM, { originBonus: { exact: 0 } });
    expect(merged.originBonus).toEqual({ exact: 0, org: 0.09 });
    // Untouched fields survive.
    expect(merged.weights).toEqual(DEFAULTS_LLM.weights);
    expect(merged.scoreThreshold).toBe(DEFAULTS_LLM.scoreThreshold);
    expect(merged.llm).toEqual(DEFAULTS_LLM.llm);
    // Base is never mutated; the result is a new object.
    expect(merged).not.toBe(DEFAULTS_LLM);
    expect(DEFAULTS_LLM.originBonus).toEqual({ exact: 0.18, org: 0.09 });
  });

  it("merges deeply nested objects (llm.tieBreaker)", () => {
    const merged = deepMergeParams(DEFAULTS_LLM, {
      llm: { tieBreaker: { maxCandidates: 2 } },
    });
    expect(merged.llm!.tieBreaker).toEqual({
      enabled: true,
      maxCandidates: 2,
      promptId: "tiebreaker-v3",
    });
    // Sibling llm fields survive the nested merge.
    expect(merged.llm!.model).toBe(DEFAULTS_LLM.llm!.model);
    expect(merged.llm!.coldStart).toEqual(DEFAULTS_LLM.llm!.coldStart);
    // Base untouched.
    expect(DEFAULTS_LLM.llm!.tieBreaker.maxCandidates).toBe(5);
  });

  it("replaces arrays and primitives instead of merging them", () => {
    const base = { ...DEFAULTS, fake: [1, 2, 3] } as unknown as HybridParams;
    const merged = deepMergeParams(base, {
      fake: [9],
      scoreThreshold: 0.5,
    }) as unknown as { fake: number[]; scoreThreshold: number };
    expect(merged.fake).toEqual([9]);
    expect(merged.scoreThreshold).toBe(0.5);
  });
});

describe("makeAdhocLlmVariant", () => {
  it("names the variant <base>+params@<8hex>, stable across calls, and registers it", () => {
    const a = makeAdhocLlmVariant({ scoreThreshold: 0.123 });
    expect(a.name).toMatch(/^ts:hybrid-llm:default\+params@[0-9a-f]{8}$/);
    const b = makeAdhocLlmVariant({ scoreThreshold: 0.123 });
    expect(b.name).toBe(a.name);
    expect(getClassifier(a.name).name).toBe(a.name);
  });

  it("produces a different name for different overrides", () => {
    const a = makeAdhocLlmVariant({ scoreThreshold: 0.123 });
    const b = makeAdhocLlmVariant({ scoreThreshold: 0.124 });
    expect(a.name).not.toBe(b.name);
  });

  it("throws via assertValidWeights when partial weight overrides break sum-to-1", () => {
    expect(() => makeAdhocLlmVariant({ weights: { sem: 0.9 } })).toThrow(
      /sum to 1/
    );
  });

  it("throws on an unknown base", () => {
    expect(() => makeAdhocLlmVariant({}, "ts:nope")).toThrow(/Unknown base/);
  });

  it("supports a deterministic base (no llm config) and classifies", async () => {
    const det = makeAdhocLlmVariant({ scoreThreshold: 0.5 }, "ts:hybrid:default");
    expect(det.name).toMatch(/^ts:hybrid:default\+params@[0-9a-f]{8}$/);
    const result = await det.classify(emptyCtx(), candidate);
    expect(result.stage).toBe("none");
    expect(result.priorityId).toBeNull();
    expect(result.llmCalls).toBe(0);
  });

  it("supports a previously registered ad-hoc variant as base", () => {
    const a = makeAdhocLlmVariant({ scoreThreshold: 0.321 });
    const chained = makeAdhocLlmVariant({ marginFloor: 0.11 }, a.name);
    expect(chained.name).toMatch(
      /^ts:hybrid-llm:default\+params@[0-9a-f]{8}\+params@[0-9a-f]{8}$/
    );
    expect(getClassifier(chained.name).name).toBe(chained.name);
  });
});

describe("eval budget neutralization", () => {
  it("evalUnlimitedBudget keeps LLM stages firing past tiny budget limits", async () => {
    const stub = countingClient();
    const classifier = makeHybridLlmClassifier("test:budget:unlimited", {
      params: tinyBudgetParams(),
      llmClientFor: () => stub,
      // The exact override the registry injects into every eval LLM variant.
      consumeBudget: evalUnlimitedBudget,
    });
    const ctx = fakeCtx(); // one userId across all three classifications
    for (let i = 0; i < 3; i++) {
      const result = await classifier.classify(ctx, candidate);
      expect(result.budgetExhausted).toBe(false);
      expect(result.llmCalls).toBe(1);
      expect(result.stage).toBe("llm_topic_ambiguity");
    }
    expect(stub.calls()).toBe(3);
  });

  it("control: without the override the default budget exhausts mid-run", async () => {
    const stub = countingClient();
    const classifier = makeHybridLlmClassifier("test:budget:default", {
      params: tinyBudgetParams(),
      llmClientFor: () => stub,
      // No consumeBudget override: the in-process per-user counter applies.
    });
    const ctx = fakeCtx();
    const r1 = await classifier.classify(ctx, candidate);
    expect(r1.budgetExhausted).toBe(false);
    expect(r1.llmCalls).toBe(1);
    const r2 = await classifier.classify(ctx, candidate);
    expect(r2.budgetExhausted).toBe(true);
    const r3 = await classifier.classify(ctx, candidate);
    expect(r3.budgetExhausted).toBe(true);
    expect(r3.llmCalls).toBe(0);
    // Only the first classification reached the LLM.
    expect(stub.calls()).toBe(1);
  });
});

describe("estimateCostUsd", () => {
  it("prices a known model: 1M in + 1M out on gemini-3-flash-preview = $2.80", () => {
    expect(
      estimateCostUsd("gemini-3-flash-preview", {
        inputTokens: 1_000_000,
        outputTokens: 1_000_000,
      })
    ).toBeCloseTo(2.8, 10);
  });

  it("scales linearly with token counts", () => {
    expect(
      estimateCostUsd("gemini-3.1-flash-lite", {
        inputTokens: 500_000,
        outputTokens: 200_000,
      })
    ).toBeCloseTo(0.05 + 0.08, 10);
  });

  it("returns null for an unknown model", () => {
    expect(
      estimateCostUsd("gpt-unknown", { inputTokens: 1000, outputTokens: 10 })
    ).toBeNull();
    expect(MODEL_COSTS["gpt-unknown"]).toBeUndefined();
  });
});

describe("makeAdhocVariantFromFile (--params plumbing)", () => {
  it("reads overrides from a JSON file and registers the variant", async () => {
    const dir = await mkdtemp(join(tmpdir(), "adhoc-params-"));
    const file = join(dir, "overrides.json");
    await writeFile(file, JSON.stringify({ scoreThreshold: 0.2 }), "utf-8");
    const variant = makeAdhocVariantFromFile(file, "ts:hybrid:default");
    expect(variant.name).toMatch(/^ts:hybrid:default\+params@[0-9a-f]{8}$/);
    expect(getClassifier(variant.name).name).toBe(variant.name);
  });

  it("defaults the base to ts:hybrid-llm:default", async () => {
    const dir = await mkdtemp(join(tmpdir(), "adhoc-params-"));
    const file = join(dir, "overrides.json");
    await writeFile(file, JSON.stringify({ marginFloor: 0.19 }), "utf-8");
    const variant = makeAdhocVariantFromFile(file);
    expect(variant.name).toMatch(/^ts:hybrid-llm:default\+params@[0-9a-f]{8}$/);
  });

  it("rejects a params file that is not a JSON object", async () => {
    const dir = await mkdtemp(join(tmpdir(), "adhoc-params-"));
    const file = join(dir, "overrides.json");
    await writeFile(file, JSON.stringify([1, 2, 3]), "utf-8");
    expect(() => makeAdhocVariantFromFile(file)).toThrow(/JSON object/);
  });
});
