import { describe, expect, it } from "vitest";

import {
  DEFAULTS,
  originBonus,
  scoringStage,
  type Candidate,
  type ClassifierContext,
  type HybridParams,
} from "@plotday/classifier";

const USER = "user-1";
const P1 = "priority-1";
const P2 = "priority-2";
const CONN_A = "conn-a";
const CONN_B = "conn-b";

// top1 aggregation + all post-aggregation bonuses off so origin/gate effects
// are directly observable; only three queries remain reachable: neighbors,
// connection_org_key, thread_facets_gated.
const PARAMS: HybridParams = {
  ...DEFAULTS,
  aggregation: { mode: "top1" },
  priorityTitleMatchWeight: 0,
  accountHierarchyBonusWeight: 0,
  negativePenaltyWeight: 0,
};

type Route = { match: string; rows: (values: unknown[]) => unknown[] };

function fakeCtx(routes: Route[], queries: string[] = []): ClassifierContext {
  return {
    db: undefined as never,
    rawQuery: async (text: string, values?: unknown[]) => {
      queries.push(text);
      const route = routes.find((r) => text.includes(r.match));
      if (!route) throw new Error(`fakeCtx: unmatched query: ${text.slice(0, 100)}`);
      return { rows: route.rows(values ?? []) };
    },
    userId: USER,
    schemaName: "public",
    corpusName: "test",
  };
}

function neighbor(priorityId: string, threadId: string, connId: string | null) {
  return {
    priority_id: priorityId,
    thread_id: threadId,
    title: null,
    topic: null,
    created_by: connId,
    contacts_expanded: [],
    groups: [],
    embedding: null,
    conn_id: connId,
  };
}

const orgKeys = (map: Record<string, string | null>): Route => ({
  match: "connection_org_key",
  rows: (v) => (v[0] as string[]).map((id) => ({ conn_id: id, org_key: map[id] ?? null })),
});

const gate = (gatedIds: string[]): Route => ({
  match: "thread_facets_gated",
  rows: (v) => (v[3] as string[]).map((pid) => ({ pid, gated: gatedIds.includes(pid) })),
});

const CANDIDATE: Candidate = {
  threadId: "t-cand",
  title: "Receipt",
  topic: null,
  contacts: [],
  groups: [],
  embedding: null,
  author: null,
  facets: null,
  authorContactId: null,
  connectionId: null,
};

describe("originBonus (pure)", () => {
  const BONUS = { exact: 0.18, org: 0.09 };
  it("exact connection match wins", () => {
    expect(originBonus(CONN_A, "domain:acme.com", CONN_A, "domain:acme.com", BONUS)).toBe(0.18);
  });
  it("org-key match scores org", () => {
    expect(originBonus(CONN_B, "domain:acme.com", CONN_A, "domain:acme.com", BONUS)).toBe(0.09);
  });
  it("no candidate connection ⇒ 0", () => {
    expect(originBonus(CONN_A, "domain:acme.com", null, null, BONUS)).toBe(0);
  });
  it("null org keys never match each other", () => {
    expect(originBonus(CONN_B, null, CONN_A, null, BONUS)).toBe(0);
  });
});

describe("scoringStage origin wiring", () => {
  it("same-connection neighbor wins on origin alone", async () => {
    const ctx = fakeCtx([
      { match: "user_moved = TRUE", rows: () => [neighbor(P1, "t1", CONN_A)] },
      orgKeys({}),
      gate([]),
    ]);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(true);
    if (out.matched) expect(out.priorityId).toBe(P1);
    expect(out.explain.topNeighbors[0]!.origin).toBe(0.18);
  });

  it("org-key match contributes the org bonus", async () => {
    const ctx = fakeCtx([
      { match: "user_moved = TRUE", rows: () => [neighbor(P1, "t1", CONN_B)] },
      orgKeys({ [CONN_A]: "domain:acme.com", [CONN_B]: "domain:acme.com" }),
      gate([]),
    ]);
    const out = await scoringStage(ctx, { ...CANDIDATE, connectionId: CONN_A }, PARAMS);
    expect(out.matched).toBe(true); // 0.09 >= scoreThreshold 0.08
    expect(out.explain.topNeighbors[0]!.origin).toBe(0.09);
  });

  it("no candidate connection ⇒ org-key query never issued, origin 0", async () => {
    const queries: string[] = [];
    const ctx = fakeCtx(
      [{ match: "user_moved = TRUE", rows: () => [neighbor(P1, "t1", CONN_A)] }, gate([])],
      queries
    );
    const out = await scoringStage(ctx, CANDIDATE, PARAMS);
    expect(out.matched).toBe(false);
    expect(queries.some((q) => q.includes("connection_org_key"))).toBe(false);
  });
});
