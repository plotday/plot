import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import {
  DEFAULT_GENERATION_MODEL,
  generateTwist,
  type GenerateAttemptEvent,
} from "../src/twist/generator";
import type { Bindings } from "../src/env";
import type { TwistSource } from "../src/twist/types";
import { runChecks } from "./lib/checks";
import { classifyGenerationError } from "./lib/classify";
import { parseCliArgs, type CliOptions } from "./lib/cli";
import { loadCorpus } from "./lib/corpus";
import {
  assertDockerAvailable,
  buildImage,
  findFreePort,
  startContainer,
  stopContainer,
  waitForHealth,
} from "./lib/docker";
import { assertRequiredVars, buildEvalEnv, loadDevVars } from "./lib/env";
import { runPool } from "./lib/pool";
import { RESULTS_DIR, TWISTER_DIST } from "./lib/paths";
import { buildRunResults, estimateCostUsd, renderCompare, renderScorecard, sumTokens } from "./lib/report";
import {
  EvalInfraError,
  EvalTimeoutError,
  type CorpusSpec,
  type FailureClass,
  type RunResults,
  type SpecResult,
  type SpecStatus,
} from "./lib/types";

const SPEC_TIMEOUT_MS = 10 * 60_000;

const log = (message: string) => console.log(`[eval] ${message}`);

async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new EvalTimeoutError(ms)), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

interface SpecExecution {
  result: SpecResult;
  source?: TwistSource;
}

async function runSpec(
  spec: CorpusSpec,
  runIndex: number,
  env: Bindings,
  model: string
): Promise<SpecExecution> {
  const events: GenerateAttemptEvent[] = [];
  const startedAt = Date.now();
  let source: TwistSource | undefined;
  let status: SpecStatus;
  let failureClass: FailureClass | null = null;
  let finalBuildClass: SpecResult["finalBuildClass"] = null;
  let failureDetail: string | null = null;
  let assertionFailures: string[] = [];

  try {
    source = await withTimeout(
      generateTwist({
        spec: spec.body,
        env,
        model,
        onEvent: (e) => events.push(e),
        skipGatewayCache: true,
      }),
      SPEC_TIMEOUT_MS
    );
    const outcome = await runChecks(spec, source);
    status = outcome.status;
    if (outcome.status === "assertion_failed") {
      failureClass = "assertion_failed";
      assertionFailures = outcome.assertionFailures;
      failureDetail = outcome.assertionFailures.join("; ").slice(0, 500);
    } else if (outcome.status === "typecheck_failed") {
      failureClass = "typecheck_failed";
      failureDetail = outcome.typecheckErrors.join("\n").slice(0, 500);
    }
  } catch (error) {
    if (error instanceof EvalTimeoutError) {
      status = "timeout";
      failureClass = "timeout";
      failureDetail = error.message;
    } else if (error instanceof EvalInfraError) {
      status = "infra";
      failureClass = "infra";
      failureDetail = error.message.slice(0, 500);
    } else {
      const c = classifyGenerationError(error, events);
      status = c.failureClass === "infra" ? "infra" : "generation_failed";
      failureClass = c.failureClass;
      finalBuildClass = c.finalBuildClass ?? null;
      failureDetail = c.detail;
    }
  }

  const tokens = sumTokens(events);
  return {
    source,
    result: {
      id: spec.id,
      category: spec.category,
      difficulty: spec.difficulty,
      corpusHash: spec.corpusHash,
      run: runIndex,
      status,
      failureClass,
      finalBuildClass,
      failureDetail,
      assertionFailures,
      attemptsUsed: events.filter((e) => e.type === "attempt_start").length,
      llmRetries: events.filter((e) => e.type === "llm_retry").length,
      durations: {
        totalMs: Date.now() - startedAt,
        llmMs: events.filter((e) => e.type === "llm_complete").map((e) => e.durationMs),
        buildMs: events.filter((e) => e.type === "build_complete").map((e) => e.durationMs),
      },
      tokens,
      estimatedCostUsd: estimateCostUsd(tokens, model),
      extraDeps: source
        ? Object.keys(source.dependencies).filter((d) => d !== "@plotday/twister")
        : [],
      files: source ? Object.keys(source.files) : [],
    },
  };
}

