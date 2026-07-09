import { describe, it, expect } from "vitest";

import {
  buildRunResults,
  computeAggregates,
  estimateCostUsd,
  renderCompare,
  renderScorecard,
  sumTokens,
} from "../lib/report";
import type { SpecResult } from "../lib/types";

function spec(overrides: Partial<SpecResult>): SpecResult {
  return {
    id: "s",
    category: "smoke",
    difficulty: "easy",
    corpusHash: "h",
    run: 1,
    status: "pass",
    failureClass: null,
    finalBuildClass: null,
    failureDetail: null,
    assertionFailures: [],
    attemptsUsed: 1,
    llmRetries: 0,
    durations: { totalMs: 60_000, llmMs: [50_000], buildMs: [10_000] },
    tokens: { input: 1000, cacheRead: 0, cacheWrite: 0, output: 500 },
    estimatedCostUsd: 0.01,
    extraDeps: [],
    files: ["index.ts"],
    ...overrides,
  };
}

describe("sumTokens", () => {
  it("sums usage across llm_complete events", () => {
    expect(
      sumTokens([
        { type: "attempt_start", attempt: 1 },
        {
          type: "llm_complete",
          attempt: 1,
          durationMs: 1,
          usage: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 7 },
        },
        {
          type: "llm_complete",
          attempt: 2,
          durationMs: 1,
          usage: { inputTokens: 20, outputTokens: 5, cacheCreationInputTokens: 3 },
        },
      ])
    ).toEqual({ input: 30, cacheRead: 7, cacheWrite: 3, output: 10 });
  });
});

describe("estimateCostUsd", () => {
  it("prices sonnet tokens per MTok with cache rates", () => {
    // 1M fresh input at $3 + 1M output at $15 = $18
    expect(
      estimateCostUsd(
        { input: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 1_000_000 },
        "claude-sonnet-4-6"
      )
    ).toBeCloseTo(18, 5);
    // input fully cache-read: 1M at $0.30
    expect(
      estimateCostUsd(
        { input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0, output: 0 },
        "claude-sonnet-4-6"
      )
    ).toBeCloseTo(0.3, 5);
  });

  it("prices gemini pro tokens", () => {
    // 1M fresh input at $2 + 1M output at $12 = $14
    expect(
      estimateCostUsd(
        { input: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 1_000_000 },
        "gemini-3-pro-preview"
      )
    ).toBeCloseTo(14, 5);
  });
});

describe("computeAggregates", () => {
  it("computes pass rates excluding infra, taxonomy, latency", () => {
    const a = computeAggregates([
      spec({ id: "a", status: "pass" }),
      spec({ id: "b", status: "typecheck_failed", failureClass: "typecheck_failed" }),
      spec({
        id: "c",
        status: "generation_failed",
        failureClass: "max_attempts_exhausted",
      }),
      spec({ id: "d", status: "infra", failureClass: "infra" }),
    ]);
    expect(a.pipelinePassRate).toBeCloseTo(2 / 3, 5); // a + b resolved; c did not; d excluded
    expect(a.fullPassRate).toBeCloseTo(1 / 3, 5);
    expect(a.taxonomy).toEqual({
      typecheck_failed: 1,
      max_attempts_exhausted: 1,
      infra: 1,
    });
    expect(a.latencyMs.median).toBe(60_000);
  });

  it("returns nulls for an empty run", () => {
    const a = computeAggregates([]);
    expect(a.pipelinePassRate).toBeNull();
    expect(a.fullPassRate).toBeNull();
    expect(a.latencyMs.median).toBeNull();
  });
});

describe("rendering", () => {
  const results = buildRunResults({
    label: "test",
    model: "claude-sonnet-4-6",
    startedAt: "2026-07-07T00:00:00Z",
    flags: { concurrency: 3, runs: 1, only: null },
    specs: [spec({ id: "a" }), spec({ id: "b", status: "typecheck_failed", failureClass: "typecheck_failed" })],
  });

  it("scorecard includes per-spec rows and aggregate lines", () => {
    const out = renderScorecard(results);
    expect(out).toContain("| a | 1 | pass |");
    expect(out).toContain("| b | 1 | typecheck_failed |");
    expect(out).toContain("pipeline pass rate: 100%");
    expect(out).toContain("full pass rate: 50%");
  });

  it("scorecard shows the retries column", () => {
    const out = renderScorecard(
      buildRunResults({
        label: "t",
        model: "m",
        startedAt: "2026-07-09T00:00:00Z",
        flags: { concurrency: 1, runs: 1, only: null },
        specs: [spec({ id: "r", llmRetries: 2 })],
      })
    );
    expect(out).toContain("| retries |");
    expect(out).toContain("| r | 1 | pass |  | 1 | 2 |");
  });

  it("compare flags regressions and corpus drift", () => {
    const baseline = buildRunResults({
      label: "base",
      model: "claude-sonnet-4-6",
      startedAt: "2026-07-06T00:00:00Z",
      flags: { concurrency: 3, runs: 1, only: null },
      specs: [spec({ id: "a" }), spec({ id: "b", corpusHash: "other" })],
    });
    const out = renderCompare(results, baseline);
    expect(out).toContain("REGRESSIONS: b (pass → typecheck_failed)");
    expect(out).toContain("CHANGED"); // b's corpusHash differs
  });
});
