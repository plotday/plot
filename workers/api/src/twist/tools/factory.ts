import type { Kysely } from "kysely";

import type { OptionsSchema } from "@plotday/twister/options";
import type {
  AICapabilities,
  AIRequest,
  AIResponse,
  AIToolSet,
  AI as IAI,
} from "@plotday/twister/tools/ai";
import type { TSchema } from "typebox";

import type { DB } from "../../db-types";
import { type TwistEnvironment, type Bindings } from "../../env";
import { type ToolPermission } from "../permissions";
import { Twists } from "./twists";
import { AI, type AiProviderConfig } from "./ai";
import { Callbacks } from "./callbacks";
import { Integrations } from "./integrations";
import { Imap, type ImapOptions } from "./imap";
import { Smtp, type SmtpOptions } from "./smtp";
import { Network } from "./network";
import { Plot } from "./plot";
import { Store } from "./store";
import { Tasks } from "./tasks";
import { Tool } from "./tool";

/**
 * Stub returned when a twist declares AI as optional (required: false)
 * and the user has AI disabled. Returns unavailable capabilities and
 * throws on actual AI calls.
 */
class AIDisabledStub extends Tool implements IAI {
  available(): AICapabilities {
    return { prompt: false, embed: false };
  }

  async prompt<TOOLS extends AIToolSet, SCHEMA extends TSchema = never>(
    _request: AIRequest<TOOLS, SCHEMA>
  ): Promise<AIResponse<TOOLS, SCHEMA>> {
    throw new Error("AI features are disabled by the user.");
  }

  async embed(_text: string): Promise<number[]> {
    throw new Error("AI features are disabled by the user.");
  }
}

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
  | typeof Imap
  | typeof Smtp
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
    case "Imap":
      return Imap;
    case "Smtp":
      return Smtp;
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
    twistInstanceId,
    env,
    ctx,
    config,
    sourceProvider,
    aiEnabled,
    providerConfig,
    effectivePlan,
    secureOptions,
  }: {
    twistId: string;
    environment: TwistEnvironment;
    db: Kysely<DB>;
    twistInstanceId: string;
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
    config?: Record<string, unknown>;
    /** Source metadata (provider, scopes, linkTypes) for Sources using the new API. */
    sourceProvider?: { provider?: string; scopes?: string[]; linkTypes?: any[]; handleReplies?: boolean } | null;
    /** Whether AI features are enabled for the user. Undefined during deployment. */
    aiEnabled?: boolean;
    /** AI provider configuration. When set, uses this provider instead of Plot AI. */
    providerConfig?: AiProviderConfig;
    /** The user's effective plan (e.g. "free", "pro", "team"). Undefined during deployment. */
    effectivePlan?: string;
    /** Pre-resolved decrypted secure option values. */
    secureOptions?: Record<string, string>;
  }
): Tool {
  switch (id) {
    case "Plot":
      return new Plot({
        db,
        twistInstanceId,
        options,
        env,
      });
    case "AI":
      // Return disabled stub when AI is off and twist declared AI as optional
      if (aiEnabled === false && (options as any)?.required === false) {
        return new AIDisabledStub();
      }
      // Return disabled stub for free users without a provider configured
      if (effectivePlan === "free" && !providerConfig) {
        return new AIDisabledStub();
      }
      return new AI({ env, twistInstanceId, providerConfig });
    case "Network":
      return new Network({
        ...options,
        callbacks: env.CALLBACKS,
        twistInstanceId,
        twistId,
        environment,
        baseUrl: env.API_ROOT,
        path,
        env,
        store: new Store({
          path,
          storage: env.STORAGE,
          twistInstanceId,
        }),
      });
    case "Integrations":
      return new Integrations({
        path,
        store: new Store({
          path,
          storage: env.STORAGE,
          twistInstanceId,
        }),
        env,
        ctx,
        db,
        twistInstanceId,
        twistId,
        environment,
        integrationOptions: options as any,
        sourceProvider,
      });
    case "Store":
      return new Store({
        path,
        storage: env.STORAGE,
        twistInstanceId,
      });
    case "Tasks":
      return new Tasks({
        path,
        callbacks: env.CALLBACKS,
        twistInstanceId,
        twistId,
        environment,
        queue: env.RUN_QUEUE,
      });
    case "Callbacks":
      return new Callbacks({
        callbacks: env.CALLBACKS,
        twistInstanceId,
        twistId,
        environment,
        path,
      });
    case "Twists":
      return new Twists({
        env,
        ctx,
        db,
        twistInstanceId,
      });
    case "Imap":
      return new Imap(options as ImapOptions);
    case "Smtp":
      return new Smtp(options as SmtpOptions);
    case "Options":
      // Options is not a real tool — return a plain object with resolved values.
      // The schema is passed as `options`, config comes from twist_instance.config
      // which is injected by the factory caller.
      // Secure options are resolved separately via secureOptions param.
      {
        const resolved = resolveOptions(options as OptionsSchema, config);
        if (secureOptions) {
          Object.assign(resolved, secureOptions);
        }
        return resolved as unknown as Tool;
      }
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
  /** Optional scope groups the user can toggle before OAuth. */
  optionalScopes?: Array<{
    id: string;
    label: string;
    description?: string;
    scopes: string[];
    default: boolean;
  }>;
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
  const byProvider = new Map<string, {
    scopes: Set<string>;
    optionalScopes?: ProviderDeclaration["optionalScopes"];
  }>();

  for (const decl of declarations) {
    if (!byProvider.has(decl.provider)) {
      byProvider.set(decl.provider, { scopes: new Set() });
    }
    const entry = byProvider.get(decl.provider)!;
    for (const scope of decl.scopes) {
      entry.scopes.add(scope);
    }
    // First declaration with optionalScopes wins (connector-level)
    if (decl.optionalScopes && !entry.optionalScopes) {
      entry.optionalScopes = decl.optionalScopes;
    }
  }

  return Array.from(byProvider.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([provider, entry]) => ({
      provider,
      scopes: Array.from(entry.scopes).sort(),
      ...(entry.optionalScopes ? { optionalScopes: entry.optionalScopes } : {}),
    }));
}
