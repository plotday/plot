import { createLogger } from "@plotday/worker-util";

import { withDb, type DB, type Kysely } from "../db";
import type { Bindings } from "../env";

/**
 * Watchdog for connections whose initial sync was orphaned mid-flight (worker
 * eviction, run-queue retry exhaustion, a callback that never resumed). The
 * "Syncing X" spinner in the app is driven purely by
 * `twist_instance_connection.initial_sync_started_at IS NOT NULL AND
 * initial_sync_completed_at IS NULL` (see
 * libs/db/schema/90-user-schema/33-twist_connection.sql). That state is only
 * cleared when the connector calls `channelSyncCompleted()` or its
 * `onChannelEnabled` throws (which triggers `__failChannelSync`). A crash
 * between those leaves the flag stuck on forever, and — unlike auth failures —
 * nothing sets `recovery_pending`, so the recover-pending sweep never picks it
 * up.
 *
 * This sweep finds those orphans and flags them `recovery_pending = true`,
 * letting the existing recover-pending sweep (which runs immediately after, in
 * the same cron tick) re-dispatch `onChannelEnabled(recovering: true)` — which
 * re-runs the idempotent initial sync and re-stamps `initial_sync_started_at`.
 */

/**
 * How long a connection may sit in the "initial syncing" state before the
 * watchdog considers it a candidate. Generous on purpose: a legitimate first
 * sync runs in batches and can take many minutes. The per-candidate liveness
 * guard (a future scheduled callback) protects the long-but-healthy case
 * independently of this threshold, so the only thing this gates against is a
 * brief race right after a sync starts.
 */
const STUCK_SYNC_GRACE_MS = 30 * 60 * 1000;

export type StuckSyncCandidate = {
  twistInstanceId: string;
  userId: string;
  provider: string;
};

/**
 * Connections whose initial sync started before `cutoff`, never completed, are
 * not already flagged for recovery, still have working auth, and belong to a
 * live (non-archived / non-suspended / non-draft) twist instance. These are
 * *candidates* only — the caller still checks each for in-flight work before
 * flagging it.
 */
export async function selectStuckSyncCandidates(
  db: Kysely<DB>,
  cutoff: Date
): Promise<StuckSyncCandidate[]> {
  return db
    .selectFrom("twist_instance_connection as tic")
    .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
    .select([
      "tic.twist_instance_id as twistInstanceId",
      "tic.user_id as userId",
      "tic.provider as provider",
    ])
    .where("tic.initial_sync_started_at", "<", cutoff)
    .where("tic.initial_sync_completed_at", "is", null)
    .where("tic.recovery_pending", "=", false)
    .where("tic.needs_reauth_at", "is", null)
    .where("ti.archived_at", "is", null)
    .where("ti.suspended_at", "is", null)
    .where("ti.draft", "=", false)
    .execute();
}

export async function recoverStuckSyncs(
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "recoverStuckSyncs" });

  await withDb(env, async (db) => {
    const cutoff = new Date(Date.now() - STUCK_SYNC_GRACE_MS);
    const candidates = await selectStuckSyncCandidates(db, cutoff);
    if (candidates.length === 0) return;

    let flagged = 0;
    let alive = 0;
    let skipped = 0;

    for (const candidate of candidates) {
      // Liveness guard. A healthy sync re-arms its next batch via
      // Tasks.runTask({ runAt }), leaving a future-dated row in the
      // connection's CallbacksState DO; a rate-limited sync does the same
      // with a longer delay. If such a row exists the sync is still going (or
      // backing off) — leave it alone. Only when nothing is queued is the
      // sync genuinely orphaned by a crash.
      let hasPending: boolean;
      try {
        const id = env.CALLBACKS.idFromName(candidate.twistInstanceId);
        const stub = env.CALLBACKS.get(id);
        hasPending = await stub.hasPendingScheduledCallback(
          candidate.twistInstanceId
        );
      } catch (error) {
        // Can't determine liveness — fail safe by NOT flagging, so we never
        // re-dispatch a sync that might still be running. Report and skip.
        logger.error(
          "Stuck-sync watchdog: liveness check failed",
          error as Error,
          { twist_instance_id: candidate.twistInstanceId }
        );
        skipped++;
        continue;
      }

      if (hasPending) {
        alive++;
        continue;
      }

      // Orphaned: flag for recovery. Re-check the started/not-completed and
      // recovery_pending predicates in the UPDATE so we don't race a sync
      // that completed (or was already flagged) between the SELECT and now.
      const result = await db
        .updateTable("twist_instance_connection")
        .set({ recovery_pending: true })
        .where("twist_instance_id", "=", candidate.twistInstanceId)
        .where("user_id", "=", candidate.userId)
        .where("provider", "=", candidate.provider)
        .where("initial_sync_completed_at", "is", null)
        .where("recovery_pending", "=", false)
        .executeTakeFirst();

      if (Number(result.numUpdatedRows ?? 0) > 0) flagged++;
    }

    // Candidates were found (the early return above handles the empty case),
    // so always emit a summary — including when every candidate was skipped
    // by a liveness-check error, which is otherwise only visible as scattered
    // per-candidate error logs.
    logger.warn("Stuck-sync watchdog swept connections", {
      candidates: candidates.length,
      flagged,
      alive,
      skipped,
    });
  });
}
