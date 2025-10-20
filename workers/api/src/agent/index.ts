import { type SupabaseClient, createClient } from "@plotday/db";
import { type Tool, type ToolConstructor } from "@plotday/sdk";

import { type Bindings } from "../env";
import AgentEntrypoint from "./entrypoint";

export * from "./management";
export * from "./tools";

export type ToolDependencies = {
  id: string;
  tool?: Tool;
  constructor?: ToolConstructor<any>;
  dependencies?: ToolDependencies[];
  httpPermissions?: string[];
};

/**
 * Common function to load an agent worker from a module
 */
function loadAgent({
  env,
  ctx,
  id,
  version,
  module,
  environment,
}: {
  env: Bindings;
  ctx: ExecutionContext;
  id: string;
  version: string;
  module: string;
  environment: string;
}) {
  const moduleId = `${id}-${version}`;
  const worker = env.LOADER.get(moduleId, async () => {
    return {
      compatibilityDate: "2025-10-01",
      mainModule: "index.js",
      modules: {
        "index.js": AgentEntrypoint.Module,
        "agent.js": module,
      },
      globalOutbound: ctx.exports.HttpProxy,
      tails: [
        ctx.exports.AgentTail({
          env: {
            AGENT_LOGS_QUEUE: env.AGENT_LOGS_QUEUE,
          },
          props: {
            agentRootId: id,
            environment,
          },
        }),
      ],
    };
  });

  return worker.getEntrypoint<AgentEntrypoint>();
}

export async function getAgent({
  env,
  ctx,
  supabase,
  id,
  environment,
  version,
}: {
  env: Bindings;
  ctx: ExecutionContext;
  supabase: SupabaseClient;
  id: string;
  environment: string;
  version?: string;
}) {
  if (!version) {
    const { data, error: agentError } = await supabase
      .from("agent")
      .select("version")
      .eq("id", id)
      .eq("environment", environment)
      .single();

    if (agentError || !data) {
      throw new Error(
        `Failed to fetch agent metadata for ${id} (${environment}): ${
          agentError?.message || "No data found"
        }`
      );
    }
    version ??= data.version;
  }

  // Load agent payload from R2 using id
  const r2Key = `agents/${id}/modules/${version}.js`;
  const agentPayload = await env.AGENT_MODULES_BUCKET.get(r2Key);

  if (!agentPayload) {
    throw new Error(`Agent module not found: ${r2Key}`);
  }

  const payloadText = await agentPayload.text();
  const { module, dependencies } = JSON.parse(payloadText) as {
    module: string;
    dependencies: ToolDependencies[];
  };

  const agent = loadAgent({ env, ctx, id, version, module, environment });
  return { agent, dependencies };
}

export function agentFactory(env: Bindings, ctx: ExecutionContext) {
  // Create a single Supabase client that will be reused for all version fetches
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  return (id: string, environment: string, version?: string) =>
    getAgent({ env, ctx, supabase, id, environment, version });
}

/**
 * Recursively extracts all HTTP permissions from a dependency tree
 */
function extractHttpPermissions(dependencies: any[]): string[] {
  const permissions: string[] = [];

  for (const dep of dependencies) {
    // Add this tool's HTTP permissions
    if (dep.httpPermissions) {
      permissions.push(...dep.httpPermissions);
    }

    // Recursively extract from nested dependencies
    if (dep.dependencies) {
      permissions.push(...extractHttpPermissions(dep.dependencies));
    }
  }

  return permissions;
}

export async function storeAgentModule({
  env,
  ctx,
  id,
  module,
  environment,
}: {
  env: Bindings;
  ctx: ExecutionContext;
  id: string;
  module: string;
  environment: string;
}) {
  // Generate timestamp version
  const version = Date.now().toString();

  const agent = loadAgent({ env, ctx, id, version, module, environment });
  const dependencies = await agent.getDependencies();

  // Extract HTTP permissions from the entire dependency tree
  const httpPermissions = extractHttpPermissions(dependencies as any[]);

  // Store module and dependencies together as JSON in R2
  const r2Key = `agents/${id}/modules/${version}.js`;
  const payload = JSON.stringify({ module, dependencies });
  await env.AGENT_MODULES_BUCKET.put(r2Key, payload);

  return {
    version,
    dependencies,
    permissions: httpPermissions.length > 0 ? { http: httpPermissions } : null,
  };
}
