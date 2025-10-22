import { type SupabaseClient } from "@plotday/db";
import { type Activity, type Priority } from "@plotday/sdk/plot";

import { type Bindings } from "../env";
import { type Callbacks } from "../state/callbacks";
import { type LogSubscriptions } from "../state/log-subscriptions";
import { type Storage } from "../state/storage";
import AgentEntrypoint from "./entrypoint";
import { createTools } from "./tools/factory";
import { type Tool } from "./tools/tool";

export * from "./management";
export * from "./tools";

export type ToolDependencies = {
  id: string;
  tool?: Tool;
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
  ctx: { exports: ExecutionContext["exports"] };
  id: string;
  version: string;
  module: string;
  environment: string;
}) {
  if (!ctx.exports) {
    throw new Error("ExecutionContext exports missing");
  }
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
  priorityId,
  priorityAgentId,
  storage,
  callbacks,
  logSubscriptions,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  id: string;
  environment: string;
  version?: string;
  priorityId: string;
  priorityAgentId: string;
  storage: DurableObjectNamespace<Storage>;
  callbacks: DurableObjectNamespace<Callbacks>;
  logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
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

  // Build tools from dependencies
  const tools = createTools(
    {
      path: [],
      dependencies,
    },
    {
      agentId: id,
      environment,
      supabase,
      priorityId,
      priorityAgentId,
      storage,
      callbacks,
      logSubscriptions,
      env,
      ctx,
    }
  );

  return { agent, tools };
}

export function agentFactory(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  supabase: SupabaseClient
) {
  if (!ctx.exports) {
    throw new Error("ExecutionContext exports missing");
  }
  const factory = async ({
    id,
    environment,
    version,
    priorityId,
    priorityAgentId,
  }: {
    id: string;
    environment: string;
    version?: string;
    priorityId: string;
    priorityAgentId: string;
  }) => {
    const { agent, tools } = await getAgent({
      env,
      ctx,
      supabase,
      id,
      environment,
      version,
      priorityId,
      priorityAgentId,
      storage: env.STORAGE,
      callbacks: env.CALLBACKS,
      logSubscriptions: env.LOG_SUBSCRIPTIONS,
    });

    return {
      activate: (priority: Pick<Priority, "id">) =>
        agent.activate(tools, priority, priorityAgentId),

      activity: (activity: Activity, changes?: { previous: Activity }) =>
        agent.activity(tools, activity, changes, priorityAgentId),

      callCallback: (
        path: string[],
        functionName: string,
        args?: any,
        context?: any
      ) => {
        // If path is non-empty, check if it points to a built-in tool
        if (path.length > 0) {
          // Navigate the tool tree to find the target
          let currentDeps = tools;
          let targetTool: ToolDependencies | undefined;

          for (const pathId of path) {
            targetTool = currentDeps.find((dep) => dep.id === pathId);
            if (!targetTool) break;
            currentDeps = targetTool.dependencies ?? [];
          }

          // If we found a built-in tool, execute the callback directly in API worker
          if (targetTool?.tool) {
            const fn = (targetTool.tool as any)[functionName];
            if (typeof fn !== "function") {
              return Promise.reject(
                `Callback function '${functionName}' not found.`
              );
            }
            // Call with proper binding
            return fn.call(targetTool.tool, args, context);
          }
        }

        // Otherwise, dispatch to agent worker (for agent callbacks or non-built-in tools)
        // @ts-ignore - Type instantiation is excessively deep due to recursive ToolDependencies type
        return agent.callCallback(
          tools,
          path,
          functionName,
          args,
          context,
          priorityAgentId
        );
      },

      tools,
    };
  };

  factory.activate = async ({
    id,
    environment,
    version,
    priorityId,
    priorityAgentId,
  }: {
    id: string;
    environment: "personal" | "private" | "review" | "public";
    version?: string;
    priorityId: string;
    priorityAgentId: string;
  }) => {
    // Log before activation
    await env.AGENT_LOGS_QUEUE.send({
      agentRootId: id,
      environment,
      severity: "info",
      message: `Activating in ${environment} for priority ${priorityId}`,
      timestamp: Date.now(),
    });

    const agent = await factory({
      id,
      environment,
      version,
      priorityId,
      priorityAgentId,
    });

    try {
      await agent.activate({ id: priorityId });
    } catch (activateError) {
      // Log activation errors
      console.error("Error activating agent:", activateError);
      const message =
        activateError instanceof Error
          ? `${activateError.name}: ${activateError.message}\n${
              activateError.stack || ""
            }`
          : String(activateError);

      try {
        await env.AGENT_LOGS_QUEUE.send({
          agentRootId: id,
          environment,
          severity: "error",
          message: `Unhandled exception in activate: ${message}`,
          timestamp: Date.now(),
        });
      } catch (logError) {
        console.error("Failed to log activation error:", logError);
      }

      throw activateError;
    }
  };

  return factory;
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
  ctx: { exports: ExecutionContext["exports"] };
  id: string;
  module: string;
  environment: string;
}) {
  // Generate timestamp version
  const version = Date.now().toString();

  const agent = loadAgent({ env, ctx, id, version, module, environment });
  const dependencies = await agent.getDependencies(id);

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
