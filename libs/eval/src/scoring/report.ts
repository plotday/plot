import type { Corpus } from "../corpus/schema";
import type { BaselineComparison, BaselineFile } from "../runner/baseline";
import type { RunResult, RunSummary } from "../runner/run";
import { mcnemarExact, wilsonInterval } from "./stats";

export type ReportFormat = "console" | "json" | "markdown";

/** A loaded baseline plus its comparison against this run (CLI --baseline). */
export type BaselineContext = {
  file: BaselineFile;
  /** Results filtered to the baseline's (classifier, trainingSet) combo. */
  results: RunResult[];
  comparison: BaselineComparison;
};

type PriorityLookup = Map<string, { slug: string; title: string }>;

function buildPriorityLookup(corpus: Corpus): PriorityLookup {
  return new Map(
    corpus.world.priorities.map((p) => [p.id, { slug: p.slug, title: p.title }])
  );
}

export function formatReport(
  corpus: Corpus,
  summary: RunSummary,
  results: RunResult[],
  format: ReportFormat,
  baseline?: BaselineContext | null
): string {
  const lookup = buildPriorityLookup(corpus);
  switch (format) {
    case "json":
      return JSON.stringify(
        {
          summary,
          results,
          ...(baseline
            ? {
                baselineComparison: {
                  meta: baseline.file.meta,
                  ...baseline.comparison,
                },
              }
            : {}),
        },
        null,
        2
      );
    case "markdown":
      return (
        renderMarkdown(summary, results, lookup) +
        (baseline
          ? "\n\n" + renderBaselineComparison(baseline, corpus)
          : "")
      );
    case "console":
    default:
      return (
        renderConsole(summary, results, lookup) +
        (baseline
          ? "\n\n" + renderBaselineComparison(baseline, corpus)
          : "")
      );
  }
}

/**
 * Console section for a --baseline comparison: discordant counts, fixed/broke
 * case lists with predicted-vs-gold priority names, and an exact McNemar p
 * over the fixed/broke counts (~noise when p >= 0.05, matching the sweep
 * leaderboard's annotation).
 */
export function renderBaselineComparison(
  baseline: BaselineContext,
  corpus: Corpus
): string {
  const lookup = buildPriorityLookup(corpus);
  const { file, comparison } = baseline;
  const byCase = new Map(baseline.results.map((r) => [r.caseId, r]));
  const detail = (caseId: string): string => {
    const was = file.results[caseId];
    const now = byCase.get(caseId);
    return (
      `    ${caseId}: was=${name(was?.predicted ?? null, lookup)} ` +
      `now=${name(now?.predicted ?? null, lookup)} ` +
      `gold=${name(now?.goldId ?? null, lookup)}`
    );
  };

  const lines: string[] = [];
  lines.push(
    `Baseline comparison (vs ${file.meta.classifier} / ${file.meta.trainingSet}, saved ${file.meta.createdAt}):`
  );
  lines.push(
    `  fixed=${comparison.fixed.length}  broke=${comparison.broke.length}  ` +
      `changed (no gold verdict)=${comparison.changedNeutral.length}  ` +
      `same=${comparison.same}  new=${comparison.newCases.length}  ` +
      `missing=${comparison.missingCases.length}`
  );
  if (comparison.fixed.length > 0) {
    lines.push("  Fixed (was wrong, now matches gold):");
    for (const id of comparison.fixed) lines.push(detail(id));
  }
  if (comparison.broke.length > 0) {
    lines.push("  Broke (was gold, now wrong):");
    for (const id of comparison.broke) lines.push(detail(id));
  }
  if (comparison.changedNeutral.length > 0) {
    lines.push(
      `  Changed without a gold verdict (${comparison.changedNeutral.length}): ` +
        comparison.changedNeutral.join(", ")
    );
  }
  if (comparison.newCases.length > 0) {
    lines.push(`  New cases not in baseline: ${comparison.newCases.length}`);
  }
  if (comparison.missingCases.length > 0) {
    lines.push(
      `  Baseline cases absent from this run: ${comparison.missingCases.length}`
    );
  }
  lines.push(
    `  McNemar p = ${comparison.mcnemarP.toFixed(3)}` +
      (comparison.mcnemarP >= 0.05 ? " ~noise" : "")
  );
  return lines.join("\n");
}

