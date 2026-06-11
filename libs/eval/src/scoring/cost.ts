/**
 * USD per 1M tokens. Estimates as of 2026-06; update when pricing changes.
 * Keyed by the model ids used in HybridParams.llm.model.
 */
export const MODEL_COSTS: Record<string, { inPerM: number; outPerM: number }> = {
  "gemini-3-flash-preview": { inPerM: 0.3, outPerM: 2.5 },
  "gemini-2.5-flash": { inPerM: 0.3, outPerM: 2.5 },
  "gemini-3.1-flash-lite": { inPerM: 0.1, outPerM: 0.4 },
};

/**
 * Estimated USD cost of the given token usage on `model`, or null when the
 * model has no entry in MODEL_COSTS (unknown pricing must surface as
 * "unknown", not $0).
 */
export function estimateCostUsd(
  model: string,
  usage: { inputTokens: number; outputTokens: number }
): number | null {
  const costs = MODEL_COSTS[model];
  if (!costs) return null;
  return (
    (usage.inputTokens / 1_000_000) * costs.inPerM +
    (usage.outputTokens / 1_000_000) * costs.outPerM
  );
}
