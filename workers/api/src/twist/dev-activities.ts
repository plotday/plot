import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import { withDb } from "../db";
import type { Bindings, LogMessage, TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";
import { rpc, rpcUser } from "../rpc";

const PLOT_TWIST_PACKAGE_ID = "0199b6f4-ae64-7718-8a02-44716f30358f";

interface DeploymentInfo {
  userName?: string;
  userEmail?: string;
  userId?: string;
  environment: TwistEnvironment;
  version: string;
  autoApproveToPublic: boolean;
}

/**
 * Ensures the Releases activity exists for a twist.
 * Creates it with source key if it doesn't exist.
 */
async function ensureReleasesActivity(
  db: Kysely<DB>,
  twistPackageId: string,
  priorityId: string,
  createdBy: string,
  authorId: string
): Promise<string> {
  const source = `@plot:releases:${twistPackageId}`;

  const data = await rpcUser(db, "upsert_thread", {
    user_id: createdBy,
    p_thread: {
      source,
      type: "note",
      title: "Releases",
      priority_id: priorityId,
    },
    p_defaults: {
      updated_by: 0,
      created_by: createdBy,
      author_id: authorId,
    },
  });

  return data.id;
}

/**
 * Adds a release note to the Releases activity.
 */
export async function addReleaseNote(
  db: Kysely<DB>,
  twistPackageId: string,
  priorityId: string,
  info: DeploymentInfo
): Promise<void> {
  const logger = createLogger({
    twist_package_id: twistPackageId,
    environment: info.environment,
  });

  try {
    // Get the priority owner for created_by
    const priorityData = await db
      .selectFrom("priority")
      .select("created_by")
      .where("id", "=", priorityId)
      .executeTakeFirst();

    if (!priorityData?.created_by) {
      logger.warn("Could not get priority owner for release note");
      return;
    }

    const createdBy = priorityData.created_by;

    // Get author_id - use deploying user's contact if available, otherwise priority owner's contact
    let authorId: string;
    if (info.userId) {
      const contactId = await rpc(db, "get_primary_contact_id", {
        p_user_id: info.userId,
      });
      if (contactId) {
        authorId = contactId;
      } else {
        // Fall back to priority owner's contact
        const ownerContactId = await rpc(db, "get_primary_contact_id", {
          p_user_id: createdBy,
        });
        authorId = ownerContactId || createdBy;
      }
    } else {
      // No user info, use priority owner's contact
      const ownerContactId = await rpc(db, "get_primary_contact_id", {
        p_user_id: createdBy,
      });
      authorId = ownerContactId || createdBy;
    }

    const activityId = await ensureReleasesActivity(
      db,
      twistPackageId,
      priorityId,
      createdBy,
      authorId
    );

    const envDisplay = info.autoApproveToPublic
      ? `${info.environment} (+ public)`
      : info.environment;

    const content = [
      `## v${info.version} - ${envDisplay}`,
      info.autoApproveToPublic ? "\n_Auto-approved to public_" : "",
    ]
      .filter(Boolean)
      .join("\n");

    await db.insertInto("note").values({
      thread_id: activityId,
      author_id: authorId,
      created_by: info.userId || createdBy,
      content,
      updated_by: 0,
      sync_depth: 1,
    }).execute();
  } catch (error) {
    // Log but don't fail the deployment
    logger.error("Failed to add release note", error as Error);
  }
}

/**
 * Ensures the Logs activity exists for a twist and environment.
 */
async function ensureLogsActivity(
  db: Kysely<DB>,
  twistPackageId: string,
  priorityId: string,
  environment: string,
  createdBy: string,
  authorId: string,
  userId: string
): Promise<string> {
  const source = `@plot:logs:${twistPackageId}:${environment}`;

  const data = await rpcUser(db, "upsert_thread", {
    user_id: userId,
    p_thread: {
      source,
      type: "note",
      title: `Logs (${environment})`,
      priority_id: priorityId,
    },
    p_defaults: {
      updated_by: 0,
      created_by: createdBy,
      author_id: authorId,
    },
  });

  return data.id;
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
        .select(["priority_child_twist.id", "priority_child_twist.owner_id"])
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
      const userId = plotPriorityTwist.owner_id;

      if (!userId) {
        logger.warn("Plot twist owner not found for log activity");
        return;
      }

      // Format logs
      const environment = logs[0]?.environment || "unknown";

      const activityId = await ensureLogsActivity(
        db,
        twistPackageId,
        adminData.priority_id,
        environment,
        createdBy,
        authorId,
        userId
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
