import { describe, expect, it } from "vitest";
import { resolve } from "node:path";

import { runEval } from "../src/runner/run";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

// These tests require a running local Postgres on $DATABASE_URL with the
// classifier migrations applied. They're already required to run libs/db
// integration tests, so we don't gate behind extra setup.
describe.runIf(!!process.env.DATABASE_URL)("sql:current classifier", () => {
  it("hits 100% gold accuracy on synthetic-tiny", async () => {
    const { summary, results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["sql:current"],
    });
    expect(summary.perClassifier).toHaveLength(1);
    const sql = summary.perClassifier[0]!;
    expect(sql.classifier).toBe("sql:current");
    expect(sql.goldAccuracy).toBe(1);
    expect(sql.expectedAccuracy).toBe(1);
    expect(sql.regressions).toBe(0);

    // Each case should report its expected stage.
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("002-root-fallback")?.stage).toBe("root_fallback");
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe(
      "topic_shortcircuit"
    );
    expect(byCase.get("004-scoring-contacts")?.stage).toBe("scoring");
    expect(byCase.get("005-scoring-no-match")?.stage).toBe("scoring");
  }, 60_000);

  it("emits stage-attributed scores in the scoring case", async () => {
    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["sql:current"],
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
