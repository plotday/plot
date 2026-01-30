import { createClient, type SupabaseClient } from "@plotday/db";

import type { Bindings, LogMessage, TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";

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
  supabase: SupabaseClient,
  twistPackageId: string,
  priorityId: string,
  createdBy: string,
  authorId: string
): Promise<string> {
  const source = `@plot:releases:${twistPackageId}`;

  const { data, error } = await supabase.rpc("upsert_activity", {
    p_activity: {
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

  if (error) {
    throw new Error(`Failed to ensure Releases activity: ${error.message}`);
  }
  return data.id;
}

/**
 * Adds a release note to the Releases activity.
 */
export async function addReleaseNote(
  supabase: SupabaseClient,
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
    const { data: priorityData, error: priorityError } = await supabase
      .from("priority")
      .select("created_by")
      .eq("id", priorityId)
      .single();

    if (priorityError || !priorityData?.created_by) {
      logger.warn("Could not get priority owner for release note", {
        error_message: priorityError?.message,
      });
      return;
    }

    const createdBy = priorityData.created_by;

    // Get author_id - use deploying user's contact if available, otherwise priority owner's contact
    let authorId: string;
    if (info.userId) {
      const { data: contactId } = await supabase.rpc("get_primary_contact_id", {
        p_user_id: info.userId,
      });
      if (contactId) {
        authorId = contactId;
      } else {
        // Fall back to priority owner's contact
        const { data: ownerContactId } = await supabase.rpc(
          "get_primary_contact_id",
          { p_user_id: createdBy }
        );
        authorId = ownerContactId || createdBy;
      }
    } else {
      // No user info, use priority owner's contact
      const { data: ownerContactId } = await supabase.rpc(
        "get_primary_contact_id",
        { p_user_id: createdBy }
      );
      authorId = ownerContactId || createdBy;
    }

    const activityId = await ensureReleasesActivity(
      supabase,
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

    const { error: noteError } = await supabase.from("note").insert({
      activity_id: activityId,
      author_id: authorId,
      created_by: info.userId || createdBy,
      content,
      updated_by: 0,
      sync_depth: 1,
    });

    if (noteError) {
      logger.error("Failed to insert release note", noteError as Error);
    }
  } catch (error) {
    // Log but don't fail the deployment
    logger.error("Failed to add release note", error as Error);
  }
}

/**
 * Ensures the Logs activity exists for a twist and environment.
 */
async function ensureLogsActivity(
  supabase: SupabaseClient,
  twistPackageId: string,
  priorityId: string,
  environment: string,
  createdBy: string,
  authorId: string
): Promise<string> {
  const source = `@plot:logs:${twistPackageId}:${environment}`;

  const { data, error } = await supabase.rpc("upsert_activity", {
    p_activity: {
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

  if (error) {
    throw new Error(`Failed to ensure Logs activity: ${error.message}`);
  }
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
    const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    // Get priority_id from twist_admin
    const { data: adminData, error: adminError } = await supabase
      .from("twist_admin")
      .select("priority_id")
      .eq("twist_package_id", twistPackageId)
      .not("priority_id", "is", null)
      .limit(1)
      .maybeSingle();

    if (adminError || !adminData?.priority_id) {
      // No priority set up yet, skip logging
      return;
    }

    // Find the Plot twist's priority_twist that covers the target priority
    // priority_child_twist joins: priority_twist -> priority_child -> twist -> twist_admin
    const { data: plotPriorityTwist, error: plotTwistError } = await supabase
      .from("priority_child_twist")
      .select(
        `
        id,
        twist!inner(
          twist_admin!inner(twist_package_id)
        )
      `
      )
      .eq("priority_child_id", adminData.priority_id)
      .eq("twist.twist_admin.twist_package_id", PLOT_TWIST_PACKAGE_ID)
      .maybeSingle();

    if (plotTwistError) {
      logger.warn("Error looking up Plot twist for logs", {
        error_message: plotTwistError.message,
      });
      return;
    }

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
      supabase,
      twistPackageId,
      adminData.priority_id,
      environment,
      createdBy,
      authorId
    );

    const formattedLogs = logs
      .map((log) => `[${log.severity.toUpperCase()}] ${log.message}`)
      .join("\n");

    const content = ["```", formattedLogs, "```"].join("\n");

    const { error: noteError } = await supabase.from("note").insert({
      activity_id: activityId,
      author_id: authorId,
      created_by: createdBy,
      content,
      updated_by: 0,
      sync_depth: 1,
    });

    if (noteError) {
      logger.error("Failed to insert logs note", noteError as Error);
    }
  } catch (error) {
    // Log but don't fail the queue processing
    logger.error("Failed to add logs note", error as Error);
  }
}
