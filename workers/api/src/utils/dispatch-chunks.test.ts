import { describe, it, expect, vi } from "vitest";

import { dispatchInChunks, FAN_OUT_DISPATCH } from "./dispatch-chunks";

describe("dispatchInChunks", () => {
  it("invokes fn for every item exactly once, with the correct index", async () => {
    const items = ["a", "b", "c", "d", "e"];
    const seen: Array<[string, number]> = [];
    await dispatchInChunks(
      items,
      async (item, index) => {
        seen.push([item, index]);
      },
      { chunkSize: 2, gapMs: 0 }
    );
    expect(seen).toEqual([
      ["a", 0],
      ["b", 1],
      ["c", 2],
      ["d", 3],
      ["e", 4],
    ]);
  });

  it("never runs more than chunkSize invocations concurrently", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const items = Array.from({ length: 25 }, (_, i) => i);
    await dispatchInChunks(
      items,
      async () => {
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        // Yield so concurrent members of a chunk overlap before any resolves.
        await Promise.resolve();
        await Promise.resolve();
        inFlight--;
      },
      { chunkSize: 8, gapMs: 0 }
    );
    expect(maxInFlight).toBeLessThanOrEqual(8);
    expect(maxInFlight).toBeGreaterThan(1); // proves it actually parallelizes within a chunk
  });

  it("returns settled results in input order, preserving rejections", async () => {
    const results = await dispatchInChunks(
      [1, 2, 3, 4],
      async (n) => {
        if (n % 2 === 0) throw new Error(`boom ${n}`);
        return n * 10;
      },
      { chunkSize: 2, gapMs: 0 }
    );
    expect(results.map((r) => r.status)).toEqual([
      "fulfilled",
      "rejected",
      "fulfilled",
      "rejected",
    ]);
    expect(results[0]).toMatchObject({ status: "fulfilled", value: 10 });
    expect(results[2]).toMatchObject({ status: "fulfilled", value: 30 });
  });

  it("processes a fan-out larger than chunkSize across multiple chunks with a gap", async () => {
    const items = Array.from({ length: 23 }, (_, i) => i);
    const settled = await dispatchInChunks(items, async (n) => n, {
      chunkSize: 10,
      gapMs: 1,
    });
    expect(settled).toHaveLength(23);
    expect(settled.every((r) => r.status === "fulfilled")).toBe(true);
  });

  it("does not wait after the final chunk (gap only between chunks)", async () => {
    const setTimeoutSpy = vi.spyOn(globalThis, "setTimeout");
    // 10 items, chunkSize 10 => exactly one chunk => no gap timer at all.
    await dispatchInChunks(
      Array.from({ length: 10 }, (_, i) => i),
      async (n) => n,
      { chunkSize: 10, gapMs: 250 }
    );
    expect(setTimeoutSpy).not.toHaveBeenCalled();
    setTimeoutSpy.mockRestore();
  });

  it("handles an empty list without invoking fn", async () => {
    const fn = vi.fn(async (n: number) => n);
    const results = await dispatchInChunks([], fn, { chunkSize: 10, gapMs: 0 });
    expect(results).toEqual([]);
    expect(fn).not.toHaveBeenCalled();
  });

  it("rejects an invalid chunkSize", async () => {
    await expect(
      dispatchInChunks([1], async (n) => n, { chunkSize: 0, gapMs: 0 })
    ).rejects.toThrow("chunkSize must be >= 1");
  });

  it("FAN_OUT_DISPATCH leaves a normal small fan-out in one chunk (no delay)", () => {
    // A typical user has only a handful of twists, so the common case must not
    // incur a gap. Guard the invariant that chunkSize comfortably exceeds that.
    expect(FAN_OUT_DISPATCH.chunkSize).toBeGreaterThanOrEqual(10);
    expect(FAN_OUT_DISPATCH.gapMs).toBeGreaterThan(0);
  });
});
