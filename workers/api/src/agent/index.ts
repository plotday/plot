import { type SupabaseClient, createClient } from "@plotday/db";

import { type Bindings } from "../env";
import AgentEntrypoint from "./entrypoint";
import { type AgentWrapper, type ToolDependencies } from "./types/agent";

export * from "./management";
export * from "./tools";

export async function getAgent(
  env: Bindings,
  supabase: SupabaseClient,
  id: string,
  environment: string,
  version?: string
) {
  // Fetch agent metadata for logging
  const { data: agentData, error: agentError } = await supabase
    .from("agent")
    .select("version")
    .eq("id", id)
    .eq("environment", environment)
    .single();

  if (agentError || !agentData) {
    throw new Error(
      `Failed to fetch agent metadata for ${id} (${environment}): ${
        agentError?.message || "No data found"
      }`
    );
  }

  version ??= agentData.version;

  let moduleId = `${id}-${environment}-${version}`;

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

  // Get the isolate with the given ID, creating it if no such isolate exists yet.
  let worker = env.LOADER.get(moduleId, async () => {
    return {
      compatibilityDate: "2025-10-01",
      mainModule: "index.js",
      modules: {
        "index.js": AgentEntrypoint.Module,
        "agent.js": module,
      },
      // tails: [{
      //   async tail(events: any) {
      //     // Parse console events from tail
      //     for (const event of events) {
      //       if (event.logs) {
      //         for (const log of event.logs) {
      //           const severity =
      //             log.level === "error"
      //               ? "error"
      //               : log.level === "warn"
      //               ? "warn"
      //               : log.level === "info"
      //               ? "info"
      //               : "log";
      //
      //           const message = Array.isArray(log.message)
      //             ? log.message.join(" ")
      //             : String(log.message);
      //
      //           // Send to logs queue
      //           await env.AGENT_LOGS_QUEUE.send({
      //             agentRootId,
      //             environment,
      //             severity,
      //             message,
      //             timestamp: log.timestamp || Date.now(),
      //           });
      //         }
      //       }
      //     }
      //   },
      // }],
    };
  });

  const agent = worker.getEntrypoint<AgentEntrypoint>();
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

  // Get the module dependencies
  let moduleId = `${id}-${version}`;
  let worker = env.LOADER.get(moduleId, async () => {
    return {
      compatibilityDate: "2025-06-01",
      mainModule: "index.js",
      modules: {
        "index.js": AgentEntrypoint.Module,
        "agent.js": module,
      },
    };
  });
  const agent = worker.getEntrypoint<AgentEntrypoint>();
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
