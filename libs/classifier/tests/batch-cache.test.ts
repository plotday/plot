import { describe, expect, it, vi } from "vitest";

import { cachedUserRead } from "../src/ts-hybrid-cache";
import { scoringStage } from "../src/ts-hybrid-scoring";
import { fetchPriorityHierarchies } from "../src/ts-hybrid-accounts";
import { DEFAULTS, type HybridParams } from "../src/ts-hybrid.defaults";
import type {
  Candidate,
  ClassifierBatchCache,
  ClassifierContext,
} from "../src/types";

/**
 * The classify queue consumer processes a batch of threads, and an hourly
 * sweep enqueues hundreds of ONE user's pending threads contiguously — so a
 * batch is dominated by a single user. Several reads in the cascade are
 * user-scoped and stable for the life of a batch (the user_moved training set,
 * the negative set, the user's focuses/role hierarchies, linked contacts,
 * account→hierarchy affinity). Re-issuing them once per thread is what made the
 * scoring path saturate the DB under load (PostHog 019ed53e). These tests pin
 * the per-batch memo that loads each of them once per (user, batch).
 */

const USER = "00000000-0000-0000-0000-000000000001";
const OTHER = "00000000-0000-0000-0000-000000000002";

function ctxWith(
  batchCache: ClassifierBatchCache | undefined,
  userId = USER
): ClassifierContext {
  return {
    db: {} as ClassifierContext["db"],
    userId,
    schemaName: "public",
    corpusName: "test",
    rawQuery: async () => ({ rows: [] }),
    batchCache,
  };
}

describe("cachedUserRead", () => {
  it("runs the loader once per (user, key) when a batch cache is present", async () => {
    const cache: ClassifierBatchCache = new Map();
    const loader = vi.fn(async () => "v");
    const ctx = ctxWith(cache);

    const a = await cachedUserRead(ctx, "k", loader);
    const b = await cachedUserRead(ctx, "k", loader);

    expect(a).toBe("v");
    expect(b).toBe("v");
    expect(loader).toHaveBeenCalledTimes(1);
  });

  it("keys by user so two users in one batch don't share results", async () => {
    const cache: ClassifierBatchCache = new Map();
    const loader = vi.fn(async (who: string) => who);

    const u1 = await cachedUserRead(ctxWith(cache, USER), "k", () =>
      loader(USER)
    );
    const u2 = await cachedUserRead(ctxWith(cache, OTHER), "k", () =>
      loader(OTHER)
    );

    expect(u1).toBe(USER);
    expect(u2).toBe(OTHER);
    expect(loader).toHaveBeenCalledTimes(2);
  });

  it("runs the loader every call when no batch cache is wired in (eval/tests unchanged)", async () => {
    const loader = vi.fn(async () => "v");
    const ctx = ctxWith(undefined);

    await cachedUserRead(ctx, "k", loader);
    await cachedUserRead(ctx, "k", loader);

    expect(loader).toHaveBeenCalledTimes(2);
  });

  it("memoizes a rejection for the batch so a saturated read isn't re-issued by every thread", async () => {
    // Under saturation the first thread's read times out (57014). Caching the
    // rejection makes the rest of that user's batch fail fast and defer to the
    // sweep, instead of each re-issuing the same 30s-timing-out query and
    // piling more load onto the already-overloaded backend.
    const cache: ClassifierBatchCache = new Map();
    const loader = vi.fn(async () => {
      throw new Error("57014");
    });
    const ctx = ctxWith(cache);

    await expect(cachedUserRead(ctx, "k", loader)).rejects.toThrow("57014");
    await expect(cachedUserRead(ctx, "k", loader)).rejects.toThrow("57014");
    expect(loader).toHaveBeenCalledTimes(1);
  });
});

// --- Integration: the cascade's user-scoped reads honor the batch cache ---

const trainingFetch = (t: string) =>
  t.includes("FROM public.thread_priority") &&
  t.includes("user_moved = TRUE") &&
  t.includes("AS embedding");

const hierarchyFetch = (t: string) =>
  t.includes("FROM public.priority p") && t.includes("LEFT JOIN public.role");

function recordingCtx(batchCache?: ClassifierBatchCache): {
  ctx: ClassifierContext;
  calls: string[];
} {
  const calls: string[] = [];
  const ctx: ClassifierContext = {
    db: {} as ClassifierContext["db"],
    userId: USER,
    schemaName: "public",
    corpusName: "test",
    batchCache,
    rawQuery: async (text) => {
      calls.push(text);
      return { rows: [] };
    },
  };
  return { ctx, calls };
}

const conOnly: HybridParams = {
  ...DEFAULTS,
  weights: { sem: 0, con: 1, grp: 0, author: 0, topic_fuzzy: 0, title: 0 },
  nonlinearity: "identity",
  aggregation: { mode: "top1" },
  scoreThreshold: 0,
  originBonus: { exact: 0, org: 0 },
  negativePenaltyWeight: 0,
  priorityTitleMatchWeight: 0,
  accountHierarchyBonusWeight: 0,
};

function candidate(): Candidate {
  return {
    threadId: "cand",
    title: "x",
    topic: null,
    contacts: ["cA"],
    groups: [],
    embedding: null,
    author: null,
    facets: null,
    authorContactId: null,
    connectionId: null,
  };
}

describe("scoringStage honors the batch cache", () => {
  it("fetches the training set once across candidates that share a batch cache", async () => {
    const { ctx, calls } = recordingCtx(new Map());
    await scoringStage(ctx, candidate(), conOnly);
    await scoringStage(ctx, candidate(), conOnly);
    expect(calls.filter(trainingFetch)).toHaveLength(1);
  });

  it("fetches the training set per candidate when there is no batch cache (unchanged)", async () => {
    const { ctx, calls } = recordingCtx(undefined);
    await scoringStage(ctx, candidate(), conOnly);
    await scoringStage(ctx, candidate(), conOnly);
    expect(calls.filter(trainingFetch)).toHaveLength(2);
  });
});

describe("fetchPriorityHierarchies honors the batch cache", () => {
  it("loads the user's hierarchies once across a shared batch cache", async () => {
    const { ctx, calls } = recordingCtx(new Map());
    await fetchPriorityHierarchies(ctx);
    await fetchPriorityHierarchies(ctx);
    expect(calls.filter(hierarchyFetch)).toHaveLength(1);
  });
});
