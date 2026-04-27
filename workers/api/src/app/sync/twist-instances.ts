import { Hono } from "hono";

import { createDb, sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { twistFactory } from "../../twist";
import { resolveOptions } from "../../twist/tools/factory";
import type { OptionsSchema } from "@plotday/twister/options";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";
import { syncUserTwistStats } from "../../utils/twist-stats";
import { createLogger } from "@plotday/worker-util";

const twistInstances = new Hono<{ Bindings: Bindings }>();

// GET /sync/twist-instances
// twist_instance table doesn't have user_id; filter by user's accessible priorities
twistInstances.get("/sync/twist-instances", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, archived, limit, sortBy, sortDir } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.twist")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);

    // Apply sort
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    if (archived === true) {
      query = query.where("archived_at", "is not", null);
    } else if (archived === false) {
      query = query.where("archived_at", "is", null);
    }

    return query.execute();
  });

  // Reconcile twist_instance_connection rows for source twist_instances
  // against the actual DO-storage state. Runs every app sync so the rows
  // never drift more than one round-trip from the truth:
  //   - DO has an auth_token for one of the user's contacts → write a
  //     "connected" row (no needs_reauth_at).
  //   - DO has no token but a channel_config records who enabled the
  //     channels → write a placeholder row with needs_reauth_at = now()
  //     so the app can prompt re-auth immediately.
  //   - Neither → leave the row absent (nothing was ever connected).
  await reconcileSourceConnections(c, rows, userId);

  return c.json(rows as any);
});

type SourceRow = {
  id: string;
  twist_id: string;
  is_source: boolean;
  user_connected: boolean;
};

async function reconcileSourceConnections(
  c: any,
  rows: any[],
  userId: string
): Promise<void> {
  const unconnected = (rows as SourceRow[]).filter(
    (r) => r.is_source && !r.user_connected
  );
  if (unconnected.length === 0) return;

  const userContacts = await c.var.db
    .selectFrom("contact")
    .select("id")
    .where("user_id", "=", userId)
    .execute();
  const contactIds = new Set<string>(userContacts.map((ct: any) => ct.id));
  if (contactIds.size === 0) return;

  const logger = createLogger({
    operation: "reconcileSourceConnections",
    user_id: userId,
  });

  for (const row of unconnected) {
    try {
      const twistInfo = await c.var.db
        .selectFrom("twist")
        .select(["twist.twist_package_id", "twist.version"])
        .where("twist.id", "=", row.twist_id)
        .executeTakeFirst();
      if (!twistInfo) continue;

      const configStr = await c.env.TWIST_CONFIG.get(
        `${twistInfo.twist_package_id}:${twistInfo.version}`
      );
      if (!configStr) continue;

      const config = JSON.parse(configStr);
      const integrationsMap: Record<string, string> =
        config.integrationsMap ?? {};

      // Pass 1: try to attribute a working token to one of the user's
      // contacts. First match wins.
      let connected: { provider: string; actorId: string } | null = null;
      // Last-known (provider, actor) signal for the placeholder fallback.
      // Populated in the same loop so we only open each Storage DO once.
      let lastKnown: { provider: string; actorId: string } | null = null;

      for (const [provider, pathStr] of Object.entries(integrationsMap)) {
        const path = pathStr.split(":");
        const toolPath = path.slice(0, -1);
        const doName = `${row.id}:${toolPath.join(":")}`;
        const storageId = c.env.STORAGE.idFromName(doName);
        const storageDO = c.env.STORAGE.get(storageId);

        const tokenKeys = await storageDO.list(`auth_token:${provider}:`);
        for (const key of tokenKeys) {
          const actorId = key.split(":").slice(2).join(":");
          if (contactIds.has(actorId)) {
            connected = { provider, actorId };
            break;
          }
        }
        if (connected) break;

        if (!lastKnown) {
          const configKeys = await storageDO.list(
            `channel_config:${provider}:`
          );
          for (const key of configKeys) {
            const raw = await storageDO.get(key);
            if (!raw) continue;
            let parsed: { enabled?: boolean; enabledBy?: string };
            try {
              parsed = JSON.parse(raw);
            } catch {
              continue;
            }
            if (
              parsed?.enabled &&
              parsed.enabledBy &&
              contactIds.has(parsed.enabledBy)
            ) {
              lastKnown = { provider, actorId: parsed.enabledBy };
              break;
            }
          }
        }
      }

      const now = new Date().toISOString();
      if (connected) {
        await c.var.db
          .insertInto("twist_instance_connection")
          .values({
            twist_instance_id: row.id,
            user_id: userId,
            provider: connected.provider,
            actor_id: connected.actorId,
            connected_at: now,
          })
          .onConflict((oc: any) =>
            oc
              .columns(["twist_instance_id", "user_id", "provider"])
              .doNothing()
          )
          .execute();
        row.user_connected = true;
      } else if (lastKnown) {
        await c.var.db
          .insertInto("twist_instance_connection")
          .values({
            twist_instance_id: row.id,
            user_id: userId,
            provider: lastKnown.provider,
            actor_id: lastKnown.actorId,
            connected_at: now,
            needs_reauth_at: now,
          })
          .onConflict((oc: any) =>
            oc
              .columns(["twist_instance_id", "user_id", "provider"])
              .doUpdateSet({ needs_reauth_at: now })
              .where("twist_instance_connection.needs_reauth_at", "is", null)
          )
          .execute();
        row.user_connected = true;
        logger.info("Flagged source twist_instance as needs_reauth", {
          twist_instance_id: row.id,
          provider: lastKnown.provider,
        });
      }
    } catch (error) {
      logger.warn("Source connection reconciliation failed", {
        twist_instance_id: row.id,
        error: (error as Error)?.message ?? String(error),
      });
    }
  }
}

