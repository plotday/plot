import { describe, expect, it } from "vitest";

import { shouldRunTieBreaker , DEFAULTS_LLM } from "@plotday/classifier";
import type { LLMClient, LLMInputs } from "@plotday/classifier";

const baseScoring = {
  matched: true as const,
  priorityId: "P1",
  explain: {
    perPrioritySorted: [
      { priorityId: "P1", score: 0.3, neighborCount: 2, neighborScore: 0.3, titleMatch: 0, accountHierarchyAffinity: 0 },
      { priorityId: "P2", score: 0.25, neighborCount: 1, neighborScore: 0.25, titleMatch: 0, accountHierarchyAffinity: 0 },
    ],
    topNeighbors: [
      {
        priorityId: "P1",
        threadId: "T1",
        sem: 0.3,
        con: 0,
        grp: 0,
        author: 0,
        topic_fuzzy: 0,
        title: 0,
        combined: 0.3,
      },
      {
        priorityId: "P1",
        threadId: "T2",
        sem: 0.3,
        con: 0,
        grp: 0,
        author: 0,
        topic_fuzzy: 0,
        title: 0,
        combined: 0.3,
      },
    ],
  },
  top1: 0.3,
  top2: 0.25,
};

describe("shouldRunTieBreaker gates", () => {
  it("fires in the soft band with a close call", () => {
    expect(shouldRunTieBreaker(baseScoring, DEFAULTS_LLM, 2)).toBe(true);
  });

  it("does NOT fire above highConfidenceFloor with enough supporting neighbors", () => {
    // Use a top1 above the (now-widened) highConfidenceFloor=0.6 default
    // and a wide margin so neither soft-band nor close-call trips.
    const high = { ...baseScoring, top1: 0.8, top2: 0.4 };
    expect(shouldRunTieBreaker(high, DEFAULTS_LLM, 2)).toBe(false);
  });

  it("fires whenever supporting neighbors below threshold (third gate)", () => {
    const confident = { ...baseScoring, top1: 0.7, top2: 0.1 };
    expect(shouldRunTieBreaker(confident, DEFAULTS_LLM, 0)).toBe(true);
  });

  it("does NOT fire on a wide margin even in the soft band", () => {
    const wide = { ...baseScoring, top1: 0.3, top2: 0.05 };
    expect(shouldRunTieBreaker(wide, DEFAULTS_LLM, 2)).toBe(false);
  });
});

describe("LLM stub client interface", () => {
  it("can be wired without making network calls", async () => {
    const calls: LLMInputs[] = [];
    const stub: LLMClient = {
      id: "stub",
      async classify(inputs) {
        calls.push(inputs);
        return {
          priorityId: inputs.allowedPriorityIds[0] ?? null,
          rationale: "stub",
        };
      },
    };
    const out = await stub.classify({
      system: "sys",
      user: "u",
      allowedPriorityIds: ["P1", "P2"],
    });
    expect(out.priorityId).toBe("P1");
    expect(calls).toHaveLength(1);
  });
});
