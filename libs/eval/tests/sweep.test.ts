import { describe, expect, it } from "vitest";

import { DEFAULTS_LLM, type HybridParams } from "@plotday/classifier";

import { parseSweepSpec } from "../src/runner/sweep";
import type { RunResult } from "../src/runner/run";
import {
  buildLeaderboard,
  renderLeaderboard,
} from "../src/scoring/report";

describe("parseSweepSpec — ranges", () => {
  it("expands an inclusive numeric range", () => {
    const points = parseSweepSpec("originBonus.exact=0:0.2:0.1", DEFAULTS_LLM);
    expect(points).toHaveLength(3);
    expect(points.map((p) => p.label)).toEqual([
      "originBonus.exact=0",
      "originBonus.exact=0.1",
      "originBonus.exact=0.2",
    ]);
    expect(points.map((p) => p.overrides)).toEqual([
      { originBonus: { exact: 0 } },
      { originBonus: { exact: 0.1 } },
      { originBonus: { exact: 0.2 } },
    ]);
  });

  it("keeps float steps clean (no 0.30000000000000004 labels)", () => {
    const points = parseSweepSpec("originBonus.exact=0:0.3:0.05", DEFAULTS_LLM);
    expect(points).toHaveLength(7);
    const values = points.map(
      (p) => (p.overrides.originBonus as { exact: number }).exact
    );
    expect(values).toEqual([0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3]);
    expect(points[6]!.label).toBe("originBonus.exact=0.3");
    for (const p of points) {
      expect(p.label).not.toMatch(/000000/);
    }
  });

  it("a single-value range start===end yields one point", () => {
    const points = parseSweepSpec("scoreThreshold=0.1:0.1:0.05", DEFAULTS_LLM);
    expect(points).toHaveLength(1);
    expect(points[0]!.overrides).toEqual({ scoreThreshold: 0.1 });
  });
});

describe("parseSweepSpec — lists", () => {
  it("parses string lists", () => {
    const points = parseSweepSpec("aggregation.mode=top1|softmax", DEFAULTS_LLM);
    expect(points).toHaveLength(2);
    expect(points[0]!.overrides).toEqual({ aggregation: { mode: "top1" } });
    expect(points[1]!.overrides).toEqual({ aggregation: { mode: "softmax" } });
    expect(points[0]!.label).toBe("aggregation.mode=top1");
  });

  it("parses boolean lists", () => {
    const points = parseSweepSpec(
      "shortcuts.singlePriorityBypass.enabled=true|false",
      DEFAULTS_LLM
    );
    expect(points).toHaveLength(2);
    expect(points[0]!.overrides).toEqual({
      shortcuts: { singlePriorityBypass: { enabled: true } },
    });
    expect(points[1]!.overrides).toEqual({
      shortcuts: { singlePriorityBypass: { enabled: false } },
    });
  });

  it("parses numeric lists as numbers", () => {
    const points = parseSweepSpec("scoreThreshold=0.05|0.08|0.2", DEFAULTS_LLM);
    expect(points.map((p) => p.overrides.scoreThreshold)).toEqual([
      0.05, 0.08, 0.2,
    ]);
  });
});

describe("parseSweepSpec — cross product", () => {
  it("crosses dimensions, first dimension outermost", () => {
    const points = parseSweepSpec(
      "scoreThreshold=0.1|0.2;marginFloor=0|0.1",
      DEFAULTS_LLM
    );
    expect(points).toHaveLength(4);
    expect(points.map((p) => p.label)).toEqual([
      "scoreThreshold=0.1;marginFloor=0",
      "scoreThreshold=0.1;marginFloor=0.1",
      "scoreThreshold=0.2;marginFloor=0",
      "scoreThreshold=0.2;marginFloor=0.1",
    ]);
    expect(points[3]!.overrides).toEqual({
      scoreThreshold: 0.2,
      marginFloor: 0.1,
    });
  });

  it("merges two dotted paths under the same parent object", () => {
    const points = parseSweepSpec(
      "originBonus.exact=0.1;originBonus.org=0.05",
      DEFAULTS_LLM
    );
    expect(points).toHaveLength(1);
    expect(points[0]!.overrides).toEqual({
      originBonus: { exact: 0.1, org: 0.05 },
    });
  });
});