// POST /sync/twist-instances
twistInstances.post("/sync/twist-instances", async (c) => {
  const body = await c.req.json();

  // Load old config before upsert (for onOptionsChanged dispatch)
  let oldConfig: Record<string, unknown> | undefined;
  let twistMeta: { twist_id: string | number | bigint; options: any; environment: string } | undefined;
  if (body.config && body.id) {
    const oldRecord = await c.var.db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select(["twist_instance.options", "twist_instance.twist_id", "twist.options_schema", "twist.environment"])
      .where("twist_instance.id", "=", body.id)
      .executeTakeFirst();
    if (oldRecord) {
      oldConfig = oldRecord.options
        ? (typeof oldRecord.options === "string" ? JSON.parse(oldRecord.options) : oldRecord.options as Record<string, unknown>)
        : {};
      twistMeta = {
        twist_id: oldRecord.twist_id,
        options: oldRecord.options_schema,
        environment: oldRecord.environment as string,
      };
    }
  }

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_twist_instance", {
      user_id: c.var.user.id,
      p_id: body.id,
      p_twist_id: body.twist_id,
      p_owner_id: body.owner_id,
      p_team_id: body.team_id ?? null,
      p_name: body.name || null,
      p_account_label: body.account_label ?? null,
      p_config: body.config || null,
      p_archived_at: body.archived_at || null,
    });
  });

  // Dispatch onOptionsChanged if config changed
  if (body.config && oldConfig && twistMeta?.options) {
    const schema = (typeof twistMeta.options === "string"
      ? JSON.parse(twistMeta.options)
      : twistMeta.options) as OptionsSchema;

    if (Object.keys(schema).length > 0) {
      const oldOptions = resolveOptions(schema, oldConfig);
      const newOptions = resolveOptions(schema, body.config);

      const changed = Object.keys(schema).some(
        (k) => oldOptions[k] !== newOptions[k]
      );

      if (changed) {
        try {
          const factory = twistFactory({
            env: c.env,
            ctx: c.executionCtx as ExecutionContext,
            db: c.var.db,
          });
          const twistInstance = await factory({
            id: String(twistMeta.twist_id),
            environment: twistMeta.environment as any,
            twistInstanceId: body.id,
          });
          await twistInstance.callCallback([], "onOptionsChanged", oldOptions, newOptions);
        } catch (error) {
          const logger = createLogger({});
          logger.warn("Failed to dispatch onOptionsChanged", { error: String(error) });
        }
      }
    }
  }

  notifyUserSync(c, c.var.user.id);

  const userId = c.var.user.id;
  const tracker = c.var.tracker;
  c.executionCtx.waitUntil(
    (async () => {
      const db = createDb(c.env);
      try {
        await syncUserTwistStats(db, tracker, userId);
      } catch (error) {
        tracker.captureException(error);
      } finally {
        await db.destroy();
      }
    })()
  );

  return c.json(result as any);
});

export default twistInstances;
