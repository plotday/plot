import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { UserAiUsage } from "../state/user-ai-usage";
import { getPersonalPlan, isUserInAnyTeam } from "./limits";

export const FREE_AI_LIMITS = {
  note_processing: 100, // embedding + analysis + summary per month
} as const;

export type AiOperation = keyof typeof FREE_AI_LIMITS;

/**
 * Single source of truth for "who gets unlimited AI". A user is unlimited if
 * they're on a paid personal plan OR a member of any team. All AI quota
 * checks (checkAiLimit, checkAiLimitForContacts) route through this so the
 * rule can't drift between callsites.
 */
export async function isUserAiUnlimited(
  db: Kysely<DB>,
  userId: string
): Promise<boolean> {
  const [plan, inTeam] = await Promise.all([
    getPersonalPlan(db, userId),
    isUserInAnyTeam(db, userId),
  ]);
  return plan !== "free" || inTeam;
}

/**
 * Check if a user is allowed to perform an AI operation. Unlimited users
 * (see isUserAiUnlimited) bypass the cap; everyone else is capped per
 * 30-day window (see FREE_AI_LIMITS).
 */
export async function checkAiLimit(
  env: Bindings,
  db: Kysely<DB>,
  userId: string,
  operation: AiOperation
): Promise<{ allowed: boolean; remaining: number }> {
  if (await isUserAiUnlimited(db, userId)) {
    return { allowed: true, remaining: Infinity };
  }

  const usage = UserAiUsage.Get(env, userId);
  return usage.check(operation, FREE_AI_LIMITS[operation]);
}

/**
 * AI limit check for a set of contacts. AI is free if ANY of the users
 * linked to these contacts is unlimited (paid or team member).
 *
 * Otherwise, it uses available free quota from any member, prioritizing
 * the syncing user.
 *
 * Returns the userId to charge usage against (null if skipped).
 */
export async function checkAiLimitForContacts(
  env: Bindings,
  db: Kysely<DB>,
  contactIds: string[],
  syncingUserId: string,
  operation: AiOperation
): Promise<{ allowed: boolean; chargeUserId: string | null }> {
  if (contactIds.length === 0) {
    // If no contacts, just check the syncing user
    const result = await checkAiLimit(env, db, syncingUserId, operation);
    return { allowed: result.allowed, chargeUserId: result.allowed ? syncingUserId : null };
  }

  // Get all users linked to these contacts
  const users = await db
    .selectFrom("user_contact")
    .select("user_id")
    .where("contact_id", "in", contactIds)
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .execute();

  const userIds = [...new Set(users.map((u) => u.user_id))];

  // 1. Skip quota if any linked user has unlimited AI
  for (const userId of userIds) {
    if (await isUserAiUnlimited(db, userId)) {
      return { allowed: true, chargeUserId: null };
    }
  }

  // 2. Otherwise, check if syncing user has free quota
  const syncingResult = await checkAiLimit(env, db, syncingUserId, operation);
  if (syncingResult.allowed) {
    return { allowed: true, chargeUserId: syncingUserId };
  }

  // 3. Check if any other user has free quota
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
