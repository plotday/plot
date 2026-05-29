import type { ClassifierContext } from "./types";
import type { BudgetLimits, HybridParams } from "./ts-hybrid.defaults";

/**
 * Resolve the user's per-user LLM budget by subscription tier.
 *
 * Paid = `user_subscription.plan ∈ {core, pro, team}` AND
 * `status ∈ {active, trialing}` — mirrors `getPersonalPlan` in
 * workers/api/src/utils/plan.ts (trialing counts as paid).
 *
 * Any read failure or missing row falls back to the free tier: never block
 * classification on a subscription lookup, and never hand a non-paying user
 * the paid ceiling. Resolved lazily (only when an LLM stage is about to
 * fire) so the deterministic-only classifications skip the query entirely.
 */
export async function resolveBudgetLimits(
  ctx: ClassifierContext,
  llm: NonNullable<HybridParams["llm"]>
): Promise<BudgetLimits> {
  try {
    const res = await ctx.rawQuery(
      `SELECT plan, status
         FROM public.user_subscription
        WHERE user_id = $1::uuid`,
      [ctx.userId]
    );
    const row = res.rows[0] as { plan: string; status: string } | undefined;
    const paid =
      !!row &&
      (row.status === "active" || row.status === "trialing") &&
      row.plan !== "free";
    return paid ? llm.budgetPaid : llm.budgetFree;
  } catch {
    return llm.budgetFree;
  }
}
