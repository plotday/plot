import type { Kysely } from "kysely";
import type { Uuid } from "@plotday/twister/plot";

import type { twistFactory } from ".";
import type { DB } from "../db-types";
import { type TwistEnvironment, type Bindings } from "../env";
import { rpc } from "../rpc";
import { createLogger } from "@plotday/worker-util";
import { checkTwistLimit } from "../utils/limits";
import { getEffectivePlan } from "../utils/plan";

/**
 * Cleans up a failed twist installation by:
 * 1. Archiving all activities created by the twist
 * 2. Attempting to call deactivate (best effort, ignores errors)
 * 3. Archiving the priority_twist record
 *
 * All cleanup steps are best-effort and continue even if individual steps fail.
 * Errors are logged but not thrown to avoid masking the original installation error.
 */
async function cleanupFailedInstallation(
  db: Kysely<DB>,
  priorityTwistId: string,
  deactivate?: {
    twistFactory: ReturnType<typeof twistFactory>;
    priorityId: string;
    twistId: number;
    environment: TwistEnvironment;
  }
): Promise<string[]> {
  const warnings: string[] = [];
  const logger = createLogger({ priority_twist_id: priorityTwistId });

  try {
    // Step 1: Archive all activities created by this twist
    logger.info("Cleaning up activities for failed installation");
    await db
      .updateTable("thread")
      .set({ archived_at: new Date().toISOString() })
      .where("created_by", "=", priorityTwistId)
      .where("archived_at", "is", null)
      .execute();
  } catch (error) {
    const msg = `Error archiving activities during cleanup: ${error instanceof Error ? error.message : String(error)}`;
    logger.error(msg);
    warnings.push(msg);
  }

  // Step 2: Try to call deactivate (best effort, may fail if activation was partial)
  if (deactivate) {
    try {
      logger.info("Attempting to deactivate failed installation");

      const twistWrapper = await deactivate.twistFactory({
        priorityId: deactivate.priorityId,
        priorityTwistId: priorityTwistId,
      });
      await twistWrapper.deactivate();
    } catch (error) {
      // Deactivation errors are expected if activation failed partway through
      logger.warn("Deactivation failed during cleanup (expected if activation was incomplete)", {
        error_message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // Step 3: Disable channels and archive the priority_twist record
  try {
    logger.info("Disabling channels and archiving priority_twist record");
    await db
      .updateTable("source_channel")
      .set({ enabled: false })
      .where("priority_twist_id", "=", priorityTwistId)
      .where("enabled", "=", true)
      .execute();
    await db
      .updateTable("priority_twist")
      .set({ archived_at: new Date().toISOString() })
      .where("id", "=", priorityTwistId)
      .execute();
  } catch (error) {
    const msg = `Failed to archive priority_twist during cleanup: ${
      error instanceof Error ? error.message : String(error)
    }`;
    logger.error(msg);
    warnings.push(msg);
  }

  return warnings;
}

export async function add(
  db: Kysely<DB>,
  userId: string,
  priority_id: string,
  twist_id: number,
  twist_environment: TwistEnvironment,
  name?: string,
  config?: any,
  activate?: {
    twistFactory: ReturnType<typeof twistFactory>;
    version?: string;
  }
) {
  try {
    if (!priority_id || typeof priority_id !== "string") {
      throw new Error("priority_id is required and must be a string");
    }
    if (twist_id === undefined || twist_id === null || typeof twist_id !== "number") {
      throw new Error("twist_id is required and must be a number");
    }
    if (!twist_environment || typeof twist_environment !== "string") {
      throw new Error("twist_environment is required and must be a string");
    }

    // Verify user has access to this twist
    const hasAccess = await rpc(db, "is_accessible_twist", {
      p_twist_id: twist_id,
      p_priority_id: priority_id,
      p_user_id: userId,
    });
    if (!hasAccess) {
      throw new Error(
        `You do not have access to twist ${twist_id} for this priority`
      );
    }

    // Get twist metadata
    const { name: twistName } = await db
      .selectFrom("twist")
      .select(["name"])
      .where("id", "=", String(twist_id))
      .executeTakeFirstOrThrow();
    if (!twistName) {
      throw new Error(
        `Twist with id ${twist_id} not found`
      );
    }
    name ??= twistName;

    // Check if twist requires AI and user has it disabled
    const twistRecord = await db
      .selectFrom("twist")
      .select(["permissions", "is_source"])
      .where("id", "=", String(twist_id))
      .executeTakeFirst();

    if (twistRecord?.permissions) {
      const perms = typeof twistRecord.permissions === 'string'
        ? JSON.parse(twistRecord.permissions)
        : twistRecord.permissions;
      if (perms._ai_required === true) {
        const aiPref = await db
          .selectFrom("ai_preference")
          .select("twist_ai_disabled")
          .where("user_id", "=", userId)
          .executeTakeFirst();
        if (aiPref?.twist_ai_disabled === true) {
          throw new Error("This twist requires AI features which are disabled in your settings.");
        }

        // Block free users without API keys from adding AI-required twists
        const effective = await getEffectivePlan(db, userId);
        if (effective.plan === "free") {
          const aiKeyCount = await db
            .selectFrom("ai_key")
            .select(db.fn.countAll().as("count"))
            .where("user_id", "=", userId)
            .executeTakeFirstOrThrow();
          if (Number(aiKeyCount.count) === 0) {
            throw new Error("Add an API key in settings to use AI-powered twists.");
          }
        }
      }
    }

    // Check plan limits before inserting (sources check limits at channel-enable time)
    if (twistRecord?.is_source !== true) {
      const limitCheck = await checkTwistLimit(db, userId, priority_id);
      if (!limitCheck.allowed) {
        throw limitCheck.error;
      }
    }

    const existingTwist = await db
      .selectFrom("priority_twist")
      .select(["id"])
      .where("priority_id", "=", priority_id)
      .where("name", "=", name)
      .where("archived_at", "is", null)
      .executeTakeFirst();
    if (existingTwist) {
      throw new Error(
        `Twist with name "${name}" already exists for this priority.`
      );
    }

    // Get owner_id from priority (using created_by as owner)
    const priority = await db
      .selectFrom("priority")
      .select(["created_by"])
      .where("id", "=", priority_id)
      .executeTakeFirst();

    if (!priority?.created_by) {
      throw new Error("Priority not found or missing created_by");
    }

    const twistValues: {
      priority_id: string;
      twist_id: number;
      name: string;
      owner_id: string;
      config?: any;
    } = {
      priority_id: priority_id,
      twist_id: twist_id,
      name: name,
      owner_id: priority.created_by,
    };
    if (config !== undefined) {
      twistValues.config = config;
    }

    // Insert priority_twist record
    // Access was already verified via is_accessible_twist check above
    const priorityTwist = await db
      .insertInto("priority_twist")
      .values(twistValues)
      .returningAll()
      .executeTakeFirstOrThrow();

    // Activate twist if requested
    if (activate) {
      try {
        const twistWrapper = await activate.twistFactory({
          version: activate.version,
          priorityId: priority_id,
          priorityTwistId: priorityTwist.id,
        });
        await twistWrapper.activate({ id: priority_id as Uuid }, { actor: { id: userId, type: 0 /* ActorType.User */ } });
      } catch (activationError) {
        // Activation failed - rollback the installation
        const logger = createLogger({ priority_twist_id: String(priorityTwist.id), twist_id: String(twist_id), environment: twist_environment });
        logger.error("Twist activation failed, rolling back installation", activationError as Error);

        const cleanupWarnings = await cleanupFailedInstallation(
          db,
          priorityTwist.id,
          {
            twistFactory: activate.twistFactory,
            priorityId: priority_id,
            twistId: twist_id,
            environment: twist_environment,
          }
        );

        // Build error message with cleanup status
        let errorMessage = `Failed to install twist: ${
          activationError instanceof Error
            ? activationError.message
            : String(activationError)
        }`;

        if (cleanupWarnings.length > 0) {
          errorMessage += `\n\nNote: Cleanup encountered issues:\n${cleanupWarnings.join("\n")}`;
        }

        throw new Error(errorMessage);
      }
    }

    return priorityTwist;
  } catch (error) {
    const logger = createLogger({ twist_id: String(twist_id), environment: twist_environment, priority_id });
    logger.error("Error adding twist", error as Error);
    throw error;
  }
}

export async function getAll(
  db: Kysely<DB>,
  userId: string,
  priorityId: string
) {
  try {
    if (!priorityId || typeof priorityId !== "string") {
      throw new Error("priorityId is required and must be a string");
    }

    // Query twists that are either:
    // 1. Public (environment = 'public'), OR
    // 2. User has access via twist_access table AND
    //    - priority_access_id is NULL (can install anywhere), OR
    //    - target priority is descendant of or equal to priority_access_id
    const data = await rpc(db, "get_accessible_twists", {
      p_priority_id: priorityId,
      p_user_id: userId,
    });

    // Enrich twist data with publisher information
    const twistArray = Array.isArray(data) ? data : data ? [data] : [];
    const enrichedData = await Promise.all(
      twistArray.map(async (twist: any) => {
        // For personal twists, author is the user themselves
        if (twist.environment === "personal") {
          return {
            ...twist,
            author_name: "You",
            author_email: null,
            author_url: null,
          };
        }

        // For other environments, get publisher info via twist_admin
        const adminData = await db
          .selectFrom("twist_admin")
          .leftJoin("publisher", "publisher.id", "twist_admin.publisher_id")
          .select([
            "twist_admin.id",
            "publisher.name as publisher_name",
            "publisher.email as publisher_email",
            "publisher.url as publisher_url",
          ])
          .where("twist_admin.id", "=", twist.twist_admin_id)
          .executeTakeFirst();

        // Always return author fields, even if null
        return {
          ...twist,
          author_name: adminData?.publisher_name || null,
          author_email: adminData?.publisher_email || null,
          author_url: adminData?.publisher_url || null,
        };
      })
    );

    return enrichedData;
  } catch (error) {
    const logger = createLogger();
    logger.error("Error fetching twists", error as Error);
    throw error;
  }
}

export async function getById(
  db: Kysely<DB>,
  priority_twist_id: string
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("twist_id is required and must be a string");
    }

    // Query priority_twist with twist permissions via JOIN
    const data = await db
      .selectFrom("priority_twist")
      .leftJoin("twist", "twist.id", "priority_twist.twist_id")
      .select([
        "priority_twist.id",
        "priority_twist.priority_id",
        "priority_twist.twist_id",
        "priority_twist.name",
        "priority_twist.owner_id",
        "priority_twist.config",
        "priority_twist.archived_at",
        "priority_twist.created_at",
        "priority_twist.updated_at",
        "twist.permissions",
        "twist.options",
        "twist.is_source",
      ])
      .where("priority_twist.id", "=", priority_twist_id)
      .where("priority_twist.archived_at", "is", null)
      .executeTakeFirstOrThrow();

    return data;
  } catch (error) {
    const logger = createLogger({ priority_twist_id });
    logger.error("Error fetching twist", error as Error);
    throw error;
  }
}

export async function getByPriority(
  db: Kysely<DB>,
  priority_id: string
) {
  try {
    if (!priority_id || typeof priority_id !== "string") {
      throw new Error("priority_id is required and must be a string");
    }

    const logger = createLogger({ priority_id });
    logger.debug("Querying priority_child_twist for priority");

    // The priority_child_twist view doesn't include permissions,
    // so we need to join with the twist table to get them.
    const data = await db
      .selectFrom("priority_child_twist")
      .leftJoin("twist", "twist.id", "priority_child_twist.twist_id")
      .select([
        "priority_child_twist.id",
        "priority_child_twist.priority_id",
        "priority_child_twist.priority_child_id",
        "priority_child_twist.twist_id",
        "priority_child_twist.name",
        "priority_child_twist.owner_id",
        "priority_child_twist.config",
        "priority_child_twist.archived_at",
        "priority_child_twist.created_at",
        "priority_child_twist.updated_at",
        "priority_child_twist.twist_environment",
        "priority_child_twist.is_source",
        "priority_child_twist.version",
        "priority_child_twist.author_name",
        "priority_child_twist.author_email",
        "priority_child_twist.author_url",
        "twist.permissions",
        "twist.options",
      ])
      .where("priority_child_twist.priority_child_id", "=", priority_id)
      .where("priority_child_twist.archived_at", "is", null)
      .execute();

    logger.debug("Query returned rows", { row_count: data?.length || 0 });
    if (data && data.length > 0) {
      logger.debug("First row", { first_row: data[0] });
    }

    return data;
  } catch (error) {
    const logger = createLogger({ priority_id });
    logger.error("Error fetching twists", error as Error);
    throw error;
  }
}

export async function update(
  db: Kysely<DB>,
  priority_twist_id: string,
  twist: { name?: string; config?: any }
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("priority_twist_id is required and must be a string");
    }

    if (twist.name !== undefined) {
      // First, get the current record to find the priority_id
      const currentTwist = await db
        .selectFrom("priority_twist")
        .select(["priority_id", "name"])
        .where("id", "=", priority_twist_id)
        .where("archived_at", "is", null)
        .executeTakeFirstOrThrow();

      // Only check for duplicates if the name is actually changing
      if (twist.name !== currentTwist.name) {
        // Check if the new name already exists for this priority
        const existingTwists = await db
          .selectFrom("priority_twist")
          .select(["id"])
          .where("priority_id", "=", currentTwist.priority_id)
          .where("name", "=", twist.name)
          .where("id", "!=", priority_twist_id)
          .where("archived_at", "is", null)
          .execute();

        if (existingTwists && existingTwists.length > 0) {
          throw new Error(
            `Twist with name "${twist.name}" already exists for this priority.`
          );
        }
      }
    }

    return await db
      .updateTable("priority_twist")
      .set(twist)
      .where("id", "=", priority_twist_id)
      .returningAll()
      .executeTakeFirstOrThrow();
  } catch (error) {
    const logger = createLogger({ priority_twist_id });
    logger.error("Error updating twist", error as Error);
    throw error;
  }
}

