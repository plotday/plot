import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";

import { withDb, type DB, type Kysely } from "../db";
import type { Bindings } from "../env";

/**
 * Proactive counterpart to the inbound-webhook lazy-clear in
 * `workers/api/src/twist/invoke-webhook.ts`.
 *
 * Auto-suspensions (rate / burst / quota / cost — see
 * `workers/api/src/state/usage.ts`) stamp `twist_instance.suspended_at` along
 * with the `suspended_version` that was live at the time. The contract is that
 * a suspension is lifted "on the next deploy of this twist": when the twist is
 * redeployed, `suspended_version` no longer matches `twist.version`, and
 * `invokeWebhookCallback` lazy-clears the suspension on the next inbound
 * webhook so each new version gets a fresh start. Manual/operator suspensions
 * leave `suspended_version` NULL and are deliberately durable across deploys.
 *
 * The webhook lazy-clear only fires if an inbound webhook actually arrives.
 * A connection auto-suspended *during* its initial sync (exactly when a
 * runaway / over-budget sync trips the limit) often never receives one —
 * webhook setup was interrupted by the very suspension — so the stale
 * suspension lingers indefinitely. And while it lingers, both recovery sweeps
 * (`recover-stuck-syncs.ts`, `recover-pending-connections.ts`) skip the
 * instance (`ti.suspended_at IS NULL`), so the orphaned "Syncing X" spinner is
 * never recovered. This sweep closes that gap by applying the same
 * staleness-based clear proactively, independent of inbound webhooks.
 *
 * Run this BEFORE `recoverStuckSyncs` in the recovery cron tick: once the
 * stale suspension is cleared, the stuck-sync watchdog picks up the orphaned
 * sync in the same tick and the recover-pending sweep re-dispatches
 * `onChannelEnabled(recovering: true)`.
 *
 * Only *stale* auto-suspensions are cleared (suspended_version present AND
 * different from the current twist version). Active same-version
 * auto-suspensions and durable manual suspensions are left untouched. If a
 * redeployed twist re-trips its limit on the new version it is simply
 * re-suspended with the new `suspended_version` — there is no clear loop.
 */
export async function clearStaleAutoSuspensions(
  db: Kysely<DB>
): Promise<string[]> {
  const result = await sql<{ id: string }>`
    UPDATE twist_instance ti
    SET suspended_at = NULL, suspended_version = NULL
    FROM twist t
    WHERE t.id = ti.twist_id
      AND ti.suspended_at IS NOT NULL
      AND ti.suspended_version IS NOT NULL
      AND ti.suspended_version <> t.version
      AND ti.archived_at IS NULL
    RETURNING ti.id
  `.execute(db);
  return result.rows.map((r) => r.id);
}

export async function clearStaleSuspensions(
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "clearStaleSuspensions" });

  await withDb(env, async (db) => {
    const cleared = await clearStaleAutoSuspensions(db);
    if (cleared.length > 0) {
      logger.warn(
        "Cleared stale auto-suspensions (twist redeployed since suspension)",
        { count: cleared.length }
      );
    }
  });
}
