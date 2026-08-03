import { describe, expect, it } from "vitest";
import { mapWithConcurrency } from "./concurrency";

describe("mapWithConcurrency", () => {
  it("returns results in input order regardless of completion order", async () => {
    const delays = [30, 0, 15];
    const result = await mapWithConcurrency(delays, 3, async (ms, i) => {
      await new Promise((r) => setTimeout(r, ms));
      return i;
    });
    expect(result).toEqual([0, 1, 2]);
  });

  it("never runs more than `limit` mappers at once", async () => {
    let inFlight = 0;
    let peak = 0;
    await mapWithConcurrency([1, 2, 3, 4, 5, 6, 7], 3, async () => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight--;
      return null;
    });
    expect(peak).toBe(3);
  });

  it("resolves to an empty array for empty input", async () => {
    expect(await mapWithConcurrency([], 5, async () => 1)).toEqual([]);
  });
});
