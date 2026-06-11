import type { Corpus } from "../corpus/schema";
import type { RunResult, RunSummary } from "../runner/run";

export type ReportFormat = "console" | "json" | "markdown";

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
  format: ReportFormat
): string {
  const lookup = buildPriorityLookup(corpus);
  switch (format) {
    case "json":
      return JSON.stringify({ summary, results }, null, 2);
    case "markdown":
      return renderMarkdown(summary, results, lookup);
    case "console":
    default:
      return renderConsole(summary, results, lookup);
  }
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
