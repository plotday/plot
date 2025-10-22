import type { SupabaseClient } from "@plotday/db";

import type { Bindings } from "../env";
import { buildAgent } from "./builder";
import { storeAgentModule } from "./index";
import type { AgentSource } from "./types";

export type DeploymentInput =
  | { module: string; source?: never }
  | { source: AgentSource; module?: never };

export interface DeployAgentOptions {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  adminId: string;
  input: DeploymentInput;
  environment: "personal" | "private" | "review";
  name: string;
  description?: string;
  userId?: string | null;
  dryRun?: boolean;
  onProgress?: (message: string) => void;
}

export interface DeployAgentResult {
  version: string;
  dependencies: string[];
  errors?: string[];
}

/**
 * Common implementation for deploying agents, used by both the API endpoint
 * and the AgentManager tool.
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

  if (input.source !== undefined) {
    // Build module from source using container sandbox
    console.log("Building agent from source...");
    const buildResult = await buildAgent(input.source, env, onProgress);

    if (!buildResult.success) {
      // Return build errors for dryRun or throw for real deployment
      if (dryRun) {
        return {
          version: "",
          dependencies: [],
          errors: buildResult.errors,
        };
      }
      throw new Error(
        `Failed to build agent from source:\n${buildResult.errors.join("\n")}`
      );
    }

    moduleCode = buildResult.module;
    console.log("Agent built successfully from source");
  } else {
    // Use provided module directly
    moduleCode = input.module!;
  }

  // If dryRun, stop here and return validation success
  if (dryRun) {
    return {
      version: "dry-run",
      dependencies: [],
      errors: [],
    };
  }

  // Report deployment progress
  onProgress?.("Deploying agent");

  // Store agent module in R2 and get version + dependencies
  let version: string;
  let dependencies: any[];
  let permissions: any;
  try {
    const storeResult = await storeAgentModule({
      env,
      ctx,
      id: adminId,
      module: moduleCode,
      environment,
    });
    version = storeResult.version;
    dependencies = storeResult.dependencies;
    permissions = storeResult.permissions;
  } catch (error) {
    throw new Error(
      `Failed to store agent module: ${
        error instanceof Error ? error.message : "Unknown error"
      }`
    );
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
        permissions,
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
    const updateData: Record<string, any> = { version, permissions };
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
          permissions,
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

  // Extract only direct dependencies (id only) for the response
  const directDependencies = dependencies.map((dep) => dep.id);

  return {
    version,
    dependencies: directDependencies,
  };
}
