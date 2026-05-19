import { describe, expect, it } from "vitest";

import {
  aggregateNeighbors,
  type ScoredNeighbor,
} from "@plotday/classifier";

const neighbors: ScoredNeighbor[] = [
  { priorityId: "P1", threadId: "T1", combined: 0.9 },
  { priorityId: "P1", threadId: "T2", combined: 0.3 },
  { priorityId: "P1", threadId: "T3", combined: 0.2 },
  { priorityId: "P2", threadId: "T4", combined: 0.6 },
  { priorityId: "P2", threadId: "T5", combined: 0.55 },
];

describe("aggregateNeighbors: top1", () => {
  it("picks the priority of the single highest-scoring neighbor", () => {
    const out = aggregateNeighbors(neighbors, { mode: "top1" });
    expect(out[0]!.priorityId).toBe("P1");
    expect(out[0]!.score).toBe(0.9);
    expect(out[0]!.neighborCount).toBe(3);
  });
});

describe("aggregateNeighbors: topk_mean", () => {
  it("means the top k neighbors per priority", () => {
    const out = aggregateNeighbors(neighbors, { mode: "topk_mean", k: 2 });
    const p1 = out.find((r) => r.priorityId === "P1")!;
    const p2 = out.find((r) => r.priorityId === "P2")!;
    expect(p1.score).toBeCloseTo((0.9 + 0.3) / 2, 6);
    expect(p2.score).toBeCloseTo((0.6 + 0.55) / 2, 6);
    // P1 mean is 0.6, P2 mean is 0.575 — P1 wins.
    expect(out[0]!.priorityId).toBe("P1");
  });

  it("divides by k always (missing neighbors count as 0)", () => {
    const sparse: ScoredNeighbor[] = [
      { priorityId: "P1", threadId: "T1", combined: 0.6 },
    ];
    const out = aggregateNeighbors(sparse, { mode: "topk_mean", k: 3 });
    expect(out[0]!.score).toBeCloseTo(0.6 / 3, 6);
  });

  it("rewards depth: 3 medium-strength neighbors beat 1 strong neighbor", () => {
    const mixed: ScoredNeighbor[] = [
      { priorityId: "P1", threadId: "T1", combined: 0.4 },
      { priorityId: "P1", threadId: "T2", combined: 0.4 },
      { priorityId: "P1", threadId: "T3", combined: 0.4 },
      { priorityId: "P2", threadId: "T4", combined: 0.9 },
    ];
    const out = aggregateNeighbors(mixed, { mode: "topk_mean", k: 3 });
    expect(out[0]!.priorityId).toBe("P1"); // 1.2/3 = 0.4 vs 0.9/3 = 0.3
  });
});

describe("aggregateNeighbors: softmax", () => {
  it("sums exp(combined / T) per priority", () => {
    const out = aggregateNeighbors(neighbors, {
      mode: "softmax",
      temperature: 1,
    });
    const p1 = out.find((r) => r.priorityId === "P1")!;
    const expected = Math.exp(0.9) + Math.exp(0.3) + Math.exp(0.2);
    expect(p1.score).toBeCloseTo(expected, 6);
  });
});
