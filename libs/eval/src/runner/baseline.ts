import { mcnemarExact } from "../scoring/stats";
import type { RunResult } from "./run";

/**
 * Per-case prediction snapshot for exactly one (classifier, trainingSet)
 * combo, written by `--save-baseline` and consumed by `--baseline`. Keys in
 * `results` are case ids, kept sorted so the serialized JSON diffs cleanly.
 */
export type BaselineFile = {
  meta: {
    classifier: string;
    corpus: string;
    trainingSet: string;
    createdAt: string;
  };
  // Gold labels are NOT stored: comparisons read gold from the CURRENT run's
  // corpus, so re-labeled cases are judged against the new gold, not the one
  // in effect when the snapshot was saved (check meta.createdAt for staleness).
  results: Record<string, { predicted: string | null; stage: string }>;
};

export type BaselineComparison = {
  /** Gold-labeled cases: baseline ≠ gold, current = gold. */
  fixed: string[];
  /** Gold-labeled cases: baseline = gold, current ≠ gold. */
  broke: string[];
  /**
   * Prediction changed but neither side settles a gold verdict: the case has
   * no gold label, or both predictions miss it.
   */
  changedNeutral: string[];
  /** Cases present in both with an unchanged prediction. */
  same: number;
  /** Case ids in the current results but not in the baseline. */
  newCases: string[];
  /** Case ids in the baseline but not in the current results. */
  missingCases: string[];
  /** Exact McNemar p over the (fixed, broke) discordant pair counts. */
  mcnemarP: number;
};

/**
 * Snapshots one run's per-case predictions. The results must all belong to a
 * single (classifier, trainingSet) combo — a baseline pins one configuration,
 * so mixed inputs (multi-classifier or multi-training-set runs) throw.
 */
export function buildBaseline(results: RunResult[]): BaselineFile {
  if (results.length === 0) {
    throw new Error("buildBaseline: no results to snapshot.");
  }
  const combos = new Set(
    results.map((r) => `${r.classifier} / ${r.trainingSet}`)
  );
  if (combos.size > 1) {
    throw new Error(
      `buildBaseline: results span multiple (classifier, training set) combos ` +
        `(${[...combos].sort().join("; ")}); a baseline snapshots exactly one.`
    );
  }
  const first = results[0]!;
  const sorted = [...results].sort((a, b) => a.caseId.localeCompare(b.caseId));
  return {
    meta: {
      classifier: first.classifier,
      corpus: first.corpus,
      trainingSet: first.trainingSet,
      createdAt: new Date().toISOString(),
    },
    results: Object.fromEntries(
      sorted.map((r) => [r.caseId, { predicted: r.predicted, stage: r.stage }])
    ),
  };
}

/**
 * Compares current results against a saved baseline, per case id. Cases in
 * both buckets as: same (prediction unchanged), fixed/broke (changed, with a
 * gold verdict), or changedNeutral (changed, no gold verdict). Cases only on
 * one side land in newCases/missingCases. All lists are sorted for stable
 * output; mcnemarP tests the fixed-vs-broke discordant counts.
 */
export function compareToBaseline(
  baseline: BaselineFile,
  results: RunResult[]
): BaselineComparison {
  const fixed: string[] = [];
  const broke: string[] = [];
  const changedNeutral: string[] = [];
  const newCases: string[] = [];
  let same = 0;
  const seen = new Set<string>();

  for (const r of results) {
    seen.add(r.caseId);
    const base = baseline.results[r.caseId];
    if (!base) {
      newCases.push(r.caseId);
      continue;
    }
    if (base.predicted === r.predicted) {
      same++;
      continue;
    }
    if (r.goldId === null) {
      changedNeutral.push(r.caseId);
      continue;
    }
    const wasGold = base.predicted === r.goldId;
    const isGold = r.predicted === r.goldId;
    if (!wasGold && isGold) fixed.push(r.caseId);
    else if (wasGold && !isGold) broke.push(r.caseId);
    else changedNeutral.push(r.caseId);
  }

  const missingCases = Object.keys(baseline.results).filter(
    (caseId) => !seen.has(caseId)
  );

  fixed.sort();
  broke.sort();
  changedNeutral.sort();
  newCases.sort();
  missingCases.sort();

  return {
    fixed,
    broke,
    changedNeutral,
    same,
    newCases,
    missingCases,
    mcnemarP: mcnemarExact(fixed.length, broke.length),
  };
}

/** Parses and shape-checks a baseline file's text, with readable errors. */
export function parseBaselineFile(text: string): BaselineFile {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new Error(
      `baseline file is not valid JSON: ${err instanceof Error ? err.message : String(err)}`
    );
  }
  const obj = parsed as Partial<BaselineFile> | null;
  if (obj === null || typeof obj !== "object" || obj.meta === undefined) {
    throw new Error(
      "baseline file has no meta object (expected { meta, results })."
    );
  }
  const meta = obj.meta as Partial<BaselineFile["meta"]>;
  if (
    typeof meta?.classifier !== "string" ||
    typeof meta.corpus !== "string" ||
    typeof meta.trainingSet !== "string" ||
    typeof meta.createdAt !== "string" ||
    obj.results === null ||
    typeof obj.results !== "object" ||
    Array.isArray(obj.results)
  ) {
    throw new Error(
      "file does not look like a baseline snapshot (expected " +
        "{ meta: { classifier, corpus, trainingSet, createdAt }, results })."
    );
  }
  return obj as BaselineFile;
}
