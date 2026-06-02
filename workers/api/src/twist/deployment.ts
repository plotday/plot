import { type Kysely, sql } from "kysely";
import { PostHog } from "posthog-node";

import type { DB } from "../db-types";
import { type TwistEnvironment, type Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { buildTwist } from "./builder";
import { addUpgradeNote } from "./dev-activities";
import { notifyUserSyncByEnv } from "../app/sync/notify";
import { type TwistPermissions, storeTwistModule } from "./index";
import type { TwistSource } from "./types";
import { getPersonalPlan } from "../utils/limits";
import { emitCustomDeploymentEvent } from "../utils/twist-events";

export type DeploymentInput =
  | { module: string; sourcemap?: string; source?: never }
  | { source: TwistSource; module?: never; sourcemap?: never };

export interface DeployTwistOptions {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  db: Kysely<DB>;
  twistPackageId: string;
  publisherId: number | null;
  userId: string | null;
  input: DeploymentInput;
  environment: TwistEnvironment;
  name: string;
  /** At-mention / attribution label. Defaults to `name`. */
  handle?: string;
  /** Optional connection-picker label. When set the twist appears in the
   * new-thread connection picker. */
  threadType?: string | null;
  description?: string;
  logoUrl?: string;
  logoUrlDark?: string;
  userName?: string;
  userEmail?: string;
  dryRun?: boolean;
  onProgress?: (message: string) => void;
  // How the user authored the twist source. "spec" means it was produced by
  // `/twist/generate` (AI-driven spec→code); "code" means hand-written or
  // CLI-bundled. Used only for PostHog analytics.
  source?: "code" | "spec";
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
  twistPackageId,
  publisherId,
  userId,
  input,
  environment,
  name,
  handle,
  threadType,
  description,
  logoUrl,
  logoUrlDark,
  dryRun = false,
  onProgress,
  source: deployedFrom = "code",
}: DeployTwistOptions): Promise<DeployTwistResult> {
  const logger = createLogger({
    twist_package_id: twistPackageId,
    environment,
  });

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
  let sourceProvider: { provider?: string; scopes?: string[]; linkTypes?: any[]; handleReplies?: boolean; shared?: boolean; keyOption?: string; premium?: boolean } | null = null;
  try {
    if (dryRun) {
      onProgress?.("Analyzing permissions");
    } else {
      onProgress?.("Deploying twist");
    }

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

  // Check if a twist row already exists for this (twist_package_id, environment)
  // (and user_id for personal).
  let existingTwistQuery = db
    .selectFrom("twist")
    .select(["id", "name", "version", "handle", "thread_type"])
    .where("twist_package_id", "=", twistPackageId)
    .where("environment", "=", environment);
  if (environment === "personal") {
    existingTwistQuery = existingTwistQuery.where("user_id", "=", userId);
  }
  const existingTwist = await existingTwistQuery.executeTakeFirst();

  // Free tier: limit to 10 unique deployed twists
  if (!existingTwist && !dryRun && userId) {
    const plan = await getPersonalPlan(db, userId);
    if (plan === "free") {
      const { count } = await db
        .selectFrom("twist")
        .select(sql<string>`count(distinct twist.id)`.as("count"))
        .where("twist.user_id", "=", userId)
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
        // Preserve existing handle/thread_type when caller doesn't supply them
        // (e.g. AI-driven self-redeploys via the Twists tool). Falls back to
        // `name` only when there's truly no existing value.
        handle: handle ?? existingTwist!.handle ?? name,
        thread_type: threadType !== undefined ? threadType : (existingTwist!.thread_type ?? null),
        description,
        version,
        permissions: JSON.stringify(twistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        premium: sourceProvider?.premium ?? false,
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
        twist_package_id: twistPackageId,
        publisher_id: environment === "personal" ? null : publisherId,
        user_id: environment === "personal" ? userId : null,
        environment,
        name,
        handle: handle ?? name,
        thread_type: threadType ?? null,
        description,
        version,
        permissions: JSON.stringify(newTwistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        premium: sourceProvider?.premium ?? false,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    logger.info("Created new twist", { twist_id: String(twist.id) });
  }

  // Emit a PostHog event for each successful deploy. Uses a dedicated PostHog
  // client (see emitCustomDeploymentEvent) so it flushes even from the SSE
  // path where the request-scoped tracker may have shut down already.
  try {
    await emitCustomDeploymentEvent({
      env,
      userId,
      publisherId,
      twistPackageId,
      name,
      version,
      environment,
      isFirstDeploy: !existingTwist,
      isSource: providers.length > 0 || isNoProviderConnector,
      deploymentType: input.source !== undefined ? "source" : "module",
      source: deployedFrom,
    });
  } catch (eventError) {
    logger.error("Failed to emit deployment event (continuing)", eventError as Error);
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

  // If deploying to review and the review row has auto_approve = true,
  // also deploy to public.
  if (environment === "review" && twist.auto_approve) {
    logger.info("Auto-approving twist to public environment");

    // Get or create the public twist - need to fetch ID for callback upgrade
    const publicPermissions = providers.length > 0
      ? { ...permissions, _providers: providers }
      : permissions;
    try {
      const publicTwist = await db
        .insertInto("twist")
        .values({
          twist_package_id: twistPackageId,
          publisher_id: publisherId,
          user_id: null,
          environment: "public",
          name,
          handle: handle ?? name,
          thread_type: threadType ?? null,
          description,
          version,
          permissions: JSON.stringify(publicPermissions),
          options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
          is_source: providers.length > 0 || isNoProviderConnector,
          shared: sourceProvider?.shared ?? false,
          key_option: sourceProvider?.keyOption ?? null,
          premium: sourceProvider?.premium ?? false,
          logo_url: logoUrl ?? null,
          logo_url_dark: logoUrlDark ?? null,
          multiple_instances: multipleInstances,
        })
        .onConflict((oc) =>
          oc
            .columns(["twist_package_id", "environment"])
            .where("environment", "<>", "personal")
            .doUpdateSet({
              name,
              handle: handle ?? name,
              thread_type: threadType ?? null,
              description,
              version,
              permissions: JSON.stringify(publicPermissions),
              options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
              is_source: providers.length > 0 || isNoProviderConnector,
              shared: sourceProvider?.shared ?? false,
              key_option: sourceProvider?.keyOption ?? null,
              premium: sourceProvider?.premium ?? false,
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
      const postHog = new PostHog(env.POSTHOG_API_KEY, {
        host: env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      postHog.captureException(upsertPublicError as Error, userId ?? undefined, {
        context: "twist:auto-approve:public-upsert",
        twist_package_id: twistPackageId,
        environment,
        version,
      });
      await postHog.shutdown();
    }
  }

  // Ensure every consumer of this twist's deploy/runtime logs has a Twist
  // Development priority before the deploy log thread is created, so the
  // priority:@plot.twist-dev: topic prefix routes there instead of falling
  // back to root. Broadcast to UserSync DOs so live clients pull the new
  // priority without having to restart.
  const ensuredUserIds: string[] = [];
  try {
    if (environment === "personal") {
      if (userId) {
        await sql`SELECT public.ensure_twist_dev_priority(${userId}::uuid)`.execute(db);
        ensuredUserIds.push(userId);
      }
    } else if (publisherId !== null) {
      const rows = await sql<{ user_id: string }>`
        SELECT public.ensure_twist_dev_priority(uc.user_id) AS priority_id, uc.user_id
        FROM "group" g
        JOIN group_member gm ON gm.group_id = g.id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
        WHERE g.auto_publisher_id = ${publisherId}
          AND g.auto_maintained = TRUE
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
      `.execute(db);
      for (const r of rows.rows) ensuredUserIds.push(r.user_id);
    }
  } catch (ensureError) {
    logger.error("Failed to ensure Twist Development priority (continuing)", ensureError as Error);
  }

  await Promise.allSettled(
    ensuredUserIds.map((id) => notifyUserSyncByEnv(env, id))
  );

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
