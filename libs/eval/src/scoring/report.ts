import { getVariantParams } from "../classifiers/registry";
import type { Corpus } from "../corpus/schema";
import type { BaselineComparison, BaselineFile } from "../runner/baseline";
import type { RunResult, RunSummary } from "../runner/run";
import { estimateCostUsd } from "./cost";
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
        renderMarkdown(corpus, summary, results, lookup) +
        (baseline
          ? "\n\n" + renderBaselineComparison(baseline, corpus)
          : "")
      );
    case "console":
    default:
      return (
        renderConsole(corpus, summary, results, lookup) +
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
  corpus: Corpus,
  summary: RunSummary,
  results: RunResult[],
  lookup: PriorityLookup
): string {
  const lines: string[] = [];
  lines.push(headerLine(corpus, summary));
  lines.push(...warningLines(corpus, results));
  const selfExcluded = new Set(
    results.filter((r) => r.selfExcluded).map((r) => r.caseId)
  ).size;
  if (selfExcluded > 0) {
    lines.push(
      `Self-exclusions: ${selfExcluded} case(s) had their source thread archived out of the training set (anti-leakage guard).`
    );
  }
  lines.push("");
  lines.push(...summaryTable(summary));

  lines.push("");
  lines.push("Stage breakdown:");
  for (const [key, rows, acc] of stageBreakdownRows(results)) {
    lines.push(`  ${key.padEnd(48)} ${rows.length.toString().padStart(4)} cases   gold=${pct(acc)}`);
  }

  for (const section of detailSections(results)) {
    lines.push("");
    lines.push(...section);
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
  corpus: Corpus,
  summary: RunSummary,
  results: RunResult[],
  lookup: PriorityLookup
): string {
  const lines: string[] = [];
  lines.push(`# Eval report — ${summary.corpus}`);
  lines.push("");
  lines.push(headerLine(corpus, summary));
  for (const w of warningLines(corpus, results)) {
    lines.push("");
    lines.push(`**${w}**`);
  }
  lines.push("");
  lines.push(
    "| Classifier | Training set | Gold acc. [95% CI] | Expected acc. | Regressions | LLM calls / case | Cache hit rate | Avg ms |"
  );
  lines.push("| --- | --- | --- | --- | --- | --- | --- | --- |");
  for (const c of summary.perClassifierTraining) {
    lines.push(
      `| \`${c.classifier}\` | \`${c.trainingSet}\` | ${goldCell(c)} | ${pct(c.expectedAccuracy)} | ${c.regressions} | ${c.llmCallsPerCase.toFixed(2)} | ${pct(c.llmCacheHitRate)} | ${c.avgDurationMs.toFixed(1)} |`
    );
  }
  lines.push("");

  // Stage breakdown table
  lines.push("## Stage breakdown");
  lines.push("");
  lines.push("| Stage | Cases | Gold acc. |");
  lines.push("| --- | --- | --- |");
  for (const [key, rows, acc] of stageBreakdownRows(results)) {
    lines.push(`| \`${key}\` | ${rows.length} | ${pct(acc).trim()} |`);
  }
  lines.push("");

  // Flips table (only when multiple training sets produced differing predictions)
  const trainingSets = [
    ...new Set(summary.perClassifierTraining.map((r) => r.trainingSet)),
  ];
  if (trainingSets.length >= 2) {
    const flipRows = renderFlipsMarkdown(summary, results, lookup);
    if (flipRows.length > 0) {
      lines.push("## Predictions that vary across training sets");
      lines.push("");
      lines.push(`| Classifier | Case | ${trainingSets.map((t) => `\`${t}\``).join(" | ")} |`);
      lines.push(`| --- | --- | ${trainingSets.map(() => "---").join(" | ")} |`);
      for (const row of flipRows) lines.push(row);
      lines.push("");
    }
  }

  const sections = detailSections(results);
  if (sections.length > 0) {
    lines.push("## Details");
    lines.push("");
    lines.push("```");
    sections.forEach((section, i) => {
      if (i > 0) lines.push("");
      lines.push(...section);
    });
    lines.push("```");
    lines.push("");
  }

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

// ---------------------------------------------------------------------------
// Shared report sections (console + markdown)
// ---------------------------------------------------------------------------

/** `Corpus: <name> (<prod-extract|handcrafted>, N cases)`. */
function headerLine(corpus: Corpus, summary: RunSummary): string {
  return `Corpus: ${summary.corpus} (${corpus.world.source.kind}, ${summary.totalCases} cases)`;
}

/**
 * Prominent warnings rendered right under the header: synthetic-corpus
 * provenance (handcrafted results must never be pooled with prod-extract
 * numbers) and LLM budget exhaustion (results were measured with a silently
 * degraded cascade).
 */
function warningLines(corpus: Corpus, results: RunResult[]): string[] {
  const lines: string[] = [];
  if (corpus.world.source.kind === "handcrafted") {
    lines.push(
      "WARNING: synthetic corpus (handcrafted) — do not pool with real-data results."
    );
  }
  const exhausted = results.filter((r) => r.budgetExhausted);
  if (exhausted.length > 0) {
    const perClassifier = [...groupBy(exhausted, (r) => r.classifier)]
      .map(([classifier, rows]) => `${classifier}=${rows.length}`)
      .join(", ");
    lines.push(
      `WARNING: LLM budget exhausted on ${exhausted.length} result(s) (${perClassifier}) — those cases fell back to deterministic stages.`
    );
  }
  return lines;
}

/** Summary table with a Wilson 95% CI on every gold-accuracy figure. */
function summaryTable(summary: RunSummary): string[] {
  const headers = [
    "Classifier",
    "Training",
    "Gold acc [95% CI]",
    "Expected",
    "Regress",
    "LLM/case",
    "Hit%",
    "AvgMs",
  ];
  const cells = summary.perClassifierTraining.map((c) => [
    c.classifier,
    c.trainingSet,
    goldCell(c),
    pctCell(c.expectedAccuracy),
    String(c.regressions),
    c.llmCallsPerCase.toFixed(2),
    pctCell(c.llmCacheHitRate),
    c.avgDurationMs.toFixed(1),
  ]);
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...cells.map((row) => row[i]!.length))
  );
  const fmt = (row: string[]) =>
    row
      .map((c, i) => (i < 2 ? c.padEnd(widths[i]!) : c.padStart(widths[i]!)))
      .join("  ")
      .trimEnd();
  return [
    fmt(headers),
    fmt(widths.map((w) => "-".repeat(w))),
    ...cells.map(fmt),
  ];
}

