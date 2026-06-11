import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, describe, expect, it } from "vitest";

import type { RunResult } from "../src/runner/run";
import {
  buildBaseline,
  compareToBaseline,
  parseBaselineFile,
} from "../src/runner/baseline";
import { mcnemarExact } from "../src/scoring/stats";

function rr(
  over: Partial<RunResult> & { caseId: string }
): RunResult {
  return {
    corpus: "synthetic-tiny",
    classifier: "ts:hybrid:default",
    trainingSet: "full",
    predicted: null,
    stage: "scoring",
    scores: {},
    durationMs: 1,
    llmCalls: 0,
    cacheHits: 0,
    goldId: null,
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
    tags: [],
    goldSource: null,
    ...over,
  };
}

describe("buildBaseline", () => {
  it("round-trips through compareToBaseline as all-same with p = 1", () => {
    const results = [
      rr({ caseId: "c-1", predicted: "P-a", goldId: "P-a" }),
      rr({ caseId: "c-2", predicted: "P-b", goldId: "P-a" }),
      rr({ caseId: "c-3", predicted: null, goldId: null }),
    ];
    const baseline = buildBaseline(results);
    const cmp = compareToBaseline(baseline, results);
    expect(cmp.fixed).toEqual([]);
    expect(cmp.broke).toEqual([]);
    expect(cmp.changedNeutral).toEqual([]);
    expect(cmp.same).toBe(3);
    expect(cmp.newCases).toEqual([]);
    expect(cmp.missingCases).toEqual([]);
    expect(cmp.mcnemarP).toBe(1);
  });

  it("snapshots meta from the single (classifier, trainingSet) combo", () => {
    const baseline = buildBaseline([
      rr({ caseId: "c-1", predicted: "P-a", stage: "shortcut" }),
    ]);
    expect(baseline.meta.classifier).toBe("ts:hybrid:default");
    expect(baseline.meta.corpus).toBe("synthetic-tiny");
    expect(baseline.meta.trainingSet).toBe("full");
    // createdAt is a parseable ISO timestamp.
    expect(Number.isNaN(Date.parse(baseline.meta.createdAt))).toBe(false);
    expect(baseline.results["c-1"]).toEqual({
      predicted: "P-a",
      stage: "shortcut",
    });
  });

  it("sorts case keys for stable serialized output", () => {
    const baseline = buildBaseline([
      rr({ caseId: "c-zebra" }),
      rr({ caseId: "c-apple" }),
      rr({ caseId: "c-mango" }),
    ]);
    expect(Object.keys(baseline.results)).toEqual([
      "c-apple",
      "c-mango",
      "c-zebra",
    ]);
  });

  it("throws on empty results", () => {
    expect(() => buildBaseline([])).toThrow(/no results/i);
  });

  it("throws when results span multiple classifiers", () => {
    expect(() =>
      buildBaseline([
        rr({ caseId: "c-1" }),
        rr({ caseId: "c-2", classifier: "ts:hybrid-llm:default" }),
      ])
    ).toThrow(/classifier/i);
  });

  it("throws when results span multiple training sets", () => {
    expect(() =>
      buildBaseline([
        rr({ caseId: "c-1" }),
        rr({ caseId: "c-2", trainingSet: "half" }),
      ])
    ).toThrow(/training/i);
  });
});