function renderConsole(
  summary: RunSummary,
  results: RunResult[],
  lookup: PriorityLookup
): string {
  const lines: string[] = [];
  lines.push(`Corpus: ${summary.corpus} (${summary.totalCases} cases)`);
  const selfExcluded = new Set(
    results.filter((r) => r.selfExcluded).map((r) => r.caseId)
  ).size;
  if (selfExcluded > 0) {
    lines.push(
      `Self-exclusions: ${selfExcluded} case(s) had their source thread archived out of the training set (anti-leakage guard).`
    );
  }
  lines.push("");
  lines.push(
    "Classifier           Training         Gold     Expected  Regress  LLM/case  Hit%   AvgMs"
  );
  lines.push(
    "-------------------- ---------------  -------  --------  -------  --------  -----  -----"
  );
  for (const c of summary.perClassifierTraining) {
    lines.push(
      [
        c.classifier.padEnd(20),
        c.trainingSet.padEnd(15),
        pct(c.goldAccuracy).padStart(7),
        pct(c.expectedAccuracy).padStart(8),
        String(c.regressions).padStart(7),
        c.llmCallsPerCase.toFixed(2).padStart(8),
        pct(c.llmCacheHitRate).padStart(5),
        c.avgDurationMs.toFixed(1).padStart(5),
      ].join("  ")
    );
  }

  const stageBreakdown = groupBy(
    results,
    (r) => `${r.classifier} / ${r.trainingSet} → ${r.stage}`
  );
  lines.push("");
  lines.push("Stage breakdown:");
  for (const [key, rows] of stageBreakdown) {
    const goldEval = rows.filter((r) => r.goldMatch !== null);
    const acc =
      goldEval.length > 0
        ? goldEval.filter((r) => r.goldMatch).length / goldEval.length
        : null;
    lines.push(`  ${key.padEnd(48)} ${rows.length.toString().padStart(4)} cases   gold=${pct(acc)}`);
  }

  const flipLines = renderFlips(summary, results, lookup);
  if (flipLines.length > 0) {
    lines.push("");
    lines.push("Predictions that vary across training sets:");
    lines.push(...flipLines);
  }

  const goldMisses = results.filter((r) => r.goldMatch === false);
  if (goldMisses.length > 0) {
    lines.push("");
    lines.push("Misses against gold:");
    for (const f of goldMisses) {
      lines.push(
        `  [${f.classifier} / ${f.trainingSet}] ${f.caseId}: ` +
          `predicted=${name(f.predicted, lookup)} (${f.stage}) ` +
          `gold=${name(f.goldId, lookup)}`
      );
    }
  }

  const expectedMisses = results.filter(
    (r) => r.expectedMatch === false && r.goldMatch !== false
  );
  if (expectedMisses.length > 0) {
    lines.push("");
    lines.push("Disagreements with the recorded baseline (no gold set):");
    for (const f of expectedMisses) {
      lines.push(
        `  [${f.classifier} / ${f.trainingSet}] ${f.caseId}: ` +
          `predicted=${name(f.predicted, lookup)} (${f.stage}) ` +
          `expected=${name(f.expectedId, lookup)}`
      );
    }
  }

  return lines.join("\n");
}

function renderMarkdown(
  summary: RunSummary,
  results: RunResult[],
  lookup: PriorityLookup
): string {
  const lines: string[] = [];
  lines.push(`# Eval report — ${summary.corpus}`);
  lines.push("");
  lines.push(`${summary.totalCases} cases evaluated.`);
  lines.push("");
  lines.push(
    "| Classifier | Training set | Gold acc. | Expected acc. | Regressions | LLM calls / case | Cache hit rate | Avg ms |"
  );
  lines.push("| --- | --- | --- | --- | --- | --- | --- | --- |");
  for (const c of summary.perClassifierTraining) {
    lines.push(
      `| \`${c.classifier}\` | \`${c.trainingSet}\` | ${pct(c.goldAccuracy)} | ${pct(c.expectedAccuracy)} | ${c.regressions} | ${c.llmCallsPerCase.toFixed(2)} | ${pct(c.llmCacheHitRate)} | ${c.avgDurationMs.toFixed(1)} |`
    );
  }
  lines.push("");

  const failures = results.filter((r) => r.goldMatch === false);
  if (failures.length > 0) {
    lines.push("## Gold misses");
    lines.push("");
    lines.push("| Classifier | Training | Case | Predicted | Stage | Gold |");
    lines.push("| --- | --- | --- | --- | --- | --- |");
    for (const f of failures) {
      lines.push(
        `| \`${f.classifier}\` | \`${f.trainingSet}\` | \`${f.caseId}\` | ${name(f.predicted, lookup)} | ${f.stage} | ${name(f.goldId, lookup)} |`
      );
    }
  }
  return lines.join("\n");
}