function goldCell(
  c: RunSummary["perClassifierTraining"][number]
): string {
  if (c.goldAccuracy === null || c.goldEvaluated === 0) return "n/a";
  const ci = wilsonInterval(c.goldCorrect, c.goldEvaluated);
  return `${pctCell(c.goldAccuracy)} ${ciCell(ci)}`;
}

/**
 * Optional detail sections, in render order. Each entry is a non-empty block
 * of lines; the console renderer separates them with blank lines and the
 * markdown renderer wraps them in a fenced block.
 */
function detailSections(results: RunResult[]): string[][] {
  const sections = [
    llmUsageSection(results),
    rankOfGoldSection(results),
    tagSection(results),
    goldSourceSection(results),
  ].filter((s) => s.length > 0);
  if (new Set(results.map((r) => r.trainingSizeAtCase)).size > 1) {
    sections.push(renderTrajectory(results).split("\n"));
  }
  return sections;
}

/**
 * Per (classifier, trainingSet): live/replayed token totals, calls without
 * usage data, and an estimated USD cost of the live calls. The model is
 * resolved from the variant's registered HybridParams (`params.llm.model`);
 * classifiers without registered params (e.g. sql:current) or with unpriced
 * models render "(cost unknown)" rather than a misleading $0.
 */
function llmUsageSection(results: RunResult[]): string[] {
  const lines: string[] = [];
  for (const [key, rows] of groupBy(
    results,
    (r) => `${r.classifier} / ${r.trainingSet}`
  )) {
    const withUsage = rows.filter((r) => r.llmUsage);
    if (withUsage.length === 0) continue;
    const sum = (f: (u: NonNullable<RunResult["llmUsage"]>) => number) =>
      withUsage.reduce((s, r) => s + f(r.llmUsage!), 0);
    const liveIn = sum((u) => u.liveInputTokens);
    const liveOut = sum((u) => u.liveOutputTokens);
    const repIn = sum((u) => u.replayedInputTokens);
    const repOut = sum((u) => u.replayedOutputTokens);
    const unknown = sum((u) => u.unknownCalls);
    const model = modelFor(rows[0]!.classifier);
    const cost =
      model === null
        ? null
        : estimateCostUsd(model, {
            inputTokens: liveIn,
            outputTokens: liveOut,
          });
    const costStr = cost === null ? "(cost unknown)" : `$${cost.toFixed(4)}`;
    lines.push(
      `  [${key}] live in/out=${liveIn}/${liveOut}  replayed in/out=${repIn}/${repOut}  unknown=${unknown}  est. live cost ${costStr}`
    );
  }
  if (lines.length === 0) return [];
  return ["LLM tokens & estimated cost:", ...lines];
}

