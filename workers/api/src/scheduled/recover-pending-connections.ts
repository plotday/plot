import type { Bindings } from "../env";
import { withDb } from "../db";
import { twistFactory } from "../twist";
import { disposeRpc } from "../utils/rpc";
import { createLogger } from "@plotday/worker-util";

/**
 * Periodic sweep: find connections with `recovery_pending = true` (set by
 * `flagNeedsReauth` whenever auth failed) AND `needs_reauth_at IS NULL`
 * (auth has since been repaired), and synthesize an `onChannelEnabled`
 * dispatch with `recovering: true` for every enabled channel of those
 * connections.
 *
 * Durability contract: `recovery_pending` is cleared HERE — only after
 * `wrapper.callCallback("recoverConnection", ...)` returns successfully.
 * The runtime entrypoint awaits the dispatch envelope's onChannelEnabled
 * calls before returning, so a successful await means the connector's
 * onChannelEnabled (and its `runTask(initCallback)` enqueue) actually
 * ran. If the worker is evicted mid-call or any onChannelEnabled throws,
 * await throws here, the flag stays true, and the next 30-min cron pass
 * retries. (`buildRecoveryDispatches` deliberately calls buildSyncContext
 * without forActor/provider so the eager auto-consume doesn't fire.)
 *
 * This is the backstop for cases where the onAuth recovery dispatch was
 * supposed to fire on re-auth but didn't (queue exhaustion, DO timeout,
 * worker crash, …). Without it, an affected connection would stay stuck
 * until the user toggled a channel.
 */
export async function recoverPendingConnections(
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "recoverPendingConnections" });

  await withDb(env, async (db) => {
    const rows = await db
      .selectFrom("twist_instance_connection as tic")
      .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
      .innerJoin("twist as t", "t.id", "ti.twist_id")
      .select([
        "tic.twist_instance_id as twistInstanceId",
        "tic.provider",
        "tic.actor_id as actorId",
        "t.twist_package_id as twistPackageId",
        "t.version",
      ])
      .where("tic.recovery_pending", "=", true)
      .where("tic.needs_reauth_at", "is", null)
      .where("ti.archived_at", "is", null)
      .where("ti.suspended_at", "is", null)
      .where("ti.draft", "=", false)
      .execute();

    if (rows.length === 0) return;

    let success = 0;
    let failed = 0;
    let skipped = 0;

    const factory = twistFactory({ env, ctx: ctx as any, db });

    for (const row of rows) {
      try {
        const configJson = await env.TWIST_CONFIG.get(
          `${row.twistPackageId}:${row.version}`
        );
        if (!configJson) {
          skipped++;
          continue;
        }
        const parsed = JSON.parse(configJson) as {
          integrationsMap?: Record<string, string>;
        };
        const integrationsPath = parsed.integrationsMap?.[row.provider];
        if (!integrationsPath) {
          skipped++;
          continue;
        }

        const wrapper = await factory({ twistInstanceId: row.twistInstanceId });
        const result = await wrapper.callCallback(
          integrationsPath.split(":"),
          "recoverConnection",
          row.provider,
          row.actorId
        );
        disposeRpc(result);

        // Dispatch round-trip succeeded — connector's onChannelEnabled
        // ran (and its runTask enqueue completed). Now safe to clear
        // recovery_pending. If we instead cleared eagerly inside
        // buildSyncContext (as before), a mid-flight failure would
        // strand the row with no retry.
        const contact = await db
          .selectFrom("contact")
          .select("user_id")
          .where("id", "=", row.actorId)
          .executeTakeFirst();
        if (contact?.user_id) {
          await db
            .updateTable("twist_instance_connection")
            .set({ recovery_pending: false })
            .where("twist_instance_id", "=", row.twistInstanceId)
            .where("user_id", "=", contact.user_id)
            .where("provider", "=", row.provider)
            .where("recovery_pending", "=", true)
            .execute();
        }
        success++;
      } catch (error) {
        // Flag stays true — next cron pass retries this row.
        failed++;
        logger.warn("Recovery dispatch failed for connection", {
          error: (error as Error).message,
          twist_instance_id: row.twistInstanceId,
          provider: row.provider,
          actor_id: row.actorId,
        });
      }
    }

    logger.info("Recovery sweep complete", {
      total: rows.length,
      success,
      failed,
      skipped,
    });
  });
}
