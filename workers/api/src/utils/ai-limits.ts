import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
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
 * Record AI usage for a user (fire-and-forget, don't block the response).
 */
export function recordAiUsage(
  env: Bindings,
  userId: string,
  operation: AiOperation,
  count = 1
): void {
  const usage = UserAiUsage.Get(env, userId);
  usage.increment(operation, count);
}

/**
 * Check if AI features are enabled for a user via user_settings.
 */
export async function isAiEnabled(
  db: Kysely<DB>,
  userId: string
): Promise<boolean> {
  const settings = await db
    .selectFrom("user_settings")
    .select("ai_enabled")
    .where("user_id", "=", userId)
    .executeTakeFirst();

  // null or true = enabled, only explicit false disables
  return settings?.ai_enabled !== false;
}
