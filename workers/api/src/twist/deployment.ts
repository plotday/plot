import { type Kysely, sql } from "kysely";

import type { DB } from "../db-types";
import { type TwistEnvironment, type Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { buildTwist } from "./builder";
import { addUpgradeNote } from "./dev-activities";
import { type TwistPermissions, storeTwistModule } from "./index";
import type { TwistSource } from "./types";
import { getPersonalPlan } from "../utils/limits";

export type DeploymentInput =
  | { module: string; sourcemap?: string; source?: never }
  | { source: TwistSource; module?: never; sourcemap?: never };

export interface DeployTwistOptions {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  db: Kysely<DB>;
  twistAdminId: number;
  input: DeploymentInput;
  environment: Exclude<TwistEnvironment, "public">;
  name: string;
  description?: string;
  logoUrl?: string;
  logoUrlDark?: string;
  userId?: string | null;
  userName?: string;
  userEmail?: string;
  dryRun?: boolean;
  onProgress?: (message: string) => void;
}

export interface DeployTwistResult {
  version: string;
  permissions: TwistPermissions;
  errors?: string[];
}

/**
 * Common implementation for deploying twists, used by both the API endpoint
 * and the Twists tool.
 *
 * Supports deploying from either:
 * - A pre-bundled module (JavaScript code)
 * - A source object (dependencies + files) which is built in a sandbox
 *
 * @throws Error if build fails
 * @throws Error if database operations fail
 */
export async function deployTwist({
  env,
  ctx,
  db,
  twistAdminId,
  input,
  environment,
  name,
  description,
  logoUrl,
  logoUrlDark,
  userId,
  dryRun = false,
  onProgress,
}: DeployTwistOptions): Promise<DeployTwistResult> {
  const logger = createLogger({ twist_admin_id: twistAdminId, environment });

  // Validate input: exactly one of module or source must be provided
  if (input.module === undefined && input.source === undefined) {
    throw new Error("Either module or source must be provided");
  }

  // Determine the module to deploy
  let moduleCode: string;
  let sourcemapCode: string | undefined;

  if (input.source !== undefined) {
    // Build module from source using container sandbox
    logger.info("Building twist from source");
    try {
      const buildResult = await buildTwist(input.source, env, onProgress);

      if (!buildResult.success) {
        // Return build errors for dryRun or throw for real deployment
        if (dryRun) {
          return {
            version: "dry-run",
            permissions: {},
            errors: buildResult.errors,
          };
        }
        throw new Error(
          `Build failed:\n${buildResult.errors.join("\n")}`
        );
      }

      moduleCode = buildResult.module;
      sourcemapCode = buildResult.sourcemap;
      logger.info("Twist built successfully from source");
    } catch (error) {
      logger.error("Error during twist build", error as Error);
      // Re-throw with user-friendly message if not already a build error
      if (error instanceof Error && error.message.startsWith("Build failed:")) {
        throw error;
      }
      throw new Error(
        `Failed to build twist: ${
          error instanceof Error ? error.message : "Build process failed"
        }`
      );
    }
  } else {
    // Use provided module directly
    moduleCode = input.module!;
    sourcemapCode = input.sourcemap;
  }

  // Store twist module in R2 and get version + permissions + providers
  // (or just collect permissions in dry-run mode)
  let version: string;
  let permissions: TwistPermissions;
  let providers: Array<{ provider: string; scopes: string[] }> = [];
  let optionsSchema: Record<string, unknown> | undefined;
  let isNoProviderConnector = false;
  let multipleInstances = false;
  let sourceProvider: { provider?: string; scopes?: string[]; linkTypes?: any[]; handleReplies?: boolean; shared?: boolean; keyOption?: string } | null = null;
  let twistPackageId: string;
  try {
    if (dryRun) {
      onProgress?.("Analyzing permissions");
    } else {
      onProgress?.("Deploying twist");
    }

    // Get twist_package_id for storage
    const adminData = await db
      .selectFrom("twist_admin")
      .select("twist_package_id")
      .where("id", "=", String(twistAdminId))
      .executeTakeFirstOrThrow();
    twistPackageId = adminData.twist_package_id;

    const storeResult = await storeTwistModule({
      env,
      ctx,
      id: twistPackageId,
      module: moduleCode,
      sourcemap: sourcemapCode,
      environment,
      db,
      dryRun,
    });
    version = storeResult.version;
    permissions = storeResult.permissions;
    optionsSchema = storeResult.optionsSchema;
    const { aiRequired } = storeResult;
    multipleInstances = storeResult.multipleInstances;

    // Store _ai_required in permissions for Flutter app access
    if (aiRequired) {
      (permissions as any)._ai_required = true;
    }

    // Store default mention flags in permissions for Flutter app access
    if (storeResult.defaultMentionCreated) {
      (permissions as any)._default_mention_created = true;
    }
    if (storeResult.defaultMentionMentioned) {
      (permissions as any)._default_mention_mentioned = true;
    }

    // Enrich providers with linkTypes from sourceProvider
    sourceProvider = storeResult.sourceProvider ?? null;
    providers = sourceProvider?.provider
      ? storeResult.providers.map(p => p.provider === sourceProvider!.provider
          ? { ...p, linkTypes: sourceProvider!.linkTypes }
          : p)
      : storeResult.providers;
    // For no-provider connectors (has sourceProvider but no OAuth provider),
    // mark as source even though providers array is empty
    isNoProviderConnector = !!sourceProvider && !sourceProvider.provider;
  } catch (error) {
    logger.error("Error storing twist module", error as Error);
    // Provide user-friendly error message
    const action = dryRun ? "analyze" : "deploy";
    throw new Error(
      `Failed to ${action} twist: ${
        error instanceof Error ? error.message : "An unexpected error occurred"
      }`
    );
  }

  // If dryRun, return permissions without storing to database
  if (dryRun) {
    return {
      version: "dry-run",
      permissions,
      errors: [],
    };
  }

  // Check if twist already exists for this admin+environment
  const existingTwist = await db
    .selectFrom("twist")
    .select(["id", "name", "version"])
    .where("twist_admin_id", "=", String(twistAdminId))
    .where("environment", "=", environment)
    .executeTakeFirst();

  // Free tier: limit to 10 unique deployed twists
  if (!existingTwist && !dryRun && userId) {
    const plan = await getPersonalPlan(db, userId);
    if (plan === "free") {
      const { count } = await db
        .selectFrom("twist")
        .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
        .select(sql<string>`count(distinct twist.id)`.as("count"))
        .where("twist_admin.user_id", "=", userId)
        .executeTakeFirstOrThrow();
      if (Number(count) >= 10) {
        throw new Error(
          "Free plan is limited to 10 deployed twists. Upgrade your plan to deploy more."
        );
      }
    }
  }

  logger.info("Deploying twist", {
    name,
    version,
    existing_id: existingTwist?.id,
    existing_name: existingTwist?.name,
    existing_version: existingTwist?.version,
  });

  let twist;

  if (existingTwist) {
    // Update existing twist - use UPDATE to avoid unique constraint issues
    const twistPermissions = providers.length > 0
      ? { ...permissions, _providers: providers }
      : permissions;
    twist = await db
      .updateTable("twist")
      .set({
        name,
        description,
        version,
        permissions: JSON.stringify(twistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,
      })
      .where("id", "=", existingTwist.id)
      .returningAll()
      .executeTakeFirstOrThrow();

    logger.info("Updated twist", { twist_id: String(twist.id) });
  } else {
    // Create new twist - use INSERT
    const newTwistPermissions = providers.length > 0
      ? { ...permissions, _providers: providers }
      : permissions;
    twist = await db
      .insertInto("twist")
      .values({
        twist_admin_id: twistAdminId,
        environment,
        name,
        description,
        version,
        permissions: JSON.stringify(newTwistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    logger.info("Created new twist", { twist_id: String(twist.id) });
  }

  // Call upgrade callback for all active twistInstances (if any exist)
  // This only matters for updates - new twists won't have twist_instances yet
  onProgress?.("Upgrading active twists");
  try {
    const twistInstances = await db
      .selectFrom("twist_instance")
      .select(["id", "twist_id"])
      .where("twist_id", "=", twist.id)
      .where("archived_at", "is", null)
      .execute();

    if (twistInstances.length > 0) {
      logger.info("Calling upgrade on active priority twists", {
        count: twistInstances.length,
      });

      const { twistFactory } = await import("./index");
      const factory = twistFactory({ env, ctx, db });

      // Use allSettled to handle errors without blocking other upgrades
      const upgradeResults = await Promise.allSettled(
        twistInstances.map(async (pa) => {
          const twistWrapper = await factory({
            version, // Use NEW version
            twistInstanceId: pa.id,
          });
          return twistWrapper.upgrade();
        })
      );

      // Log any upgrade failures
      upgradeResults.forEach((result, index) => {
        if (result.status === "rejected") {
          logger.error("Failed to upgrade twist_instance", result.reason as Error, {
            twist_instance_id: twistInstances[index].id,
          });
        }
      });

      // Upgrade all callbacks for each twist_instance to use the new version
      logger.info("Upgrading callbacks for active priority twists");
      const callbackUpgradeResults = await Promise.allSettled(
        twistInstances.map(async (pa) => {
          // Get the callbacks Durable Object for this twist_instance
          const callbacksId = env.CALLBACKS.idFromName(pa.id);
          const callbacksStub = env.CALLBACKS.get(callbacksId);
          return callbacksStub.upgradeCallbacks(pa.id, version);
        })
      );

      // Log any callback upgrade failures
      callbackUpgradeResults.forEach((result, index) => {
        if (result.status === "rejected") {
          logger.error(
            "Failed to upgrade callbacks for twist_instance",
            result.reason as Error,
            {
              twist_instance_id: twistInstances[index].id,
            }
          );
        }
      });
    }
  } catch (upgradeError) {
    // Log upgrade errors but continue with deployment
    logger.error("Error during upgrade callback processing (continuing with deployment)", upgradeError as Error);
  }

  // If deploying to review and auto_approve is true, also deploy to public
  if (environment === "review") {
    const twistAdmin = await db
      .selectFrom("twist_admin")
      .select("auto_approve")
      .where("id", "=", String(twistAdminId))
      .executeTakeFirst();

    if (twistAdmin?.auto_approve) {
      logger.info("Auto-approving twist to public environment");

      // Get or create the public twist - need to fetch ID for callback upgrade
      const publicPermissions = providers.length > 0
        ? { ...permissions, _providers: providers }
        : permissions;
      try {
        const publicTwist = await db
          .insertInto("twist")
          .values({
            twist_admin_id: twistAdminId,
            environment: "public",
            name,
            description,
            version,
            permissions: JSON.stringify(publicPermissions),
            options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
            is_source: providers.length > 0 || isNoProviderConnector,
            shared: sourceProvider?.shared ?? false,
            key_option: sourceProvider?.keyOption ?? null,
            logo_url: logoUrl ?? null,
            logo_url_dark: logoUrlDark ?? null,
            multiple_instances: multipleInstances,
          })
          .onConflict((oc) =>
            oc.columns(["twist_admin_id", "environment"]).doUpdateSet({
              name,
              description,
              version,
              permissions: JSON.stringify(publicPermissions),
              options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
              is_source: providers.length > 0 || isNoProviderConnector,
              shared: sourceProvider?.shared ?? false,
              key_option: sourceProvider?.keyOption ?? null,
              logo_url: logoUrl ?? null,
              logo_url_dark: logoUrlDark ?? null,
              multiple_instances: multipleInstances,
            })
          )
          .returningAll()
          .executeTakeFirstOrThrow();

        logger.info("Successfully auto-deployed twist to public environment");

        // Upgrade callbacks for PUBLIC twist_instances too
        // This ensures webhooks execute with the new twist version
        try {
          const publicTwistInstances = await db
            .selectFrom("twist_instance")
            .select(["id", "twist_id"])
            .where("twist_id", "=", publicTwist.id)
            .where("archived_at", "is", null)
            .execute();

          if (publicTwistInstances.length > 0) {
            logger.info("Upgrading callbacks for public priority twists", {
              count: publicTwistInstances.length,
            });

            // Upgrade callbacks for public installations
            const publicCallbackUpgradeResults = await Promise.allSettled(
              publicTwistInstances.map(async (pa) => {
                const callbacksId = env.CALLBACKS.idFromName(pa.id);
                const callbacksStub = env.CALLBACKS.get(callbacksId);
                return callbacksStub.upgradeCallbacks(pa.id, version);
              })
            );

            // Log any failures
            publicCallbackUpgradeResults.forEach((result, index) => {
              if (result.status === "rejected") {
                logger.error(
                  "Failed to upgrade callbacks for public twist_instance",
                  result.reason as Error,
                  {
                    twist_instance_id: publicTwistInstances[index].id,
                  }
                );
              }
            });
          }
        } catch (publicUpgradeError) {
          // Log error but continue with deployment
          logger.error("Error during public callback upgrade (continuing with deployment)", publicUpgradeError as Error);
        }
      } catch (upsertPublicError) {
        logger.error("Error auto-deploying to public", upsertPublicError as Error);
      }
    }
  }

  // Add upgrade note to the Logs thread
  try {
    await addUpgradeNote(env, twistPackageId, environment, version);
  } catch (upgradeNoteError) {
    logger.error("Failed to add upgrade note (deployment succeeded)", upgradeNoteError as Error);
  }

  return {
    version,
    permissions,
  };
}
