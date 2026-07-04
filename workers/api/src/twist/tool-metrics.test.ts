import { describe, expect, it } from "vitest";

import { formatToolMetrics } from "./tool-metrics";

describe("formatToolMetrics", () => {
  it("returns an empty object for null/empty metrics", () => {
    expect(formatToolMetrics(null)).toEqual({});
    expect(formatToolMetrics(undefined)).toEqual({});
    expect(formatToolMetrics({})).toEqual({});
  });

  it("computes totals and passes through the per-method breakdown", () => {
    const out = formatToolMetrics({
      "Store.set": { n: 800, ms: 240_000, max: 900 },
      "Integrations.saveLink": { n: 20, ms: 60_000, max: 8_000 },
    });

    expect(out.tool_calls_count).toBe(820);
    expect(out.tool_calls_total_ms).toBe(300_000);
    expect(out.tool_calls).toEqual({
      "Store.set": { n: 800, ms: 240_000, max: 900 },
      "Integrations.saveLink": { n: 20, ms: 60_000, max: 8_000 },
    });
    expect(out.tool_calls_truncated).toBeUndefined();
  });

  it("caps the breakdown to the top entries by total duration", () => {
    const metrics = Object.fromEntries(
      Array.from({ length: 30 }, (_, i) => [
        `Tool.method${i}`,
        { n: 1, ms: i, max: i },
      ])
    );

    const out = formatToolMetrics(metrics);
    const breakdown = out.tool_calls as Record<string, { ms: number }>;

    expect(Object.keys(breakdown)).toHaveLength(20);
    // Top by ms: method29 down to method10.
    expect(breakdown["Tool.method29"]).toBeDefined();
    expect(breakdown["Tool.method9"]).toBeUndefined();
    expect(out.tool_calls_truncated).toBe(10);
    // Totals still cover ALL entries, not just the surfaced top.
    expect(out.tool_calls_count).toBe(30);
  });

  it("ignores malformed entries", () => {
    const out = formatToolMetrics({
      "Store.set": { n: 1, ms: 5, max: 5 },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      broken: { n: "x" } as any,
    });
    expect(out.tool_calls_count).toBe(1);
    expect((out.tool_calls as object)["broken" as keyof object]).toBeUndefined();
  });
});