export async function deleteTwist(
  db: Kysely<DB>,
  priority_twist_id: string,
  deactivate?: {
    twistFactory: ReturnType<typeof twistFactory>;
  }
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("priority_twist_id is required and must be a string");
    }

    // Call deactivate callback if requested
    if (deactivate) {
      try {
        // Get twist metadata needed to create wrapper
        // Need to join with twist table to get environment and twist_admin_id
        const priorityTwist = await db
          .selectFrom("priority_twist")
          .innerJoin("twist", "twist.id", "priority_twist.twist_id")
          .select([
            "priority_twist.twist_id",
            "priority_twist.priority_id",
            "twist.environment",
            "twist.twist_admin_id",
          ])
          .where("priority_twist.id", "=", priority_twist_id)
          .where("priority_twist.archived_at", "is", null)
          .executeTakeFirst();

        const logger = createLogger({ priority_twist_id });

        if (!priorityTwist) {
          logger.warn("Could not fetch priority_twist for deactivation");
        } else {
          // Get twist_package_id from twist_admin
          const adminData = await db
            .selectFrom("twist_admin")
            .select(["twist_package_id"])
            .where("id", "=", priorityTwist.twist_admin_id)
            .executeTakeFirst();

          if (!adminData) {
            logger.warn("Could not fetch twist_package_id for deactivation");
          } else {
            const twistWrapper = await deactivate.twistFactory({
              id: adminData.twist_package_id,
              environment: priorityTwist.environment,
              priorityId: priorityTwist.priority_id!,
              priorityTwistId: priority_twist_id,
            });
            await twistWrapper.deactivate();
          }
        }
      } catch (deactivateError) {
        // Log deactivation errors but continue with deletion
        const logger = createLogger({ priority_twist_id });
        logger.error("Error calling deactivate callback (continuing with deletion)", deactivateError as Error);
      }
    }

    // Disable all channels before archiving
    await db
      .updateTable("source_channel")
      .set({ enabled: false })
      .where("priority_twist_id", "=", priority_twist_id)
      .where("enabled", "=", true)
      .execute();

    // Clean up connection rows before archiving
    await db
      .deleteFrom("priority_twist_connection")
      .where("priority_twist_id", "=", priority_twist_id)
      .execute();

    return await db
      .updateTable("priority_twist")
      .set({ archived_at: new Date().toISOString() })
      .where("id", "=", priority_twist_id)
      .returningAll()
      .executeTakeFirstOrThrow();
  } catch (error) {
    const logger = createLogger({ priority_twist_id });
    logger.error("Error deleting twist", error as Error);
    throw error;
  }
}

