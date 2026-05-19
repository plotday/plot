import type { AggregationMode } from "./ts-hybrid.defaults";

export type ScoredNeighbor = {
  priorityId: string;
  threadId: string;
  combined: number;
};

export type AggregatedPriority = {
  priorityId: string;
  score: number;
  neighborCount: number;
};

export function aggregateNeighbors(
  neighbors: ScoredNeighbor[],
  mode: AggregationMode
): AggregatedPriority[] {
  const byPriority = new Map<string, number[]>();
  for (const n of neighbors) {
    const list = byPriority.get(n.priorityId);
    if (list) list.push(n.combined);
    else byPriority.set(n.priorityId, [n.combined]);
  }

  const out: AggregatedPriority[] = [];
  for (const [priorityId, combinedValues] of byPriority) {
    combinedValues.sort((a, b) => b - a);
    let score: number;
    switch (mode.mode) {
      case "top1":
        score = combinedValues[0]!;
        break;
      case "topk_mean": {
        // Always divide by k, treating missing neighbors as 0. This rewards
        // priorities with more supporting neighbors and prevents a single
        // noisy neighbor from dominating priorities with weaker-but-deeper
        // evidence. Equivalent to `top_k_mean * min(1, n/k)`.
        const k = Math.max(1, mode.k);
        const take = combinedValues.slice(0, k);
        score = take.reduce((a, b) => a + b, 0) / k;
        break;
      }
      case "softmax": {
        const T = mode.temperature > 0 ? mode.temperature : 1;
        score = combinedValues.reduce((a, c) => a + Math.exp(c / T), 0);
        break;
      }
    }
    out.push({ priorityId, score, neighborCount: combinedValues.length });
  }
  out.sort((a, b) => b.score - a.score);
  return out;
}
