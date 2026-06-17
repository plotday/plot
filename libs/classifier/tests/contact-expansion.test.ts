import { describe, expect, it } from "vitest";

import { scoringStage } from "../src/ts-hybrid-scoring";
import { buildAliasMap, expandWithAliasMap } from "../src/ts-hybrid-contacts";
import { DEFAULTS, type HybridParams } from "../src/ts-hybrid.defaults";
import type { Candidate, ClassifierContext } from "../src/types";

/**
 * The scoring stage used to call public.expand_contacts(mt.contacts) once per
 * training row (1500+ non-inlinable STABLE SQL function calls per classify
 * job), which crossed the 30s statement_timeout for large training sets. These
 * tests pin the replacement: one batched alias lookup, expanded in JS, with
 * IDENTICAL semantics to expand_contacts (raw contacts ∪ linked aliases,
 * deduped) — so no explicit classification is dropped.
 */

function recordingCtx(rows: unknown[]): {
  ctx: ClassifierContext;
  calls: { text: string; values?: unknown[] }[];
} {
  const calls: { text: string; values?: unknown[] }[] = [];
  const ctx: ClassifierContext = {
    db: {} as ClassifierContext["db"],
    userId: "00000000-0000-0000-0000-000000000001",
    schemaName: "public",
    corpusName: "test",
    rawQuery: async (text, values) => {
      calls.push({ text, values });
      return { rows };
    },
  };
  return { ctx, calls };
}

describe("expandWithAliasMap", () => {
  it("returns [] for no contacts", () => {
    expect(expandWithAliasMap([], new Map())).toEqual([]);
  });

  it("returns the raw contacts (deduped) when there are no aliases", () => {
    const r = expandWithAliasMap(["a", "a", "b"], new Map());
    expect(r).toHaveLength(2);
    expect(new Set(r)).toEqual(new Set(["a", "b"]));
  });

  it("unions raw contacts with their linked aliases, deduped", () => {
    const map = new Map([
      ["a", ["x", "y"]],
      ["b", ["x"]],
    ]);
    const r = expandWithAliasMap(["a", "b"], map);
    expect(r).toHaveLength(4); // shared alias x not duplicated
    expect(new Set(r)).toEqual(new Set(["a", "b", "x", "y"]));
  });

  it("does not duplicate an alias that equals a raw contact", () => {
    const map = new Map([["a", ["b"]]]);
    const r = expandWithAliasMap(["a", "b"], map);
    expect(r).toHaveLength(2);
    expect(new Set(r)).toEqual(new Set(["a", "b"]));
  });
});

describe("buildAliasMap", () => {
  it("issues no query and returns an empty map for no contacts", async () => {
    const { ctx, calls } = recordingCtx([]);
    const map = await buildAliasMap(ctx, []);
    expect(map.size).toBe(0);
    expect(calls).toHaveLength(0);
  });

  it("looks up the distinct input contacts in one round trip", async () => {
    const { ctx, calls } = recordingCtx([]);
    await buildAliasMap(ctx, ["a", "a", "b"]);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.values?.[0]).toEqual(["a", "b"]); // deduped input set
  });

  it("groups multiple aliases (incl. a contact linked under two users) per input", async () => {
    const { ctx } = recordingCtx([
      { input: "a", alias: "x" },
      { input: "a", alias: "y" },
      { input: "b", alias: "z" },
    ]);
    const map = await buildAliasMap(ctx, ["a", "b"]);
    expect(new Set(map.get("a"))).toEqual(new Set(["x", "y"]));
    expect(map.get("b")).toEqual(["z"]);
  });
});

// --- Integration: the scoring stage must keep alias-expanding both sides ---

function scoringCtx(): {
  ctx: ClassifierContext;
  calls: { text: string; values?: unknown[] }[];
} {
  const calls: { text: string; values?: unknown[] }[] = [];
  const ctx: ClassifierContext = {
    db: {} as ClassifierContext["db"],
    userId: "00000000-0000-0000-0000-000000000001",
    schemaName: "public",
    corpusName: "test",
    rawQuery: async (text, values) => {
      calls.push({ text, values });
      if (text.includes("FROM public.thread_priority")) {
        // One training neighbor whose RAW contact (cB) is a linked alias of
        // the candidate's RAW contact (cA) — they only overlap after expansion.
        return {
          rows: [
            {
              priority_id: "p1",
              thread_id: "n1",
              title: null,
              topic: null,
              created_by: null,
              conn_id: null,
              contacts: ["cB"],
              groups: [],
              embedding: null,
            },
          ],
        };
      }
      if (text.includes("FROM public.user_contact")) {
        // cA and cB are linked aliases of the same human.
        return {
          rows: [
            { input: "cA", alias: "cB" },
            { input: "cB", alias: "cA" },
          ],
        };
      }
      if (text.includes("thread_facets_gated")) {
        return { rows: [{ pid: "p1", gated: false }] };
      }
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

describe("scoringStage batched contact expansion", () => {
  it("alias-expands BOTH neighbor and candidate contacts so con(jaccard) reflects linked aliases", async () => {
    const { ctx } = scoringCtx();
    const out = await scoringStage(ctx, candidate(), conOnly);
    // Expanded sets: candidate {cA,cB}, neighbor {cB,cA} → jaccard = 1.
    // Without expanding the neighbor it would be jaccard({cB},{cA,cB}) = 0.5;
    // without expanding either side, jaccard({cA},{cB}) = 0.
    expect(out.explain.topNeighbors[0]?.con).toBe(1);
    expect(out.matched).toBe(true);
    if (out.matched) expect(out.priorityId).toBe("p1");
  });

  it("does not call expand_contacts per training row — uses one batched user_contact lookup", async () => {
    const { ctx, calls } = scoringCtx();
    await scoringStage(ctx, candidate(), conOnly);
    const main = calls.find((c) =>
      c.text.includes("FROM public.thread_priority")
    );
    expect(main?.text).not.toContain("expand_contacts");
    const aliasLookups = calls.filter((c) =>
      c.text.includes("FROM public.user_contact")
    );
    expect(aliasLookups).toHaveLength(1);
  });
});
