import type { RunResult, RunSummary } from "../runner/run";

export type ReportFormat = "console" | "json" | "markdown";

export function formatReport(
  summary: RunSummary,
  results: RunResult[],
  format: ReportFormat
): string {
  switch (format) {
    case "json":
      return JSON.stringify({ summary, results }, null, 2);
    case "markdown":
      return renderMarkdown(summary, results);
    case "console":
    default:
      return renderConsole(summary, results);
  }
}

function renderConsole(summary: RunSummary, results: RunResult[]): string {
  const lines: string[] = [];
  lines.push(`Corpus: ${summary.corpus} (${summary.totalCases} cases)`);
  lines.push("");
  lines.push("Classifier           Gold     Expected  Regress  AvgMs");
  lines.push("-------------------- -------  --------  -------  -----");
  for (const c of summary.perClassifier) {
    lines.push(
      [
        c.classifier.padEnd(20),
        pct(c.goldAccuracy).padStart(7),
        pct(c.expectedAccuracy).padStart(8),
        String(c.regressions).padStart(7),
        c.avgDurationMs.toFixed(1).padStart(5),
      ].join("  ")
    );
  }

  const stageBreakdown = groupBy(results, (r) => `${r.classifier} → ${r.stage}`);
  lines.push("");
  lines.push("Stage breakdown:");
  for (const [key, rows] of stageBreakdown) {
    const goldEval = rows.filter((r) => r.goldMatch !== null);
    const acc =
      goldEval.length > 0
        ? goldEval.filter((r) => r.goldMatch).length / goldEval.length
        : null;
    lines.push(`  ${key.padEnd(36)} ${rows.length.toString().padStart(4)} cases   gold=${pct(acc)}`);
  }

  const failures = results.filter((r) => r.goldMatch === false);
  if (failures.length > 0) {
    lines.push("");
    lines.push("Misses against gold:");
    for (const f of failures) {
      lines.push(
        `  [${f.classifier}] case ${f.caseId}: predicted=${short(f.predicted)} (${f.stage}) gold=${short(f.goldId)}`
      );
    }
  }
  return lines.join("\n");
}

function renderMarkdown(summary: RunSummary, results: RunResult[]): string {
  const lines: string[] = [];
  lines.push(`# Eval report — ${summary.corpus}`);
  lines.push("");
  lines.push(`${summary.totalCases} cases evaluated.`);
  lines.push("");
  lines.push("| Classifier | Gold acc. | Expected acc. | Regressions | Avg ms |");
  lines.push("| --- | --- | --- | --- | --- |");
  for (const c of summary.perClassifier) {
    lines.push(
      `| \`${c.classifier}\` | ${pct(c.goldAccuracy)} | ${pct(c.expectedAccuracy)} | ${c.regressions} | ${c.avgDurationMs.toFixed(1)} |`
    );
  }
  lines.push("");

  const failures = results.filter((r) => r.goldMatch === false);
  if (failures.length > 0) {
    lines.push("## Gold misses");
    lines.push("");
    lines.push("| Classifier | Case | Predicted | Stage | Gold |");
    lines.push("| --- | --- | --- | --- | --- |");
    for (const f of failures) {
      lines.push(
        `| \`${f.classifier}\` | \`${f.caseId}\` | \`${short(f.predicted)}\` | ${f.stage} | \`${short(f.goldId)}\` |`
      );
    }
  }
  return lines.join("\n");
}

function pct(v: number | null): string {
  if (v === null) return "  n/a";
  return `${(v * 100).toFixed(1)}%`;
}

function short(id: string | null): string {
  if (id === null) return "null";
  return id.slice(0, 8);
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
