#!/usr/bin/env tsx
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import {
  getVariantParams,
  listClassifiers,
  makeAdhocLlmVariant,
  makeAdhocVariantFromFile,
} from "./classifiers/registry";
import {
  buildBaseline,
  compareToBaseline,
  parseBaselineFile,
  type BaselineFile,
} from "./runner/baseline";
import { runEval } from "./runner/run";
import { parseSweepSpec } from "./runner/sweep";
import {
  buildLeaderboard,
  formatReport,
  renderBaselineComparison,
  renderLeaderboard,
  type BaselineContext,
  type ReportFormat,
} from "./scoring/report";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

async function main() {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      "corpus-dir": { type: "string" },
      classifiers: { type: "string" },
      params: { type: "string" },
      sweep: { type: "string" },
      base: { type: "string" },
      "training-sets": { type: "string" },
      baseline: { type: "string" },
      "save-baseline": { type: "string" },
      "exclude-tags": { type: "string" },
      "include-holdout": { type: "boolean" },
      format: { type: "string" },
      "list-classifiers": { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
    allowPositionals: false,
  });

  if (values.help) {
    printHelp();
    return;
  }

  if (values["list-classifiers"]) {
    console.log(listClassifiers().join("\n"));
    return;
  }

  if (!values.corpus && !values["corpus-dir"]) {
    console.error("Error: --corpus <name> or --corpus-dir <path> required.");
    printHelp();
    process.exit(2);
  }

  const corpusDir =
    values["corpus-dir"] ??
    resolve(SCRIPT_DIR, "..", "corpora", values.corpus!);

  let classifierNames = (values.classifiers ?? "ts:hybrid-llm:default").split(",");
  // Sweep state: base name + variant-name → point-label map for the leaderboard.
  let sweepBase: string | null = null;
  let sweepLabels: Map<string, string> | null = null;
  if (values.sweep) {
    if (values.params) {
      console.error("Error: --sweep and --params are mutually exclusive.");
      process.exit(2);
    }
    if (values.classifiers) {
      console.error(
        "Error: --sweep builds its own classifier list (base + grid points); use --base, not --classifiers."
      );
      process.exit(2);
    }
    sweepBase = values.base ?? "ts:hybrid-llm:default";
    const points = parseSweepSpec(values.sweep, getVariantParams(sweepBase));
    sweepLabels = new Map([[sweepBase, "base"]]);
    classifierNames = [sweepBase];
    for (const point of points) {
      const variant = makeAdhocLlmVariant(point.overrides, sweepBase);
      // Identical override sets (e.g. a point that re-states base values
      // alongside a duplicate) collapse to one variant name — run it once.
      if (!sweepLabels.has(variant.name)) {
        classifierNames.push(variant.name);
        sweepLabels.set(variant.name, point.label);
      }
    }
  } else if (values.params) {
    // One-off variant: base params + JSON-file overrides, registered as
    // <base>+params@<hash> and appended to this run's classifier list.
    const adhoc = makeAdhocVariantFromFile(values.params, values.base);
    classifierNames.push(adhoc.name);
  } else if (values.base) {
    console.error("Error: --base requires --params <file.json> or --sweep <spec>.");
    process.exit(2);
  }
  const trainingSets = values["training-sets"]
    ? values["training-sets"].split(",")
    : undefined;
  if (values["save-baseline"]) {
    // A baseline snapshots exactly one (classifier, trainingSet) combo. Catch
    // what is knowable before the run; the default all-training-sets case is
    // only countable after loadCorpus, so buildBaseline re-validates below.
    if (values.sweep) {
      console.error("Error: --save-baseline and --sweep are mutually exclusive.");
      process.exit(2);
    }
    if (classifierNames.length > 1) {
      console.error(
        `Error: --save-baseline requires exactly one classifier; got ${classifierNames.length} (${classifierNames.join(", ")}).`
      );
      process.exit(2);
    }
    if (trainingSets && trainingSets.length > 1) {
      console.error(
        `Error: --save-baseline requires exactly one training set; got ${trainingSets.length} (${trainingSets.join(", ")}).`
      );
      process.exit(2);
    }
  }
  // holdout-move cases are excluded from every run unless --include-holdout;
  // --exclude-tags appends more excluded tags.
  const extraExcludes = (values["exclude-tags"] ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
  const excludeTags = values["include-holdout"]
    ? extraExcludes
    : ["holdout-move", ...extraExcludes];
  const format = ((values.format as ReportFormat) ?? "console") as ReportFormat;

  const { corpus, results, summary } = await runEval({
    corpusDir,
    classifiers: classifierNames,
    trainingSets,
    excludeTags,
  });

  if (values["save-baseline"]) {
    try {
      const snapshot = buildBaseline(results);
      writeFileSync(
        values["save-baseline"],
        JSON.stringify(snapshot, null, 2) + "\n"
      );
      // stderr so --format json keeps a clean stdout.
      console.error(
        `[eval] baseline saved to ${values["save-baseline"]} (${results.length} cases).`
      );
    } catch (err) {
      console.error(
        `Error: ${err instanceof Error ? err.message : String(err)}`
      );
      process.exit(2);
    }
  }

  // --baseline: compare this run's results for the snapshot's
  // (classifier, trainingSet) combo against the saved predictions.
  let baselineCtx: BaselineContext | null = null;
  if (values.baseline) {
    let file: BaselineFile;
    try {
      file = parseBaselineFile(readFileSync(values.baseline, "utf8"));
    } catch (err) {
      console.error(
        `Error reading baseline ${values.baseline}: ${err instanceof Error ? err.message : String(err)}`
      );
      process.exit(2);
    }
    if (file.meta.corpus !== corpus.name) {
      console.error(
        `[eval] warning: baseline corpus "${file.meta.corpus}" differs from this run's corpus "${corpus.name}".`
      );
    }
    const matching = results.filter(
      (r) =>
        r.classifier === file.meta.classifier &&
        r.trainingSet === file.meta.trainingSet
    );
    if (matching.length === 0) {
      const combos = [
        ...new Set(results.map((r) => `${r.classifier} / ${r.trainingSet}`)),
      ].sort();
      console.error(
        `Error: baseline is for (${file.meta.classifier}, ${file.meta.trainingSet}) ` +
          `but this run produced no results for that combo. ` +
          `Run combos: ${combos.join("; ")}.`
      );
      process.exit(2);
    }
    baselineCtx = {
      file,
      results: matching,
      comparison: compareToBaseline(file, matching),
    };
  }

  if (sweepBase !== null && sweepLabels !== null) {
    const leaderboard = buildLeaderboard(results, sweepBase, sweepLabels);
    if (format === "json") {
      console.log(
        JSON.stringify(
          {
            summary,
            results,
            sweep: leaderboard,
            ...(baselineCtx
              ? {
                  baselineComparison: {
                    meta: baselineCtx.file.meta,
                    ...baselineCtx.comparison,
                  },
                }
              : {}),
          },
          null,
          2
        )
      );
    } else {
      console.log(renderLeaderboard(leaderboard));
      if (baselineCtx) {
        console.log("");
        console.log(renderBaselineComparison(baselineCtx, corpus));
      }
    }
  } else {
    console.log(formatReport(corpus, summary, results, format, baselineCtx));
  }

  const hasRegression = summary.perClassifierTraining.some((c) => c.regressions > 0);
  process.exit(hasRegression ? 1 : 0);
}

