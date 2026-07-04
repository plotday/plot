import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";

import { withDb, type DB, type Kysely } from "../db";
import type { Bindings } from "../env";
import { notifyUserSyncByEnv } from "../app/sync/notify";

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
 *
 * Recovery is BOUNDED. Each flag bumps `initial_sync_attempts`; a sync that
 * keeps failing (a connector whose backfill throws every time, a permanently
 * broken credential) would otherwise be re-dispatched on every 30-min tick
 * forever, spinning the "Syncing X" indicator indefinitely. After
 * {@link MAX_INITIAL_SYNC_ATTEMPTS} failed cycles the watchdog gives up:
 * it sets `needs_reauth_at`, which (a) takes the connection out of both
 * recovery sweeps and (b) flips the app's tile from "Syncing X" to
 * "Reconnect X" (reauth is rendered ahead of syncing in
 * connection_status_tile.dart). The counter resets to 0 on a successful
 * `channelSyncCompleted` and on re-auth, so a genuine reconnect gets a fresh
 * recovery budget.
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

/**
 * How many times the watchdog re-dispatches a stuck sync before giving up and
 * surfacing "Reconnect" instead. At one attempt per 30-min tick this is ~1.5h
 * of automatic retries — enough to ride out transient breakage (a deploy, a
 * provider blip) without spinning forever on a deterministic failure.
 */
export const MAX_INITIAL_SYNC_ATTEMPTS = 3;

/**
 * How soon a connection's next scheduled callback must fire for the watchdog to
 * treat its initial sync as "still batching" (alive) rather than orphaned.
 *
 * A healthy initial sync re-arms its next batch within seconds-to-minutes (or,
 * when rate-limited, a few minutes). What it does NOT do is park its next step
 * hours away — that pattern belongs to independent *background* crawls. The
 * Unipile relations backfill, for example, reschedules itself 2–4h out (and
 * 4–8h on error) while the initial chat sync (`backfillChats`, the task that
 * calls `channelSyncCompleted`) runs in one pass. This horizon stays comfortably
 * below that 2h crawl floor so such a parked callback can never masquerade as a
 * live sync.
 *
 * This horizon is only half the defense. The other half lives in
 * `CallbacksState.nextScheduledCallbackAt`, which now excludes keyed
 * (`scheduleTask`) and recurring (`scheduleRecurring`) callbacks entirely, so a
 * *near-future* maintenance callback — e.g. a 60-second `gmail-writeback-retry`
 * or a watch renewal — can no longer keep an orphaned Google initial sync
 * looking alive. Only the initial sync's own unkeyed one-shot batch
 * continuation counts, and the horizon then guards against a genuinely parked
 * continuation.
 */
export const LIVENESS_HORIZON_MS = 90 * 60 * 1000;

/**
 * Decide whether an in-progress initial sync is still actively batching, given
 * the timestamp (epoch ms) of its soonest pending scheduled callback (or `null`
 * when nothing is queued). Alive iff a callback is due within
 * {@link LIVENESS_HORIZON_MS}; a callback parked further out is a background
 * task, not the initial sync, and a `null` means the sync was orphaned by a
 * crash (nothing left to fire).
 */
export function isSyncStillBatching(
  nextScheduledCallbackAt: number | null,
  now: number
): boolean {
  return (
    nextScheduledCallbackAt !== null &&
    nextScheduledCallbackAt <= now + LIVENESS_HORIZON_MS
  );
}

