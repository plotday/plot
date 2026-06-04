import { describe, it, expect } from "vitest";

import {
  utf8ByteLength,
  buildSizeAwareBatches,
  splitBatch,
} from "./twist-sync-batching";

describe("utf8ByteLength", () => {
  it("counts ASCII as one byte per char", () => {
    expect(utf8ByteLength("abc")).toBe(3);
    expect(utf8ByteLength("")).toBe(0);
  });

  it("counts multibyte characters by their UTF-8 byte length, not UTF-16 units", () => {
    // These are the cases that the old `String.prototype.length` accounting got
    // wrong: Cloudflare Queues limit by UTF-8 bytes, but `.length` counts UTF-16
    // code units, undercounting non-ASCII content.
    expect(utf8ByteLength("é")).toBe(2); // .length === 1
    expect(utf8ByteLength("中")).toBe(3); // .length === 1
    expect(utf8ByteLength("😀")).toBe(4); // .length === 2

    const multibyte = "中".repeat(1000);
    expect(multibyte.length).toBe(1000);
    expect(utf8ByteLength(multibyte)).toBe(3000);
    expect(utf8ByteLength(multibyte)).toBeGreaterThan(multibyte.length);
  });
});

describe("buildSizeAwareBatches", () => {
  it("packs items up to the byte budget", () => {
    const items = [
      { id: "a", size: 40 },
      { id: "b", size: 40 },
      { id: "c", size: 40 },
    ];
    const batches = buildSizeAwareBatches(items, 100, 12);
    expect(batches).toEqual([
      [
        { id: "a", size: 40 },
        { id: "b", size: 40 },
      ],
      [{ id: "c", size: 40 }],
    ]);
  });

  it("caps each batch at the item count limit", () => {
    const items = Array.from({ length: 5 }, (_, i) => ({ id: String(i), size: 1 }));
    const batches = buildSizeAwareBatches(items, 1_000_000, 2);
    expect(batches.map((b) => b.length)).toEqual([2, 2, 1]);
  });

  it("always allows at least one item per batch, even when oversized", () => {
    // A single item larger than the budget must still form its own batch rather
    // than be dropped — the caller handles oversized singletons separately.
    const items = [
      { id: "huge", size: 500 },
      { id: "small", size: 10 },
    ];
    const batches = buildSizeAwareBatches(items, 100, 12);
    expect(batches).toEqual([[{ id: "huge", size: 500 }], [{ id: "small", size: 10 }]]);
  });

  it("returns no batches for an empty input", () => {
    expect(buildSizeAwareBatches([], 100, 12)).toEqual([]);
  });
});

describe("splitBatch", () => {
  it("splits a batch into two halves", () => {
    expect(splitBatch([1, 2, 3, 4])).toEqual([
      [1, 2],
      [3, 4],
    ]);
    expect(splitBatch([1, 2, 3])).toEqual([[1], [2, 3]]);
  });

  it("keeps the single element on the right when splitting a 1-item batch", () => {
    expect(splitBatch([1])).toEqual([[], [1]]);
  });
});
