import { sql, type Kysely } from "kysely";

import type { DB } from "../db-types";
import { withDb } from "../db";
import type { Bindings, LogMessage, TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";
import { BUILTIN_TWIST_PACKAGE_ID as PLOT_TWIST_PACKAGE_ID } from "../utils/limits";

/**
 * Ensures the Logs thread exists for a twist and environment.
 * Uses direct insert to bypass user-level permission checks (the twist dev
 * priority owner is a viewer who can't create non-private threads via upsert_thread).
 */
async function ensureLogsThread(
  db: Kysely<DB>,
  twistPackageId: string,
  userId: string,
  environment: string,
  createdBy: string
): Promise<string> {
  const key = `logs:${twistPackageId}:${environment}`;

  const result = await db
    .insertInto("thread")
    .values({
      key,
      title: `Logs (${environment})`,
      created_by: createdBy,
      updated_by: 0,
    })
    .onConflict((oc) =>
      oc.columns(["created_by", "key"]).doUpdateSet({
        updated_by: 0,
      })
    )
    .returning("id")
    .executeTakeFirstOrThrow();

  // File the thread under the user's root priority
  const rootPriority = await db
    .selectFrom("priority")
    .select(["id", "user_id"])
    .where("user_id", "=", userId)
    .where("archived_at", "is", null)
    .orderBy(sql`nlevel(path)`, "asc")
    .orderBy("created_at", "asc")
    .limit(1)
    .executeTakeFirst();

  if (!rootPriority) {
    // User has no priorities yet — skip filing this log thread
    return result.id;
  }

  await db
    .insertInto("thread_priority")
    .values({ thread_id: result.id, user_id: userId, priority_id: rootPriority.id })
    .onConflict((oc) => oc.columns(["thread_id", "user_id"]).doUpdateSet({ priority_id: rootPriority.id }))
    .execute();

  return result.id;
}

/**
 * Adds logs to the Logs activity.
 */
export async function addLogsNote(
  env: Bindings,
  twistPackageId: string,
  logs: LogMessage[]
): Promise<void> {
  const logger = createLogger({
    twist_package_id: twistPackageId,
  });

  try {
    await withDb(env, async (db) => {
      // Get user_id from twist_admin
      const adminData = await db
        .selectFrom("twist_admin")
        .select("user_id")
        .where("twist_package_id", "=", twistPackageId)
        .where("user_id", "is not", null)
        .limit(1)
        .executeTakeFirst();

      if (!adminData?.user_id) {
        // publisher-owned twists don't get dev logs
        return;
      }

      const ownerId = adminData.user_id;

      // Find the Plot twist's twist_instance owned by the twist developer.
      const plotTwistInstance = await db
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
        .select(["twist_instance.id"])
        .where("twist_instance.owner_id", "=", ownerId)
        .where("twist_admin.twist_package_id", "=", PLOT_TWIST_PACKAGE_ID)
        .where("twist_instance.archived_at", "is", null)
        .executeTakeFirst();

      if (!plotTwistInstance?.id) {
        // Plot twist not installed for this user, skip silently
        return;
      }

      // Use the Plot twist's twist_instance.id as both created_by and author_id
      const createdBy = plotTwistInstance.id;
      const authorId = plotTwistInstance.id;

      // Format logs
      const environment = logs[0]?.environment || "unknown";

      const threadId = await ensureLogsThread(
        db,
        twistPackageId,
        ownerId,
        environment,
        createdBy
      );

      const formattedLogs = logs
        .map((log) => `[${log.severity.toUpperCase()}] ${log.message}`)
        .join("\n");

      const content = ["```", formattedLogs, "```"].join("\n");

      await db.insertInto("note").values({
        thread_id: threadId,
        author_id: authorId,
        created_by: createdBy,
        content,
        updated_by: 0,
        sync_depth: 1,
      }).execute();
    });
  } catch (error) {
    // Log but don't fail the queue processing
    logger.error("Failed to add logs note", error as Error);
  }
}

/**
 * Adds an upgrade note to the Logs thread for a twist deployment.
 */
export async function addUpgradeNote(
  env: Bindings,
  twistPackageId: string,
  environment: TwistEnvironment,
  version: string
): Promise<void> {
  const logger = createLogger({
    twist_package_id: twistPackageId,
    environment,
  });

  try {
    await withDb(env, async (db) => {
      const adminData = await db
        .selectFrom("twist_admin")
        .select("user_id")
        .where("twist_package_id", "=", twistPackageId)
        .where("user_id", "is not", null)
        .limit(1)
        .executeTakeFirst();

      if (!adminData?.user_id) {
        // publisher-owned twists don't get dev logs
        return;
      }

      const ownerId = adminData.user_id;

      const plotTwistInstance = await db
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
        .select(["twist_instance.id"])
        .where("twist_instance.owner_id", "=", ownerId)
        .where("twist_admin.twist_package_id", "=", PLOT_TWIST_PACKAGE_ID)
        .where("twist_instance.archived_at", "is", null)
        .executeTakeFirst();

      if (!plotTwistInstance?.id) {
        return;
      }

      const createdBy = plotTwistInstance.id;

      const threadId = await ensureLogsThread(
        db,
        twistPackageId,
        ownerId,
        environment,
        createdBy
      );

      await db.insertInto("note").values({
        thread_id: threadId,
        author_id: createdBy,
        created_by: createdBy,
        content: `Upgraded to v${version}`,
        updated_by: 0,
        sync_depth: 1,
      }).execute();
    });
  } catch (error) {
    logger.error("Failed to add upgrade note", error as Error);
  }
}
