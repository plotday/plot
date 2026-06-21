import { describe, it, expect, vi, beforeEach } from "vitest";

import { TRAINING_READ_KEY, userReadCacheKey } from "@plotday/classifier";
import type { ClassifierBatchCache } from "@plotday/classifier";

import {
  primeTrainingCache,
  resetTrainingCacheForTests,
  TRAINING_CACHE_TTL_MS,
} from "./training-cache";

type RawQuery = (
  text: string,
  values?: unknown[]
) => Promise<{ rows: unknown[] }>;

const U1 = "user-1";
const U2 = "user-2";

function trainingRow(threadId: string) {
  return {
    priority_id: "p1",
    thread_id: threadId,
    title: "t",
    topic: null,
    created_by: null,
    conn_id: null,
    contacts: [],
    groups: [],
    embedding: null,
  };
}

beforeEach(() => resetTrainingCacheForTests());

describe("primeTrainingCache", () => {
  it("fetches the training set once and reuses it across batches within the TTL", async () => {
    const rawQuery = vi.fn<RawQuery>(async () => ({ rows: [trainingRow("a")] }));

    const batch1: ClassifierBatchCache = new Map();
    primeTrainingCache(rawQuery, batch1, [{ userId: U1, threadId: "c1" }], 1000);
    const batch2: ClassifierBatchCache = new Map();
    primeTrainingCache(rawQuery, batch2, [{ userId: U1, threadId: "c2" }], 2000);

    // One DB fetch shared by both batches.
    expect(rawQuery).toHaveBeenCalledTimes(1);
    const rows1 = (await batch1.get(
      userReadCacheKey(U1, TRAINING_READ_KEY)
    )) as unknown[];
    const rows2 = (await batch2.get(
      userReadCacheKey(U1, TRAINING_READ_KEY)
    )) as unknown[];
    expect(rows1).toHaveLength(1);
    expect(rows2).toBe(rows1); // same cached array
  });

  it("refetches once the TTL has expired", async () => {
    const rawQuery = vi.fn<RawQuery>(async () => ({ rows: [trainingRow("a")] }));

    primeTrainingCache(rawQuery, new Map(), [{ userId: U1, threadId: "c1" }], 1000);
    primeTrainingCache(
      rawQuery,
      new Map(),
      [{ userId: U1, threadId: "c2" }],
      1000 + TRAINING_CACHE_TTL_MS + 1
    );

    expect(rawQuery).toHaveBeenCalledTimes(2);
  });

  it("fetches each user in a batch independently", async () => {
    const rawQuery = vi.fn<RawQuery>(async () => ({ rows: [] }));
    primeTrainingCache(
      rawQuery,
      new Map(),
      [
        { userId: U1, threadId: "c1" },
        { userId: U2, threadId: "c2" },
      ],
      1000
    );
    expect(rawQuery).toHaveBeenCalledTimes(2);
  });

  it("does not cache a failed fetch, so the next batch retries", async () => {
    const rawQuery = vi
      .fn<RawQuery>()
      .mockRejectedValueOnce(new Error("57014"))
      .mockResolvedValueOnce({ rows: [trainingRow("a")] });

    const batch1: ClassifierBatchCache = new Map();
    primeTrainingCache(rawQuery, batch1, [{ userId: U1, threadId: "c1" }], 1000);
    // The first batch's primed read rejects — scoringStage defers, as today.
    await expect(
      batch1.get(userReadCacheKey(U1, TRAINING_READ_KEY))
    ).rejects.toThrow("57014");

    // Still within the TTL, but the failure was evicted: the next batch refetches.
    const batch2: ClassifierBatchCache = new Map();
    primeTrainingCache(rawQuery, batch2, [{ userId: U1, threadId: "c2" }], 1500);
    const rows = (await batch2.get(
      userReadCacheKey(U1, TRAINING_READ_KEY)
    )) as unknown[];
    expect(rows).toHaveLength(1);
    expect(rawQuery).toHaveBeenCalledTimes(2);
  });
});
