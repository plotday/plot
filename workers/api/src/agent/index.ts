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
};

/**
 * Common function to load an agent worker from a module
 */
function loadAgent(env: Bindings, id: string, version: string, module: string) {
  const moduleId = `${id}-${version}`;

  const worker = env.LOADER.get(moduleId, async () => {
    return {
      compatibilityDate: "2025-10-01",
      mainModule: "index.js",
      modules: {
        "index.js": AgentEntrypoint.Module,
        "agent.js": module,
      },
    };
  });

  return worker.getEntrypoint<AgentEntrypoint>();
}

export async function getAgent(
  env: Bindings,
  supabase: SupabaseClient,
  id: string,
  environment: string,
  version?: string
) {
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

  const agent = loadAgent(env, id, version, module);
  return { agent, dependencies };
}

export function agentFactory(env: Bindings) {
  // Create a single Supabase client that will be reused for all version fetches
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  return (id: string, environment: string, version?: string) =>
    getAgent(env, supabase, id, environment, version);
}

export async function storeAgentModule(
  env: Bindings,
  id: string,
  module: string
) {
  // Generate timestamp version
  const version = Date.now().toString();

  const agent = loadAgent(env, id, version, module);
  const dependencies = await agent.getDependencies();

  // Store module and dependencies together as JSON in R2
  const r2Key = `agents/${id}/modules/${version}.js`;
  const payload = JSON.stringify({ module, dependencies });
  await env.AGENT_MODULES_BUCKET.put(r2Key, payload);

  return {
    version,
    dependencies,
  };
}