export type StuckSyncCandidate = {
  twistInstanceId: string;
  userId: string;
  provider: string;
  initialSyncAttempts: number;
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
      "tic.initial_sync_attempts as initialSyncAttempts",
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

/**
 * Decide what to do with an orphaned stuck sync given how many recovery
 * attempts have already been spent: re-dispatch it once more, or give up and
 * surface "Reconnect".
 */
export function recoveryAction(attempts: number): "retry" | "give_up" {
  return attempts >= MAX_INITIAL_SYNC_ATTEMPTS ? "give_up" : "retry";
}

/**
 * Flag an orphaned connection for recovery and bump its attempt counter. The
 * WHERE re-checks the started/not-completed/not-already-flagged/working-auth
 * predicates so we don't race a sync that completed (or was flagged, or broke
 * its auth) between the SELECT and now. Returns rows updated.
 */
export async function flagForRetry(
  db: Kysely<DB>,
  candidate: StuckSyncCandidate
): Promise<number> {
  const result = await db
    .updateTable("twist_instance_connection")
    .set({
      recovery_pending: true,
      initial_sync_attempts: sql<number>`initial_sync_attempts + 1`,
    })
    .where("twist_instance_id", "=", candidate.twistInstanceId)
    .where("user_id", "=", candidate.userId)
    .where("provider", "=", candidate.provider)
    .where("initial_sync_completed_at", "is", null)
    .where("recovery_pending", "=", false)
    .where("needs_reauth_at", "is", null)
    .executeTakeFirst();
  return Number(result.numUpdatedRows ?? 0);
}

/**
 * Give up on an orphaned connection whose initial sync has failed to complete
 * across {@link MAX_INITIAL_SYNC_ATTEMPTS} recovery cycles. Sets
 * `needs_reauth_at` so the app shows "Reconnect X" instead of an eternal
 * "Syncing X", and so both recovery sweeps stop re-dispatching it. Re-checks
 * the predicates in the WHERE to avoid racing a sync that just completed.
 * Returns rows updated.
 */
export async function giveUpStuckSync(
  db: Kysely<DB>,
  candidate: StuckSyncCandidate
): Promise<number> {
  const result = await db
    .updateTable("twist_instance_connection")
    .set({ needs_reauth_at: sql<Date>`now()` })
    .where("twist_instance_id", "=", candidate.twistInstanceId)
    .where("user_id", "=", candidate.userId)
    .where("provider", "=", candidate.provider)
    .where("initial_sync_completed_at", "is", null)
    .where("needs_reauth_at", "is", null)
    .executeTakeFirst();
  return Number(result.numUpdatedRows ?? 0);
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
    let gaveUp = 0;
    let alive = 0;
    let skipped = 0;

    for (const candidate of candidates) {
      // Liveness guard. A healthy sync re-arms its next batch via
      // Tasks.runTask({ runAt }), leaving a *near-future* row in the
      // connection's CallbacksState DO; a rate-limited sync does the same with
      // a slightly longer delay. If such a row is due within
      // LIVENESS_HORIZON_MS the sync is still going — leave it alone. A
      // callback parked hours out is NOT the initial sync (e.g. the Unipile
      // relations crawl, 2–8h), and nothing queued means the sync was orphaned
      // by a crash; both are recovery candidates.
      let stillBatching: boolean;
      try {
        const id = env.CALLBACKS.idFromName(candidate.twistInstanceId);
        const stub = env.CALLBACKS.get(id);
        const nextAt = await stub.nextScheduledCallbackAt(
          candidate.twistInstanceId
        );
        stillBatching = isSyncStillBatching(nextAt, Date.now());
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

      if (stillBatching) {
        alive++;
        continue;
      }

      // Orphaned. Re-dispatch while there's recovery budget left; once it's
      // spent, give up and surface "Reconnect" rather than spinning forever.
      if (recoveryAction(candidate.initialSyncAttempts) === "give_up") {
        const updated = await giveUpStuckSync(db, candidate);
        if (updated > 0) {
          gaveUp++;
          // Push the needs_reauth flip to the client so the tile updates now.
          await notifyUserSyncByEnv(env, candidate.userId);
        }
      } else if ((await flagForRetry(db, candidate)) > 0) {
        flagged++;
      }
    }

    // Candidates were found (the early return above handles the empty case),
    // so always emit a summary — including when every candidate was skipped
    // by a liveness-check error, which is otherwise only visible as scattered
    // per-candidate error logs.
    logger.warn("Stuck-sync watchdog swept connections", {
      candidates: candidates.length,
      flagged,
      gaveUp,
      alive,
      skipped,
    });
  });
}