describe("parseSweepSpec — weight renormalization", () => {
  it("emits a full weights object summing to 1, others scaled proportionally", () => {
    const points = parseSweepSpec("weights.sem=0.3", DEFAULTS_LLM);
    expect(points).toHaveLength(1);
    const w = points[0]!.overrides.weights as Record<string, number>;
    expect(Object.keys(w).sort()).toEqual(
      Object.keys(DEFAULTS_LLM.weights).sort()
    );
    expect(w.sem).toBe(0.3);
    const sum = Object.values(w).reduce((s, v) => s + v, 0);
    expect(Math.abs(sum - 1)).toBeLessThan(1e-9);
    // Remaining mass (1 - 0.3) distributed proportionally from base shares:
    // scale = (1 - 0.3) / (1 - 0.4)
    const scale = 0.7 / 0.6;
    expect(w.con).toBeCloseTo(DEFAULTS_LLM.weights.con * scale, 12);
    expect(w.title).toBeCloseTo(DEFAULTS_LLM.weights.title * scale, 12);
    expect(points[0]!.label).toBe("weights.sem=0.3");
  });

  it("renormalizes every point of a weights range", () => {
    const points = parseSweepSpec("weights.sem=0.2:0.6:0.2", DEFAULTS_LLM);
    expect(points).toHaveLength(3);
    for (const p of points) {
      const w = p.overrides.weights as Record<string, number>;
      const sum = Object.values(w).reduce((s, v) => s + v, 0);
      expect(Math.abs(sum - 1)).toBeLessThan(1e-9);
    }
  });

  it("rejects two weights.* dimensions in one spec", () => {
    expect(() =>
      parseSweepSpec("weights.sem=0.3;weights.con=0.2", DEFAULTS_LLM)
    ).toThrow(/weights/);
  });

  it("rejects renormalizing when the base weight is 1 (no remaining mass)", () => {
    const base: HybridParams = {
      ...DEFAULTS_LLM,
      weights: { sem: 1, con: 0, grp: 0, author: 0, topic_fuzzy: 0, title: 0 },
    };
    expect(() => parseSweepSpec("weights.sem=0.5", base)).toThrow(/weights\.sem/);
  });

  it("rejects non-numeric weight values", () => {
    expect(() => parseSweepSpec("weights.sem=high", DEFAULTS_LLM)).toThrow(
      /numeric/
    );
  });

  it("rejects an unknown weight component", () => {
    expect(() => parseSweepSpec("weights.semantic=0.3", DEFAULTS_LLM)).toThrow(
      /semantic/
    );
  });
});

describe("parseSweepSpec — invalid specs", () => {
  it("rejects a dimension without =", () => {
    expect(() => parseSweepSpec("scoreThreshold", DEFAULTS_LLM)).toThrow(
      /scoreThreshold/
    );
  });

  it("rejects an empty values part", () => {
    expect(() => parseSweepSpec("scoreThreshold=", DEFAULTS_LLM)).toThrow(
      /scoreThreshold/
    );
  });

  it("rejects a reversed range", () => {
    expect(() =>
      parseSweepSpec("originBonus.exact=0.3:0:0.05", DEFAULTS_LLM)
    ).toThrow(/sign/);
  });

  it("rejects a zero step", () => {
    expect(() =>
      parseSweepSpec("originBonus.exact=0:0.2:0", DEFAULTS_LLM)
    ).toThrow(/step/);
  });

  it("rejects non-numeric range parts", () => {
    expect(() =>
      parseSweepSpec("originBonus.exact=0:end:0.1", DEFAULTS_LLM)
    ).toThrow(/originBonus\.exact/);
  });

  it("rejects unknown top-level HybridParams keys at parse time", () => {
    expect(() => parseSweepSpec("scoreThresold=0.1", DEFAULTS_LLM)).toThrow(
      /scoreThresold/
    );
  });

  it("rejects an empty spec", () => {
    expect(() => parseSweepSpec("", DEFAULTS_LLM)).toThrow(/empty/i);
  });
});

// ---------------------------------------------------------------------------
// Leaderboard
// ---------------------------------------------------------------------------

function rr(
  over: Partial<RunResult> & { caseId: string; classifier: string }
): RunResult {
  return {
    corpus: "t",
    trainingSet: "ts1",
    predicted: null,
    stage: "scoring",
    scores: {},
    durationMs: 1,
    llmCalls: 0,
    cacheHits: 0,
    goldId: "G",
    goldMatch: null,
    expectedId: null,
    expectedMatch: null,
    expectedStage: null,
    expectedStageMatch: null,
    selfExcluded: false,
    trainingSizeAtCase: 0,
    budgetExhausted: false,
    llmUsage: null,
    rankOfGold: null,
    goldMargin: null,
    ...over,
  };
}

function usage(liveIn: number, liveOut: number): RunResult["llmUsage"] {
  return {
    liveInputTokens: liveIn,
    liveOutputTokens: liveOut,
    replayedInputTokens: 0,
    replayedOutputTokens: 0,
    unknownCalls: 0,
  };
}

