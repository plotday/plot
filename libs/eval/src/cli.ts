#!/usr/bin/env tsx
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import { listClassifiers } from "./classifiers/registry";
import { runEval } from "./runner/run";
import { formatReport, type ReportFormat } from "./scoring/report";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

async function main() {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      "corpus-dir": { type: "string" },
      classifiers: { type: "string" },
      "training-sets": { type: "string" },
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

  const classifierNames = (values.classifiers ?? "ts:hybrid-llm:default").split(",");
  const trainingSets = values["training-sets"]
    ? values["training-sets"].split(",")
    : undefined;
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

  console.log(formatReport(corpus, summary, results, format));

  const hasRegression = summary.perClassifierTraining.some((c) => c.regressions > 0);
  process.exit(hasRegression ? 1 : 0);
}

function printHelp() {
  console.log(`Usage: pnpm --filter @plotday/eval eval -- [options]

Options:
  --corpus <name>           Corpus under libs/eval/corpora/<name>
  --corpus-dir <path>       Absolute path to a corpus directory (overrides --corpus)
  --classifiers <list>      Comma-separated classifier names (default: ts:hybrid-llm:default)
  --training-sets <list>    Comma-separated training-set names (default: all)
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
