import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { twistFactory } from "../../twist";
import { resolveOptions } from "../../twist/tools/factory";
import type { OptionsSchema } from "@plotday/twister/options";
import { assertPriorityAccess } from "./authorize";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync, notifyUserSync } from "./notify";
import { createLogger } from "@plotday/worker-util";

const priorityTwists = new Hono<{ Bindings: Bindings }>();

// GET /sync/priority-twists
// priority_twist table doesn't have user_id; filter by user's accessible priorities
priorityTwists.get("/sync/priority-twists", async (c) => {
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

  // Self-heal: backfill priority_twist_connection for pre-existing connections
  const unconnectedSources = (rows as any[]).filter(
    (r) => r.is_source && !r.user_connected
  );

  if (unconnectedSources.length > 0) {
    const userContacts = await c.var.db
      .selectFrom("contact")
      .select("id")
      .where("user_id", "=", userId)
      .execute();
    const contactIds = new Set(userContacts.map((ct) => ct.id));

    if (contactIds.size > 0) {
      for (const row of unconnectedSources) {
        try {
          const twistInfo = await c.var.db
            .selectFrom("twist")
            .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
            .select(["twist_admin.twist_package_id", "twist.version"])
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
                await c.var.db
                  .insertInto("priority_twist_connection")
                  .values({
                    priority_twist_id: row.id,
                    user_id: userId,
                    provider,
                    actor_id: actorId,
                    connected_at: new Date().toISOString(),
                  })
                  .onConflict((oc) =>
                    oc
                      .columns(["priority_twist_id", "user_id", "provider"])
                      .doNothing()
                  )
                  .execute();
                row.user_connected = true;
                break;
              }
            }
            if (row.user_connected) break;
          }
        } catch {
          // Non-critical backfill — don't fail the sync
        }
      }
    }
  }

  return c.json(rows as any);
});

// POST /sync/priority-twists
priorityTwists.post("/sync/priority-twists", async (c) => {
  const body = await c.req.json();

  // Load old config before upsert (for onOptionsChanged dispatch)
  let oldConfig: Record<string, unknown> | undefined;
  let twistMeta: { twist_id: string | number | bigint; priority_id: string | null; options: any; environment: string } | undefined;
  if (body.config && body.id) {
    const oldRecord = await c.var.db
      .selectFrom("priority_twist")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .select(["priority_twist.config", "priority_twist.priority_id", "priority_twist.twist_id", "twist.options", "twist.environment"])
      .where("priority_twist.id", "=", body.id)
      .executeTakeFirst();
    if (oldRecord) {
      oldConfig = oldRecord.config
        ? (typeof oldRecord.config === "string" ? JSON.parse(oldRecord.config) : oldRecord.config as Record<string, unknown>)
        : {};
      twistMeta = {
        twist_id: oldRecord.twist_id,
        priority_id: oldRecord.priority_id,
        options: oldRecord.options,
        environment: oldRecord.environment as string,
      };
    }
  }

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    // Source accounts have NULL priority_id; skip access check for those
    if (body.priority_id) {
      await assertPriorityAccess(trx, c.var.user.id, body.priority_id);
    }
    return rpcUser(trx, "upsert_priority_twist", {
      user_id: c.var.user.id,
      p_id: body.id,
      p_priority_id: body.priority_id || null,
      p_twist_id: body.twist_id,
      p_owner_id: body.owner_id,
      p_name: body.name || null,
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

      if (changed && twistMeta.priority_id) {
        try {
          const factory = twistFactory({
            env: c.env,
            ctx: c.executionCtx as ExecutionContext,
            db: c.var.db,
          });
          const twistInstance = await factory({
            id: String(twistMeta.twist_id),
            environment: twistMeta.environment as any,
            priorityId: twistMeta.priority_id,
            priorityTwistId: body.id,
          });
          await twistInstance.callCallback([], "onOptionsChanged", oldOptions, newOptions);
        } catch (error) {
          const logger = createLogger({});
          logger.warn("Failed to dispatch onOptionsChanged", { error: String(error) });
        }
      }
    }
  }

  if (body.priority_id) {
    notifySync(c, body.priority_id);
  } else {
    notifyUserSync(c, c.var.user.id);
  }

  return c.json(result as any);
});

export default priorityTwists;
