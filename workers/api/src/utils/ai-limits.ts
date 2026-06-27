import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { UserAiUsage } from "../state/user-ai-usage";

/**
 * INTERNAL, UNPUBLISHED abuse safeguard — never surfaced to users and not a
 * product limit. Applied uniformly to ALL users regardless of plan.
 *
 * Raise freely if legitimate heavy usage approaches this ceiling; it exists
 * only to catch runaway automation loops.
 *
 * Cost context (@cf/meta/llama-3.3-70b-instruct-fp8-fast ≈ $0.0009/call):
 * 10 000 calls ≈ $9/user/mo — a clear abuse signal, not normal heavy usage.
 * The per-30-day window is enforced by the UserAiUsage Durable Object.
 */
export const INTERNAL_AI_CAP = {
  note_processing: 10_000,
} as const;

export type AiOperation = keyof typeof INTERNAL_AI_CAP;

/**
 * Check if a user is allowed to perform an AI operation. The cap is applied
 * uniformly to ALL users — no plan or team bypass. This is an unpublished
 * internal abuse safeguard (see INTERNAL_AI_CAP), not a product limit.
 *
 * `db` is kept in the signature for call-site compatibility but is no longer
 * queried; plan lookups were removed with the per-plan bypass.
 */
export async function checkAiLimit(
  env: Bindings,
  _db: Kysely<DB>,
  userId: string,
  operation: AiOperation
): Promise<{ allowed: boolean; remaining: number }> {
  const usage = UserAiUsage.Get(env, userId);
  return usage.check(operation, INTERNAL_AI_CAP[operation]);
}

/**
 * AI limit check for a set of contacts. Picks the syncing user as the charge
 * target; falls back to any other linked user who still has quota.
 *
 * The cap is uniform (no unlimited bypass for paid/team users) — see
 * INTERNAL_AI_CAP. Returns the userId to charge usage against (null if
 * no one has remaining quota).
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

  // 1. Check if syncing user has quota
  const syncingResult = await checkAiLimit(env, db, syncingUserId, operation);
  if (syncingResult.allowed) {
    return { allowed: true, chargeUserId: syncingUserId };
  }

  // 2. Check if any other linked user has quota
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
 * Single source of truth for "are built-in AI features enabled for this user".
 * Every built-in AI call site (classification, embeddings, summaries,
 * notification copy, priority suggestions, search, intent, note enrichment)
 * gates on this so the user's opt-out can't leak through one forgotten path.
 *
 * `ai_preference.builtin_ai_disabled` is the canonical opt-out written by the
 * settings UI. When no preference row exists, fall back to the legacy
 * `user_settings.ai_enabled` flag — accounts that turned AI off before
 * `ai_preference` existed were never backfilled, so that flag is the only
 * record of their choice. Either explicit disable wins; absence of both ⇒
 * enabled (the default).
 */
export async function isAiEnabled(
  db: Kysely<DB>,
  userId: string
): Promise<boolean> {
  const [pref, settings] = await Promise.all([
    db
      .selectFrom("ai_preference")
      .select("builtin_ai_disabled")
      .where("user_id", "=", userId)
      .executeTakeFirst(),
    db
      .selectFrom("user_settings")
      .select("ai_enabled")
      .where("user_id", "=", userId)
      .executeTakeFirst(),
  ]);

  if (pref) return pref.builtin_ai_disabled !== true;
  return settings?.ai_enabled !== false;
}