/**
 * Create a draft twist (priority_id = NULL).
 * Used during the setup flow before the user picks a priority.
 */
export async function createDraft(
  db: Kysely<DB>,
  userId: string,
  twist_id: number,
  twist_environment: TwistEnvironment,
  name?: string
) {
  try {
    if (twist_id === undefined || twist_id === null || typeof twist_id !== "number") {
      throw new Error("twist_id is required and must be a number");
    }

    // Get twist metadata for the name
    const { name: twistName } = await db
      .selectFrom("twist")
      .select(["name"])
      .where("id", "=", String(twist_id))
      .executeTakeFirstOrThrow();
    if (!twistName) {
      throw new Error(`Twist with id ${twist_id} not found`);
    }
    name ??= twistName;

    // Insert priority_twist with NULL priority_id (draft)
    const priorityTwist = await db
      .insertInto("priority_twist")
      .values({
        priority_id: null,
        twist_id: twist_id,
        name: name,
        owner_id: userId,
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    return priorityTwist;
  } catch (error) {
    const logger = createLogger({ twist_id: String(twist_id), environment: twist_environment });
    logger.error("Error creating draft twist", error as Error);
    throw error;
  }
}

/**
 * Activate a draft twist: assign priority, call activate lifecycle, enable channels.
 */
export async function activateDraft(
  db: Kysely<DB>,
  env: Bindings,
  draftId: string,
  priorityId: string | undefined,
  name: string,
  config: Record<string, any> | undefined,
  syncables: Array<{ provider: string; syncableId: string; priorityId?: string; createThreads?: string }> | undefined,
  activate: {
    twistFactory: ReturnType<typeof twistFactory>;
  }
) {
  const logger = createLogger({ priority_twist_id: draftId });

  // Verify draft exists and is actually a draft (priority_id IS NULL)
  const draft = await db
    .selectFrom("priority_twist")
    .selectAll()
    .where("id", "=", draftId)
    .where("priority_id", "is", null)
    .where("archived_at", "is", null)
    .executeTakeFirst();

  if (!draft) {
    throw new Error("Draft not found or already activated");
  }

  // Check if twist requires AI and user has it disabled
  const twistRecord = await db
    .selectFrom("twist")
    .select(["permissions", "is_source"])
    .where("id", "=", String(draft.twist_id))
    .executeTakeFirst();

  if (twistRecord?.permissions) {
    const perms = typeof twistRecord.permissions === 'string'
      ? JSON.parse(twistRecord.permissions)
      : twistRecord.permissions;
    if (perms._ai_required === true) {
      const aiPref = await db
        .selectFrom("ai_preference")
        .select("twist_ai_disabled")
        .where("user_id", "=", draft.owner_id)
        .executeTakeFirst();
      if (aiPref?.twist_ai_disabled === true) {
        throw new Error("This twist requires AI features which are disabled in your settings.");
      }

      // Block free users without API keys from activating AI-required twists
      const effective = await getEffectivePlan(db, draft.owner_id);
      if (effective.plan === "free") {
        const aiKeyCount = await db
          .selectFrom("ai_key")
          .select(db.fn.countAll().as("count"))
          .where("user_id", "=", draft.owner_id)
          .executeTakeFirstOrThrow();
        if (Number(aiKeyCount.count) === 0) {
          throw new Error("Add an API key in settings to use AI-powered twists.");
        }
      }
    }
  }

  // Check plan limits before activating (sources check limits at channel-enable time)
  if (twistRecord?.is_source !== true) {
    const limitCheck = await checkTwistLimit(db, draft.owner_id, priorityId ?? null);
    if (!limitCheck.allowed) {
      throw limitCheck.error;
    }
  }

  // Check for name conflicts on the target priority (only if priorityId provided)
  if (priorityId) {
    const existingTwist = await db
      .selectFrom("priority_twist")
      .select(["id"])
      .where("priority_id", "=", priorityId)
      .where("name", "=", name)
      .where("archived_at", "is", null)
      .executeTakeFirst();
    if (existingTwist) {
      throw new Error(`Twist with name "${name}" already exists for this priority.`);
    }
  }

  // Set priority_id (may be null for sources), name, and config
  await db
    .updateTable("priority_twist")
    .set({
      ...(priorityId ? { priority_id: priorityId } : {}),
      name,
      ...(config ? { config } : {}),
    })
    .where("id", "=", draftId)
    .execute();

  // Call activate lifecycle
  try {
    const twistWrapper = await activate.twistFactory({
      priorityId: priorityId ?? draftId, // Sources use draftId as context
      priorityTwistId: draftId,
    });

    const actorContext: { actor: { id: string; type: number }; auth?: any } = {
      actor: { id: draft.owner_id, type: 0 /* ActorType.User */ },
    };

    // For sources, construct Authorization from sourceProvider metadata and owner contact
    if (twistWrapper.sourceProvider) {
      const ownerContact = await db
        .selectFrom("contact")
        .select(["id", "email", "name"])
        .where("user_id", "=", draft.owner_id)
        .executeTakeFirst();

      if (ownerContact) {
        actorContext.auth = {
          provider: twistWrapper.sourceProvider.provider,
          scopes: twistWrapper.sourceProvider.scopes,
          actor: {
            id: ownerContact.id,
            type: 0 /* ActorType.User */,
            email: ownerContact.email,
            name: ownerContact.name,
          },
        };
      }
    }

    await twistWrapper.activate(
      { id: (priorityId ?? draftId) as Uuid },
      actorContext,
    );
  } catch (activationError) {
    logger.error("Twist activation failed during draft activation", activationError as Error);

    // Rollback: set priority_id back to NULL (keep draft alive for retry)
    if (priorityId) {
      await db
        .updateTable("priority_twist")
        .set({ priority_id: null })
        .where("id", "=", draftId)
        .execute();
    }

    throw new Error(
      `Failed to activate twist: ${
        activationError instanceof Error ? activationError.message : String(activationError)
      }`
    );
  }

  // Enable selected channels via callCallback to the Integrations tool
  if (syncables && syncables.length > 0) {
    logger.info("activateDraft: enabling channels", {
      channel_count: syncables.length,
      channels: syncables.map(s => `${s.provider}:${s.syncableId}`),
    });

    // Look up integrationsMap from twist config KV
    const twistInfo = await db
      .selectFrom("priority_twist")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
      .select([
        "twist.version",
        "twist_admin.twist_package_id as twistPackageId",
      ])
      .where("priority_twist.id", "=", draftId)
      .executeTakeFirst();

    logger.info("activateDraft: twist info lookup", {
      twist_package_id: twistInfo?.twistPackageId,
      version: twistInfo?.version,
    });

    const configKey = twistInfo ? `${twistInfo.twistPackageId}:${twistInfo.version}` : null;
    const configStr = configKey
      ? await env.TWIST_CONFIG.get(configKey)
      : null;
    const integrationsMap: Record<string, string> = configStr
      ? (JSON.parse(configStr).integrationsMap ?? {})
      : {};

    logger.info("activateDraft: integrationsMap", {
      config_key: configKey,
      has_config: !!configStr,
      integrations_map: integrationsMap,
    });

    // Get current user's contact for the actor ID
    const contact = await db
      .selectFrom("contact")
      .select("id")
      .where("user_id", "=", draft.owner_id)
      .executeTakeFirst();

    logger.info("activateDraft: contact lookup", {
      owner_id: draft.owner_id,
      contact_id: contact?.id,
    });

    if (contact) {
      const twistWrapper = await activate.twistFactory({
        priorityId: priorityId ?? draftId,
        priorityTwistId: draftId,
      });

      for (const { provider, syncableId, priorityId: channelPriorityId, createThreads } of syncables) {
        const integrationsPath = integrationsMap[provider];
        if (!integrationsPath) {
          logger.warn("No integrations path found for provider during activation", {
            provider,
            syncable_id: syncableId,
            available_providers: Object.keys(integrationsMap),
          });
          continue;
        }

        logger.info("activateDraft: calling enableSync", {
          provider,
          syncable_id: syncableId,
          integrations_path: integrationsPath,
          actor_id: contact.id,
          priority_id: channelPriorityId,
          create_threads: createThreads,
        });

        try {
          const result = await twistWrapper.callCallback(
            integrationsPath.split(":"),
            "enableSync",
            provider,
            syncableId,
            contact.id,
            undefined, // title
            channelPriorityId,
            createThreads
          );
          logger.info("activateDraft: enableSync result", {
            provider,
            syncable_id: syncableId,
            has_result: !!result,
            result_type: typeof result,
          });
          if (result && typeof result === "object" && Symbol.dispose in result) {
            (result as any)[Symbol.dispose]();
          }
        } catch (error) {
          logger.warn("Failed to enable channel during activation", {
            provider,
            syncable_id: syncableId,
            error_message: error instanceof Error ? error.message : String(error),
          });
        }
      }
    }
  } else {
    logger.info("activateDraft: no channels to enable", {
      has_channels: !!syncables,
      channel_count: syncables?.length ?? 0,
    });
  }

  return draft;
}

/**
 * Delete a draft twist (hard delete since it was never activated).
 */
export async function deleteDraft(
  db: Kysely<DB>,
  draftId: string
) {
  const logger = createLogger({ priority_twist_id: draftId });

  // Verify it's actually a draft
  const draft = await db
    .selectFrom("priority_twist")
    .selectAll()
    .where("id", "=", draftId)
    .where("priority_id", "is", null)
    .executeTakeFirst();

  if (!draft) {
    // Not a draft or doesn't exist - no-op
    return;
  }

  // Hard-delete the draft row
  await db
    .deleteFrom("priority_twist")
    .where("id", "=", draftId)
    .where("priority_id", "is", null)
    .execute();

  logger.info("Draft twist deleted", { draft_id: draftId });
}

export async function archiveAndDeleteTwist(
  db: Kysely<DB>,
  priority_twist_id: string,
  deactivate?: {
    twistFactory: ReturnType<typeof twistFactory>;
  }
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("priority_twist_id is required and must be a string");
    }

    // Check if this is a connector (source) or a twist
    const pt = await db
      .selectFrom("priority_twist")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .select("twist.is_source")
      .where("priority_twist.id", "=", priority_twist_id)
      .executeTakeFirst();

    if (pt?.is_source) {
      // Connector: archive links and threads with no remaining active links
      await rpc(db, "archive_links", {
        p_created_by: priority_twist_id,
        p_filter: {},
      });
    } else {
      // Twist: archive threads directly (twists create threads, not links)
      await db
        .updateTable("thread")
        .set({ archived_at: new Date().toISOString() })
        .where("created_by", "=", priority_twist_id)
        .where("archived_at", "is", null)
        .execute();
    }

    // Then delete the twist (which also calls deactivate if provided)
    return await deleteTwist(db, priority_twist_id, deactivate);
  } catch (error) {
    const logger = createLogger({ priority_twist_id });
    logger.error("Error archiving and deleting twist", error as Error);
    throw error;
  }
}
