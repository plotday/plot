import { describe, expect, it } from "vitest";
import { resolve } from "node:path";

import { runEval } from "../src/runner/run";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

describe.runIf(!!process.env.DATABASE_URL)("ts:hybrid classifier", () => {
  it("matches sql:current on synthetic-tiny stages with full training set", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    // No-match now lands in the matched role's Inbox (the corpus root focus,
    // wired as the synthetic "Eval" role's Inbox by loadWorld) — the
    // role_inbox_fallback stage replaces the old root_fallback.
    expect(byCase.get("002-root-fallback")?.stage).toBe("role_inbox_fallback");
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe(
      "topic_shortcircuit"
    );
    expect(byCase.get("004-scoring-contacts")?.stage).toBe("scoring");
    expect(byCase.get("005-scoring-no-match")?.stage).toBe("scoring");
  }, 60_000);

  it("falls back to non-scoring stages with empty training", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["empty"],
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("002-root-fallback")?.stage).toBe("role_inbox_fallback");
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe(
      "role_inbox_fallback"
    );
    expect(byCase.get("004-scoring-contacts")?.stage).toBe(
      "role_inbox_fallback"
    );
    expect(byCase.get("005-scoring-no-match")?.stage).toBe(
      "role_inbox_fallback"
    );
  }, 60_000);

  it("emits per-priority neighborScore and titleMatch in scoring explain", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
      caseFilter: (id) => id === "004-scoring-contacts",
    });
    expect(results).toHaveLength(1);
    const r = results[0]!;
    expect(r.stage).toBe("scoring");
    const explain = r.scores as {
      perPrioritySorted: {
        priorityId: string;
        score: number;
        neighborScore: number;
        titleMatch: number;
        neighborCount: number;
      }[];
    };
    expect(explain.perPrioritySorted[0]).toMatchObject({
      score: expect.any(Number),
      neighborScore: expect.any(Number),
      titleMatch: expect.any(Number),
      neighborCount: expect.any(Number),
    });
  }, 60_000);

  it("emits scoring explain JSON when scoring matches", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
      caseFilter: (id) => id === "004-scoring-contacts",
    });
    expect(results).toHaveLength(1);
    const r = results[0]!;
    expect(r.stage).toBe("scoring");
    expect(r.scores).toHaveProperty("perPrioritySorted");
    expect(r.scores).toHaveProperty("topNeighbors");
  }, 60_000);
});
