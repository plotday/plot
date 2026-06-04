import type { Bindings } from "../env";
import { withDb } from "../db";
import { twistFactory } from "../twist";
import { disposeRpc } from "../utils/rpc";
import { createLogger } from "@plotday/worker-util";

/**
 * Daily sweep: re-run getChannels → setChannels for every active connection.
 *
 * Picks up newly-discovered channels (new Slack channels, new Airtable bases,
 * new Linear projects, …) without requiring the user to re-auth or hit the
 * refresh button. When the per-connection auto-enable flag is on, setChannels
 * also enables those new channels in the same call.
 *
 * Runs in the cron handler's once-per-day window. Errors on individual rows
 * are logged and skipped — a single failing token does not block the rest.
 */
export async function refreshAllChannels(
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "refreshAllChannels" });

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
      .where("ti.archived_at", "is", null)
      .where("ti.suspended_at", "is", null)
      .where("ti.draft", "=", false)
      // Skip connections already awaiting re-auth: re-running getChannels would
      // just re-hit the same auth failure (and re-capture it) every day. The
      // flag clears automatically when the user re-authorizes (onAuth), so the
      // sweep resumes then.
      .where("tic.needs_reauth_at", "is", null)
      .execute();

    let success = 0;
    let failed = 0;
    let skipped = 0;

    const factory = twistFactory({ env, ctx: ctx as any, db });

    for (const row of rows) {
      let integrationsPath: string | undefined;
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
        integrationsPath = parsed.integrationsMap?.[row.provider];
        if (!integrationsPath) {
          skipped++;
          continue;
        }

        const wrapper = await factory({ twistInstanceId: row.twistInstanceId });
        const result = await wrapper.callCallback(
          integrationsPath.split(":"),
          "refreshChannels",
          row.provider,
          row.actorId
        );
        disposeRpc(result);
        success++;
      } catch (error) {
        failed++;
        const message = (error as Error).message;
        // If the failure is a missing-scope 403, flag the connection for
        // re-auth (and stop sweeping it — see the needs_reauth_at filter above)
        // instead of re-capturing the same error every day.
        if (integrationsPath) {
          try {
            const wrapper = await factory({
              twistInstanceId: row.twistInstanceId,
            });
            const flagResult = await wrapper.callCallback(
              integrationsPath.split(":"),
              "flagReauthIfInsufficientScope",
              row.provider,
              row.actorId,
              message
            );
            disposeRpc(flagResult);
          } catch (flagError) {
            logger.warn("Failed to flag needs_reauth after refresh failure", {
              error: (flagError as Error).message,
              twist_instance_id: row.twistInstanceId,
              provider: row.provider,
              actor_id: row.actorId,
            });
          }
        }
        logger.warn("Periodic channel refresh failed for connection", {
          error: message,
          twist_instance_id: row.twistInstanceId,
          provider: row.provider,
          actor_id: row.actorId,
        });
      }
    }

    logger.info("Periodic channel refresh complete", {
      total: rows.length,
      success,
      failed,
      skipped,
    });
  });
}
