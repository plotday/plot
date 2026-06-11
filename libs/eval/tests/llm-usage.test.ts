import { describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { cachedLlmClient, hashInputs } from "../src/classifiers/llm-cache";
import { DEFAULTS_LLM, makeHybridLlmClassifier } from "@plotday/classifier";
import type {
  Candidate,
  ClassifierContext,
  LLMClient,
  LLMInputs,
  LLMOutput,
  SandboxDb,
} from "@plotday/classifier";

const baseInputs: LLMInputs = {
  system: "sys",
  user: "user",
  allowedPriorityIds: ["P1", "P2"],
};

describe("cachedLlmClient usage plumbing", () => {
  it("stores usage in the cache file and replays it with fromCache: true", async () => {
    const dir = await mkdtemp(join(tmpdir(), "llm-usage-"));
    let calls = 0;
    const inner: LLMClient = {
      id: "stub",
      async classify(): Promise<LLMOutput> {
        calls++;
        return {
          priorityId: "P1",
          rationale: "r",
          usage: { inputTokens: 100, outputTokens: 5 },
        };
      },
    };
    const wrapped = cachedLlmClient({
      client: inner,
      cacheDir: dir,
      namespace: "test",
      promptTemplateId: "tiebreaker-v1",
    });

    const first = await wrapped.classify(baseInputs);
    expect(first.usage).toEqual({ inputTokens: 100, outputTokens: 5 });
    expect(first.fromCache).toBeFalsy();

    const hash = hashInputs("stub", "tiebreaker-v1", baseInputs);
    const text = await readFile(join(dir, "test", `${hash}.json`), "utf-8");
    expect(JSON.parse(text).response.usage).toEqual({
      inputTokens: 100,
      outputTokens: 5,
    });

    const second = await wrapped.classify(baseInputs);
    expect(calls).toBe(1);
    expect(second.fromCache).toBe(true);
    expect(second.usage).toEqual({ inputTokens: 100, outputTokens: 5 });
    expect(second.priorityId).toBe("P1");
  });
});

/**
 * Fake ClassifierContext that drives the cascade down the topic-ambiguity
 * path with exactly one LLM call:
 *   - topicTrainingSummary (the only query matching `mt.topic = $2`) returns
 *     a single priority with n=1, tripping the single-sample-fragility
 *     ambiguity rule;
 *   - every other query (scoring neighbors, hierarchies, linked contacts,
 *     user_subscription, ...) returns no rows.
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
    corpusName: "llm-usage-test",
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

function usageClient(extra: Partial<LLMOutput>): LLMClient {
  return {
    id: "fake-usage",
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      return {
        priorityId: inputs.allowedPriorityIds[0] ?? null,
        rationale: "fake",
        ...extra,
      };
    },
  };
}

describe("hybrid LLM cascade usage aggregation", () => {
  it("aggregates live usage from a single LLM call", async () => {
    const classifier = makeHybridLlmClassifier("test:usage:live", {
      params: DEFAULTS_LLM,
      llmClientFor: () =>
        usageClient({ usage: { inputTokens: 100, outputTokens: 5 } }),
    });
    const result = await classifier.classify(fakeCtx(), candidate);
    expect(result.stage).toBe("llm_topic_ambiguity");
    expect(result.llmCalls).toBe(1);
    expect(result.llmUsage).toEqual({
      liveInputTokens: 100,
      liveOutputTokens: 5,
      replayedInputTokens: 0,
      replayedOutputTokens: 0,
      unknownCalls: 0,
    });
  });

  it("counts a call with no usage as unknown", async () => {
    const classifier = makeHybridLlmClassifier("test:usage:unknown", {
      params: DEFAULTS_LLM,
      llmClientFor: () => usageClient({}),
    });
    const result = await classifier.classify(fakeCtx(), candidate);
    expect(result.stage).toBe("llm_topic_ambiguity");
    expect(result.llmUsage).toEqual({
      liveInputTokens: 0,
      liveOutputTokens: 0,
      replayedInputTokens: 0,
      replayedOutputTokens: 0,
      unknownCalls: 1,
    });
  });

  it("lands fromCache usage in the replayed buckets", async () => {
    const classifier = makeHybridLlmClassifier("test:usage:replayed", {
      params: DEFAULTS_LLM,
      llmClientFor: () =>
        usageClient({
          usage: { inputTokens: 100, outputTokens: 5 },
          fromCache: true,
        }),
    });
    const result = await classifier.classify(fakeCtx(), candidate);
    expect(result.stage).toBe("llm_topic_ambiguity");
    expect(result.llmUsage).toEqual({
      liveInputTokens: 0,
      liveOutputTokens: 0,
      replayedInputTokens: 100,
      replayedOutputTokens: 5,
      unknownCalls: 0,
    });
    expect(result.cacheHits).toBe(1);
    expect(result.llmCalls).toBe(0);
  });

  it("reports zero usage when no LLM call fires", async () => {
    let llmCalls = 0;
    const classifier = makeHybridLlmClassifier("test:usage:zeros", {
      params: DEFAULTS_LLM,
      llmClientFor: () => ({
        id: "never",
        async classify(): Promise<LLMOutput> {
          llmCalls++;
          return { priorityId: null, rationale: "never" };
        },
      }),
    });
    // priority_prefix fires deterministically before any LLM stage.
    const ctx: ClassifierContext = {
      ...fakeCtx(),
      rawQuery: async (text: string) => {
        if (text.includes("AND key = $2")) {
          return { rows: [{ id: "P9" }] };
        }
        return { rows: [] };
      },
    };
    const result = await classifier.classify(ctx, {
      ...candidate,
      topic: "priority:work",
    });
    expect(result.stage).toBe("priority_prefix");
    expect(llmCalls).toBe(0);
    expect(result.llmUsage).toEqual({
      liveInputTokens: 0,
      liveOutputTokens: 0,
      replayedInputTokens: 0,
      replayedOutputTokens: 0,
      unknownCalls: 0,
    });
  });
});
