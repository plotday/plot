import type { SupabaseClient } from "@plotday/db";

import { type AgentEnvironment, type Bindings } from "../../env";
import { type ToolPermission } from "../permissions";
import { Agents } from "./agents";
import { AI } from "./ai";
import { Callbacks } from "./callbacks";
import { Integrations } from "./integrations";
import { Network } from "./network";
import { Plot } from "./plot";
import { Store } from "./store";
import { Tasks } from "./tasks";
import type { Tool } from "./tool";

/**
 * Returns the tool class for a given tool ID.
 * Centralizes the tool ID -> class mapping to ensure consistency
 * across createTool() and collectToolPermissions().
 *
 * @param toolId - The tool identifier (e.g., "Plot", "Network")
 * @returns The tool class
 * @throws Error if tool ID is unknown
 */
function getToolClass(
  toolId: string
):
  | typeof Plot
  | typeof Network
  | typeof AI
  | typeof Integrations
  | typeof Store
  | typeof Tasks
  | typeof Callbacks
  | typeof Agents {
  switch (toolId) {
    case "Plot":
      return Plot;
    case "Network":
      return Network;
    case "AI":
      return AI;
    case "Integrations":
      return Integrations;
    case "Store":
      return Store;
    case "Tasks":
      return Tasks;
    case "Callbacks":
      return Callbacks;
    case "Agents":
      return Agents;
    default:
      throw new Error(`Unknown tool ID: ${toolId}`);
  }
}

export function createTool(
  path: string[],
  id: string,
  options: object,
  {
    agentId,
    environment,
    supabase,
    priorityId,
    priorityAgentId,
    env,
    ctx,
  }: {
    agentId: string;
    environment: AgentEnvironment;
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
  }
): Tool {
  switch (id) {
    case "Plot":
      return new Plot({
        supabase,
        priorityId,
        priorityAgentId,
        options,
        env,
      });
    case "AI":
      return new AI({ env, priorityAgentId });
    case "Network":
      return new Network({
        ...options,
        callbacks: env.CALLBACKS,
        priorityAgentId,
        agentId,
        environment,
        baseUrl: env.API_ROOT,
        path,
      });
    case "Integrations":
      return new Integrations({
        path,
        store: new Store({
          path,
          storage: env.STORAGE,
          priorityAgentId,
        }),
        env,
        priorityAgentId,
        agentId,
        environment,
      });
    case "Store":
      return new Store({
        path,
        storage: env.STORAGE,
        priorityAgentId,
      });
    case "Tasks":
      return new Tasks({
        path,
        callbacks: env.CALLBACKS,
        priorityAgentId,
        agentId,
        environment,
        queue: env.RUN_QUEUE,
      });
    case "Callbacks":
      return new Callbacks({
        callbacks: env.CALLBACKS,
        priorityAgentId,
        agentId,
        environment,
        path,
      });
    case "Agents":
      return new Agents({
        env,
        ctx,
        supabase,
        priorityAgentId,
      });
    default:
      throw new Error(`Unknown tool: ${id}`);
  }
}

/**
 * Collects permissions for a tool by calling its static Permissions method.
 * Returns empty array if the tool doesn't implement the method.
 */
export function collectToolPermissions(
  toolId: string,
  options: any
): ToolPermission[] {
  const ToolClass = getToolClass(toolId);

  // Check if the class has a static Permissions method
  if (
    "Permissions" in ToolClass &&
    typeof ToolClass.Permissions === "function"
  ) {
    return ToolClass.Permissions(options);
  }

  // Tool doesn't require permissions
  return [];
}