describe("buildLeaderboard", () => {
  // base: c1 ✓, c2 ✓, c3 ✗, c4 ✗ (2/4). variant: c1 ✓, c2 ✗, c3 ✓, c4 ✓ (3/4).
  // → fixed = 2 (c3, c4), broke = 1 (c2). McNemar(2,1) = 1.0 → within noise.
  const fixtures: RunResult[] = [
    rr({ classifier: "B", caseId: "c1", goldMatch: true }),
    rr({ classifier: "B", caseId: "c2", goldMatch: true }),
    rr({ classifier: "B", caseId: "c3", goldMatch: false }),
    rr({ classifier: "B", caseId: "c4", goldMatch: false }),
    rr({ classifier: "B", caseId: "c5", goldMatch: null }),
    rr({ classifier: "V", caseId: "c1", goldMatch: true, llmUsage: usage(100, 10) }),
    rr({ classifier: "V", caseId: "c2", goldMatch: false, llmUsage: usage(100, 10) }),
    rr({ classifier: "V", caseId: "c3", goldMatch: true }),
    rr({ classifier: "V", caseId: "c4", goldMatch: true }),
    rr({ classifier: "V", caseId: "c5", goldMatch: null }),
  ];
  const labels = new Map([["V", "scoreThreshold=0.05"]]);

  it("counts fixed/broke vs base on gold-labeled cases only", () => {
    const rows = buildLeaderboard(fixtures, "B", labels);
    const v = rows.find((r) => r.classifier === "V")!;
    expect(v.fixed).toBe(2);
    expect(v.broke).toBe(1);
    expect(v.goldAccuracy).toBeCloseTo(0.75, 12);
    expect(v.label).toBe("scoreThreshold=0.05");
  });

  it("computes Wilson CI bounds around the accuracy", () => {
    const rows = buildLeaderboard(fixtures, "B", labels);
    const v = rows.find((r) => r.classifier === "V")!;
    expect(v.ciLo).not.toBeNull();
    expect(v.ciHi).not.toBeNull();
    expect(v.ciLo!).toBeGreaterThanOrEqual(0);
    expect(v.ciLo!).toBeLessThan(v.goldAccuracy!);
    expect(v.ciHi!).toBeGreaterThan(v.goldAccuracy!);
    expect(v.ciHi!).toBeLessThanOrEqual(1);
  });

  it("flags within-noise variants (p >= 0.05) and leaves the base p null", () => {
    const rows = buildLeaderboard(fixtures, "B", labels);
    const v = rows.find((r) => r.classifier === "V")!;
    const b = rows.find((r) => r.classifier === "B")!;
    expect(v.mcnemarP).toBeCloseTo(1.0, 12); // 2·P(X≤1), X~Bin(3,½) = 1.0
    expect(v.withinNoise).toBe(true);
    expect(b.mcnemarP).toBeNull();
    expect(b.label).toBe("base");
    expect(b.fixed).toBe(0);
    expect(b.broke).toBe(0);
  });

  it("sorts by gold accuracy descending", () => {
    const rows = buildLeaderboard(fixtures, "B", labels);
    expect(rows.map((r) => r.classifier)).toEqual(["V", "B"]);
  });

  it("sums live token usage across all cases", () => {
    const rows = buildLeaderboard(fixtures, "B", labels);
    const v = rows.find((r) => r.classifier === "V")!;
    expect(v.liveInputTokens).toBe(200);
    expect(v.liveOutputTokens).toBe(20);
    const b = rows.find((r) => r.classifier === "B")!;
    expect(b.liveInputTokens).toBe(0);
  });

  it("pairs per (trainingSet, caseId) when multiple training sets pool", () => {
    const multi: RunResult[] = [
      rr({ classifier: "B", caseId: "c1", trainingSet: "ts1", goldMatch: true }),
      rr({ classifier: "B", caseId: "c1", trainingSet: "ts2", goldMatch: false }),
      rr({ classifier: "V", caseId: "c1", trainingSet: "ts1", goldMatch: false }),
      rr({ classifier: "V", caseId: "c1", trainingSet: "ts2", goldMatch: true }),
    ];
    const rows = buildLeaderboard(multi, "B", new Map());
    const v = rows.find((r) => r.classifier === "V")!;
    expect(v.fixed).toBe(1);
    expect(v.broke).toBe(1);
  });

  it("throws when the base classifier has no results", () => {
    expect(() => buildLeaderboard(fixtures, "missing", labels)).toThrow(
      /missing/
    );
  });
});

describe("renderLeaderboard", () => {
  it("renders percentages, the noise marker, and the base star", () => {
    const fixtures: RunResult[] = [
      rr({ classifier: "B", caseId: "c1", goldMatch: true }),
      rr({ classifier: "B", caseId: "c2", goldMatch: false }),
      rr({ classifier: "V", caseId: "c1", goldMatch: true }),
      rr({ classifier: "V", caseId: "c2", goldMatch: true }),
    ];
    const rows = buildLeaderboard(fixtures, "B", new Map([["V", "marginFloor=0"]]));
    const out = renderLeaderboard(rows);
    expect(out).toContain("100.0%");
    expect(out).toContain("50.0%");
    expect(out).toContain("~noise");
    expect(out).toContain("* base");
    expect(out).toContain("marginFloor=0");
  });

  it("renders n/a for variants without gold-labeled cases", () => {
    const fixtures: RunResult[] = [
      rr({ classifier: "B", caseId: "c1", goldMatch: null }),
      rr({ classifier: "V", caseId: "c1", goldMatch: null }),
    ];
    const rows = buildLeaderboard(fixtures, "B", new Map());
    const out = renderLeaderboard(rows);
    expect(out).toContain("n/a");
  });
});
