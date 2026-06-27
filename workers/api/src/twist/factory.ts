import type { Kysely } from "kysely";

import type { OptionsSchema } from "@plotday/twister/options";
import { createLogger } from "@plotday/worker-util";

import type { DB } from "../db-types";
import { type Bindings, type TwistEnvironment } from "../env";
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
    twistInstanceId,
  }: {
    id?: string;
    environment?: TwistEnvironment;
    version?: string;
    twistInstanceId: string;
  }) => {
    const twistData = await getTwist({
      env,
      ctx,
      db,
      id: providedId,
      environment: providedEnvironment,
      version,
      twistInstanceId,
      storage: env.STORAGE,
      callbacks: env.CALLBACKS,
      logSubscriptions: env.LOG_SUBSCRIPTIONS,
      module,
    });
    const twist = twistData.twist;
    const id = twistData.id!;
    const environment = twistData.environment!;
    version = twistData.version!;

    // Some callers pass a narrowed ctx (e.g. DO state's `{ exports }` shape)
    // that lacks waitUntil. Probe at runtime so handleTwistOperation can
    // skip the PostHog escalation when no real ExecutionContext is in
    // scope. Request and scheduled-handler callers always pass the full
    // ctx; permission-introspection paths and the like don't.
    const operationCtx: { waitUntil: ExecutionContext["waitUntil"] } | undefined =
      typeof (ctx as { waitUntil?: unknown }).waitUntil === "function"
        ? (ctx as ExecutionContext)
        : undefined;

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
      autoEnableNewChannelsByDefault?: boolean;
      autoThreading?: boolean;
      autoThreadingByDefault?: boolean;
      access?: string[];
      // Per-product metadata for combined (multi-product) connectors. Absent
      // for plain connectors. Each entry's scopeGroupId matches an optional
      // scope group id; the integrations endpoint derives productStatus from it.
      products?: Array<{
        key: string;
        label: string;
        description: string;
        icon: string;
        scopeGroupId: string;
      }>;
    } | null = null;

    // Load twist_instance config for Options resolution at runtime
    let twistInstanceConfig: Record<string, unknown> | undefined;

    // Owning user (twist_instance.owner_id) — passed to handleTwistOperation so
    // PostHog captures are attributed to a real person instead of a random
    // per-event distinct_id. Matches the queue consumer's twistOwnerId convention.
    let ownerId: string | null = null;

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

      // Load user config from twist_instance for Options resolution
      if (twistInstanceId && twistInstanceId !== "__deployment__") {
        const pt = await db
          .selectFrom("twist_instance")
          .select(["options", "owner_id"])
          .where("id", "=", twistInstanceId)
          .executeTakeFirst();
        if (pt?.options) {
          twistInstanceConfig =
            typeof pt.options === "string"
              ? JSON.parse(pt.options)
              : (pt.options as Record<string, unknown>);
        }
        ownerId = pt?.owner_id ?? null;
      }
    }

    // Query user's twist AI preference at runtime (not during deployment)
    let aiEnabled: boolean | undefined;
    if (
      checkPermissions &&
      twistInstanceId &&
      twistInstanceId !== "__deployment__"
    ) {
      const ownerPref = await db
        .selectFrom("twist_instance")
        .innerJoin(
          "ai_preference",
          "ai_preference.user_id",
          "twist_instance.owner_id"
        )
        .select("ai_preference.twist_ai_disabled")
        .where("twist_instance.id", "=", twistInstanceId)
        .executeTakeFirst();
      aiEnabled = ownerPref?.twist_ai_disabled !== true;
    }

    // BYOK removed in B4 — providerConfig is always undefined; all AI uses the built-in provider.
    // The providerConfig branch in tools/ai.ts is left in place but never reached.
    // See factory.ts change in pricing-model-product-changes for the removal rationale.
    const providerConfig: AiProviderConfig | undefined = undefined;

    // Resolve secure options at runtime (decrypt secure values from secure_option table)
    let resolvedSecureOptions: Record<string, string> | undefined;
    if (
      checkPermissions &&
      twistInstanceId &&
      twistInstanceId !== "__deployment__"
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
          .selectFrom("twist_instance")
          .innerJoin("twist", "twist.id", "twist_instance.twist_id")
          .select("twist.options_schema")
          .where("twist_instance.id", "=", twistInstanceId)
          .executeTakeFirst();
        if (twistRow?.options_schema) {
          optSchema = (
            typeof twistRow.options_schema === "string"
              ? JSON.parse(twistRow.options_schema)
              : twistRow.options_schema
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
            twistInstanceId,
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
          twistInstanceId,
          env,
          ctx,
          config: twistInstanceConfig,
          sourceProvider,
          aiEnabled,
          providerConfig,
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
        twistInstanceId,
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

    // Look up the twist owner user ID once so we can hand it to the twist
    // runtime as `this.userId`. Falls back to empty string for the synthetic
    // deployment twist instance that has no real owner row.
    let twistOwnerUserId = "";
    if (twistInstanceId && twistInstanceId !== "__deployment__") {
      const ownerRow = await db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", twistInstanceId)
        .executeTakeFirst();
      twistOwnerUserId = ownerRow?.owner_id ?? "";
    }

    // Create twistInit object to pass to each twist method
    const twistInit = {
      twistInstanceId,
      userId: twistOwnerUserId,
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
    let multipleInstances = false;
    let reactionCapabilities: unknown = null;
    let dynamicLinkTypes = false;

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
          ...(sourceProvider.access ? { access: sourceProvider.access } : {}),
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

      // Read static multipleInstances flag from the twist class
      multipleInstances = (twist.constructor as { multipleInstances?: boolean }).multipleInstances ?? false;

      // Read reactionCapabilities instance property from the connector
      reactionCapabilities =
        (twist as { reactionCapabilities?: unknown }).reactionCapabilities ?? null;

      // Read dynamicLinkTypes instance property from the connector
      dynamicLinkTypes =
        (twist as { dynamicLinkTypes?: boolean }).dynamicLinkTypes ?? false;
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
      multipleInstances,
      reactionCapabilities,
      dynamicLinkTypes,
      activate: async (
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
          () => twist.activate(twistInit, context),
          { env, id, version, environment, userId: ownerId, ctx: operationCtx }
        );
      },

      upgrade: async () => {
        await handleTwistOperation("upgrade", () => twist.upgrade(twistInit), {
          env,
          id,
          version,
          environment,
          userId: ownerId,
          ctx: operationCtx,
        });
      },

      deactivate: async () => {
        await env.TWIST_LOGS_QUEUE.send({
          twistRootId: id,
          environment,
          severity: "info",
          message: `Deactivating in ${environment} for twist instance ${twistInstanceId}`,
          timestamp: Date.now(),
        });

        await handleTwistOperation(
          "deactivate",
          () => twist.deactivate(twistInit),
          { env, id, version, environment, userId: ownerId, ctx: operationCtx }
        );
      },

      dispatch: async (toolName: string, ...args: any[]) => {
        // Find all tool paths that include this tool type
        let toolPaths = Object.keys(
          storedToolPermissions ?? toolPermissionsMap
        ).filter((path) => path.split(":").includes(toolName));

        if (toolPaths.length === 0) {
          return; // No instances of this tool
        }

        // When a connector includes sub-connectors that declare the same tool
        // (e.g. GoogleChat includes GoogleContacts, both have Integrations),
        // prefer the shortest paths to avoid duplicate dispatch.
        if (toolPaths.length > 1) {
          const minDepth = Math.min(
            ...toolPaths.map((p) => p.split(":").length)
          );
          toolPaths = toolPaths.filter(
            (p) => p.split(":").length === minDepth
          );
        }

        const logger = createLogger({ twist_id: id, environment });
        logger.info("Dispatching to twist tool", {
          tool_name: toolName,
        });

        const twistInit = {
          twistInstanceId,
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
          { env, id, version, environment, userId: ownerId, ctx: operationCtx }
        );
      },

      /**
       * Call a method directly on the connector/twist instance and return its
       * result. Used for request/response patterns such as `downloadAttachment`.
       *
       * Calls `callCallback` with an empty path so the method is invoked on the
       * twist root (i.e. the Connector class instance) rather than on a built-in
       * tool. Errors propagate to the caller unmodified.
       *
       * @param methodName - Name of the method to call on the connector instance.
       * @param args - Arguments forwarded to the method.
       * @returns Whatever the method returns.
       */
      runConnectorMethod: async (
        methodName: string,
        ...args: unknown[]
      ): Promise<unknown> => {
        return await handleTwistOperation(
          methodName,
          // @ts-ignore - Type instantiation is excessively deep and possibly infinite
          () => twist.callCallback(twistInit, [], methodName, ...args),
          { env, id, version, environment, userId: ownerId, ctx: operationCtx }
        );
      },
    };
  };
}
