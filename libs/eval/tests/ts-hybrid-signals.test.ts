import { describe, expect, it } from "vitest";

import {
  applyNonlinearity,
  author as authorSignal,
  combineSignals,
  con,
  grp,
  jaccard,
  priorityTitleMatch,
  sem,
  titleTrigramJaccard,
  tokenize,
  topicFuzzy,
} from "@plotday/classifier";

describe("ts-hybrid signals: sem", () => {
  it("returns 0 when either embedding is null", () => {
    expect(sem(null, [0.1, 0.2])).toBe(0);
    expect(sem([0.1, 0.2], null)).toBe(0);
  });

  it("returns 0 when cosine similarity is below the 0.5 floor", () => {
    const a = [1, 0, 0];
    const b = [0, 1, 0];
    expect(sem(a, b)).toBe(0);
  });

  it("scales (cos - 0.5) * 2 to [0, 1]", () => {
    const a = [1, 0, 0];
    expect(sem(a, a)).toBeCloseTo(1, 6);
  });
});

describe("ts-hybrid signals: con / grp / jaccard", () => {
  it("jaccard handles empty sets as 0", () => {
    expect(jaccard([], [])).toBe(0);
    expect(jaccard(["a"], [])).toBe(0);
    expect(jaccard([], ["a"])).toBe(0);
  });

  it("jaccard computes intersection / union for non-empty sets", () => {
    expect(jaccard(["a", "b"], ["a", "c"])).toBeCloseTo(1 / 3, 6);
    expect(jaccard(["a", "b"], ["a", "b"])).toBe(1);
  });

  it("con and grp are thin wrappers around jaccard", () => {
    expect(con(["c1", "c2"], ["c1"])).toBeCloseTo(1 / 2, 6);
    expect(grp(["g1"], ["g2"])).toBe(0);
  });
});

describe("ts-hybrid signals: author", () => {
  it("returns 1 when both sides have the same author", () => {
    expect(authorSignal("u1", "u1")).toBe(1);
  });
  it("returns 0 when either side is null", () => {
    expect(authorSignal(null, "u1")).toBe(0);
    expect(authorSignal("u1", null)).toBe(0);
  });
  it("returns 0 when authors differ", () => {
    expect(authorSignal("u1", "u2")).toBe(0);
  });
});

describe("ts-hybrid signals: topicFuzzy", () => {
  it("returns 1 for exact match", () => {
    expect(topicFuzzy("channel:1", "channel:1", 0.6)).toBe(1);
  });
  it("returns prefix weight for shared leading colon-segment", () => {
    expect(topicFuzzy("channel:1", "channel:2", 0.6)).toBeCloseTo(0.6, 6);
  });
  it("returns 0 when leading segments differ", () => {
    expect(topicFuzzy("slack:foo", "gmail:bar", 0.6)).toBe(0);
  });
  it("returns 0 when either side is null", () => {
    expect(topicFuzzy(null, "channel:1", 0.6)).toBe(0);
    expect(topicFuzzy("channel:1", null, 0.6)).toBe(0);
  });
  it("returns 0 for non-colon topics that differ; 1 when identical", () => {
    expect(topicFuzzy("foo", "bar", 0.6)).toBe(0);
    expect(topicFuzzy("foo", "foo", 0.6)).toBe(1);
  });
});

describe("ts-hybrid signals: titleTrigramJaccard", () => {
  it("returns 1 for identical titles", () => {
    expect(titleTrigramJaccard("hello world", "hello world")).toBe(1);
  });
  it("returns 0 for disjoint short titles", () => {
    expect(titleTrigramJaccard("abc", "xyz")).toBe(0);
  });
  it("is case-insensitive", () => {
    expect(titleTrigramJaccard("Hello", "hello")).toBe(1);
  });
  it("returns 0 when either is empty or too short for any trigram", () => {
    expect(titleTrigramJaccard("", "abc")).toBe(0);
    expect(titleTrigramJaccard("ab", "ab")).toBe(0);
  });
  it("partial overlap is between 0 and 1", () => {
    const v = titleTrigramJaccard("hello world", "world hello");
    expect(v).toBeGreaterThan(0);
    expect(v).toBeLessThan(1);
  });
});

describe("applyNonlinearity", () => {
  it("identity passes through", () => {
    expect(applyNonlinearity(0.5, "identity")).toBe(0.5);
  });
  it("square squares", () => {
    expect(applyNonlinearity(0.5, "square")).toBeCloseTo(0.25, 6);
  });
  it("sigmoid maps to (0, 1)", () => {
    expect(applyNonlinearity(0, "sigmoid")).toBeCloseTo(0.5, 6);
    const high = applyNonlinearity(1, "sigmoid");
    expect(high).toBeGreaterThan(0.5);
    expect(high).toBeLessThan(1);
  });
});

describe("tokenize", () => {
  it("lowercases and splits on non-alphanumerics", () => {
    expect(tokenize("Hello, World! 42-times")).toEqual(
      new Set(["hello", "world", "times"])
    );
  });
  it("drops tokens shorter than 3 chars", () => {
    expect(tokenize("a be cat")).toEqual(new Set(["cat"]));
  });
  it("drops common stopwords", () => {
    expect(tokenize("the and for cats")).toEqual(new Set(["cats"]));
  });
});

describe("priorityTitleMatch", () => {
  it("returns 1 when tokens match exactly (modulo stopwords)", () => {
    expect(priorityTitleMatch("Governance Committee", "Governance Committee")).toBe(
      1
    );
  });
  it("returns 0 when no tokens overlap", () => {
    expect(priorityTitleMatch("Doug Ford budget", "Onboarding")).toBe(0);
  });
  it("returns partial Jaccard for partial overlap", () => {
    // "execution focused leader discovery questions" ∩ "execution focus leader discovery"
    // = {execution, leader, discovery}; union = {execution, focused, focus, leader, discovery, questions} = 6
    expect(
      priorityTitleMatch(
        "Execution-focused leader discovery questions",
        "Execution-focus Leader Discovery"
      )
    ).toBeCloseTo(3 / 6, 6);
  });
});

describe("combineSignals", () => {
  const weights = {
    sem: 0.4,
    con: 0.25,
    grp: 0.1,
    author: 0.1,
    topic_fuzzy: 0.1,
    title: 0.05,
  };

  it("returns weighted sum with identity nonlinearity", () => {
    const v = combineSignals(
      { sem: 1, con: 1, grp: 1, author: 1, topic_fuzzy: 1, title: 1 },
      weights,
      "identity"
    );
    expect(v).toBeCloseTo(1, 6);
  });

  it("applies the nonlinearity per signal", () => {
    const v = combineSignals(
      { sem: 0.5, con: 0.5, grp: 0.5, author: 0.5, topic_fuzzy: 0.5, title: 0.5 },
      weights,
      "square"
    );
    expect(v).toBeCloseTo(0.25, 6);
  });
});