/** LLM model for a classifier name, or null when not resolvable. */
function modelFor(classifier: string): string | null {
  try {
    return getVariantParams(classifier).llm?.model ?? null;
  } catch {
    // Registered without HybridParams (sql:current, test stubs) or unknown.
    return null;
  }
}

/**
 * Per (classifier, trainingSet) over gold-labeled cases: top-3 hit rate and
 * MRR (mean of 1/rank). Both use cases WITH a ranking as the denominator —
 * stages that carry no ranking (topic_shortcircuit, sql:current, …) are
 * excluded and surfaced via the `unranked` count instead.
 */
function rankOfGoldSection(results: RunResult[]): string[] {
  const lines: string[] = [];
  for (const [key, rows] of groupBy(
    results,
    (r) => `${r.classifier} / ${r.trainingSet}`
  )) {
    const goldLabeled = rows.filter((r) => r.goldId !== null);
    if (goldLabeled.length === 0) continue;
    const ranked = goldLabeled.filter((r) => r.rankOfGold !== null);
    const unranked = goldLabeled.length - ranked.length;
    const top3 = ranked.filter((r) => r.rankOfGold! <= 3).length;
    const top3Str =
      ranked.length > 0
        ? `${pctCell(top3 / ranked.length)} (${top3}/${ranked.length} ranked)`
        : "n/a (0/0 ranked)";
    const mrr =
      ranked.length > 0
        ? (
            ranked.reduce((s, r) => s + 1 / r.rankOfGold!, 0) / ranked.length
          ).toFixed(3)
        : "n/a";
    lines.push(`  [${key}] top-3 ${top3Str}  MRR ${mrr}  unranked=${unranked}`);
  }
  if (lines.length === 0) return [];
  return [
    "Rank of gold (gold-labeled cases; rates over ranked cases only):",
    ...lines,
  ];
}

/** Gold accuracy + CI + n per case tag, per combo. Empty when nothing is tagged. */
function tagSection(results: RunResult[]): string[] {
  if (!results.some((r) => r.tags.length > 0)) return [];
  const lines: string[] = [];
  for (const [key, rows] of groupBy(
    results,
    (r) => `${r.classifier} / ${r.trainingSet}`
  )) {
    const tagged = rows.filter(
      (r) => r.goldMatch !== null && r.tags.length > 0
    );
    if (tagged.length === 0) continue;
    const tags = [...new Set(tagged.flatMap((r) => r.tags))].sort();
    const width = Math.max(...tags.map((t) => t.length));
    lines.push(`  [${key}]`);
    for (const tag of tags) {
      const slice = tagged.filter((r) => r.tags.includes(tag));
      lines.push(
        `    ${tag.padEnd(width)}  ${accuracyWithCi(slice)}  n=${slice.length}`
      );
    }
  }
  if (lines.length === 0) return [];
  return ["Gold accuracy by tag:", ...lines];
}

/**
 * Gold accuracy split by gold-label provenance (human vs llm-proposed).
 * Rendered only when both kinds exist — with a single kind the split is the
 * overall accuracy and would just be noise.
 */
function goldSourceSection(results: RunResult[]): string[] {
  const kinds = new Set(
    results.map((r) => r.goldSource).filter((s) => s !== null)
  );
  if (kinds.size < 2) return [];
  const lines: string[] = [];
  for (const [key, rows] of groupBy(
    results,
    (r) => `${r.classifier} / ${r.trainingSet}`
  )) {
    const evaluated = rows.filter(
      (r) => r.goldMatch !== null && r.goldSource !== null
    );
    if (evaluated.length === 0) continue;
    lines.push(`  [${key}]`);
    for (const source of ["human", "llm-proposed"] as const) {
      const slice = evaluated.filter((r) => r.goldSource === source);
      if (slice.length === 0) continue;
      lines.push(
        `    ${source.padEnd(12)}  ${accuracyWithCi(slice)}  n=${slice.length}`
      );
    }
  }
  if (lines.length === 0) return [];
  return ["Gold accuracy by gold source (human vs llm-proposed):", ...lines];
}

