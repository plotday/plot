import type { SupabaseClient } from "@plotday/db";

import { type TwistEnvironment, type Bindings } from "../env";
import { createLogger } from "../utils/logger";
import { buildTwist } from "./builder";
import { type TwistPermissions, storeTwistModule } from "./index";
import type { TwistSource } from "./types";

export type DeploymentInput =
  | { module: string; sourcemap?: string; source?: never }
  | { source: TwistSource; module?: never; sourcemap?: never };

export interface DeployTwistOptions {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  twistAdminId: number;
  input: DeploymentInput;
  environment: Exclude<TwistEnvironment, "public">;
  name: string;
  description?: string;
  userId?: string | null;
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
  supabase,
  twistAdminId,
  input,
  environment,
  name,
  description,
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

  // Store twist module in R2 and get version + permissions
  // (or just collect permissions in dry-run mode)
  let version: string;
  let permissions: TwistPermissions;
  try {
    if (dryRun) {
      onProgress?.("Analyzing permissions");
    } else {
      onProgress?.("Deploying twist");
    }

    // Get twist_package_id for storage
    const { data: adminData, error: adminError } = await supabase
      .from("twist_admin")
      .select("twist_package_id")
      .eq("id", twistAdminId)
      .single();

    if (adminError || !adminData) {
      throw new Error(
        `Failed to fetch twist configuration: ${adminError?.message || "Not found"}`
      );
    }

    const storeResult = await storeTwistModule({
      env,
      ctx,
      id: adminData.twist_package_id,
      module: moduleCode,
      sourcemap: sourcemapCode,
      environment,
      supabase,
      dryRun,
    });
    version = storeResult.version;
    permissions = storeResult.permissions;
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
  const { data: existingTwist, error: existingError } = await supabase
    .from("twist")
    .select("id, name, version")
    .eq("twist_admin_id", twistAdminId)
    .eq("environment", environment)
    .maybeSingle();

  if (existingError) {
    logger.error("Error checking for existing twist", existingError as Error);
    throw new Error(
      `Failed to check existing twist: ${existingError.message}`
    );
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
    const { data: updatedTwist, error: updateError } = await supabase
      .from("twist")
      .update({
        name,
        description,
        version,
        permissions: permissions as any,
      })
      .eq("id", existingTwist.id)
      .select()
      .single();

    if (updateError || !updatedTwist) {
      logger.error("Failed to update twist in database", updateError as Error);
      throw new Error(
        `Failed to save twist update: ${
          updateError?.message || "Database error"
        }`
      );
    }

    twist = updatedTwist;
    logger.info("Updated twist", { twist_id: twist.id });
  } else {
    // Create new twist - use INSERT
    const { data: newTwist, error: insertError } = await supabase
      .from("twist")
      .insert({
        twist_admin_id: twistAdminId,
        environment,
        name,
        description,
        version,
        permissions: permissions as any,
      })
      .select()
      .single();

    if (insertError || !newTwist) {
      logger.error("Failed to create twist in database", insertError as Error);
      throw new Error(
        `Failed to save new twist: ${insertError?.message || "Database error"}`
      );
    }

    twist = newTwist;
    logger.info("Created new twist", { twist_id: twist.id });
  }

  // Call upgrade callback for all active priorityTwists (if any exist)
  // This only matters for updates - new twists won't have priority_twists yet
  onProgress?.("Upgrading active twists");
  try {
    const { data: priorityTwists, error: fetchError } = await supabase
      .from("priority_twist")
      .select("id, priority_id, twist_id")
      .eq("twist_id", twist.id)
      .is("archived_at", null);

    if (fetchError) {
      logger.error("Error fetching priority twists for upgrade", fetchError as Error);
    } else if (priorityTwists && priorityTwists.length > 0) {
      logger.info("Calling upgrade on active priority twists", {
        count: priorityTwists.length,
      });

      const { twistFactory } = await import("./index");
      const factory = twistFactory({ env, ctx, supabase });

      // Use allSettled to handle errors without blocking other upgrades
      const upgradeResults = await Promise.allSettled(
        priorityTwists.map(async (pa) => {
          const twistWrapper = await factory({
            version, // Use NEW version
            priorityId: pa.priority_id,
            priorityTwistId: pa.id,
          });
          return twistWrapper.upgrade();
        })
      );

      // Log any upgrade failures
      upgradeResults.forEach((result, index) => {
        if (result.status === "rejected") {
          logger.error("Failed to upgrade priority_twist", result.reason as Error, {
            priority_twist_id: priorityTwists[index].id,
          });
        }
      });
    }
  } catch (upgradeError) {
    // Log upgrade errors but continue with deployment
    logger.error("Error during upgrade callback processing (continuing with deployment)", upgradeError as Error);
  }

  // If deploying to review and auto_approve is true, also deploy to public
  if (environment === "review") {
    const { data: twistAdmin, error: adminFetchError } = await supabase
      .from("twist_admin")
      .select("auto_approve")
      .eq("id", twistAdminId)
      .single();

    if (!adminFetchError && twistAdmin?.auto_approve) {
      logger.info("Auto-approving twist to public environment");

      const { error: upsertPublicError } = await supabase.from("twist").upsert(
        {
          twist_admin_id: twistAdminId,
          environment: "public",
          name,
          description,
          version,
          permissions: permissions as any,
        },
        {
          onConflict: "twist_admin_id,environment",
        }
      );

      if (upsertPublicError) {
        logger.error("Error auto-deploying to public", upsertPublicError as Error);
      } else {
        logger.info("Successfully auto-deployed twist to public environment");
      }
    }
  }

  return {
    version,
    permissions,
  };
}
