import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { UserAiUsage } from "../state/user-ai-usage";
import { getPersonalPlan } from "./limits";

export const FREE_AI_LIMITS = {
  note_processing: 100, // embedding + analysis + summary per month
} as const;

export type AiOperation = keyof typeof FREE_AI_LIMITS;

/**
 * Check if a user is allowed to perform an AI operation.
 * Paid plans are unlimited; free plans are capped.
 */
export async function checkAiLimit(
  env: Bindings,
  db: Kysely<DB>,
  userId: string,
  operation: AiOperation
): Promise<{ allowed: boolean; remaining: number }> {
  const plan = await getPersonalPlan(db, userId);
  if (plan !== "free") return { allowed: true, remaining: Infinity };

  const usage = UserAiUsage.Get(env, userId);
  return usage.check(operation, FREE_AI_LIMITS[operation]);
}

/**
 * Priority-aware AI limit check. Checks in order:
 * 1. Team priorities → always allowed (covered by team plan)
 * 2. Syncing user → if paid or within free limits, use their quota
 * 3. Other priority members → if any has capacity, use their quota
 *
 * Returns the userId to charge usage against (null for team priorities).
 */
export async function checkAiLimitForPriority(
  env: Bindings,
  db: Kysely<DB>,
  priorityId: string,
  syncingUserId: string,
  operation: AiOperation
): Promise<{ allowed: boolean; chargeUserId: string | null }> {
  // 1. Team priorities are covered by the team plan
  const priority = await db
    .selectFrom("priority")
    .select("team_id")
    .where("id", "=", priorityId)
    .executeTakeFirst();

  if (priority?.team_id) {
    return { allowed: true, chargeUserId: null };
  }

  // 2. Check syncing user first
  const syncingResult = await checkAiLimit(env, db, syncingUserId, operation);
  if (syncingResult.allowed) {
    return { allowed: true, chargeUserId: syncingUserId };
  }

  // 3. Check other users in the priority
  // rpc() unwraps single-column TABLE results, so we get string[] directly
  const usersData = await rpc(db, "get_users_with_priority_access", {
    target_priority_id: priorityId,
  });
  const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];

  for (const userId of userIds) {
    if (userId === syncingUserId) continue;
    const result = await checkAiLimit(env, db, userId, operation);
    if (result.allowed) {
      return { allowed: true, chargeUserId: userId };
    }
  }

  return { allowed: false, chargeUserId: null };
}

/**
 * Record AI usage for a user (fire-and-forget, don't block the response).
 * Pass null to skip recording (e.g. for team-covered priorities).
 */
export function recordAiUsage(
  env: Bindings,
  userId: string | null,
  operation: AiOperation,
  count = 1
): void {
  if (!userId) return;
  const usage = UserAiUsage.Get(env, userId);
  usage.increment(operation, count);
}

/**
 * Check if built-in AI features are enabled for a user via ai_preference.
 */
export async function isAiEnabled(
  db: Kysely<DB>,
  userId: string
): Promise<boolean> {
  const pref = await db
    .selectFrom("ai_preference")
    .select("builtin_ai_disabled")
    .where("user_id", "=", userId)
    .executeTakeFirst();

  // No preference row or false = enabled, only explicit true disables
  return pref?.builtin_ai_disabled !== true;
}
