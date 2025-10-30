import { type Priority } from "@plotday/agent/plot";
import { type SupabaseClient } from "@plotday/db";

import { type AgentEnvironment, type Bindings } from "../env";
import { handleAgentOperation } from "./error-handling";
import { getAgent } from "./loader";
import {
  type MergedPermissions,
  type ToolPermission,
  comparePermissions,
  mergeToolPermissions,
} from "./permissions";
import { collectToolPermissions, createTool } from "./tools/factory";
import { type Tool } from "./tools/tool";

export function agentFactory({
  env,
  ctx,
  supabase,
  checkPermissions,
  module,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  checkPermissions?: boolean;
  module?: string;
}) {
  if (!ctx.exports) {
    throw new Error("ExecutionContext exports missing");
  }
  checkPermissions ??= true;
  return async ({
    id,
    environment,
    version,
    priorityId,
    priorityAgentId,
  }: {
    id: string;
    environment: AgentEnvironment;
    version?: string;
    priorityId: string;
    priorityAgentId: string;
  }) => {
    const { agent, version: resolvedVersion } = await getAgent({
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
      module,
    });
    version = resolvedVersion;

    // Track tool instances for permission collection
    const toolInstances: Array<{ path: string[]; id: string; options: any }> =
      [];
    let storedPermissions: MergedPermissions | undefined;
    let storedToolPermissions: Record<string, ToolPermission[]> | undefined;

    if (checkPermissions) {
      const config = await env.AGENT_CONFIG.get(`${id}:${version}`);
      if (!config) {
        throw new Error(`Agent configuration not found: ${id}:${version}`);
      }
      ({
        permissions: storedPermissions,
        toolPermissions: storedToolPermissions,
      } = JSON.parse(config));
    }

    // Create factory function for constructing built-in tools at runtime
    const builtInToolFactory = (
      path: string[],
      toolId: string,
      options?: any
    ): Tool => {
      // Validate permissions before creating tool
      const pathString = path.join(":");
      if (checkPermissions && storedToolPermissions) {
        const expected = collectToolPermissions(toolId, options);
        const stored = storedToolPermissions[pathString];

        if (!stored) {
          throw new Error(`No stored permissions for tool path: ${pathString}`);
        }

        if (!comparePermissions(expected, stored)) {
          throw new Error(
            `Permission mismatch for ${pathString}. ` +
              `Expected: ${JSON.stringify(expected)}, ` +
              `Stored: ${JSON.stringify(stored)}`
          );
        }
      }

      const tool = createTool(path, toolId, options, {
        agentId: id,
        environment,
        supabase,
        priorityId,
        priorityAgentId,
        env,
        ctx,
      });

      // Track tool for permission collection
      toolInstances.push({ path, id: toolId, options });

      return tool;
    };

    // Create agentInit object to pass to each agent method
    const agentInit = {
      priorityAgentId,
      builtInToolFactory,
    };

    // Initialize agent and collect/validate permissions
    let permissions: MergedPermissions = {};
    let toolPermissionsMap: Record<string, ToolPermission[]> = {};

    if (!checkPermissions) {
      // DEPLOYMENT: Initialize agent to build tools and collect permissions
      await agent.init(agentInit);

      // Collect and merge permissions from all tools
      const allPermissions: ToolPermission[] = [];
      for (const { id: toolId, options } of toolInstances) {
        const perms = collectToolPermissions(toolId, options);
        allPermissions.push(...perms);
      }
      permissions = mergeToolPermissions(allPermissions);

      // Build per-path toolPermissions map for storage
      // Maps tool paths (e.g., "Plot", "Plot:Activity") to their ToolPermission arrays
      for (const { path, id: toolId, options } of toolInstances) {
        const pathString = path.join(":");
        toolPermissionsMap[pathString] = collectToolPermissions(
          toolId,
          options
        );
      }
    } else {
      // RUNTIME: Tools are validated per-path in builtInToolFactory as they're created
      // Use stored permissions without rebuilding agent
      permissions = storedPermissions || {};
    }

    return {
      permissions,
      toolPermissions: toolPermissionsMap,
      activate: async (priority: Pick<Priority, "id">) => {
        await env.AGENT_LOGS_QUEUE.send({
          agentRootId: id,
          environment,
          severity: "info",
          message: `Activating in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleAgentOperation(
          "activate",
          () => agent.activate(agentInit, priority),
          { env, id, version, environment }
        );
      },

      upgrade: async () => {
        await env.AGENT_LOGS_QUEUE.send({
          agentRootId: id,
          environment,
          severity: "info",
          message: `Upgrading in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleAgentOperation("upgrade", () => agent.upgrade(agentInit), {
          env,
          id,
          version,
          environment,
        });
      },

      deactivate: async () => {
        await env.AGENT_LOGS_QUEUE.send({
          agentRootId: id,
          environment,
          severity: "info",
          message: `Deactivating in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleAgentOperation(
          "deactivate",
          () => agent.deactivate(agentInit),
          { env, id, version, environment }
        );
      },

      dispatch: async (toolName: string, ...args: any[]) => {
        // Find all tool paths that include this tool type
        const toolPaths = Object.keys(
          storedToolPermissions ?? toolPermissionsMap
        ).filter((path) => path.split(":").includes(toolName));

        if (toolPaths.length === 0) {
          return; // No instances of this tool
        }

        const agentInit = {
          priorityAgentId,
          builtInToolFactory,
        };

        // Convert all paths to arrays
        const pathArrays = toolPaths.map((path) => path.split(":"));

        // Single RPC call with all paths
        await agent.dispatchToTool(agentInit, pathArrays, ...args);
      },

      callCallback: async (
        path: string[],
        functionName: string,
        ...args: any[]
      ) => {
        return await handleAgentOperation(
          functionName,
          // @ts-ignore - Type instantiation is excessively deep and possibly infinite
          () => agent.callCallback(agentInit, path, functionName, ...args),
          { env, id, version, environment }
        );
      },
    };
  };
}
