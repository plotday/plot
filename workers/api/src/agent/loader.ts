import { type SupabaseClient } from "@plotday/db";

import { type AgentEnvironment, type Bindings } from "../env";
import { type CallbacksState } from "../state/callbacks";
import { type LogSubscriptions } from "../state/log-subscriptions";
import { type Storage } from "../state/storage";
import AgentEntrypoint from "./entrypoint";

export async function getAgent({
  env,
  ctx,
  supabase,
  id,
  environment,
  version,
  priorityId: _priorityId,
  priorityAgentId,
  storage: _storage,
  callbacks: _callbacks,
  logSubscriptions: _logSubscriptions,
  module: providedModule,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  id: string;
  environment: AgentEnvironment;
  version?: string;
  priorityId: string;
  priorityAgentId: string;
  storage: DurableObjectNamespace<Storage>;
  callbacks: DurableObjectNamespace<CallbacksState>;
  logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
  module?: string;
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

  const config = await env.AGENT_CONFIG.get(`${id}:${version}`);
  let httpPermissions = ["*"];
  if (config) {
    const parsed = JSON.parse(config);
    const permissions = parsed?.permissions;
    if (permissions) {
      // Extract network URLs for HttpProxy from permissions
      const networkPerms = permissions["network"] as
        | Record<string, string[]>
        | undefined;
      httpPermissions = networkPerms ? Object.keys(networkPerms) : [];
    }
  }

  // If module is provided directly (e.g., in tests), use it without LOADER
  if (providedModule && !env.LOADER) {
    // Create a mock worker instance for tests
    const mockWorker = {
      getEntrypoint: () => ({
        // Return mock entrypoint with all required methods
        init: async () => {},
        activate: async () => {},
        deactivate: async () => {},
        upgrade: async () => {},
        dispatch: async () => {},
        callCallback: async () => {},
        collectToolPermissions: () => ({
          toolPermissions: {},
          permissions: {},
        }),
      }),
    };
    return {
      agent: mockWorker.getEntrypoint() as any,
      version,
    };
  }

  const moduleId = `${priorityAgentId}-${version}`;
  const worker = env.LOADER.get(moduleId, async () => {
    // Use provided module or load from R2
    let module: string;
    if (providedModule) {
      module = providedModule;
    } else {
      const moduleFromR2 = await (
        await env.AGENT_MODULES_BUCKET.get(`agents/${id}/${version}/modules`)
      )?.text();
      if (!moduleFromR2) {
        throw new Error(`Agent module not found: ${id}:${version}`);
      }
      module = moduleFromR2;
    }
    return {
      compatibilityDate: "2025-10-01",
      mainModule: "index.js",
      modules: {
        "index.js": AgentEntrypoint.Module,
        "agent.js": module,
      },
      globalOutbound: ctx.exports.HttpProxy({
        props: { allowedPatterns: httpPermissions },
      }),
      tails: [
        ctx.exports.AgentTail({
          env: {
            AGENT_LOGS_QUEUE: env.AGENT_LOGS_QUEUE,
            USAGE: env.USAGE,
          },
          props: {
            agentRootId: id,
            environment,
            priorityAgentId,
          },
        }),
      ],
    };
  });

  return {
    agent: worker.getEntrypoint<AgentEntrypoint>(),
    version,
  };
}