function printHelp() {
  console.log(`Usage: pnpm --filter @plotday/eval eval -- [options]

Options:
  --corpus <name>           Corpus under libs/eval/corpora/<name>
  --corpus-dir <path>       Absolute path to a corpus directory (overrides --corpus)
  --classifiers <list>      Comma-separated classifier names (default: ts:hybrid-llm:default)
  --params <file.json>      JSON object of HybridParams overrides; registers an
                            ad-hoc variant named <base>+params@<hash> and adds
                            it to this run's classifier list
  --sweep "<spec>"          Grid sweep: ;-separated dimensions, each
                            path=start:end:step (inclusive numeric range) or
                            path=v1|v2|v3 (list). Runs base + every grid point
                            in one eval and prints a leaderboard (gold accuracy
                            with Wilson 95% CI, fixed/broke + exact McNemar p
                            vs base, live token sums). weights.<k> dimensions
                            renormalize the other weight components so the sum
                            stays 1; at most one weights.* dimension per spec.
                            Mutually exclusive with --params/--classifiers.
                            Example: --sweep "scoreThreshold=0.05:0.2:0.05;aggregation.mode=top1|softmax"
  --base <variant>          Base variant for --params/--sweep overrides
                            (default: ts:hybrid-llm:default)
  --training-sets <list>    Comma-separated training-set names (default: all)
  --save-baseline <file>    After the run, write a per-case prediction snapshot
                            as pretty-printed JSON. Requires exactly one
                            classifier and one training set; mutually
                            exclusive with --sweep
  --baseline <file>         Compare this run against a saved snapshot for the
                            snapshot's (classifier, training set) combo and
                            report fixed/broke/changed cases with an exact
                            McNemar p (attached as baselineComparison in
                            --format json)
  --exclude-tags <csv>      Additional case tags to exclude (appended to the
                            default holdout-move exclusion)
  --include-holdout         Include cases tagged holdout-move (excluded by default)
  --format <console|json|markdown>
                            Output format (default: console)
  --list-classifiers        Print registered classifier names and exit
  -h, --help                Show this help

Environment:
  DATABASE_URL              Postgres connection string (required)
`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