function renderFlips(
  summary: RunSummary,
  results: RunResult[],
  lookup: PriorityLookup
): string[] {
  const trainingSets = [
    ...new Set(summary.perClassifierTraining.map((r) => r.trainingSet)),
  ];
  if (trainingSets.length < 2) return [];

  const lines: string[] = [];
  const byClassifier = groupBy(results, (r) => r.classifier);
  const colWidth = 22;
  for (const [classifier, rows] of byClassifier) {
    const byCase = groupBy(rows, (r) => r.caseId);
    const flipped: { caseId: string; cells: Map<string, string | null> }[] = [];
    for (const [caseId, caseRows] of byCase) {
      const cells = new Map<string, string | null>();
      for (const r of caseRows) cells.set(r.trainingSet, r.predicted);
      const distinct = new Set(cells.values());
      if (distinct.size > 1) flipped.push({ caseId, cells });
    }
    if (flipped.length === 0) continue;

    lines.push(`  [${classifier}]`);
    lines.push(
      `    ${"Case".padEnd(28)}  ${trainingSets
        .map((t) => t.padEnd(colWidth))
        .join("  ")}`
    );
    for (const { caseId, cells } of flipped) {
      lines.push(
        `    ${caseId.padEnd(28)}  ${trainingSets
          .map((t) => name(cells.get(t) ?? null, lookup).padEnd(colWidth))
          .join("  ")}`
      );
    }
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Sweep leaderboard (--sweep)
// ---------------------------------------------------------------------------

export type LeaderboardRow = {
  classifier: string;
  /** Sweep point label (e.g. "scoreThreshold=0.05") or "base". */
  label: string;
  goldAccuracy: number | null;
  ciLo: number | null;
  ciHi: number | null;
  /** Gold-labeled cases the base got wrong and this variant got right. */
  fixed: number;
  /** Gold-labeled cases the base got right and this variant got wrong. */
  broke: number;
  /** Exact McNemar p over the discordant pairs; null for the base row. */
  mcnemarP: number | null;
  /** True when mcnemarP >= 0.05 — the difference from base is plausibly noise. */
  withinNoise: boolean;
  liveInputTokens: number;
  liveOutputTokens: number;
};

/**
 * Builds the sweep leaderboard: per classifier, gold accuracy with a Wilson
 * 95% CI plus a paired comparison against `baseClassifier` (fixed/broke
 * discordant counts and an exact McNemar p) over gold-labeled cases.
 *
 * Pairing is keyed on (trainingSet, caseId), so a sweep run over multiple
 * training sets stays a valid matched-pairs design: accuracies pool across
 * sets while each (case, set) outcome is compared against the base's outcome
 * for the same (case, set). Live token sums cover ALL cases, not just
 * gold-labeled ones. Rows sort by gold accuracy descending; the base row is
 * always present (marked with `*` by renderLeaderboard).
 */
export function buildLeaderboard(
  results: RunResult[],
  baseClassifier: string,
  labels: Map<string, string>
): LeaderboardRow[] {
  const byClassifier = groupBy(results, (r) => r.classifier);
  const baseRows = byClassifier.get(baseClassifier);
  if (!baseRows) {
    throw new Error(
      `buildLeaderboard: base classifier "${baseClassifier}" has no results. ` +
        `Classifiers in results: ${[...byClassifier.keys()].join(", ")}`
    );
  }
  const pairKey = (r: RunResult) => `${r.trainingSet} ${r.caseId}`;
  const baseGold = new Map<string, boolean>();
  for (const r of baseRows) {
    if (r.goldMatch !== null) baseGold.set(pairKey(r), r.goldMatch);
  }

  const rows: LeaderboardRow[] = [];
  for (const [classifier, cRows] of byClassifier) {
    const goldEval = cRows.filter((r) => r.goldMatch !== null);
    const correct = goldEval.filter((r) => r.goldMatch).length;
    const ci = goldEval.length > 0 ? wilsonInterval(correct, goldEval.length) : null;
    let fixed = 0;
    let broke = 0;
    if (classifier !== baseClassifier) {
      for (const r of goldEval) {
        const baseMatch = baseGold.get(pairKey(r));
        if (baseMatch === undefined) continue; // unpaired: base lacks this case
        if (!baseMatch && r.goldMatch) fixed++;
        if (baseMatch && !r.goldMatch) broke++;
      }
    }
    const mcnemarP =
      classifier === baseClassifier ? null : mcnemarExact(fixed, broke);
    rows.push({
      classifier,
      label:
        classifier === baseClassifier
          ? "base"
          : (labels.get(classifier) ?? classifier),
      goldAccuracy: goldEval.length > 0 ? correct / goldEval.length : null,
      ciLo: ci?.lo ?? null,
      ciHi: ci?.hi ?? null,
      fixed,
      broke,
      mcnemarP,
      withinNoise: mcnemarP !== null && mcnemarP >= 0.05,
      liveInputTokens: cRows.reduce(
        (s, r) => s + (r.llmUsage?.liveInputTokens ?? 0),
        0
      ),
      liveOutputTokens: cRows.reduce(
        (s, r) => s + (r.llmUsage?.liveOutputTokens ?? 0),
        0
      ),
    });
  }

  rows.sort((a, b) => {
    const accA = a.goldAccuracy ?? -1;
    const accB = b.goldAccuracy ?? -1;
    if (accB !== accA) return accB - accA;
    // Ties: base first, then label for a deterministic order.
    if (a.classifier === baseClassifier) return -1;
    if (b.classifier === baseClassifier) return 1;
    return a.label.localeCompare(b.label);
  });
  return rows;
}

/** Aligned console table for the sweep leaderboard. */
export function renderLeaderboard(rows: LeaderboardRow[]): string {
  const headers = [
    "Variant",
    "Gold acc [95% CI]",
    "Fixed",
    "Broke",
    "McNemar p",
    "Live tokens in/out",
  ];
  const cells = rows.map((r) => [
    `${r.mcnemarP === null ? "* " : "  "}${r.label}`,
    accCell(r),
    r.mcnemarP === null ? "-" : String(r.fixed),
    r.mcnemarP === null ? "-" : String(r.broke),
    pCell(r),
    `${r.liveInputTokens}/${r.liveOutputTokens}`,
  ]);
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...cells.map((row) => row[i]!.length))
  );
  const fmt = (row: string[]) =>
    row
      .map((c, i) => (i === 0 ? c.padEnd(widths[i]!) : c.padStart(widths[i]!)))
      .join("  ")
      .trimEnd();
  return [
    "Sweep leaderboard (gold accuracy; fixed/broke and McNemar p are paired vs * base):",
    fmt(headers),
    fmt(widths.map((w) => "-".repeat(w))),
    ...cells.map(fmt),
    "",
    "~noise: the difference from base is not statistically significant (p >= 0.05).",
  ].join("\n");
}

function accCell(r: LeaderboardRow): string {
  if (r.goldAccuracy === null) return "n/a";
  return `${pct(r.goldAccuracy)} [${(r.ciLo! * 100).toFixed(1)}–${(r.ciHi! * 100).toFixed(1)}]`;
}

function pCell(r: LeaderboardRow): string {
  if (r.mcnemarP === null) return "-";
  return `${r.mcnemarP.toFixed(3)}${r.withinNoise ? " ~noise" : ""}`;
}

function name(id: string | null, lookup: PriorityLookup): string {
  if (id === null) return "(none)";
  const hit = lookup.get(id);
  if (!hit) return id.slice(0, 8);
  return hit.slug;
}

function pct(v: number | null): string {
  if (v === null) return "  n/a";
  return `${(v * 100).toFixed(1)}%`;
}

function groupBy<T>(arr: T[], keyOf: (x: T) => string): Map<string, T[]> {
  const m = new Map<string, T[]>();
  for (const x of arr) {
    const k = keyOf(x);
    const list = m.get(k);
    if (list) list.push(x);
    else m.set(k, [x]);
  }
  return m;
}
