/**
 * Extracts the 1-based rank of the gold priority (and its score margin to
 * the top-ranked priority) from a ClassificationResult's `scores` payload.
 *
 * The scoring stage's explain object (`ScoringExplain` in
 * libs/classifier/src/ts-hybrid-scoring.ts) lands in `scores` in two shapes:
 *   - stage "scoring": the explain object IS the scores payload, so the
 *     ranking lives at `scores.perPrioritySorted`;
 *   - stage "llm_tiebreaker": the explain is nested as
 *     `scores.scoring.perPrioritySorted` (`{ rationale, scoring: explain }`).
 * Every other stage (topic_shortcircuit, channel_default, llm_coldstart,
 * root_fallback, …) and the `sql:current` classifier (`{ top: [...] }`)
 * carries no ranking — those return null, as does a malformed payload.
 */
export function rankOfGold(
  scores: Record<string, unknown>,
  goldId: string | null
): { rank: number; margin: number } | null {
  if (goldId === null) return null;
  const ranking = findPerPrioritySorted(scores);
  if (ranking === null || ranking.length === 0) return null;
  const idx = ranking.findIndex((e) => e.priorityId === goldId);
  if (idx === -1) return null;
  // perPrioritySorted is sorted descending by score, so entry 0 is the top.
  return { rank: idx + 1, margin: ranking[0]!.score - ranking[idx]!.score };
}

type RankedEntry = { priorityId: string; score: number };

function findPerPrioritySorted(
  scores: Record<string, unknown>
): RankedEntry[] | null {
  const direct = asRankedEntries(scores["perPrioritySorted"]);
  if (direct !== null) return direct;
  const nested = scores["scoring"];
  if (typeof nested === "object" && nested !== null) {
    return asRankedEntries(
      (nested as Record<string, unknown>)["perPrioritySorted"]
    );
  }
  return null;
}

function asRankedEntries(value: unknown): RankedEntry[] | null {
  if (!Array.isArray(value)) return null;
  const out: RankedEntry[] = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null) return null;
    const { priorityId, score } = entry as Record<string, unknown>;
    if (typeof priorityId !== "string" || typeof score !== "number") {
      return null;
    }
    out.push({ priorityId, score });
  }
  return out;
}
