import { describe, expect, it } from "vitest";

import type { ScoringOutcome } from "../src/ts-hybrid-scoring";
import type { TopicTrainingSummary } from "../src/ts-hybrid-stages";
import {
  isTopicAmbiguous,
  pickTopicOutcome,
  scoringContradictsTopic,
} from "../src/ts-hybrid-topic-llm";

function summary(
  perPriority: { priorityId: string; n: number; overlap?: boolean }[]
): TopicTrainingSummary {
  return {
    topPriorityId: perPriority[0]!.priorityId,
    perPriority: perPriority.map((p) => ({
      priorityId: p.priorityId,
      n: p.n,
      overlapsCandidateContacts: p.overlap ?? false,
      exemplarTitles: [],
    })),
    anyContactOverlap: perPriority.some((p) => p.overlap),
  };
}

const emptyExplain = { perPrioritySorted: [], topNeighbors: [] };

function matched(priorityId: string, top1 = 0.3): ScoringOutcome {
  return { matched: true, priorityId, explain: emptyExplain, top1, top2: 0.05 };
}

const unmatched: ScoringOutcome = {
  matched: false,
  explain: emptyExplain,
  top1: 0.01,
  top2: null,
};

describe("isTopicAmbiguous", () => {
  it("flags a topic shared across many priorities (the Cycling bug)", () => {
    // The production bug: 9 priorities share one coarse topic, Cycling the
    // bare plurality at n=3. Must be treated as ambiguous.
    const s = summary([
      { priorityId: "cycling", n: 3 },
      { priorityId: "finances", n: 2 },
      { priorityId: "retreat", n: 2 },
      { priorityId: "home", n: 1 },
    ]);
    expect(isTopicAmbiguous(s, [], false)).toBe(true);
  });

  it("treats a single-priority, well-supported, contact-overlapping topic as unambiguous", () => {
    const s = summary([{ priorityId: "p1", n: 3, overlap: true }]);
    expect(isTopicAmbiguous(s, ["c1"], false)).toBe(false);
  });

  it("flags single-sample fragility", () => {
    const s = summary([{ priorityId: "p1", n: 1, overlap: true }]);
    expect(isTopicAmbiguous(s, ["c1"], false)).toBe(true);
  });
});

describe("scoringContradictsTopic", () => {
  const s = summary([{ priorityId: "topicMode", n: 3 }]);

  it("is true when scoring confidently picks a different priority", () => {
    expect(scoringContradictsTopic(s, matched("other", 0.2), 0.08)).toBe(true);
  });

  it("is false when scoring agrees with the topic mode", () => {
    expect(scoringContradictsTopic(s, matched("topicMode", 0.2), 0.08)).toBe(
      false
    );
  });

  it("is false when scoring is below the confidence bar", () => {
    expect(scoringContradictsTopic(s, matched("other", 0.1), 0.08)).toBe(false);
    expect(scoringContradictsTopic(s, unmatched, 0.08)).toBe(false);
  });
});

describe("pickTopicOutcome", () => {
  const s = summary([
    { priorityId: "cycling", n: 3 },
    { priorityId: "finances", n: 2 },
  ]);

  it("short-circuits to the mode for an unambiguous topic", () => {
    const single = summary([{ priorityId: "p1", n: 3, overlap: true }]);
    expect(pickTopicOutcome(single, unmatched, false, null)).toEqual({
      priorityId: "p1",
      stage: "topic_shortcircuit",
    });
  });

  it("uses the LLM pick when an ambiguous topic was resolved", () => {
    expect(pickTopicOutcome(s, matched("other"), true, "llmPick")).toEqual({
      priorityId: "llmPick",
      stage: "llm_topic_ambiguity",
    });
  });

  it("defers to scoring (NOT the mode) when ambiguous and the LLM did not resolve", () => {
    // The fix: budget-exhausted / declined LLM on an ambiguous topic must
    // use the per-thread scoring signal, not the bare plurality (Cycling).
    expect(pickTopicOutcome(s, matched("scored"), true, null)).toEqual({
      priorityId: "scored",
      stage: "scoring",
    });
  });

  it("falls through (null) when ambiguous, no LLM, and scoring is weak", () => {
    expect(pickTopicOutcome(s, unmatched, true, null)).toBeNull();
  });
});
