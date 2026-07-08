import { describe, it, expect } from "vitest";

import { runPool } from "../lib/pool";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("runPool", () => {
  it("preserves result order", async () => {
    const results = await runPool([3, 1, 2], 2, async (n) => {
      await sleep(n * 10);
      return n * 2;
    });
    expect(results).toEqual([6, 2, 4]);
  });

  it("never exceeds the concurrency limit", async () => {
    let active = 0;
    let peak = 0;
    await runPool([1, 2, 3, 4, 5, 6], 2, async () => {
      active++;
      peak = Math.max(peak, active);
      await sleep(20);
      active--;
    });
    expect(peak).toBe(2);
  });

  it("handles an empty list", async () => {
    expect(await runPool([], 3, async () => 1)).toEqual([]);
  });
});
