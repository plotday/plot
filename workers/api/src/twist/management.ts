import { sql, type Kysely } from "kysely";
import type { Uuid } from "@plotday/twister/plot";

import type { twistFactory } from ".";
import type { DB } from "../db-types";
import { type TwistEnvironment, type Bindings } from "../env";
import { rpc } from "../rpc";
import { createLogger } from "@plotday/worker-util";
import { BUILTIN_TWIST_PACKAGE_ID, checkTwistLimit } from "../utils/limits";
import { getEffectivePlan } from "../utils/plan";

/**
 * Cleans up a failed twist installation by:
 * 1. Archiving all activities created by the twist
 * 2. Attempting to call deactivate (best effort, ignores errors)
 * 3. Archiving the twist_instance record
 *
 * All cleanup steps are best-effort and continue even if individual steps fail.
 * Errors are logged but not thrown to avoid masking the original installation error.
 */
async function cleanupFailedInstallation(
  db: Kysely<DB>,
  twistInstanceId: string,
  deactivate?: {
    twistFactory: ReturnType<typeof twistFactory>;
    twistId: number;
    environment: TwistEnvironment;
  }
): Promise<string[]> {
  const warnings: string[] = [];
  const logger = createLogger({ twist_instance_id: twistInstanceId });

  try {
    // Step 1: Archive all activities created by this twist
    logger.info("Cleaning up activities for failed installation");
    await db
      .updateTable("thread")
      .set({ archived_at: new Date().toISOString() })
      .where("created_by", "=", twistInstanceId)
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
        twistInstanceId: twistInstanceId,
      });
      await twistWrapper.deactivate();
    } catch (error) {
      // Deactivation errors are expected if activation failed partway through
      logger.warn("Deactivation failed during cleanup (expected if activation was incomplete)", {
        error_message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // Step 3: Disable channels and archive the twist_instance record
  try {
    logger.info("Disabling channels and archiving twist_instance record");
    await db
      .updateTable("channel")
      .set({ enabled: false })
      .where("twist_instance_id", "=", twistInstanceId)
      .where("enabled", "=", true)
      .execute();
    await db
      .updateTable("twist_instance")
      .set({ archived_at: new Date().toISOString() })
      .where("id", "=", twistInstanceId)
      .execute();
  } catch (error) {
    const msg = `Failed to archive twist_instance during cleanup: ${
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
  },
  team_id?: string | null
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

    // If the caller specified a team, verify the user is a member.
    if (team_id) {
      const membership = await db
        .selectFrom("team_user")
        .select("role")
        .where("team_id", "=", team_id)
        .where("user_id", "=", userId)
        .executeTakeFirst();
      if (!membership) {
        throw new Error("You are not a member of the specified team");
      }
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
      const limitCheck = await checkTwistLimit(db, userId, team_id ?? null);
      if (!limitCheck.allowed) {
        throw limitCheck.error;
      }
    }

    // Twists are workspace-level: name uniqueness is per owner (personal)
    // or per team for team-owned twists. Sources (connectors) are exempt
    // because users can add multiple connections from the same connector.
    if (twistRecord?.is_source !== true) {
      const existingTwist = await db
        .selectFrom("twist_instance")
        .select(["id"])
        .$if(team_id != null, (qb) => qb.where("team_id", "=", team_id!))
        .$if(team_id == null, (qb) =>
          qb.where("owner_id", "=", userId).where("team_id", "is", null)
        )
        .where("name", "=", name)
        .where("archived_at", "is", null)
        .executeTakeFirst();
      if (existingTwist) {
        throw new Error(
          `Twist with name "${name}" already exists.`
        );
      }
    }

    const twistValues: {
      twist_id: number;
      name: string;
      owner_id: string;
      team_id?: string | null;
      options?: any;
    } = {
      twist_id: twist_id,
      name: name,
      owner_id: userId,
      team_id: team_id ?? null,
    };
    if (config !== undefined) {
      twistValues.options = config;
    }

    // Insert twist_instance record
    // Access was already verified via is_accessible_twist check above
    const twistInstance = await db
      .insertInto("twist_instance")
      .values(twistValues)
      .returningAll()
      .executeTakeFirstOrThrow();

    // Activate twist if requested
    if (activate) {
      try {
        const twistWrapper = await activate.twistFactory({
          version: activate.version,
          twistInstanceId: twistInstance.id,
        });
        // Resolve user's contact ID — twists should always see contact IDs, never user IDs
        const actorContact = await db
          .selectFrom("contact")
          .select(["id", "email", "name"])
          .where("user_id", "=", userId)
          .executeTakeFirst();

        await twistWrapper.activate({ id: priority_id as Uuid }, {
          actor: {
            id: actorContact?.id ?? userId,
            type: 0 /* ActorType.User */,
            ...(actorContact?.email ? { email: actorContact.email } : {}),
            ...(actorContact?.name ? { name: actorContact.name } : {}),
          },
        });
      } catch (activationError) {
        // Activation failed - rollback the installation
        const logger = createLogger({ twist_instance_id: String(twistInstance.id), twist_id: String(twist_id), environment: twist_environment });
        logger.error("Twist activation failed, rolling back installation", activationError as Error);

        const cleanupWarnings = await cleanupFailedInstallation(
          db,
          twistInstance.id,
          {
            twistFactory: activate.twistFactory,
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

    return twistInstance;
  } catch (error) {
    const logger = createLogger({ twist_id: String(twist_id), environment: twist_environment, priority_id });
    logger.error("Error adding twist", error as Error);
    throw error;
  }
}

export async function getAll(
  db: Kysely<DB>,
  userId: string
) {
  try {
    // Query twists the user has access to install. The legacy
    // get_accessible_twists RPC still takes a priority_id for access
    // scoping; pass the user's root priority as a stable anchor since
    // twists are now workspace-level.
    const rootPriority = await db
      .selectFrom("priority")
      .select("id")
      .where("user_id", "=", userId)
      .where("archived_at", "is", null)
      .orderBy(sql`nlevel(path)`, "asc")
      .orderBy("created_at", "asc")
      .limit(1)
      .executeTakeFirstOrThrow();

    const data = await rpc(db, "get_accessible_twists", {
      p_priority_id: rootPriority.id,
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
  twist_instance_id: string
) {
  try {
    if (!twist_instance_id || typeof twist_instance_id !== "string") {
      throw new Error("twist_id is required and must be a string");
    }

    // Query twist_instance with twist permissions via JOIN
    const data = await db
      .selectFrom("twist_instance")
      .leftJoin("twist", "twist.id", "twist_instance.twist_id")
      .select([
        "twist_instance.id",
        "twist_instance.twist_id",
        "twist_instance.name",
        "twist_instance.owner_id",
        "twist_instance.options",
        "twist_instance.archived_at",
        "twist_instance.created_at",
        "twist_instance.updated_at",
        "twist.permissions",
        "twist.options_schema",
        "twist.is_source",
      ])
      .where("twist_instance.id", "=", twist_instance_id)
      .where("twist_instance.archived_at", "is", null)
      .executeTakeFirstOrThrow();

    return data;
  } catch (error) {
    const logger = createLogger({ twist_instance_id });
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
    logger.debug("Querying workspace twist_instances for priority owner");

    // Twists are workspace-level: return all active twist_instances owned
    // by the user who owns this priority.
    const priority = await db
      .selectFrom("priority")
      .select("user_id")
      .where("id", "=", priority_id)
      .executeTakeFirst();

    if (!priority?.user_id) {
      return [];
    }

    const data = await db
      .selectFrom("priority_child_twist")
      .leftJoin("twist", "twist.id", "priority_child_twist.twist_id")
      .select([
        "priority_child_twist.id",
        "priority_child_twist.twist_id",
        "priority_child_twist.name",
        "priority_child_twist.owner_id",
        "priority_child_twist.options",
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
        "twist.options_schema",
      ])
      .where("priority_child_twist.owner_id", "=", priority.user_id)
      .where("priority_child_twist.archived_at", "is", null)
      .execute();

    logger.debug("Query returned rows", { row_count: data?.length || 0 });
    return data;
  } catch (error) {
    const logger = createLogger({ priority_id });
    logger.error("Error fetching twists", error as Error);
    throw error;
  }
}

export async function update(
  db: Kysely<DB>,
  twist_instance_id: string,
  twist: { name?: string; config?: any }
) {
  try {
    if (!twist_instance_id || typeof twist_instance_id !== "string") {
      throw new Error("twist_instance_id is required and must be a string");
    }

    if (twist.name !== undefined) {
      // Per-user name uniqueness: check other active instances for this owner.
      // Sources (connectors) are exempt — users can have multiple connections.
      const currentTwist = await db
        .selectFrom("twist_instance")
        .select(["owner_id", "name", "twist_id"])
        .where("id", "=", twist_instance_id)
        .where("archived_at", "is", null)
        .executeTakeFirstOrThrow();

      const twistDef = await db
        .selectFrom("twist")
        .select("is_source")
        .where("id", "=", String(currentTwist.twist_id))
        .executeTakeFirst();

      if (twist.name !== currentTwist.name && twistDef?.is_source !== true) {
        const existingTwists = await db
          .selectFrom("twist_instance")
          .select(["id"])
          .where("owner_id", "=", currentTwist.owner_id)
          .where("name", "=", twist.name)
          .where("id", "!=", twist_instance_id)
          .where("archived_at", "is", null)
          .execute();

        if (existingTwists && existingTwists.length > 0) {
          throw new Error(
            `Twist with name "${twist.name}" already exists for this user.`
          );
        }
      }
    }

    // Map config → options for the updateTable call.
    const dbUpdate: { name?: string; options?: any } = {};
    if (twist.name !== undefined) dbUpdate.name = twist.name;
    if (twist.config !== undefined) dbUpdate.options = twist.config;

    return await db
      .updateTable("twist_instance")
      .set(dbUpdate)
      .where("id", "=", twist_instance_id)
      .returningAll()
      .executeTakeFirstOrThrow();
  } catch (error) {
    const logger = createLogger({ twist_instance_id });
    logger.error("Error updating twist", error as Error);
    throw error;
  }
}

export async function deleteTwist(
  db: Kysely<DB>,
  twist_instance_id: string,
  deactivate?: {
    twistFactory: ReturnType<typeof twistFactory>;
  }
) {
  try {
    if (!twist_instance_id || typeof twist_instance_id !== "string") {
      throw new Error("twist_instance_id is required and must be a string");
    }

    // Prevent deletion of the built-in Plot twist
    const twistMeta = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
      .select("twist_admin.twist_package_id")
      .where("twist_instance.id", "=", twist_instance_id)
      .executeTakeFirst();
    if (twistMeta?.twist_package_id === BUILTIN_TWIST_PACKAGE_ID) {
      throw new Error("The Plot twist cannot be removed");
    }

    // Call deactivate callback if requested
    if (deactivate) {
      try {
        // Get twist metadata needed to create wrapper
        // Need to join with twist table to get environment and twist_admin_id
        const twistInstance = await db
          .selectFrom("twist_instance")
          .innerJoin("twist", "twist.id", "twist_instance.twist_id")
          .select([
            "twist_instance.twist_id",
            "twist.environment",
            "twist.twist_admin_id",
          ])
          .where("twist_instance.id", "=", twist_instance_id)
          .where("twist_instance.archived_at", "is", null)
          .executeTakeFirst();

        const logger = createLogger({ twist_instance_id });

        if (!twistInstance) {
          logger.warn("Could not fetch twist_instance for deactivation");
        } else {
          // Get twist_package_id from twist_admin
          const adminData = await db
            .selectFrom("twist_admin")
            .select(["twist_package_id"])
            .where("id", "=", twistInstance.twist_admin_id)
            .executeTakeFirst();

          if (!adminData) {
            logger.warn("Could not fetch twist_package_id for deactivation");
          } else {
            const twistWrapper = await deactivate.twistFactory({
              id: adminData.twist_package_id,
              environment: twistInstance.environment,
              twistInstanceId: twist_instance_id,
            });
            await twistWrapper.deactivate();
          }
        }
      } catch (deactivateError) {
        // Log deactivation errors but continue with deletion
        const logger = createLogger({ twist_instance_id });
        logger.error("Error calling deactivate callback (continuing with deletion)", deactivateError as Error);
      }
    }

    // Disable all channels before archiving
    await db
      .updateTable("channel")
      .set({ enabled: false })
      .where("twist_instance_id", "=", twist_instance_id)
      .where("enabled", "=", true)
      .execute();

    // Clean up connection rows before archiving
    await db
      .deleteFrom("twist_instance_connection")
      .where("twist_instance_id", "=", twist_instance_id)
      .execute();

    return await db
      .updateTable("twist_instance")
      .set({ archived_at: new Date().toISOString() })
      .where("id", "=", twist_instance_id)
      .returningAll()
      .executeTakeFirstOrThrow();
  } catch (error) {
    const logger = createLogger({ twist_instance_id });
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

    // Insert twist_instance in draft state — excluded from views/runtime
    // until activateDraft() flips draft=false.
    const twistInstance = await db
      .insertInto("twist_instance")
      .values({
        twist_id: twist_id,
        name: name,
        owner_id: userId,
        draft: true,
      } as any)
      .returningAll()
      .executeTakeFirstOrThrow();

    return twistInstance;
  } catch (error) {
    const logger = createLogger({ twist_id: String(twist_id), environment: twist_environment });
    logger.error("Error creating draft twist", error as Error);
    throw error;
  }
}

/**
 * Activate a draft twist: flip draft=false, call activate lifecycle, enable channels.
 * The legacy `priorityId` parameter is accepted for API compatibility but
 * ignored — twists are workspace-level.
 */
export async function activateDraft(
  db: Kysely<DB>,
  env: Bindings,
  draftId: string,
  _unusedPriorityId: string | undefined,
  name: string,
  config: Record<string, any> | undefined,
  syncables: Array<{ provider: string; syncableId: string }> | undefined,
  activate: {
    twistFactory: ReturnType<typeof twistFactory>;
  }
) {
  const logger = createLogger({ twist_instance_id: draftId });

  // Verify draft exists and is actually a draft
  const draft = await db
    .selectFrom("twist_instance")
    .selectAll()
    .where("id", "=", draftId)
    .where("draft" as any, "=", true)
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
    const limitCheck = await checkTwistLimit(db, draft.owner_id);
    if (!limitCheck.allowed) {
      throw limitCheck.error;
    }
  }

  // Name uniqueness per owner (sources exempt — multiple connections allowed)
  if (twistRecord?.is_source !== true) {
    const existingTwist = await db
      .selectFrom("twist_instance")
      .select(["id"])
      .where("owner_id", "=", draft.owner_id)
      .where("name", "=", name)
      .where("archived_at", "is", null)
      .where("draft", "=", false)
      .executeTakeFirst();
    if (existingTwist) {
      throw new Error(`Twist with name "${name}" already exists for this user.`);
    }
  }

  // Flip draft → false, set name/options
  await db
    .updateTable("twist_instance")
    .set({
      draft: false,
      name,
      ...(config ? { options: config } : {}),
    })
    .where("id", "=", draftId)
    .execute();

  // Call activate lifecycle
  try {
    const twistWrapper = await activate.twistFactory({
      twistInstanceId: draftId,
    });

    // Resolve user's contact ID — twists should always see contact IDs, never user IDs
    const ownerContact = await db
      .selectFrom("contact")
      .select(["id", "email", "name"])
      .where("user_id", "=", draft.owner_id)
      .executeTakeFirst();

    const actorContext: { actor: { id: string; type: number }; auth?: any } = {
      actor: {
        id: ownerContact?.id ?? draft.owner_id,
        type: 0 /* ActorType.User */,
        ...(ownerContact?.email ? { email: ownerContact.email } : {}),
        ...(ownerContact?.name ? { name: ownerContact.name } : {}),
      },
    };

    // For sources, construct Authorization from sourceProvider metadata and owner contact
    if (twistWrapper.sourceProvider && ownerContact) {
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

    // Twists are workspace-level, so the activate callback gets the
    // owner user's root priority as the stable anchor.
    const rootPriority = await db
      .selectFrom("priority")
      .select("id")
      .where("user_id", "=", draft.owner_id)
      .where("archived_at", "is", null)
      .orderBy(sql`nlevel(path)`, "asc")
      .orderBy("created_at", "asc")
      .limit(1)
      .executeTakeFirstOrThrow();
    await twistWrapper.activate(
      { id: rootPriority.id as Uuid },
      actorContext,
    );
  } catch (activationError) {
    logger.error("Twist activation failed during draft activation", activationError as Error);

    // Rollback: flip draft back to true (keep draft alive for retry)
    await db
      .updateTable("twist_instance")
      .set({ draft: true } as any)
      .where("id", "=", draftId)
      .execute();

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
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
      .select([
        "twist.version",
        "twist_admin.twist_package_id as twistPackageId",
      ])
      .where("twist_instance.id", "=", draftId)
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
        twistInstanceId: draftId,
      });

      for (const { provider, syncableId } of syncables) {
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
        });

        try {
          const result = await twistWrapper.callCallback(
            integrationsPath.split(":"),
            "enableSync",
            provider,
            syncableId,
            contact.id,
            undefined // title
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
  const logger = createLogger({ twist_instance_id: draftId });

  // Verify it's actually a draft
  const draft = await db
    .selectFrom("twist_instance")
    .selectAll()
    .where("id", "=", draftId)
    .where("draft", "=", true)
    .executeTakeFirst();

  if (!draft) {
    // Not a draft or doesn't exist - no-op
    return;
  }

  // Hard-delete the draft row
  await db
    .deleteFrom("twist_instance")
    .where("id", "=", draftId)
    .where("draft", "=", true)
    .execute();

  logger.info("Draft twist deleted", { draft_id: draftId });
}

export async function archiveAndDeleteTwist(
  db: Kysely<DB>,
  twist_instance_id: string,
  deactivate?: {
    twistFactory: ReturnType<typeof twistFactory>;
  }
) {
  try {
    if (!twist_instance_id || typeof twist_instance_id !== "string") {
      throw new Error("twist_instance_id is required and must be a string");
    }

    // Prevent deletion of the built-in Plot twist
    const twistMeta = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
      .select("twist_admin.twist_package_id")
      .where("twist_instance.id", "=", twist_instance_id)
      .executeTakeFirst();
    if (twistMeta?.twist_package_id === BUILTIN_TWIST_PACKAGE_ID) {
      throw new Error("The Plot twist cannot be removed");
    }

    // Wrap in a transaction for atomicity and to ensure Hyperdrive sees all
    // mutations (including the archive_links RPC which uses SELECT syntax)
    // as a single write operation, preventing stale query cache responses.
    return await db.transaction().execute(async (trx) => {
      // Check if this is a connector (source) or a twist
      const pt = await trx
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .select("twist.is_source")
        .where("twist_instance.id", "=", twist_instance_id)
        .executeTakeFirst();

      if (pt?.is_source) {
        // Connector: archive links and threads with no remaining active links
        await rpc(trx, "archive_links", {
          p_created_by: twist_instance_id,
          p_filter: {},
        });
      } else {
        // Twist: archive threads directly (twists create threads, not links)
        await trx
          .updateTable("thread")
          .set({ archived_at: new Date().toISOString() })
          .where("created_by", "=", twist_instance_id)
          .where("archived_at", "is", null)
          .execute();
      }

      // Then delete the twist (which also calls deactivate if provided)
      return await deleteTwist(trx, twist_instance_id, deactivate);
    });
  } catch (error) {
    const logger = createLogger({ twist_instance_id });
    logger.error("Error archiving and deleting twist", error as Error);
    throw error;
  }
}
