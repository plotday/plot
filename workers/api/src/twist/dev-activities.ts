import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import { withDb } from "../db";
import type { Bindings, LogMessage, TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";

const PLOT_TWIST_PACKAGE_ID = "0199b6f4-ae64-7718-8a02-44716f30358f";

/**
 * Ensures the Logs activity exists for a twist and environment.
 * Uses direct insert to bypass user-level permission checks (the twist dev
 * priority owner is a viewer who can't create non-private threads via upsert_thread).
 */
async function ensureLogsActivity(
  db: Kysely<DB>,
  twistPackageId: string,
  priorityId: string,
  environment: string,
  createdBy: string
): Promise<string> {
  const key = `logs:${twistPackageId}:${environment}`;

  const result = await db
    .insertInto("thread")
    .values({
      key,
      title: `Logs (${environment})`,
      priority_id: priorityId,
      created_by: createdBy,
      updated_by: 0,
    })
    .onConflict((oc) =>
      oc.columns(["priority_id", "key"]).doUpdateSet({
        updated_by: 0,
      })
    )
    .returning("id")
    .executeTakeFirstOrThrow();

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
      // Get priority_id from twist_admin
      const adminData = await db
        .selectFrom("twist_admin")
        .select("priority_id")
        .where("twist_package_id", "=", twistPackageId)
        .where("priority_id", "is not", null)
        .limit(1)
        .executeTakeFirst();

      if (!adminData?.priority_id) {
        // No priority set up yet, skip logging
        return;
      }

      // Find the Plot twist's priority_twist that covers the target priority
      // priority_child_twist joins: priority_twist -> priority_child -> twist -> twist_admin
      const plotPriorityTwist = await db
        .selectFrom("priority_child_twist")
        .innerJoin("twist", "twist.id", "priority_child_twist.twist_id")
        .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
        .select(["priority_child_twist.id"])
        .where("priority_child_twist.priority_child_id", "=", adminData.priority_id)
        .where("twist_admin.twist_package_id", "=", PLOT_TWIST_PACKAGE_ID)
        .executeTakeFirst();

      if (!plotPriorityTwist?.id) {
        // Plot twist not installed in this priority's path, skip silently
        return;
      }

      // Use the Plot twist's priority_twist.id as both created_by and author_id
      const createdBy = plotPriorityTwist.id;
      const authorId = plotPriorityTwist.id;

      // Format logs
      const environment = logs[0]?.environment || "unknown";

      const activityId = await ensureLogsActivity(
        db,
        twistPackageId,
        adminData.priority_id,
        environment,
        createdBy
      );

      const formattedLogs = logs
        .map((log) => `[${log.severity.toUpperCase()}] ${log.message}`)
        .join("\n");

      const content = ["```", formattedLogs, "```"].join("\n");

      await db.insertInto("note").values({
        thread_id: activityId,
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
 * Adds an upgrade note to the Logs activity for a twist deployment.
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
        .select("priority_id")
        .where("twist_package_id", "=", twistPackageId)
        .where("priority_id", "is not", null)
        .limit(1)
        .executeTakeFirst();

      if (!adminData?.priority_id) {
        return;
      }

      const plotPriorityTwist = await db
        .selectFrom("priority_child_twist")
        .innerJoin("twist", "twist.id", "priority_child_twist.twist_id")
        .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
        .select(["priority_child_twist.id"])
        .where("priority_child_twist.priority_child_id", "=", adminData.priority_id)
        .where("twist_admin.twist_package_id", "=", PLOT_TWIST_PACKAGE_ID)
        .executeTakeFirst();

      if (!plotPriorityTwist?.id) {
        return;
      }

      const createdBy = plotPriorityTwist.id;

      const activityId = await ensureLogsActivity(
        db,
        twistPackageId,
        adminData.priority_id,
        environment,
        createdBy
      );

      await db.insertInto("note").values({
        thread_id: activityId,
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
