import type { BudgetLimits, ConsumeBudgetFn } from "@plotday/classifier";

const DAY_TTL_SECONDS = 24 * 60 * 60;
// 35 days: comfortably outlives any calendar month so the rolling yyyymm key
// is always present for the month it covers, then expires on its own.
const MONTH_TTL_SECONDS = 35 * 24 * 60 * 60;

/** yyyymmdd in UTC. */
function dayKey(now: Date): string {
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, "0");
  const d = String(now.getUTCDate()).padStart(2, "0");
  return `${y}${m}${d}`;
}

/** yyyymm in UTC. */
function monthKey(now: Date): string {
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `${y}${m}`;
}

/**
 * Per-user LLM-call budget gate, stored in KV.
 *
 * Two counters: a generous monthly pool and a daily fallback. A call is
 * allowed when `month < monthlyMax OR day < dailyMax`, so the monthly pool
 * absorbs a large one-time import with no daily throttle, and once it is
 * spent the daily cap takes over for the rest of the month. On allow both
 * counters are incremented (incrementing the daily counter during the
 * import is harmless — the daily check is bypassed while the monthly pool
 * has room — and means the daily cap is already accurate the moment the pool
 * runs dry, preventing a burst at the boundary).
 *
 * KV is eventually consistent across PoPs — two concurrent classify requests
 * in different regions may each see "below limit" and both proceed. The cost
 * overrun is bounded (one extra call per concurrent request); correctness is
 * unaffected.
 */
export function kvBudget(kv: KVNamespace): ConsumeBudgetFn {
  return async (userId: string, limits: BudgetLimits): Promise<boolean> => {
    const now = new Date();
    const mKey = `llm-budget-month:${userId}:${monthKey(now)}`;
    const dKey = `llm-budget-day:${userId}:${dayKey(now)}`;
    const [mCur, dCur] = await Promise.all([kv.get(mKey), kv.get(dKey)]);
    const mCount = mCur ? parseInt(mCur, 10) || 0 : 0;
    const dCount = dCur ? parseInt(dCur, 10) || 0 : 0;
    if (mCount >= limits.monthlyMax && dCount >= limits.dailyMax) return false;
    try {
      await Promise.all([
        kv.put(mKey, String(mCount + 1), { expirationTtl: MONTH_TTL_SECONDS }),
        kv.put(dKey, String(dCount + 1), { expirationTtl: DAY_TTL_SECONDS }),
      ]);
    } catch {
      // Failing to record a budget increment must not block classification.
    }
    return true;
  };
}
