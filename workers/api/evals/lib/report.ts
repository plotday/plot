import type { GenerateAttemptEvent } from "../../src/twist/generator";
import type { RunResults, SpecResult, TokenTotals } from "./types";

// USD per million tokens. Estimates for reporting only — update as pricing
// moves; unknown models fall back to the default model's rates.
const MODEL_RATES: Record<
  string,
  { input: number; output: number; cacheRead: number; cacheWrite: number }
> = {
  "claude-sonnet-4-6": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  // Gemini list prices (estimates as of 2026-07). Implicit caching bills
  // cached input at ~25% of the input rate; there is no separate write
  // charge, so cacheWrite mirrors the input rate (and is always 0 tokens
  // for gemini in practice — extractUsage only sets it for anthropic).
  "gemini-3-pro-preview": { input: 2, output: 12, cacheRead: 0.5, cacheWrite: 2 },
  "gemini-3.1-pro-preview": { input: 2, output: 12, cacheRead: 0.5, cacheWrite: 2 },
  "gemini-3-flash-preview": { input: 0.3, output: 2.5, cacheRead: 0.075, cacheWrite: 0.3 },
};
const DEFAULT_RATES = MODEL_RATES["gemini-3.1-pro-preview"];

export function sumTokens(events: GenerateAttemptEvent[]): TokenTotals {
  const totals: TokenTotals = { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 };
  for (const event of events) {
    if (event.type !== "llm_complete" || !event.usage) continue;
    totals.input += event.usage.inputTokens ?? 0;
    totals.output += event.usage.outputTokens ?? 0;
    totals.cacheRead += event.usage.cacheReadInputTokens ?? 0;
    totals.cacheWrite += event.usage.cacheCreationInputTokens ?? 0;
  }
  return totals;
}

export function estimateCostUsd(tokens: TokenTotals, model: string): number {
  const rates = MODEL_RATES[model] ?? DEFAULT_RATES;
  const freshInput = Math.max(0, tokens.input - tokens.cacheRead - tokens.cacheWrite);
  return (
    (freshInput * rates.input +
      tokens.cacheRead * rates.cacheRead +
      tokens.cacheWrite * rates.cacheWrite +
      tokens.output * rates.output) /
    1_000_000
  );
}

function percentile(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null;
  const index = Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1);
  return sorted[Math.max(0, index)];
}

const PIPELINE_RESOLVED: ReadonlySet<SpecResult["status"]> = new Set([
  "pass",
  "assertion_failed",
  "typecheck_failed",
]);

export function computeAggregates(specs: SpecResult[]): RunResults["aggregates"] {
  const counted = specs.filter((s) => s.status !== "infra");
  const latencies = counted.map((s) => s.durations.totalMs).sort((a, b) => a - b);
  const attempts = counted.filter((s) => s.attemptsUsed > 0);
  const taxonomy: Record<string, number> = {};
  for (const s of specs) {
    if (s.failureClass) taxonomy[s.failureClass] = (taxonomy[s.failureClass] ?? 0) + 1;
  }
  return {
    pipelinePassRate: counted.length
      ? counted.filter((s) => PIPELINE_RESOLVED.has(s.status)).length / counted.length
      : null,
    fullPassRate: counted.length
      ? counted.filter((s) => s.status === "pass").length / counted.length
      : null,
    meanAttempts: attempts.length
      ? attempts.reduce((sum, s) => sum + s.attemptsUsed, 0) / attempts.length
      : null,
    latencyMs: { median: percentile(latencies, 0.5), p95: percentile(latencies, 0.95) },
    totalCostUsd: specs.reduce((sum, s) => sum + s.estimatedCostUsd, 0),
    taxonomy,
  };
}

export function buildRunResults(input: {
  label: string;
  model: string;
  startedAt: string;
  flags: RunResults["flags"];
  specs: SpecResult[];
}): RunResults {
  return {
    schemaVersion: 1,
    startedAt: input.startedAt,
    label: input.label,
    model: input.model,
    flags: input.flags,
    specs: input.specs,
    aggregates: computeAggregates(input.specs),
  };
}

