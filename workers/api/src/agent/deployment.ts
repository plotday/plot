import type { SupabaseClient } from "@plotday/db";

import { type AgentEnvironment, type Bindings } from "../env";
import { buildAgent } from "./builder";
import { type AgentPermissions, storeAgentModule } from "./index";
import type { AgentSource } from "./types";

export type DeploymentInput =
  | { module: string; sourcemap?: string; source?: never }
  | { source: AgentSource; module?: never; sourcemap?: never };

export interface DeployAgentOptions {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  adminId: string;
  input: DeploymentInput;
  environment: Exclude<AgentEnvironment, "public">;
  name: string;
  description?: string;
  userId?: string | null;
  dryRun?: boolean;
  onProgress?: (message: string) => void;
}

export interface DeployAgentResult {
  version: string;
  permissions: AgentPermissions;
  errors?: string[];
}

/**
 * Common implementation for deploying agents, used by both the API endpoint
 * and the Agents tool.
 *
 * Supports deploying from either:
 * - A pre-bundled module (JavaScript code)
 * - A source object (dependencies + files) which is built in a sandbox
 *
 * @throws Error if build fails
 * @throws Error if database operations fail
 */
export async function deployAgent({
  env,
  ctx,
  supabase,
  adminId,
  input,
  environment,
  name,
  description,
  userId,
  dryRun = false,
  onProgress,
}: DeployAgentOptions): Promise<DeployAgentResult> {
  // Validate input: exactly one of module or source must be provided
  if (input.module === undefined && input.source === undefined) {
    throw new Error("Either module or source must be provided");
  }

  // Determine the module to deploy
  let moduleCode: string;
  let sourcemapCode: string | undefined;

  if (input.source !== undefined) {
    // Build module from source using container sandbox
    console.log("Building agent from source...");
    const buildResult = await buildAgent(input.source, env, onProgress);

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
        `Failed to build agent from source:\n${buildResult.errors.join("\n")}`
      );
    }

    moduleCode = buildResult.module;
    sourcemapCode = buildResult.sourcemap;
    console.log("Agent built successfully from source");
  } else {
    // Use provided module directly
    moduleCode = input.module!;
    sourcemapCode = input.sourcemap;
  }

  // Store agent module in R2 and get version + permissions
  // (or just collect permissions in dry-run mode)
  let version: string;
  let permissions: AgentPermissions;
  try {
    if (dryRun) {
      onProgress?.("Analyzing permissions");
    } else {
      onProgress?.("Deploying agent");
    }

    const storeResult = await storeAgentModule({
      env,
      ctx,
      id: adminId,
      module: moduleCode,
      sourcemap: sourcemapCode,
      environment,
      supabase,
      dryRun,
    });
    version = storeResult.version;
    permissions = storeResult.permissions;
  } catch (error) {
    console.error("Error storing agent module:", error);
    throw new Error(
      `Failed to ${dryRun ? "analyze" : "store"} agent module: ${
        error instanceof Error ? error.message : "Unknown error"
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

  // Check if agent already exists for this environment
  const { data: existingAgent } = await supabase
    .from("agent")
    .select("name, description")
    .eq("id", adminId)
    .eq("environment", environment)
    .maybeSingle();

  if (!existingAgent) {
    // Create new agent
    const { data: newAgent, error: createError } = await supabase
      .from("agent")
      .insert({
        id: adminId,
        name,
        description,
        version,
        permissions: permissions as any,
        environment,
        user_id: userId ?? null,
      })
      .select()
      .single();

    if (createError || !newAgent) {
      throw new Error(`Failed to create agent: ${createError?.message}`);
    }
  } else {
    // Update existing agent
    const updateData: Record<string, any> = {
      version,
      permissions,
    };
    if (name !== undefined) updateData.name = name;
    if (description !== undefined) updateData.description = description;

    const { data: updatedAgent, error: updateError } = await supabase
      .from("agent")
      .update(updateData)
      .eq("id", adminId)
      .eq("environment", environment)
      .select()
      .single();

    if (updateError || !updatedAgent) {
      throw new Error(`Failed to update agent: ${updateError?.message}`);
    }

    // Call upgrade callback for all active priorityAgents
    onProgress?.("Upgrading active agents");
    try {
      const { data: priorityAgents, error: fetchError } = await supabase
        .from("priority_agent")
        .select("id, priority_id")
        .eq("agent_id", adminId)
        .eq("agent_environment", environment)
        .is("archived_at", null);

      if (fetchError) {
        console.error(
          "Error fetching priority agents for upgrade:",
          fetchError
        );
      } else if (priorityAgents && priorityAgents.length > 0) {
        console.log(
          `Calling upgrade on ${priorityAgents.length} active priority agents`
        );

        const { agentFactory } = await import("./index");
        const factory = agentFactory({ env, ctx, supabase });

        // Use allSettled to handle errors without blocking other upgrades
        const upgradeResults = await Promise.allSettled(
          priorityAgents.map(async (pa) => {
            const agentWrapper = await factory({
              id: adminId,
              environment,
              version, // Use NEW version
              priorityId: pa.priority_id,
              priorityAgentId: pa.id,
            });
            return agentWrapper.upgrade();
          })
        );

        // Log any upgrade failures
        upgradeResults.forEach((result, index) => {
          if (result.status === "rejected") {
            console.error(
              `Failed to upgrade priority_agent ${priorityAgents[index].id}:`,
              result.reason
            );
          }
        });
      }
    } catch (upgradeError) {
      // Log upgrade errors but continue with deployment
      console.error(
        "Error during upgrade callback processing (continuing with deployment):",
        upgradeError
      );
    }
  }

  // If deploying to review and auto_approve is true, also deploy to public
  if (environment === "review") {
    const { data: agentAdmin, error: adminFetchError } = await supabase
      .from("agent_admin")
      .select("auto_approve")
      .eq("id", adminId)
      .single();

    if (!adminFetchError && agentAdmin?.auto_approve) {
      console.log(`Auto-approving agent ${adminId} to public environment`);

      const { error: upsertPublicError } = await supabase.from("agent").upsert(
        {
          id: adminId,
          environment: "public",
          name,
          description,
          version,
          permissions: permissions as any,
          user_id: null,
        },
        {
          onConflict: "id,environment",
        }
      );

      if (upsertPublicError) {
        console.error("Error auto-deploying to public:", upsertPublicError);
      } else {
        console.log(
          `Successfully auto-deployed agent ${adminId} to public environment`
        );
      }
    }
  }

  return {
    version,
    permissions,
  };
}