function selectSpecs(corpus: CorpusSpec[], only: string | null): CorpusSpec[] {
  if (!only) return corpus;
  const wanted = new Set(only.split(",").map((s) => s.trim()).filter(Boolean));
  const selected = corpus.filter((s) => wanted.has(s.id) || wanted.has(s.category));
  if (selected.length === 0) {
    throw new EvalInfraError(
      `--only matched nothing. Available: ${corpus
        .map((s) => `${s.id} (${s.category})`)
        .join(", ")}`
    );
  }
  return selected;
}

function timestamp(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
}

async function saveOutputs(
  results: RunResults,
  executions: SpecExecution[],
  opts: CliOptions,
  stamp: string
): Promise<string> {
  await mkdir(RESULTS_DIR, { recursive: true });
  const safeLabel = results.label.replace(/[^A-Za-z0-9._-]+/g, "-");
  const basename = `${stamp}-${safeLabel}`;
  const resultsPath = join(RESULTS_DIR, `${basename}.json`);
  await writeFile(resultsPath, JSON.stringify(results, null, 2), "utf-8");
  if (opts.keepOutput) {
    for (const execution of executions) {
      if (!execution.source) continue;
      const dir = join(
        RESULTS_DIR,
        `${basename}.sources`,
        `${execution.result.id}.run${execution.result.run}`
      );
      await mkdir(dir, { recursive: true });
      for (const [name, content] of Object.entries(execution.source.files)) {
        const filePath = join(dir, name);
        await mkdir(dirname(filePath), { recursive: true });
        await writeFile(filePath, content, "utf-8");
      }
    }
  }
  return resultsPath;
}

async function main(): Promise<void> {
  const opts = parseCliArgs(process.argv.slice(2));
  const corpus = await loadCorpus();

  if (opts.list) {
    for (const spec of corpus) {
      console.log(`${spec.id}\t${spec.category}\t${spec.difficulty}`);
    }
    return;
  }

  // Preflight — fail fast with actionable messages.
  assertDockerAvailable();
  const vars = loadDevVars();
  const model = opts.model ?? DEFAULT_GENERATION_MODEL;
  assertRequiredVars(vars, model);
  if (!existsSync(join(TWISTER_DIST, "index.d.ts"))) {
    throw new EvalInfraError(
      "public/twister/dist is missing — run 'cd public/twister && pnpm build'"
    );
  }
  const selected = selectSpecs(corpus, opts.only);
  const label = opts.label ?? model;

  log(`building container image…`);
  buildImage();
  const port = await findFreePort();
  const containerName = startContainer(port);
  const cleanup = () => stopContainer(containerName);
  process.on("SIGINT", () => {
    cleanup();
    process.exit(130);
  });

  try {
    await waitForHealth(port);
    log(`container ready on :${port} — ${selected.length} spec(s) × ${opts.runs} run(s), model ${model}`);
    const env = buildEvalEnv(vars, port) as unknown as Bindings;
    const startedAt = new Date().toISOString();
    const stamp = timestamp();
    const executions: SpecExecution[] = [];

    for (let run = 1; run <= opts.runs; run++) {
      let remaining = [...selected];
      if (run === 1 && remaining.length > 1) {
        // Warm the Anthropic prompt cache with one solo spec so concurrent
        // first calls don't all pay the cache write.
        const [first, ...rest] = remaining;
        log(`warmup: ${first.id}`);
        const execution = await runSpec(first, run, env, model);
        log(`done: ${first.id} → ${execution.result.status}`);
        executions.push(execution);
        remaining = rest;
      }
      const results = await runPool(remaining, opts.concurrency, async (spec) => {
        log(`running: ${spec.id} (run ${run})`);
        const execution = await runSpec(spec, run, env, model);
        log(`done: ${spec.id} → ${execution.result.status}`);
        return execution;
      });
      executions.push(...results);
    }

    const results = buildRunResults({
      label,
      model,
      startedAt,
      flags: { concurrency: opts.concurrency, runs: opts.runs, only: opts.only },
      specs: executions.map((e) => e.result),
    });
    const resultsPath = await saveOutputs(results, executions, opts, stamp);

    console.log("");
    console.log(renderScorecard(results));
    console.log("");
    log(`results written to ${resultsPath}`);

    if (opts.compare) {
      try {
        const baseline = JSON.parse(await readFile(opts.compare, "utf-8")) as RunResults;
        console.log("");
        console.log(renderCompare(results, baseline));
      } catch (error) {
        log(
          `WARN: could not load baseline ${opts.compare}: ${
            error instanceof Error ? error.message : String(error)
          }`
        );
      }
    }
  } finally {
    cleanup();
  }
}

main().catch((error: unknown) => {
  console.error(`[eval] FATAL: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
