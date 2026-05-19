import type { ConsumeBudgetFn } from "@plotday/classifier";

const BUDGET_TTL_SECONDS = 24 * 60 * 60;

/** yyyymmdd in UTC. */
function todayKey(now: Date = new Date()): string {
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, "0");
  const d = String(now.getUTCDate()).padStart(2, "0");
  return `${y}${m}${d}`;
}

/**
 * Per-user daily LLM-call budget gate, stored in KV.
 *
 * KV is eventually consistent across PoPs — two concurrent classify
 * requests in different regions may each see "count below limit" and
 * both proceed. The cost overrun is bounded (one extra call per
 * concurrent request); correctness is unaffected.
 */
export function kvBudget(kv: KVNamespace): ConsumeBudgetFn {
  return async (userId: string, dailyMax: number): Promise<boolean> => {
    const key = `llm-budget:${userId}:${todayKey()}`;
    const cur = await kv.get(key);
    const count = cur ? parseInt(cur, 10) || 0 : 0;
    if (count >= dailyMax) return false;
    try {
      await kv.put(key, String(count + 1), {
        expirationTtl: BUDGET_TTL_SECONDS,
      });
    } catch {
      // Failing to record a budget increment must not block classification.
    }
    return true;
  };
}