const secs = (ms: number | null) => (ms == null ? "n/a" : (ms / 1000).toFixed(1));
const secsList = (list: number[]) => list.map((ms) => (ms / 1000).toFixed(1)).join("+");
const pct = (x: number | null) => (x == null ? "n/a" : `${Math.round(x * 100)}%`);

export function renderScorecard(r: RunResults): string {
  const lines: string[] = [];
  lines.push(`# Twist generation eval — ${r.label}`);
  lines.push(`model: ${r.model} · started: ${r.startedAt} · specs: ${r.specs.length}`);
  lines.push("");
  lines.push(
    "| spec | run | status | fail class | attempts | retries | total s | llm s | build s | out tok | cost $ |"
  );
  lines.push("|---|---|---|---|---|---|---|---|---|---|---|");
  for (const s of r.specs) {
    lines.push(
      `| ${s.id} | ${s.run} | ${s.status} | ${s.failureClass ?? ""} | ${s.attemptsUsed} | ${
        s.llmRetries
      } | ${secs(s.durations.totalMs)} | ${secsList(s.durations.llmMs)} | ${secsList(
        s.durations.buildMs
      )} | ${s.tokens.output} | ${s.estimatedCostUsd.toFixed(2)} |`
    );
  }
  const a = r.aggregates;
  lines.push("");
  lines.push(
    `pipeline pass rate: ${pct(a.pipelinePassRate)} · full pass rate: ${pct(a.fullPassRate)}`
  );
  lines.push(
    `mean attempts: ${a.meanAttempts?.toFixed(2) ?? "n/a"} · latency median: ${secs(
      a.latencyMs.median
    )}s · p95: ${secs(a.latencyMs.p95)}s`
  );
  lines.push(`total est. cost: $${a.totalCostUsd.toFixed(2)}`);
  lines.push(
    `taxonomy: ${
      Object.entries(a.taxonomy)
        .map(([k, v]) => `${k}=${v}`)
        .join(", ") || "none"
    }`
  );
  return lines.join("\n");
}

export function renderCompare(current: RunResults, baseline: RunResults): string {
  const key = (s: SpecResult) => `${s.id}#${s.run}`;
  const base = new Map(baseline.specs.map((s) => [key(s), s]));
  const lines: string[] = [];
  const regressions: string[] = [];
  lines.push(`# Compare vs ${baseline.label} (${baseline.startedAt})`);
  lines.push("");
  lines.push("| spec | run | status | baseline | Δ total s | corpus |");
  lines.push("|---|---|---|---|---|---|");
  for (const s of current.specs) {
    const b = base.get(key(s));
    const drift = b && b.corpusHash !== s.corpusHash ? "CHANGED" : "";
    const delta = b ? ((s.durations.totalMs - b.durations.totalMs) / 1000).toFixed(1) : "";
    lines.push(`| ${s.id} | ${s.run} | ${s.status} | ${b?.status ?? "—"} | ${delta} | ${drift} |`);
    if (b && b.status === "pass" && s.status !== "pass") {
      regressions.push(`${s.id} (${b.status} → ${s.status})`);
    }
  }
  lines.push("");
  lines.push(regressions.length ? `REGRESSIONS: ${regressions.join(", ")}` : "No regressions.");
  const deltaPp = (x: number | null, y: number | null) =>
    x != null && y != null ? `${((x - y) * 100).toFixed(0)}pp` : "n/a";
  lines.push(
    `pipeline pass: ${pct(current.aggregates.pipelinePassRate)} (Δ ${deltaPp(
      current.aggregates.pipelinePassRate,
      baseline.aggregates.pipelinePassRate
    )}) · full pass: ${pct(current.aggregates.fullPassRate)} (Δ ${deltaPp(
      current.aggregates.fullPassRate,
      baseline.aggregates.fullPassRate
    )})`
  );
  return lines.join("\n");
}
