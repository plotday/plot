import { type Kysely } from "kysely";
import { PostHog } from "posthog-node";

import type { twistFactory } from ".";
import type { DB } from "../db-types";
import { type TwistEnvironment, type Bindings } from "../env";
import { rpc } from "../rpc";
import { createLogger } from "@plotday/worker-util";
import {
  BUILTIN_TWIST_PACKAGE_ID,
  checkTwistCapacity,
  getPersonalPremiumAddons,
  type PlanLimits,
  selectConnectionsToTrim,
  SingleInstanceError,
} from "../utils/limits";
import { resolveOwnerContact } from "../utils/owner-contact";
import { disposeRpc } from "../utils/rpc";

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
    if (twist_id === undefined || twist_id === null || typeof twist_id !== "number") {
      throw new Error("twist_id is required and must be a number");
    }
    if (!twist_environment || typeof twist_environment !== "string") {
      throw new Error("twist_environment is required and must be a string");
    }

    // Verify user has access to this twist
    const hasAccess = await rpc(db, "is_accessible_twist", {
      p_twist_id: twist_id,
      p_user_id: userId,
    });
    if (!hasAccess) {
      throw new Error(
        `You do not have access to twist ${twist_id}`
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
      .select(["permissions", "is_source", "multiple_instances", "twist_package_id", "capacity_weight"])
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
      }
    }

    // Check automation capacity before inserting (sources check at channel-enable time)
    if (twistRecord?.is_source !== true) {
      const limitCheck = await checkTwistCapacity(
        db,
        userId,
        team_id ?? null,
        twistRecord?.capacity_weight ?? 1
      );
      if (!limitCheck.allowed) {
        throw limitCheck.error;
      }
    }

    // Single-instance enforcement and name handling
    if (twistRecord?.multiple_instances === false && twistRecord?.is_source !== true) {
      // For single-instance twists, always use the package name
      name = twistName;

      // Check for existing active instance in the same scope (same package, same scope)
      const existingInstance = await db
        .selectFrom("twist_instance")
        .innerJoin("twist as t2", "t2.id", "twist_instance.twist_id")
        .select("twist_instance.id")
        .where("t2.twist_package_id", "=", twistRecord.twist_package_id)
        .where("twist_instance.archived_at", "is", null)
        .where("twist_instance.draft", "=", false)
        .$if(team_id != null, (qb) => qb.where("twist_instance.team_id", "=", team_id!))
        .$if(team_id == null, (qb) =>
          qb.where("twist_instance.owner_id", "=", userId).where("twist_instance.team_id", "is", null)
        )
        .executeTakeFirst();

      if (existingInstance) {
        throw new SingleInstanceError(team_id ? "team" : "personal");
      }
    }

    // Name uniqueness — only for multi-instance twists (single-instance always uses package name)
    if (twistRecord?.is_source !== true && twistRecord?.multiple_instances !== false) {
      const existingTwist = await db
        .selectFrom("twist_instance")
        .select(["id"])
        .$if(team_id != null, (qb) => qb.where("team_id", "=", team_id!))
        .$if(team_id == null, (qb) =>
          qb.where("owner_id", "=", userId).where("team_id", "is", null)
        )
        .where("name", "=", name)
        .where("archived_at", "is", null)
        .where("draft", "=", false)
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

        await twistWrapper.activate({
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
    const logger = createLogger({ twist_id: String(twist_id), environment: twist_environment });
    logger.error("Error adding twist", error as Error);
    throw error;
  }
}

export async function getAll(
  db: Kysely<DB>,
  userId: string
) {
  try {
    const data = await rpc(db, "get_accessible_twists", {
      p_user_id: userId,
    });

    // Enrich twist data with publisher information.
    const twistArray = Array.isArray(data) ? data : data ? [data] : [];

    // get_accessible_twists already returns each twist's publisher_id, so fetch
    // every publisher in a single batched query rather than one lookup per
    // twist. The old N+1 issued one query per accessible twist — hundreds of
    // serial round trips for reviewers/admins who can see the whole public
    // catalog, which made opening Connections take 10s+.
    const publisherIds = [
      ...new Set(
        twistArray
          .filter(
            (twist: any) => twist.environment !== "personal" && twist.publisher_id
          )
          .map((twist: any) => String(twist.publisher_id))
      ),
    ];
    const publishers = publisherIds.length
      ? await db
          .selectFrom("publisher")
          .select(["id", "name", "email", "url"])
          .where("id", "in", publisherIds)
          .execute()
      : [];
    const publisherById = new Map(publishers.map((p) => [String(p.id), p]));

    const enrichedData = twistArray.map((twist: any) => {
      // For personal twists, author is the user themselves.
      if (twist.environment === "personal") {
        return {
          ...twist,
          author_name: "You",
          author_email: null,
          author_url: null,
        };
      }

      // Always return author fields, even if the publisher is missing.
      const publisher = twist.publisher_id
        ? publisherById.get(String(twist.publisher_id))
        : undefined;
      return {
        ...twist,
        author_name: publisher?.name || null,
        author_email: publisher?.email || null,
        author_url: publisher?.url || null,
      };
    });

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
      .selectFrom("twist_instance_details")
      .leftJoin("twist", "twist.id", "twist_instance_details.twist_id")
      .select([
        "twist_instance_details.id",
        "twist_instance_details.twist_id",
        "twist_instance_details.name",
        "twist_instance_details.owner_id",
        "twist_instance_details.options",
        "twist_instance_details.archived_at",
        "twist_instance_details.created_at",
        "twist_instance_details.updated_at",
        "twist_instance_details.twist_environment",
        "twist_instance_details.is_source",
        "twist_instance_details.version",
        "twist_instance_details.author_name",
        "twist_instance_details.author_email",
        "twist_instance_details.author_url",
        "twist.permissions",
        "twist.options_schema",
      ])
      .where("twist_instance_details.owner_id", "=", priority.user_id)
      .where("twist_instance_details.archived_at", "is", null)
      .execute();

    logger.debug("Query returned rows", { row_count: data?.length || 0 });
    return data;
  } catch (error) {
    const logger = createLogger({ priority_id });
    logger.error("Error fetching twists", error as Error);
    throw error;
  }
}

/**
 * Returns active twist_instances accessible to the given user.
 * If teamId is provided, returns only twists for that team.
 * Otherwise returns personal twists + twists for all teams the user belongs to.
 */
export async function getByFilter(
  db: Kysely<DB>,
  userId: string,
  teamId?: string
) {
  try {
    let query = db
      .selectFrom("twist_instance_details")
      .leftJoin("twist", "twist.id", "twist_instance_details.twist_id")
      .select([
        "twist_instance_details.id",
        "twist_instance_details.twist_id",
        "twist_instance_details.name",
        "twist_instance_details.owner_id",
        "twist_instance_details.options",
        "twist_instance_details.archived_at",
        "twist_instance_details.created_at",
        "twist_instance_details.updated_at",
        "twist_instance_details.twist_environment",
        "twist_instance_details.is_source",
        "twist_instance_details.version",
        "twist_instance_details.author_name",
        "twist_instance_details.author_email",
        "twist_instance_details.author_url",
        "twist.permissions",
        "twist.options_schema",
      ])
      .where("twist_instance_details.archived_at", "is", null);

    if (teamId) {
      query = query.where("twist_instance_details.team_id", "=", BigInt(teamId) as any);
    } else {
      query = query.where((eb) =>
        eb.or([
          eb.and([
            eb("twist_instance_details.owner_id", "=", userId),
            eb("twist_instance_details.team_id", "is", null),
          ]),
          eb(
            "twist_instance_details.team_id",
            "in",
            eb.selectFrom("team_user").select("team_id").where("user_id", "=", userId)
          ),
        ])
      );
    }

    return await query.execute();
  } catch (error) {
    const logger = createLogger({ user_id: userId, team_id: teamId });
    logger.error("Error fetching twists", error as Error);
    throw error;
  }
}

export async function update(
  db: Kysely<DB>,
  twist_instance_id: string,
  twist: {
    name?: string;
    config?: any;
    teamId?: string | null;
    accountLabel?: string | null;
  }
) {
  try {
    if (!twist_instance_id || typeof twist_instance_id !== "string") {
      throw new Error("twist_instance_id is required and must be a string");
    }

    const currentTwist = await db
      .selectFrom("twist_instance")
      .select(["owner_id", "name", "twist_id", "team_id"])
      .where("id", "=", twist_instance_id)
      .where("archived_at", "is", null)
      .executeTakeFirstOrThrow();

    const twistDef = await db
      .selectFrom("twist")
      .select(["is_source", "multiple_instances", "twist_package_id", "capacity_weight"])
      .where("id", "=", String(currentTwist.twist_id))
      .executeTakeFirst();

    // Verify team membership if teamId is changed
    if (
      twist.teamId !== undefined &&
      twist.teamId !== (currentTwist.team_id ? String(currentTwist.team_id) : null)
    ) {
      if (twist.teamId) {
        const membership = await db
          .selectFrom("team_user")
          .select("role")
          .where("team_id", "=", twist.teamId)
          .where("user_id", "=", currentTwist.owner_id)
          .executeTakeFirst();
        if (!membership) {
          throw new Error("You are not a member of this team");
        }
      }

      // Check quota limits if owner changes
      if (twistDef?.is_source !== true) {
        const limitCheck = await checkTwistCapacity(
          db,
          currentTwist.owner_id,
          twist.teamId ?? null,
          twistDef?.capacity_weight ?? 1
        );
        if (!limitCheck.allowed) {
          throw limitCheck.error;
        }
      }

      // Single-instance conflict check when moving to a new scope
      if (twistDef?.multiple_instances === false && twistDef?.is_source !== true) {
        const targetTeamId = twist.teamId ?? null;
        const existingInTarget = await db
          .selectFrom("twist_instance")
          .innerJoin("twist as t2", "t2.id", "twist_instance.twist_id")
          .select("twist_instance.id")
          .where("t2.twist_package_id", "=", twistDef.twist_package_id)
          .where("twist_instance.id", "!=", twist_instance_id)
          .where("twist_instance.archived_at", "is", null)
          .where("twist_instance.draft", "=", false)
          .$if(targetTeamId != null, (qb) => qb.where("twist_instance.team_id", "=", targetTeamId!))
          .$if(targetTeamId == null, (qb) =>
            qb.where("twist_instance.owner_id", "=", currentTwist.owner_id).where("twist_instance.team_id", "is", null)
          )
          .executeTakeFirst();

        if (existingInTarget) {
          throw new SingleInstanceError(targetTeamId ? "team" : "personal");
        }
      }
    }

    if (twist.name !== undefined) {
      // Source (connection) names are the connector's own name and not
      // user-editable. Use account_label to distinguish accounts instead.
      if (twistDef?.is_source === true) {
        twist = { ...twist, name: undefined };
      } else if (twist.name !== currentTwist.name) {
        const teamId =
          twist.teamId !== undefined
            ? twist.teamId
            : currentTwist.team_id
            ? String(currentTwist.team_id)
            : null;
        const existingTwists = await db
          .selectFrom("twist_instance")
          .select(["id"])
          .where("owner_id", "=", currentTwist.owner_id)
          .where("team_id", teamId ? "=" : "is", (teamId ? BigInt(teamId) : null) as any)
          .where("name", "=", twist.name)
          .where("id", "!=", twist_instance_id)
          .where("archived_at", "is", null)
          .execute();

        if (existingTwists && existingTwists.length > 0) {
          throw new Error(
            `Twist with name "${twist.name}" already exists for this ${
              teamId ? "team" : "user"
            }.`
          );
        }
      }
    }

    // Map config → options for the updateTable call.
    const dbUpdate: {
      name?: string;
      options?: any;
      team_id?: bigint | null;
      account_label?: string | null;
    } = {};
    if (twist.name !== undefined) dbUpdate.name = twist.name;
    if (twist.config !== undefined) dbUpdate.options = twist.config;
    if (twist.teamId !== undefined)
      dbUpdate.team_id = twist.teamId ? BigInt(twist.teamId) : null;
    if (twist.accountLabel !== undefined)
      dbUpdate.account_label = twist.accountLabel;

    if (Object.keys(dbUpdate).length === 0) {
      return await db
        .selectFrom("twist_instance")
        .selectAll()
        .where("id", "=", twist_instance_id)
        .executeTakeFirstOrThrow();
    }

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
      .select("twist.twist_package_id")
      .where("twist_instance.id", "=", twist_instance_id)
      .executeTakeFirst();
    if (twistMeta?.twist_package_id === BUILTIN_TWIST_PACKAGE_ID) {
      throw new Error("The Plot twist cannot be removed");
    }

    // Call deactivate callback if requested
    if (deactivate) {
      try {
        // Get twist metadata needed to create wrapper
        const twistInstance = await db
          .selectFrom("twist_instance")
          .innerJoin("twist", "twist.id", "twist_instance.twist_id")
          .select([
            "twist_instance.twist_id",
            "twist.environment",
            "twist.twist_package_id",
          ])
          .where("twist_instance.id", "=", twist_instance_id)
          .where("twist_instance.archived_at", "is", null)
          .executeTakeFirst();

        const logger = createLogger({ twist_instance_id });

        if (!twistInstance) {
          logger.warn("Could not fetch twist_instance for deactivation");
        } else {
          const twistWrapper = await deactivate.twistFactory({
            id: twistInstance.twist_package_id,
            environment: twistInstance.environment,
            twistInstanceId: twist_instance_id,
          });
          await twistWrapper.deactivate();
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

/** Dispose an RPC stub returned by callCallback, if it is disposable. */
export function disposeRpcResult(result: unknown): void {
  if (result && typeof result === "object" && Symbol.dispose in result) {
    (result as any)[Symbol.dispose]();
  }
}

/**
 * Enable the user's selected channels during draft activation. One
 * `enableSyncBatch` callCallback per provider (instead of one enableSync per
 * channel) plus the per-provider auto-enable / auto-threading default seeds.
 */
export async function enableActivatedChannels(
  twistWrapper: { callCallback: (path: string[], method: string, ...args: any[]) => Promise<any> },
  integrationsMap: Record<string, string>,
  syncables: Array<{ provider: string; syncableId: string }>,
  actorId: string,
  logger: { warn: (msg: string, meta?: any) => void },
  captureException?: (error: unknown, context: { provider: string; operation: string }) => void,
  // Per-provider override mapping a provider to the actor its connection was
  // bound to (`twist_instance_connection.actor_id` — the contact the auth token
  // is stored under). The channel MUST be enabled under this actor so
  // `channel_config.enabledBy` matches `auth_token:{provider}:{actor}`; otherwise
  // sync throws "has no stored credentials — reconnect". Falls back to `actorId`
  // for providers without a connection row (e.g. key-based connectors).
  actorByProvider?: Record<string, string>
): Promise<Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }>> {
  const byProvider = new Map<string, string[]>();
  for (const { provider, syncableId } of syncables) {
    const list = byProvider.get(provider) ?? [];
    list.push(syncableId);
    byProvider.set(provider, list);
  }

  const descriptors: Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }> = [];

  for (const [provider, channelIds] of byProvider) {
    const integrationsPath = integrationsMap[provider];
    if (!integrationsPath) {
      logger.warn("No integrations path found for provider during activation", {
        provider,
        available_providers: Object.keys(integrationsMap),
      });
      continue;
    }
    const path = integrationsPath.split(":");
    // Enable under the actor the connection is bound to, not a re-guessed owner
    // contact. See `actorByProvider` above.
    const providerActorId = actorByProvider?.[provider] ?? actorId;

    try {
      disposeRpcResult(
        await twistWrapper.callCallback(path, "enableSyncBatch", provider, channelIds, providerActorId, undefined, { dispatch: false })
      );
      descriptors.push({ provider, actorId: providerActorId, channelIds, integrationsPath });
    } catch (error) {
      logger.warn("Failed to enable channels during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
      captureException?.(error, { provider, operation: "enableSyncBatch" });
    }

    try {
      disposeRpcResult(await twistWrapper.callCallback(path, "initAutoEnableDefault", provider, providerActorId));
    } catch (error) {
      logger.warn("Failed to seed auto-enable default during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
      captureException?.(error, { provider, operation: "initAutoEnableDefault" });
    }
    try {
      disposeRpcResult(await twistWrapper.callCallback(path, "initAutoThreadingDefault", provider, providerActorId));
    } catch (error) {
      logger.warn("Failed to seed auto-threading default during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
      captureException?.(error, { provider, operation: "initAutoThreadingDefault" });
    }
  }

  return descriptors;
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
  },
  teamId?: string | null
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

  // Verify team membership if teamId is provided
  if (teamId) {
    const membership = await db
      .selectFrom("team_user")
      .select("role")
      .where("team_id", "=", teamId)
      .where("user_id", "=", draft.owner_id)
      .executeTakeFirst();
    if (!membership) {
      throw new Error("You are not a member of this team");
    }
  }

  // Check if twist requires AI and user has it disabled
  const twistRecord = await db
    .selectFrom("twist")
    .select(["permissions", "is_source", "multiple_instances", "twist_package_id", "name", "capacity_weight"])
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
    }
  }

  // Check automation capacity before activating (sources check at channel-enable time)
  if (twistRecord?.is_source !== true) {
    const limitCheck = await checkTwistCapacity(
      db,
      draft.owner_id,
      teamId ?? null,
      twistRecord?.capacity_weight ?? 1
    );
    if (!limitCheck.allowed) {
      throw limitCheck.error;
    }
  }

  // Single-instance enforcement and name override
  if (twistRecord?.multiple_instances === false && twistRecord?.is_source !== true) {
    // Always use package name for single-instance twists
    name = twistRecord.name;

    // Check for existing active instance in the same scope (excluding the draft itself)
    const existingInstance = await db
      .selectFrom("twist_instance")
      .innerJoin("twist as t2", "t2.id", "twist_instance.twist_id")
      .select("twist_instance.id")
      .where("t2.twist_package_id", "=", twistRecord.twist_package_id)
      .where("twist_instance.id", "!=", draftId)
      .where("twist_instance.archived_at", "is", null)
      .where("twist_instance.draft", "=", false)
      .$if(teamId != null, (qb) => qb.where("twist_instance.team_id", "=", teamId!))
      .$if(teamId == null, (qb) =>
        qb.where("twist_instance.owner_id", "=", draft.owner_id).where("twist_instance.team_id", "is", null)
      )
      .executeTakeFirst();

    if (existingInstance) {
      throw new SingleInstanceError(teamId ? "team" : "personal");
    }
  }

  // Source (connection) name: always the connector's own name. Per-connection
  // disambiguation happens via twist_instance.account_label (written by
  // Integrations.storeAuthorization for OAuth; set via form for non-OAuth).
  if (twistRecord?.is_source === true) {
    name = twistRecord.name;
  }

  // Non-OAuth connectors: seed account_label from _accountName in options if
  // present, so the same field isn't stored twice.
  let accountLabelFromOptions: string | null = null;
  if (twistRecord?.is_source === true) {
    const opts = config
      ?? (typeof draft.options === "string"
        ? JSON.parse(draft.options)
        : (draft.options as Record<string, any> | null));
    const fromOptions = opts?._accountName;
    if (typeof fromOptions === "string" && fromOptions) {
      accountLabelFromOptions = fromOptions;
    }
  }

  // Name uniqueness — only for multi-instance twists (single-instance always uses package name)
  if (twistRecord?.is_source !== true && twistRecord?.multiple_instances !== false) {
    const existingTwist = await db
      .selectFrom("twist_instance")
      .select(["id"])
      .where("owner_id", "=", draft.owner_id)
      .where("team_id", teamId ? "=" : "is", teamId ?? null)
      .where("name", "=", name)
      .where("archived_at", "is", null)
      .where("draft", "=", false)
      .executeTakeFirst();
    if (existingTwist) {
      throw new Error(`Twist with name "${name}" already exists for this ${teamId ? 'team' : 'user'}.`);
    }
  }

  // Flip draft → false, set name/options/team_id. For non-OAuth source
  // connectors, seed account_label from options._accountName when no OAuth
  // flow populated it already (Integrations.storeAuthorization only writes
  // when account_label is null).
  await db
    .updateTable("twist_instance")
    .set({
      draft: false,
      name,
      team_id: teamId as any,
      ...(config ? { options: config } : {}),
      ...(accountLabelFromOptions
        ? { account_label: accountLabelFromOptions }
        : {}),
    })
    .where("id", "=", draftId)
    .execute();

  // Fallback: every source connection should have a disambiguating label even
  // when the provider exposes no natural one (e.g. providers without
  // extractAccountLabel, or when the OAuth metadata lookup fails). Use the
  // team name when scoped to a team, otherwise 'Personal'.
  if (twistRecord?.is_source === true) {
    const current = await db
      .selectFrom("twist_instance")
      .select("account_label")
      .where("id", "=", draftId)
      .executeTakeFirst();
    if (!current?.account_label) {
      let fallbackLabel = "Personal";
      if (teamId) {
        const team = await db
          .selectFrom("team")
          .select("name")
          .where("id", "=", teamId)
          .executeTakeFirst();
        if (team?.name) fallbackLabel = team.name;
      }
      await db
        .updateTable("twist_instance")
        .set({ account_label: fallbackLabel })
        .where("id", "=", draftId)
        .where("account_label", "is", null)
        .execute();
    }
  }

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

    await twistWrapper.activate(actorContext);
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

  let channelDispatch: Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }> = [];

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
      .select([
        "twist.version",
        "twist.twist_package_id as twistPackageId",
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

    // Resolve the actor each provider's connection is bound to
    // (`twist_instance_connection.actor_id` — the contact the auth token was
    // stored under by onAuth). Channels MUST be enabled under this actor so
    // `channel_config.enabledBy` matches `auth_token:{provider}:{actor}`.
    // Guessing a fresh owner contact here (which is non-deterministic for a
    // multi-contact user) is what previously left the channel's `enabledBy`
    // diverged from the token, breaking every sync with
    // "has no stored credentials — reconnect".
    const connectionRows = await db
      .selectFrom("twist_instance_connection")
      .select(["provider", "actor_id"])
      .where("twist_instance_id", "=", draftId)
      .where("user_id", "=", draft.owner_id)
      .execute();
    const actorByProvider: Record<string, string> = {};
    for (const row of connectionRows) {
      actorByProvider[row.provider] = row.actor_id;
    }

    // Fallback actor for providers without a connection row (e.g. key-based
    // connectors that never run onAuth). Resolved deterministically (primary
    // contact) so it can't diverge from the token actor for a multi-contact
    // user — see resolveOwnerContact.
    const contact = await resolveOwnerContact(db, draft.owner_id);

    logger.info("activateDraft: contact lookup", {
      owner_id: draft.owner_id,
      contact_id: contact?.id,
      actor_by_provider: actorByProvider,
    });

    if (contact) {
      const twistWrapper = await activate.twistFactory({ twistInstanceId: draftId });
      const captureActivateError = (error: unknown, ctx: { provider: string; operation: string }) => {
        const postHog = new PostHog(env.POSTHOG_API_KEY, {
          host: env.POSTHOG_HOST,
          flushAt: 1,
          flushInterval: 0,
        });
        postHog.captureException(
          error instanceof Error ? error : new Error(String(error)),
          draft.owner_id ?? undefined,
          { context: `activate:${ctx.operation}`, provider: ctx.provider }
        );
        void postHog.shutdown();
      };
      channelDispatch = await enableActivatedChannels(twistWrapper, integrationsMap, syncables, contact.id, logger, captureActivateError, actorByProvider);
    }
  } else {
    logger.info("activateDraft: no channels to enable", {
      has_channels: !!syncables,
      channel_count: syncables?.length ?? 0,
    });
  }

  return { draft, channelDispatch };
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

/**
 * Remove an account (auth) from a connector the same way the app's
 * `DELETE /twist/:id/integrations/:provider/:actorId` endpoint does it.
 *
 * This goes through the connector's `removeAuth` callback, which:
 *   - disables (or reassigns) any channels this actor enabled, firing
 *     `onChannelDisabled` (most connectors archive the channel's links
 *     and therefore its threads from inside that callback)
 *   - clears the stored auth token and channel access entries
 *   - deletes the `twist_instance_connection` row
 *
 * Use this (rather than a raw delete) whenever we need to match the
 * in-app disconnect behaviour — e.g. trimming excess connections on
 * trial expiry or plan downgrade.
 */
export async function removeIntegrationAccount({
  db,
  env,
  twistFactory: factory,
  twistInstanceId,
  provider,
  actorId,
}: {
  db: Kysely<DB>;
  env: Bindings;
  twistFactory: ReturnType<typeof twistFactory>;
  twistInstanceId: string;
  provider: string;
  actorId: string;
}): Promise<void> {
  const logger = createLogger({
    twist_instance_id: twistInstanceId,
    provider,
    actor_id: actorId,
  });

  const twistInfo = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select(["twist.twist_package_id as twistPackageId", "twist.version"])
    .where("twist_instance.id", "=", twistInstanceId)
    .where("twist_instance.archived_at", "is", null)
    .executeTakeFirst();

  if (!twistInfo) {
    logger.warn("Twist instance not found or already archived, skipping removeAuth");
    return;
  }

  const configRaw = await env.TWIST_CONFIG.get(
    `${twistInfo.twistPackageId}:${twistInfo.version}`
  );
  if (!configRaw) {
    logger.warn("Twist config not found, skipping removeAuth");
    return;
  }

  const config = JSON.parse(configRaw);
  const integrationsPathStr: string | undefined =
    config?.integrationsMap?.[provider];
  if (!integrationsPathStr) {
    logger.warn(`Provider ${provider} not configured on twist, skipping removeAuth`);
    return;
  }

  const twistWrapper = await factory({ twistInstanceId });

  const result = await twistWrapper.callCallback(
    integrationsPathStr.split(":"),
    "removeAuth",
    provider,
    actorId
  );
  disposeRpc(result);
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
      .select("twist.twist_package_id")
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
        // Connector: soft-archive every link this instance created (empty
        // filter = whole-instance uninstall). archive_links always soft-deletes
        // now, so each link emits a durable per-row tombstone via
        // user.link_redacted that the client uses to hard-delete the link + its
        // schedules. deleteTwist (below) only soft-archives the twist_instance,
        // so the ti row survives and link_redacted can still resolve the owner.
        // (We no longer hard-delete + rely on the fire-once instance-archived
        // purge, which raced sync-cursor ordering and stranded straggler
        // links/schedules — see the archive_links header.)
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

/**
 * Trim a user's personal connections and non-source twists to fit a plan's
 * limits, using the same archival flow the app invokes when a user removes
 * a connection or twist:
 *
 *   - Excess connections go through the connector's `removeAuth` callback
 *     (via `removeIntegrationAccount`), which disables/reassigns channels
 *     and lets each connector archive its own links/threads via
 *     `onChannelDisabled`.
 *   - Excess non-built-in twists go through `archiveAndDeleteTwist`, which
 *     archives links/threads created by the twist and runs the twist's
 *     `deactivate` callback.
 *
 * Called from both trial expiry (`expireTrial`) and the Stripe downgrade
 * webhook (`enforceDowngradeLimits`).
 */
export async function enforcePersonalPlanLimits({
  db,
  env,
  twistFactory: factory,
  userId,
  limits,
}: {
  db: Kysely<DB>;
  env: Bindings;
  twistFactory: ReturnType<typeof twistFactory>;
  userId: string;
  limits: Pick<PlanLimits, "connections" | "twists">;
}): Promise<{ removedConnections: number; archivedTwists: number }> {
  const logger = createLogger({
    operation: "enforcePersonalPlanLimits",
    user_id: userId,
  });

  let removedConnections = 0;
  let archivedTwists = 0;

  // Trim connections that exceed the new plan, via each connector's removeAuth
  // callback (which deletes the upstream hosted/Unipile account). Add-on
  // connections beyond purchased credits are trimmed regardless of plan (Free
  // users can buy add-on credits); regular connections beyond the pool budget
  // are also trimmed. See `selectConnectionsToTrim`.
  const allConnections = await db
    .selectFrom("twist_instance_connection as ptc")
    .innerJoin("twist_instance as pt", "pt.id", "ptc.twist_instance_id")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select([
      "ptc.twist_instance_id",
      "ptc.provider",
      "ptc.actor_id",
      "ptc.connected_at",
      "tw.premium",
    ])
    .where("ptc.user_id", "=", userId)
    .where("pt.archived_at", "is", null)
    .execute();

  const premiumAddons = await getPersonalPremiumAddons(db, userId);
  const connectionsToTrim = selectConnectionsToTrim(
    allConnections.map((row) => ({
      twistInstanceId: row.twist_instance_id,
      provider: row.provider,
      actorId: row.actor_id,
      premium: !!row.premium,
      connectedAt: row.connected_at,
    })),
    {
      connections: limits.connections,
      addonCredits: premiumAddons,
    }
  );

  for (const conn of connectionsToTrim) {
    try {
      await removeIntegrationAccount({
        db,
        env,
        twistFactory: factory,
        twistInstanceId: conn.twistInstanceId,
        provider: conn.provider,
        actorId: conn.actorId,
      });
      removedConnections++;
    } catch (error) {
      logger.error(
        "Failed to remove excess connection during plan downgrade",
        error as Error,
        {
          twist_instance_id: conn.twistInstanceId,
          provider: conn.provider,
          actor_id: conn.actorId,
        }
      );
    }
  }

  if (removedConnections > 0) {
    logger.info("Removed excess connections on plan downgrade", {
      user_id: userId,
      removed: removedConnections,
    });
  }

  // Archive excess non-source twists (preserving the built-in Plot twist).
  if (limits.twists !== Infinity) {
    const excessTwists = await db
      .selectFrom("twist_instance as pt")
      .innerJoin("twist as t", "t.id", "pt.twist_id")
      .select("pt.id")
      .where("pt.owner_id", "=", userId)
      .where("pt.archived_at", "is", null)
      .where("t.is_source", "=", false)
      .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
      .orderBy("pt.created_at", "desc")
      .offset(limits.twists)
      .execute();

    for (const row of excessTwists) {
      try {
        await archiveAndDeleteTwist(db, row.id, { twistFactory: factory });
        archivedTwists++;
      } catch (error) {
        logger.error(
          "Failed to archive excess twist during plan downgrade",
          error as Error,
          { twist_instance_id: row.id }
        );
      }
    }

    if (archivedTwists > 0) {
      logger.info("Archived excess twists on plan downgrade", {
        user_id: userId,
        archived: archivedTwists,
      });
    }
  }

  return { removedConnections, archivedTwists };
}
