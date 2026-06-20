import type { Kysely } from "kysely";

import { sql, type DB } from "../db";

/**
 * Apply the user's "Skip active for threads like this" (mute) rules to a newly
 * arrived thread. If the thread matches one of the user's active mute seeds, it
 * is stamped with the seed reference and marked read + inactive so it lands in
 * Done rather than Doing. Returns the matched seed id, or null when no rule
 * matched. No-ops on threads already archived/muted.
 *
 * This is the single forward-mute entry point shared by every ingestion path —
 * the client compose endpoint (`/sync/threads`), the capture endpoint, and
 * connector ingestion (`createLink`). Centralizing it prevents the divergence
 * that previously left connector-synced threads (Gmail, Slack, …) un-muted:
 * the call existed only on the client path, so recurring notification emails
 * were never auto-skipped.
 *
 * MUST run AFTER the thread's link row is attached, because
 * `user.find_mute_candidates` matches on the link's `channel_id` + `author_id`.
 */
export async function applyMuteForNewThread(
  db: Kysely<DB>,
  userId: string,
  threadId: string,
): Promise<string | null> {
  const result = await sql<{ apply_mute_for_new_thread: string | null }>`
    SELECT "user".apply_mute_for_new_thread(
      ${sql.val(userId)}::uuid,
      ${sql.val(threadId)}::uuid
    ) AS apply_mute_for_new_thread
  `.execute(db);
  return result.rows[0]?.apply_mute_for_new_thread ?? null;
}