describe("compareToBaseline", () => {
  it("classifies one of each: fixed, broke, changedNeutral, same, new, missing", () => {
    const baseline = buildBaseline([
      rr({ caseId: "c-fixed", predicted: "P-wrong", goldId: "P-gold" }),
      rr({ caseId: "c-broke", predicted: "P-gold", goldId: "P-gold" }),
      rr({ caseId: "c-neutral", predicted: "P-a", goldId: null }),
      rr({ caseId: "c-same", predicted: "P-x", goldId: "P-x" }),
      rr({ caseId: "c-missing", predicted: "P-y", goldId: null }),
    ]);
    const current = [
      rr({ caseId: "c-fixed", predicted: "P-gold", goldId: "P-gold" }),
      rr({ caseId: "c-broke", predicted: "P-wrong", goldId: "P-gold" }),
      rr({ caseId: "c-neutral", predicted: "P-b", goldId: null }),
      rr({ caseId: "c-same", predicted: "P-x", goldId: "P-x" }),
      rr({ caseId: "c-new", predicted: "P-z", goldId: null }),
    ];
    const cmp = compareToBaseline(baseline, current);
    expect(cmp.fixed).toEqual(["c-fixed"]);
    expect(cmp.broke).toEqual(["c-broke"]);
    expect(cmp.changedNeutral).toEqual(["c-neutral"]);
    expect(cmp.same).toBe(1);
    expect(cmp.newCases).toEqual(["c-new"]);
    expect(cmp.missingCases).toEqual(["c-missing"]);
    expect(cmp.mcnemarP).toBe(mcnemarExact(1, 1));
    expect(cmp.mcnemarP).toBe(1);
  });

  it("a gold-labeled change where neither prediction matches gold is changedNeutral", () => {
    const baseline = buildBaseline([
      rr({ caseId: "c-both-wrong", predicted: "P-w1", goldId: "P-gold" }),
    ]);
    const cmp = compareToBaseline(baseline, [
      rr({ caseId: "c-both-wrong", predicted: "P-w2", goldId: "P-gold" }),
    ]);
    expect(cmp.fixed).toEqual([]);
    expect(cmp.broke).toEqual([]);
    expect(cmp.changedNeutral).toEqual(["c-both-wrong"]);
  });

  it("null predictions participate: null→gold is fixed, gold→null is broke", () => {
    const baseline = buildBaseline([
      rr({ caseId: "c-was-null", predicted: null, goldId: "P-gold" }),
      rr({ caseId: "c-now-null", predicted: "P-gold", goldId: "P-gold" }),
    ]);
    const cmp = compareToBaseline(baseline, [
      rr({ caseId: "c-was-null", predicted: "P-gold", goldId: "P-gold" }),
      rr({ caseId: "c-now-null", predicted: null, goldId: "P-gold" }),
    ]);
    expect(cmp.fixed).toEqual(["c-was-null"]);
    expect(cmp.broke).toEqual(["c-now-null"]);
  });

  it("sorts every output list", () => {
    const baseline = buildBaseline([
      rr({ caseId: "c-z", predicted: "P-wrong", goldId: "P-gold" }),
      rr({ caseId: "c-a", predicted: "P-wrong", goldId: "P-gold" }),
      rr({ caseId: "c-m", predicted: "P-wrong", goldId: "P-gold" }),
      rr({ caseId: "m-gone-2", predicted: null, goldId: null }),
      rr({ caseId: "m-gone-1", predicted: null, goldId: null }),
    ]);
    const cmp = compareToBaseline(baseline, [
      rr({ caseId: "c-z", predicted: "P-gold", goldId: "P-gold" }),
      rr({ caseId: "c-a", predicted: "P-gold", goldId: "P-gold" }),
      rr({ caseId: "c-m", predicted: "P-gold", goldId: "P-gold" }),
      rr({ caseId: "n-new-2", predicted: null, goldId: null }),
      rr({ caseId: "n-new-1", predicted: null, goldId: null }),
    ]);
    expect(cmp.fixed).toEqual(["c-a", "c-m", "c-z"]);
    expect(cmp.newCases).toEqual(["n-new-1", "n-new-2"]);
    expect(cmp.missingCases).toEqual(["m-gone-1", "m-gone-2"]);
  });

  it("fixed=6 broke=0 yields mcnemarP ≈ 0.03125 (real stats module)", () => {
    const ids = ["c-1", "c-2", "c-3", "c-4", "c-5", "c-6"];
    const baseline = buildBaseline([
      ...ids.map((id) =>
        rr({ caseId: id, predicted: "P-wrong", goldId: "P-gold" })
      ),
      rr({ caseId: "c-steady", predicted: "P-gold", goldId: "P-gold" }),
    ]);
    const cmp = compareToBaseline(baseline, [
      ...ids.map((id) =>
        rr({ caseId: id, predicted: "P-gold", goldId: "P-gold" })
      ),
      rr({ caseId: "c-steady", predicted: "P-gold", goldId: "P-gold" }),
    ]);
    expect(cmp.fixed).toHaveLength(6);
    expect(cmp.broke).toHaveLength(0);
    expect(cmp.same).toBe(1);
    expect(cmp.mcnemarP).toBeCloseTo(0.03125, 4);
  });
});

describe("baseline file I/O", () => {
  let dir: string | null = null;
  afterAll(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it("write + read round-trips through parseBaselineFile", async () => {
    dir = await mkdtemp(join(tmpdir(), "eval-baseline-"));
    const results = [
      rr({ caseId: "c-1", predicted: "P-a", goldId: "P-a", stage: "shortcut" }),
      rr({ caseId: "c-2", predicted: null, goldId: null }),
    ];
    const baseline = buildBaseline(results);
    const file = join(dir, "baseline.json");
    await writeFile(file, JSON.stringify(baseline, null, 2));

    const loaded = parseBaselineFile(await readFile(file, "utf8"));
    expect(loaded).toEqual(baseline);
    const cmp = compareToBaseline(loaded, results);
    expect(cmp.same).toBe(2);
    expect(cmp.fixed).toEqual([]);
    expect(cmp.broke).toEqual([]);
    expect(cmp.mcnemarP).toBe(1);
  });

  it("parseBaselineFile rejects invalid JSON and wrong shapes", () => {
    expect(() => parseBaselineFile("not json")).toThrow(/JSON/);
    expect(() => parseBaselineFile('{"results": {}}')).toThrow(/meta/i);
    expect(() =>
      parseBaselineFile('{"meta": {"classifier": "x"}, "results": {}}')
    ).toThrow(/baseline/i);
    // typeof [] === "object": an array results would silently classify every
    // case as new — must be rejected at parse time.
    expect(() =>
      parseBaselineFile(
        '{"meta": {"classifier": "x", "corpus": "c", "trainingSet": "t", "createdAt": "now"}, "results": []}'
      )
    ).toThrow(/baseline/i);
  });
});
