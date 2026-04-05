import type { Kysely } from "kysely";

import type { OptionsSchema } from "@plotday/twister/options";
import { type Priority } from "@plotday/twister/plot";
import { createLogger } from "@plotday/worker-util";

import type { DB } from "../db-types";
import { type Bindings, type TwistEnvironment } from "../env";
import { decrypt } from "../utils/encryption";
import { getEffectivePlan } from "../utils/plan";
import { resolveSecureOptions } from "../utils/secure-options";
import { handleTwistOperation } from "./error-handling";
import { getTwist } from "./loader";
import {
  type MergedPermissions,
  type ToolPermission,
  comparePermissions,
  mergeToolPermissions,
} from "./permissions";
import type { AiProviderConfig } from "./tools/ai";
import {
  type ProviderDeclaration,
  collectToolPermissions,
  collectToolProviders,
  createTool,
  mergeProviderDeclarations,
} from "./tools/factory";
import { type Tool } from "./tools/tool";

export function twistFactory({
  env,
  ctx,
  db,
  checkPermissions,
  module,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  db: Kysely<DB>;
  checkPermissions?: boolean;
  module?: string;
}) {
  if (!ctx.exports) {
    throw new Error("ExecutionContext exports missing");
  }
  checkPermissions ??= true;
  return async ({
    id: providedId,
    environment: providedEnvironment,
    version,
    priorityId,
    priorityTwistId,
  }: {
    id?: string;
    environment?: TwistEnvironment;
    version?: string;
    priorityId: string;
    priorityTwistId: string;
  }) => {
    const twistData = await getTwist({
      env,
      ctx,
      db,
      id: providedId,
      environment: providedEnvironment,
      version,
      priorityId,
      priorityTwistId,
      storage: env.STORAGE,
      callbacks: env.CALLBACKS,
      logSubscriptions: env.LOG_SUBSCRIPTIONS,
      module,
    });
    const twist = twistData.twist;
    const id = twistData.id!;
    const environment = twistData.environment!;
    version = twistData.version!;

    // Track tool instances for permission collection
    const toolInstances: Array<{ path: string[]; id: string; options: any }> =
      [];
    let storedPermissions: MergedPermissions | undefined;
    let storedToolPermissions: Record<string, ToolPermission[]> | undefined;

    // Track options schema captured during deployment introspection
    let optionsSchema: Record<string, unknown> | undefined;

    // Source metadata (provider, scopes, linkTypes, auth model) — set during deployment, loaded at runtime
    let sourceProvider: {
      provider?: string;
      scopes?: string[];
      linkTypes?: any[];
      handleReplies?: boolean;
      shared?: boolean;
      keyOption?: string;
    } | null = null;

    // Load priority_twist config for Options resolution at runtime
    let priorityTwistConfig: Record<string, unknown> | undefined;

    if (checkPermissions) {
      const config = await env.TWIST_CONFIG.get(`${id}:${version}`);
      if (!config) {
        throw new Error(`Twist configuration not found: ${id}:${version}`);
      }
      const parsedConfig = JSON.parse(config);
      ({
        permissions: storedPermissions,
        toolPermissions: storedToolPermissions,
      } = parsedConfig);
      sourceProvider = parsedConfig.sourceProvider ?? null;

      // Load user config from priority_twist for Options resolution
      if (priorityTwistId && priorityTwistId !== "__deployment__") {
        const pt = await db
          .selectFrom("priority_twist")
          .select("config")
          .where("id", "=", priorityTwistId)
          .executeTakeFirst();
        if (pt?.config) {
          priorityTwistConfig =
            typeof pt.config === "string"
              ? JSON.parse(pt.config)
              : (pt.config as Record<string, unknown>);
        }
      }
    }

    // Query user's twist AI preference at runtime (not during deployment)
    let aiEnabled: boolean | undefined;
    if (
      checkPermissions &&
      priorityTwistId &&
      priorityTwistId !== "__deployment__"
    ) {
      const ownerPref = await db
        .selectFrom("priority_twist")
        .innerJoin(
          "ai_preference",
          "ai_preference.user_id",
          "priority_twist.owner_id"
        )
        .select("ai_preference.twist_ai_disabled")
        .where("priority_twist.id", "=", priorityTwistId)
        .executeTakeFirst();
      aiEnabled = ownerPref?.twist_ai_disabled !== true;
    }

    // Resolve effective plan at runtime (not during deployment)
    let effectivePlan: string | undefined;
    if (
      checkPermissions &&
      priorityTwistId &&
      priorityTwistId !== "__deployment__"
    ) {
      // Get owner_id from priority_twist
      const ptOwner = await db
        .selectFrom("priority_twist")
        .select("owner_id")
        .where("id", "=", priorityTwistId)
        .executeTakeFirst();
      if (ptOwner?.owner_id) {
        const plan = await getEffectivePlan(db, ptOwner.owner_id);
        effectivePlan = plan.plan;
      }
    }

    // Resolve AI provider config at runtime (not during deployment)
    let providerConfig: AiProviderConfig | undefined;
    if (
      checkPermissions &&
      priorityTwistId &&
      priorityTwistId !== "__deployment__"
    ) {
      // Determine scope: org priority → org preference, else → user preference
      // Account-level connectors have no priority_id, skip org lookup
      const priorityOrg = priorityId
        ? await db
            .selectFrom("priority")
            .select("organization_id")
            .where("id", "=", priorityId)
            .executeTakeFirst()
        : undefined;

      let aiPref;
      let scopeFilter: { column: "user_id" | "organization_id"; value: any };

      if (priorityOrg?.organization_id) {
        aiPref = await db
          .selectFrom("ai_preference")
          .select(["twist_ai_key_id", "twist_ai_disabled"])
          .where("organization_id", "=", priorityOrg.organization_id)
          .executeTakeFirst();
        scopeFilter = {
          column: "organization_id",
          value: priorityOrg.organization_id,
        };
      } else {
        const pt = await db
          .selectFrom("priority_twist")
          .select("owner_id")
          .where("id", "=", priorityTwistId)
          .executeTakeFirst();
        if (pt?.owner_id) {
          aiPref = await db
            .selectFrom("ai_preference")
            .select(["twist_ai_key_id", "twist_ai_disabled"])
            .where("user_id", "=", pt.owner_id)
            .executeTakeFirst();
          scopeFilter = { column: "user_id", value: pt.owner_id };
        } else {
          scopeFilter = { column: "user_id", value: null };
        }
      }

      // If twist AI is explicitly disabled via preference, we'll handle below in tool creation
      if (aiPref?.twist_ai_disabled) {
        // Signal to tool factory that AI is disabled
        effectivePlan = "free" as any; // Forces AIDisabledStub when no byok keys
      } else if (aiPref?.twist_ai_key_id) {
        // Load the specific ai_key row for the selected provider
        const aiKeyRow = await db
          .selectFrom("ai_key")
          .select([
            "provider",
            "encrypted_key",
            "iv",
            "custom_base_url",
            "fast_model",
            "thinking_model",
          ])
          .where("id", "=", aiPref.twist_ai_key_id)
          .executeTakeFirst();

        if (aiKeyRow) {
          const plainKey = await decrypt(
            aiKeyRow.encrypted_key,
            aiKeyRow.iv,
            env.AI_KEY_ENCRYPTION_KEY
          );
          providerConfig = {
            provider: aiKeyRow.provider as AiProviderConfig["provider"],
            apiKey: plainKey,
            ...(aiKeyRow.custom_base_url
              ? { baseUrl: aiKeyRow.custom_base_url }
              : {}),
            ...(aiKeyRow.fast_model ? { fastModel: aiKeyRow.fast_model } : {}),
            ...(aiKeyRow.thinking_model
              ? { thinkingModel: aiKeyRow.thinking_model }
              : {}),
          };
        }
      } else if (!aiPref) {
        // No preference row: fall back to legacy behavior — check for any ai_key rows
        // This preserves backward compatibility during migration
        let aiKeyRows;
        if (scopeFilter.value) {
          aiKeyRows = await db
            .selectFrom("ai_key")
            .select([
              "provider",
              "encrypted_key",
              "iv",
              "custom_base_url",
              "fast_model",
              "thinking_model",
            ])
            .where(scopeFilter.column, "=", scopeFilter.value)
            .orderBy("updated_at", "desc")
            .limit(1)
            .execute();
        }

        if (aiKeyRows && aiKeyRows.length > 0) {
          const row = aiKeyRows[0];
          const plainKey = await decrypt(
            row.encrypted_key,
            row.iv,
            env.AI_KEY_ENCRYPTION_KEY
          );
          providerConfig = {
            provider: row.provider as AiProviderConfig["provider"],
            apiKey: plainKey,
            ...(row.custom_base_url ? { baseUrl: row.custom_base_url } : {}),
            ...(row.fast_model ? { fastModel: row.fast_model } : {}),
            ...(row.thinking_model
              ? { thinkingModel: row.thinking_model }
              : {}),
          };
        }
      }
      // else: aiPref exists with twist_ai_key_id=null and twist_ai_disabled=false → Plot AI (no providerConfig)
    }

    // Resolve secure options at runtime (decrypt secure values from secure_option table)
    let resolvedSecureOptions: Record<string, string> | undefined;
    if (
      checkPermissions &&
      priorityTwistId &&
      priorityTwistId !== "__deployment__"
    ) {
      // Get the options schema from KV config (or fall back to DB twist.options)
      let optSchema: OptionsSchema | undefined;
      const storedConfig = await env.TWIST_CONFIG.get(`${id}:${version}`);
      if (storedConfig) {
        const parsedStored = JSON.parse(storedConfig);
        optSchema = parsedStored.optionsSchema as OptionsSchema | undefined;
      }
      // Fallback: load from twist.options column (for twists deployed before
      // optionsSchema was added to KV config)
      if (!optSchema) {
        const twistRow = await db
          .selectFrom("priority_twist")
          .innerJoin("twist", "twist.id", "priority_twist.twist_id")
          .select("twist.options")
          .where("priority_twist.id", "=", priorityTwistId)
          .executeTakeFirst();
        if (twistRow?.options) {
          optSchema = (
            typeof twistRow.options === "string"
              ? JSON.parse(twistRow.options)
              : twistRow.options
          ) as OptionsSchema;
        }
      }
      if (optSchema) {
        const hasSecure = Object.values(optSchema).some(
          (def) => def.type === "text" && "secure" in def && (def as any).secure
        );
        if (hasSecure && env.AI_KEY_ENCRYPTION_KEY) {
          const resolved = await resolveSecureOptions(
            db,
            env.AI_KEY_ENCRYPTION_KEY,
            priorityTwistId,
            optSchema,
            {}
          );
          if (Object.keys(resolved).length > 0) {
            resolvedSecureOptions = resolved as Record<string, string>;
          }
        }
      }
    }

    // Create factory function for constructing built-in tools at runtime
    const builtInToolFactory = (
      path: string[],
      toolId: string,
      options?: any
    ): Tool => {
      // Options tool: capture schema at deploy, resolve values at runtime
      if (toolId === "Options") {
        if (!checkPermissions) {
          // DEPLOYMENT: capture the schema for storage
          optionsSchema = options;
        }
        // Both deploy and runtime: return resolved options object
        toolInstances.push({ path, id: toolId, options });
        return createTool(path, toolId, options, {
          twistId: id,
          environment,
          db,
          priorityId,
          priorityTwistId,
          env,
          ctx,
          config: priorityTwistConfig,
          sourceProvider,
          aiEnabled,
          providerConfig,
          effectivePlan,
          secureOptions: resolvedSecureOptions,
        });
      }

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
        twistId: id,
        environment,
        db,
        priorityId,
        priorityTwistId,
        env,
        ctx,
        sourceProvider,
        aiEnabled,
        providerConfig,
      });

      // Track tool for permission collection
      toolInstances.push({ path, id: toolId, options });

      return tool;
    };

    // Create twistInit object to pass to each twist method
    const twistInit = {
      priorityTwistId,
      builtInToolFactory,
    };

    // Initialize twist and collect/validate permissions and providers
    let permissions: MergedPermissions = {};
    let toolPermissionsMap: Record<string, ToolPermission[]> = {};
    let providers: ProviderDeclaration[] = [];
    let integrationsMap: Record<string, string> = {};
    let aiRequired = false;
    let defaultMentionCreated = false;
    let defaultMentionMentioned = false;

    if (!checkPermissions) {
      // DEPLOYMENT: Initialize twist to build tools and collect permissions
      await twist.init(twistInit);

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

      // Collect source metadata if this is a Source
      sourceProvider = (await twist.getSourceMetadata(twistInit)) ?? null;

      // Backwards-compat inference for auth model:
      // No provider + no keyOption = shared key connector (infer keyOption from first secure option)
      if (
        sourceProvider &&
        !sourceProvider.provider &&
        !sourceProvider.keyOption
      ) {
        sourceProvider.shared = true;
        // Infer keyOption from first secure Options field if present
        if (optionsSchema) {
          for (const [key, def] of Object.entries(optionsSchema)) {
            if ((def as any)?.type === "text" && (def as any)?.secure) {
              sourceProvider.keyOption = key;
              break;
            }
          }
        }
      }

      // Collect and merge provider declarations from all Integrations instances
      const allProviders: ProviderDeclaration[] = [];
      for (const { id: toolId, options } of toolInstances) {
        allProviders.push(...collectToolProviders(toolId, options));
      }
      // For sources using the new API, add provider declaration from source metadata
      // Skip for no-provider connectors (provider is undefined)
      if (sourceProvider?.provider) {
        // Resolve scopes — the connector may declare string[] or ScopeConfig.
        // getSourceMetadata() passes through the raw value from the connector.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const rawScopes: any = sourceProvider.scopes;
        let requiredScopes: string[];
        let optionalScopes: any[] | undefined;
        if (Array.isArray(rawScopes)) {
          requiredScopes = rawScopes;
        } else if (rawScopes?.required) {
          requiredScopes = rawScopes.required;
          optionalScopes = rawScopes.optional;
        } else {
          requiredScopes = [];
        }
        allProviders.push({
          provider: sourceProvider.provider,
          scopes: requiredScopes,
          ...(optionalScopes ? { optionalScopes } : {}),
        });
        // Normalize scopes to string[] so downstream consumers see a flat array
        sourceProvider = { ...sourceProvider, scopes: requiredScopes };
      }
      providers = mergeProviderDeclarations(allProviders);

      // Collect integrations provider-to-path mapping.
      // When multiple Integrations instances register the same provider
      // (e.g., GoogleCalendar and GoogleContacts both register "google"),
      // prefer the shallowest path since child tools share the parent's auth.
      for (const { path, id: toolId, options } of toolInstances) {
        if (toolId === "Integrations" && (options as any)?.providers) {
          const pathString = path.join(":");
          for (const p of (options as any).providers) {
            if (p.provider) {
              const existing = integrationsMap[p.provider];
              if (!existing || path.length < existing.split(":").length) {
                integrationsMap[p.provider] = pathString;
              }
            }
          }
        }
        // For sources: map the source's provider to the Integrations tool path
        if (toolId === "Integrations" && sourceProvider?.provider) {
          const pathString = path.join(":");
          const existing = integrationsMap[sourceProvider.provider];
          if (!existing || path.length < existing.split(":").length) {
            integrationsMap[sourceProvider.provider] = pathString;
          }
        }
        // For no-provider connectors: map synthetic "_options" provider to the Integrations path
        if (
          toolId === "Integrations" &&
          sourceProvider &&
          !sourceProvider.provider
        ) {
          const pathString = path.join(":");
          integrationsMap["_options"] = pathString;
        }
      }

      // Compute whether this twist requires AI
      // AI is required if any tool is "AI" and its options don't set required: false
      const aiTool = toolInstances.find(({ id: toolId }) => toolId === "AI");
      aiRequired = aiTool ? aiTool.options?.required !== false : false;

      // Compute default mention flags from Plot tool options
      for (const { id: toolId, options } of toolInstances) {
        if (toolId === "Plot") {
          if ((options as any)?.thread?.defaultMention)
            defaultMentionCreated = true;
          if ((options as any)?.note?.defaultMention)
            defaultMentionMentioned = true;
        }
      }

      // For connectors, read handleReplies from source metadata
      if (sourceProvider?.handleReplies) {
        defaultMentionCreated = true;
      }
    } else {
      // RUNTIME: Tools are validated per-path in builtInToolFactory as they're created
      // Use stored permissions without rebuilding twist
      permissions = storedPermissions || {};
    }

    return {
      permissions,
      toolPermissions: toolPermissionsMap,
      providers,
      integrationsMap,
      optionsSchema,
      sourceProvider,
      aiRequired,
      defaultMentionCreated,
      defaultMentionMentioned,
      activate: async (
        priority: Pick<Priority, "id">,
        context?: {
          actor: { id: string; type: number };
          /** Authorization for source activation (Sources only). */
          auth?: {
            provider: string;
            scopes: string[];
            actor: {
              id: string;
              type: number;
              email?: string | null;
              name?: string | null;
            };
          };
        }
      ) => {
        await handleTwistOperation(
          "activate",
          () => twist.activate(twistInit, priority, context),
          { env, id, version, environment }
        );
      },

      upgrade: async () => {
        await handleTwistOperation("upgrade", () => twist.upgrade(twistInit), {
          env,
          id,
          version,
          environment,
        });
      },

      deactivate: async () => {
        await env.TWIST_LOGS_QUEUE.send({
          twistRootId: id,
          environment,
          severity: "info",
          message: `Deactivating in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleTwistOperation(
          "deactivate",
          () => twist.deactivate(twistInit),
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

        const logger = createLogger({ twist_id: id, environment });
        logger.info("Dispatching to twist tool", {
          tool_name: toolName,
        });

        const twistInit = {
          priorityTwistId,
          builtInToolFactory,
        };

        // Convert all paths to arrays
        const pathArrays = toolPaths.map((path) => path.split(":"));

        // Single RPC call with all paths
        await twist.dispatchToTool(twistInit, pathArrays, ...args);
      },

      callCallback: async (
        path: string[],
        functionName: string,
        ...args: any[]
      ) => {
        return await handleTwistOperation(
          functionName,
          // @ts-ignore - Type instantiation is excessively deep and possibly infinite
          () => twist.callCallback(twistInit, path, functionName, ...args),
          { env, id, version, environment }
        );
      },
    };
  };
}
