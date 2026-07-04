import type { ToolCallMetrics } from "./entrypoint";

/** Max distinct "ToolId.method" entries included in a boundary log. */
const MAX_TOOL_METRIC_ENTRIES = 20;

/**
 * Shape per-invocation tool-call metrics into structured log fields for the
 * twist boundary logs ("Twist callback RPC finished" / "Twist dispatch
 * finished"):
 *
 * - `tool_calls_count` / `tool_calls_total_ms` — scalars for cheap
 *   aggregation ("how much of this invocation was tool round-trips").
 * - `tool_calls` — the per-method breakdown (top entries by total duration),
 *   e.g. `{ "Store.set": { n: 800, ms: 240000, max: 900 } }`, which is what
 *   explains a multi-minute sync pass.
 *
 * Returns an empty object when there are no metrics so callers can spread the
 * result unconditionally.
 */
export function formatToolMetrics(
  metrics: ToolCallMetrics | null | undefined
): Record<string, unknown> {
  if (!metrics) return {};
  const entries = Object.entries(metrics).filter(
    ([, value]) =>
      value &&
      typeof value.n === "number" &&
      typeof value.ms === "number" &&
      typeof value.max === "number"
  );
  if (entries.length === 0) return {};

  let totalCount = 0;
  let totalMs = 0;
  for (const [, value] of entries) {
    totalCount += value.n;
    totalMs += value.ms;
  }

  entries.sort(([, a], [, b]) => b.ms - a.ms);
  const top = entries.slice(0, MAX_TOOL_METRIC_ENTRIES);

  return {
    tool_calls_count: totalCount,
    tool_calls_total_ms: totalMs,
    tool_calls: Object.fromEntries(top),
    ...(entries.length > top.length
      ? { tool_calls_truncated: entries.length - top.length }
      : {}),
  };
}
