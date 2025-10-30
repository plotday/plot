import { type SupabaseClient } from "@plotday/db";

import { type AgentEnvironment, type Bindings } from "../env";
import { agentFactory } from "./factory";

export async function storeAgentModule({
  env,
  ctx,
  id,
  module,
  sourcemap,
  environment,
  supabase,
  dryRun = false,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  id: string;
  module: string;
  sourcemap?: string;
  environment: AgentEnvironment;
  supabase: SupabaseClient;
  dryRun?: boolean;
}) {
  // Generate timestamp version (or placeholder for dry-run)
  const version = dryRun ? "dry-run" : Date.now().toString();

  // Initialize agent to collect permissions
  const { permissions, toolPermissions } = await agentFactory({
    env,
    ctx,
    supabase,
    checkPermissions: false,
    module,
  })({ id, environment, version, priorityId: "", priorityAgentId: "" });

  // Only store to R2 and KV if not in dry-run mode
  if (!dryRun) {
    await env.AGENT_MODULES_BUCKET.put(
      `agents/${id}/${version}/modules`,
      module
    );

    // Store sourcemap if provided (for stack trace translation)
    if (sourcemap) {
      await env.AGENT_MODULES_BUCKET.put(
        `agents/${id}/${version}/sourcemaps`,
        sourcemap
      );
    }

    await env.AGENT_CONFIG.put(
      `${id}:${version}`,
      JSON.stringify({ permissions, toolPermissions })
    );
  }

  return {
    version,
    permissions,
  };
}
