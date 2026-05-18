import { describe, expect, it } from "vitest";
import { resolve } from "node:path";

import { runEval } from "../src/runner/run";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

// These tests require a running local Postgres on $DATABASE_URL with the
// classifier migrations applied.
describe.runIf(!!process.env.DATABASE_URL)("sql:current classifier", () => {
  it("hits 100% gold accuracy on synthetic-tiny with the full training set", async () => {
    const { summary, results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["sql:current"],
      trainingSets: ["full"],
    });
    expect(summary.perClassifierTraining).toHaveLength(1);
    const cell = summary.perClassifierTraining[0]!;
    expect(cell.classifier).toBe("sql:current");
    expect(cell.trainingSet).toBe("full");
    expect(cell.goldAccuracy).toBe(1);
    expect(cell.expectedAccuracy).toBe(1);
    expect(cell.regressions).toBe(0);

    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("002-root-fallback")?.stage).toBe("root_fallback");
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe(
      "topic_shortcircuit"
    );
    expect(byCase.get("004-scoring-contacts")?.stage).toBe("scoring");
    expect(byCase.get("005-scoring-no-match")?.stage).toBe("scoring");
  }, 60_000);

  it("falls back to non-scoring stages when training is empty", async () => {
    const { summary, results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["sql:current"],
      trainingSets: ["empty"],
    });
    expect(summary.perClassifierTraining).toHaveLength(1);
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    // priority_prefix and root_fallback still fire — they don't need training.
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("002-root-fallback")?.stage).toBe("root_fallback");
    // Without training, topic_shortcircuit and scoring can't match — both fall
    // through to root_fallback.
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe("root_fallback");
    expect(byCase.get("004-scoring-contacts")?.stage).toBe("root_fallback");
    expect(byCase.get("005-scoring-no-match")?.stage).toBe("root_fallback");
  }, 60_000);

  it("matrices full and empty training sets when no filter is given", async () => {
    const { summary, results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["sql:current"],
    });
    // 2 training sets × 1 classifier = 2 summary cells, 2 × 5 cases = 10 rows.
    expect(summary.perClassifierTraining).toHaveLength(2);
    expect(results).toHaveLength(10);
  }, 60_000);

  it("emits stage-attributed scores in the scoring case", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["sql:current"],
      trainingSets: ["full"],
      caseFilter: (id) => id === "004-scoring-contacts",
    });
    expect(results).toHaveLength(1);
    const r = results[0]!;
    expect(r.stage).toBe("scoring");
    expect(r.scores).toHaveProperty("top");
    const top = (r.scores as { top: unknown[] }).top;
    expect(Array.isArray(top)).toBe(true);
    expect(top.length).toBeGreaterThan(0);
  }, 60_000);
});
