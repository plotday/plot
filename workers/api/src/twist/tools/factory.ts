import type { Kysely } from "kysely";

import type { OptionsSchema } from "@plotday/twister/options";

import type { DB } from "../../db-types";
import { type TwistEnvironment, type Bindings } from "../../env";
import { type ToolPermission } from "../permissions";
import { Twists } from "./twists";
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
 * @returns The tool class or null for special built-in tools like Options
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
  | typeof Twists
  | null {
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
    case "Twists":
      return Twists;
    case "Options":
      return null; // Handled specially — not a real tool
    default:
      throw new Error(`Unknown tool ID: ${toolId}`);
  }
}

/**
 * Resolves option values by merging user config with schema defaults.
 * For each key in the schema, uses the config value if present, otherwise the default.
 */
export function resolveOptions(
  schema: OptionsSchema,
  config: Record<string, unknown> = {}
): Record<string, unknown> {
  const resolved: Record<string, unknown> = {};
  for (const [key, def] of Object.entries(schema)) {
    if (key in config && config[key] !== undefined) {
      resolved[key] = config[key];
    } else {
      resolved[key] = def.default;
    }
  }
  return resolved;
}

export function createTool(
  path: string[],
  id: string,
  options: object,
  {
    twistId,
    environment,
    db,
    priorityId,
    priorityTwistId,
    env,
    ctx,
    config,
  }: {
    twistId: string;
    environment: TwistEnvironment;
    db: Kysely<DB>;
    priorityId: string;
    priorityTwistId: string;
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
    config?: Record<string, unknown>;
  }
): Tool {
  switch (id) {
    case "Plot":
      return new Plot({
        db,
        priorityId,
        priorityTwistId,
        options,
        env,
      });
    case "AI":
      return new AI({ env, priorityTwistId });
    case "Network":
      return new Network({
        ...options,
        callbacks: env.CALLBACKS,
        priorityTwistId,
        twistId,
        environment,
        baseUrl: env.API_ROOT,
        path,
        store: new Store({
          path,
          storage: env.STORAGE,
          priorityTwistId,
        }),
      });
    case "Integrations":
      return new Integrations({
        path,
        store: new Store({
          path,
          storage: env.STORAGE,
          priorityTwistId,
        }),
        env,
        db,
        priorityTwistId,
        twistId,
        environment,
        integrationOptions: options as any,
      });
    case "Store":
      return new Store({
        path,
        storage: env.STORAGE,
        priorityTwistId,
      });
    case "Tasks":
      return new Tasks({
        path,
        callbacks: env.CALLBACKS,
        priorityTwistId,
        twistId,
        environment,
        queue: env.RUN_QUEUE,
      });
    case "Callbacks":
      return new Callbacks({
        callbacks: env.CALLBACKS,
        priorityTwistId,
        twistId,
        environment,
        path,
      });
    case "Twists":
      return new Twists({
        env,
        ctx,
        db,
        priorityTwistId,
      });
    case "Options":
      // Options is not a real tool — return a plain object with resolved values.
      // The schema is passed as `options`, config comes from priority_twist.config
      // which is injected by the factory caller.
      return resolveOptions(options as OptionsSchema, config) as unknown as Tool;
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

  // Options tool has no permissions
  if (!ToolClass) return [];

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

export type ProviderDeclaration = {
  provider: string;
  scopes: string[];
};

/**
 * Collects provider declarations from a tool by calling its static Providers method.
 * Only the Integrations tool implements this.
 */
export function collectToolProviders(
  toolId: string,
  options: any
): ProviderDeclaration[] {
  if (toolId !== "Integrations") return [];
  return Integrations.Providers(options);
}

/**
 * Merges provider declarations from multiple tools, deduplicating scopes per provider.
 */
export function mergeProviderDeclarations(
  declarations: ProviderDeclaration[]
): ProviderDeclaration[] {
  const byProvider = new Map<string, Set<string>>();

  for (const decl of declarations) {
    if (!byProvider.has(decl.provider)) {
      byProvider.set(decl.provider, new Set());
    }
    for (const scope of decl.scopes) {
      byProvider.get(decl.provider)!.add(scope);
    }
  }

  return Array.from(byProvider.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([provider, scopes]) => ({
      provider,
      scopes: Array.from(scopes).sort(),
    }));
}
