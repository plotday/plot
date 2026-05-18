import { describe, expect, it } from "vitest";
import { resolve } from "node:path";

import { loadCorpus } from "../src/corpus/load";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

describe("corpus loader (synthetic-tiny)", () => {
  it("loads world, training sets, and cases", async () => {
    const corpus = await loadCorpus(SYNTHETIC_TINY_DIR);
    expect(corpus.name).toBe("synthetic-tiny");
    expect(corpus.world.priorities.length).toBeGreaterThanOrEqual(3);
    expect(corpus.cases.length).toBe(5);
    // synthetic-tiny ships with `full` and `empty`.
    expect(corpus.trainingSets.map((t) => t.name).sort()).toEqual(["empty", "full"]);
  });

  it("resolves all cross-references", async () => {
    const corpus = await loadCorpus(SYNTHETIC_TINY_DIR);
    for (const cs of corpus.cases) {
      if (cs.labels.gold) {
        expect(corpus.world.priorities.some((p) => p.id === cs.labels.gold)).toBe(true);
      }
      if (cs.labels.expected) {
        expect(
          corpus.world.priorities.some((p) => p.id === cs.labels.expected)
        ).toBe(true);
      }
    }
    for (const ts of corpus.trainingSets) {
      for (const t of ts.threads) {
        expect(
          corpus.world.priorities.some((p) => p.id === t.filed_to_priority)
        ).toBe(true);
      }
    }
  });

  it("has unique case ids and training-set names", async () => {
    const corpus = await loadCorpus(SYNTHETIC_TINY_DIR);
    const caseIds = new Set<string>();
    for (const c of corpus.cases) {
      expect(caseIds.has(c.id)).toBe(false);
      caseIds.add(c.id);
    }
    const tsNames = new Set<string>();
    for (const t of corpus.trainingSets) {
      expect(tsNames.has(t.name)).toBe(false);
      tsNames.add(t.name);
    }
  });
});
