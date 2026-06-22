import { createLogger } from "@plotday/worker-util";

import { withDb, type DB, type Kysely } from "../db";
import type { Bindings } from "../env";

/**
 * Backstop for periodic maintenance chains (watch renewals, self-heal, polling)
 * that died with no live recurring task — e.g. a chain that predates the
 * recurring primitive, or a row lost to a bug. The recurring DO alarm makes a
 * chain self-perpetuating once it exists, so this sweep only has to notice the
 * "no row at all" case and re-assert it via the connector's existing idempotent
 * recovery path (recovery_pending → recover-pending sweep re-dispatches
 * onChannelEnabled(recovering: true), which re-registers the recurring task).
 *
 * It is gated on the DO's needsRecurringRecovery() (instance has EVER had a
 * recurring task but has none now), so webhook-only connectors that never
 * register one are never flagged.
 */
export type MaintenanceCandidate = {
  twistInstanceId: string;
  userId: string;
  provider: string;
};

export async function selectActiveMaintenanceConnections(
  db: Kysely<DB>
): Promise<MaintenanceCandidate[]> {
  return db
    .selectFrom("twist_instance_connection as tic")
    .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
    .select([
      "tic.twist_instance_id as twistInstanceId",
      "tic.user_id as userId",
      "tic.provider as provider",
    ])
    .where("tic.initial_sync_completed_at", "is not", null) // past initial sync
    .where("tic.recovery_pending", "=", false)
    .where("tic.needs_reauth_at", "is", null)
    .where("ti.archived_at", "is", null)
    .where("ti.suspended_at", "is", null)
    .where("ti.draft", "=", false)
    .execute();
}

export async function flagMaintenanceForRecovery(
  db: Kysely<DB>,
  candidate: MaintenanceCandidate
): Promise<number> {
  const result = await db
    .updateTable("twist_instance_connection")
    .set({ recovery_pending: true })
    .where("twist_instance_id", "=", candidate.twistInstanceId)
    .where("user_id", "=", candidate.userId)
    .where("provider", "=", candidate.provider)
    .where("recovery_pending", "=", false)
    .where("needs_reauth_at", "is", null)
    .executeTakeFirst();
  return Number(result.numUpdatedRows ?? 0);
}

export async function recoverRecurringMaintenance(
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "recoverRecurringMaintenance" });
  await withDb(env, async (db) => {
    const candidates = await selectActiveMaintenanceConnections(db);
    if (candidates.length === 0) return;

    let flagged = 0;
    let alive = 0;
    let skipped = 0;
    for (const c of candidates) {
      let needs: boolean;
      try {
        const id = env.CALLBACKS.idFromName(c.twistInstanceId);
        const stub = env.CALLBACKS.get(id);
        needs = await stub.needsRecurringRecovery(c.twistInstanceId);
      } catch (error) {
        // Fail safe: never re-dispatch a chain we can't confirm is dead.
        logger.error("maintenance liveness check failed", error as Error, {
          twist_instance_id: c.twistInstanceId,
        });
        skipped++;
        continue;
      }
      if (!needs) {
        alive++;
        continue;
      }
      if ((await flagMaintenanceForRecovery(db, c)) > 0) flagged++;
    }
    logger.warn("Recurring-maintenance watchdog swept connections", {
      candidates: candidates.length,
      flagged,
      alive,
      skipped,
    });
  });
}