/**
 * `66.7% [49.0–80.9]` over rows that all have goldMatch !== null.
 * Returns "n/a" when the slice is empty (no pre-condition on caller).
 */
function accuracyWithCi(rows: RunResult[]): string {
  if (rows.length === 0) return "n/a";
  const correct = rows.filter((r) => r.goldMatch).length;
  return `${pctCell(correct / rows.length)} ${ciCell(wilsonInterval(correct, rows.length))}`;
}

function ciCell(ci: { lo: number; hi: number }): string {
  return `[${(ci.lo * 100).toFixed(1)}–${(ci.hi * 100).toFixed(1)}]`;
}

const TRAJECTORY_BUCKETS: { label: string; lo: number; hi: number }[] = [
  { label: "0", lo: 0, hi: 0 },
  { label: "1–5", lo: 1, hi: 5 },
  { label: "6–15", lo: 6, hi: 15 },
  { label: "16–30", lo: 16, hi: 30 },
  { label: "31+", lo: 31, hi: Infinity },
];

/**
 * Backtest trajectory: gold accuracy bucketed by how many training threads
 * were available when the case ran (trainingSizeAtCase), per classifier
 * (training sets pool — a backtest replays one growing set). formatReport
 * includes this section only when sizes actually vary; backtest runners
 * (--mode backtest) can call it directly.
 */
export function renderTrajectory(results: RunResult[]): string {
  const headers = ["Classifier", ...TRAJECTORY_BUCKETS.map((b) => b.label)];
  const cells: string[][] = [];
  for (const [classifier, rows] of groupBy(results, (r) => r.classifier)) {
    const goldEval = rows.filter((r) => r.goldMatch !== null);
    cells.push([
      classifier,
      ...TRAJECTORY_BUCKETS.map((b) => {
        const slice = goldEval.filter(
          (r) => r.trainingSizeAtCase >= b.lo && r.trainingSizeAtCase <= b.hi
        );
        if (slice.length === 0) return "-";
        const correct = slice.filter((r) => r.goldMatch).length;
        return `${pctCell(correct / slice.length)} (${slice.length})`;
      }),
    ]);
  }
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...cells.map((row) => row[i]!.length))
  );
  const fmt = (row: string[]) =>
    "  " + row.map((c, i) => c.padEnd(widths[i]!)).join("  ").trimEnd();
  return [
    "Training-size trajectory (gold accuracy by training threads available at case time):",
    fmt(headers),
    ...cells.map(fmt),
  ].join("\n");
}

/**
 * Shared stage-breakdown data: yields [key, rows, goldAccuracy|null] tuples
 * in insertion order so both console and markdown renderers stay in sync.
 */
function stageBreakdownRows(
  results: RunResult[]
): [string, RunResult[], number | null][] {
  const breakdown = groupBy(
    results,
    (r) => `${r.classifier} / ${r.trainingSet} → ${r.stage}`
  );
  return [...breakdown].map(([key, rows]) => {
    const goldEval = rows.filter((r) => r.goldMatch !== null);
    const acc =
      goldEval.length > 0
        ? goldEval.filter((r) => r.goldMatch).length / goldEval.length
        : null;
    return [key, rows, acc];
  });
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

/**
 * Markdown table rows (no header) for the flips section. Returns one row per
 * (classifier, case) pair where predictions differ across training sets. The
 * caller is responsible for emitting the header row using the same `trainingSets`
 * order from `summary.perClassifierTraining`.
 */
function renderFlipsMarkdown(
  summary: RunSummary,
  results: RunResult[],
  lookup: PriorityLookup
): string[] {
  const trainingSets = [
    ...new Set(summary.perClassifierTraining.map((r) => r.trainingSet)),
  ];
  if (trainingSets.length < 2) return [];

  const rows: string[] = [];
  for (const [classifier, cRows] of groupBy(results, (r) => r.classifier)) {
    for (const [caseId, caseRows] of groupBy(cRows, (r) => r.caseId)) {
      const cells = new Map<string, string | null>();
      for (const r of caseRows) cells.set(r.trainingSet, r.predicted);
      const distinct = new Set(cells.values());
      if (distinct.size <= 1) continue;
      const cols = trainingSets
        .map((t) => name(cells.get(t) ?? null, lookup))
        .join(" | ");
      rows.push(`| \`${classifier}\` | \`${caseId}\` | ${cols} |`);
    }
  }
  return rows;
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

/** Like pct() but without legacy left-padding (for dynamic-width tables). */
function pctCell(v: number | null): string {
  if (v === null) return "n/a";
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
