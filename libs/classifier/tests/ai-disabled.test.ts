import { describe, expect, it } from "vitest";

import {
  DEFAULTS_LLM,
  makeHybridLlmClassifier,
  type Candidate,
  type ClassifierContext,
  type LLMClient,
} from "../src";

// Three priorities so cold-start's `priorities.length < 3` guard passes and the
// cascade actually reaches an LLM stage. Every other stage query returns empty,
// so all the deterministic stages decline and the only thing that *can* fire is
// the cold-start LLM call — the perfect probe for "did we touch the LLM?".
const PRIORITIES = [
  { id: "p1", title: "Alpha", path: "alpha", description: null, key: null, depth: 1 },
  { id: "p2", title: "Beta", path: "beta", description: null, key: null, depth: 1 },
  { id: "p3", title: "Gamma", path: "gamma", description: null, key: null, depth: 1 },
];

function fakeCtx(aiDisabled: boolean): ClassifierContext {
  return {
    db: {} as never,
    userId: "00000000-0000-0000-0000-000000000001",
    schemaName: "public",
    corpusName: "test",
    aiDisabled,
    async rawQuery(text: string) {
      // Only the cold-start priority-tree query (ordered by nlevel) returns
      // rows; every other stage query is empty so it declines and the cascade
      // falls through to the cold-start LLM gate.
      if (text.includes("FROM public.priority") && text.includes("nlevel(path)")) {
        return { rows: PRIORITIES };
      }
      return { rows: [] };
    },
  };
}

const candidate: Candidate = {
  threadId: "",
  title: "totally novel subject with no training history",
  topic: null,
  contacts: [],
  groups: [],
  embedding: null,
  author: null,
  facets: null,
  authorContactId: null,
  connectionId: null,
};

function spyLlm(): { client: LLMClient; calls: unknown[] } {
  const calls: unknown[] = [];
  const client: LLMClient = {
    id: "stub:always-first",
    async classify(inputs) {
      calls.push(inputs);
      return { priorityId: inputs.allowedPriorityIds[0] ?? null, rationale: "stub" };
    },
  };
  return { client, calls };
}

describe("makeHybridLlmClassifier — built-in AI opt-out (ctx.aiDisabled)", () => {
  it("makes zero LLM calls and degrades to a deterministic stage when AI is disabled", async () => {
    const { client, calls } = spyLlm();
    const classifier = makeHybridLlmClassifier("test:ai-disabled", {
      params: DEFAULTS_LLM,
      llmClientFor: () => client,
    });

    const result = await classifier.classify(fakeCtx(true), candidate);

    expect(calls).toHaveLength(0);
    expect(result.llmCalls).toBe(0);
    // budgetExhausted is reused as the "an LLM stage wanted to fire but
    // couldn't" signal — surfaced for observability, same as a real budget cap.
    expect(result.budgetExhausted).toBe(true);
    expect(result.stage.startsWith("llm_")).toBe(false);
  });

  it("control: reaches the cold-start LLM when AI is enabled", async () => {
    const { client, calls } = spyLlm();
    const classifier = makeHybridLlmClassifier("test:ai-enabled", {
      params: DEFAULTS_LLM,
      llmClientFor: () => client,
    });

    const result = await classifier.classify(fakeCtx(false), candidate);

    expect(calls).toHaveLength(1);
    expect(result.llmCalls).toBe(1);
    expect(result.stage).toBe("llm_coldstart");
  });
});
