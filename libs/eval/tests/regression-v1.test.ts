import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { runEval } from "../src/runner/run";

const KRIS_V1_DIR = resolve(__dirname, "fixtures", "kris-v1");
const EXPECTED_PATH = resolve(__dirname, "fixtures", "kris-v1-expected.json");

/**
 * Durable v1 byte-exactness gate (spec A6): the frozen kris-v1 snapshot in
 * tests/fixtures must keep producing EXACTLY the predictions recorded when
 * the snapshot was taken. Any diff means a refactor changed v1 behavior —
 * fix the regression, never re-record the fixture to make this pass.
 */
describe.runIf(!!process.env.DATABASE_URL)("v1 regression gate", () => {
  it("ts:hybrid:default on frozen kris-v1/full matches the recorded snapshot", async () => {
    const { results } = await runEval({
      corpusDir: KRIS_V1_DIR,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["full"],
    });

    const actual = Object.fromEntries(
      results.map((r) => [r.caseId, { predicted: r.predicted, stage: r.stage }])
    );
    const expected = JSON.parse(await readFile(EXPECTED_PATH, "utf-8")) as Record<
      string,
      { predicted: string | null; stage: string }
    >;

    expect(Object.keys(actual)).toHaveLength(Object.keys(expected).length);
    expect(actual).toEqual(expected);

    // The frozen corpus contains two true case↔training leaks that the
    // always-on self-exclusion guard (spec A3a) catches via the case-id
    // prefix fallback: 002's source thread re-appears as a training thread
    // with the identical embedding ref, and 005's with the identical title.
    // Their predictions are nevertheless byte-identical to the pre-guard
    // snapshot (002 resolves via a *different* thread's topic match, 005 via
    // priority_title_override which fires before scoring), so the gate and
    // the guard coexist. Pin both facts.
    const selfExcluded = results
      .filter((r) => r.selfExcluded)
      .map((r) => r.caseId)
      .sort();
    expect(selfExcluded).toEqual(["002-019df366", "005-019dbff2"]);
  }, 120_000);
});
