import type { Kysely } from "kysely";
import { Hono } from "hono";
import { z } from "zod";

import type { DB } from "../db";
import type { Bindings } from "../env";
import { twistFactory } from "../twist";
import { Integrations } from "../twist/tools/integrations";
import { Store } from "../twist/tools/store";
import { createLogger } from "@plotday/worker-util";
import type { ProviderDeclaration } from "../twist/tools/factory";
import { disposeRpc } from "../utils/rpc";
import { checkChannelConnectionLimit, PlanLimitError } from "../utils/limits";
import { handleValidationError } from "../utils/validation";
import type { OptionsSchema } from "@plotday/twister/options";
import { saveSecureOptions } from "../utils/secure-options";

const twistIntegrations = new Hono<{ Bindings: Bindings }>();

// ============================================================================
// Helpers
// ============================================================================

/**
 * Look up priority_twist metadata needed for integration operations.
 */
async function resolveTwistInfo(db: Kysely<DB>, priorityTwistId: string) {
  const row = await db
    .selectFrom("priority_twist")
    .innerJoin("twist", "twist.id", "priority_twist.twist_id")
    .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
    .select([
      "priority_twist.twist_id as twistId",
      "priority_twist.priority_id as priorityId",
      "twist.version",
      "twist.environment",
      "twist.options as twistOptions",
      "twist.shared",
      "twist.key_option as keyOption",
      "twist_admin.twist_package_id as twistPackageId",
    ])
    .where("priority_twist.id", "=", priorityTwistId)
    .where("priority_twist.archived_at", "is", null)
    .executeTakeFirst();

  return row ?? null;
}

/**
 * Load twist KV config (providers, integrationsMap, etc.)
 */
async function loadTwistConfig(
  env: Bindings,
  twistPackageId: string,
  version: string
): Promise<{
  providers: ProviderDeclaration[];
  integrationsMap: Record<string, string>;
  toolPermissions: Record<string, any>;
  optionsSchema: OptionsSchema | null;
  singleChannel: boolean;
} | null> {
  const config = await env.TWIST_CONFIG.get(`${twistPackageId}:${version}`);
  if (!config) return null;

  const parsed = JSON.parse(config);
  return {
    providers: parsed.providers ?? [],
    integrationsMap: parsed.integrationsMap ?? {},
    toolPermissions: parsed.toolPermissions ?? {},
    optionsSchema: parsed.optionsSchema ?? null,
    singleChannel: parsed.sourceProvider?.singleChannel === true,
  };
}

/**
 * Find the current user's contact ID (any contact linked to their user account).
 */
async function getCurrentActorId(
  db: Kysely<DB>,
  userId: string
): Promise<string | null> {
  const row = await db
    .selectFrom("contact")
    .select("id")
    .where("user_id", "=", userId)
    .executeTakeFirst();

  return row?.id ?? null;
}

/**
 * Create a standalone Integrations instance for read-only operations.
 * Uses stub lifecycle callbacks since mutations are not needed.
 */
function createReadOnlyIntegrations(
  path: string[],
  providers: ProviderDeclaration[],
  env: Bindings,
  db: Kysely<DB>,
  priorityTwistId: string,
  twistPackageId: string,
  environment: string
): Integrations {
  // Create stub provider configs (no lifecycle callbacks needed for read-only)
  const providerConfigs = providers.map((p) => ({
    provider: p.provider as any,
    scopes: p.scopes,
    getChannels: async () => [],
    onChannelEnabled: async () => {},
    onChannelDisabled: async () => {},
  }));

  const store = new Store({
    path,
    storage: env.STORAGE,
    priorityTwistId,
  });

  return new Integrations({
    path,
    store,
    env,
    db,
    priorityId: "", // Read-only context - save operations not used
    priorityTwistId,
    twistId: twistPackageId,
    environment: environment as any,
    integrationOptions: { providers: providerConfigs },
  });
}

// ============================================================================
// Endpoints
// ============================================================================

// GET /twist/:id/integrations
// Returns accounts, providers, and channels for the edit modal.
twistIntegrations.get("/twist/:id/integrations", async (c) => {
  const priorityTwistId = c.req.param("id");

  const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
  if (!twistInfo) {
    return c.json({ message: "Twist not found" }, 404);
  }

  const config = await loadTwistConfig(
    c.env,
    twistInfo.twistPackageId,
    twistInfo.version
  );
  if (!config) {
    return c.json({ message: "Twist config not found" }, 404);
  }

  if (config.providers.length === 0) {
    // No-provider connector: check if options have been configured (via /connect)
    const pt = await c.var.db
      .selectFrom("priority_twist")
      .select("config")
      .where("id", "=", priorityTwistId)
      .executeTakeFirst();
    const ptConfig = pt?.config
      ? typeof pt.config === "string"
        ? JSON.parse(pt.config)
        : pt.config
      : {};
    const hasConfig = Object.keys(ptConfig).length > 0;

    if (!hasConfig) {
      // Include options schema and twist metadata for the connect form
      let optionsSchema = config.optionsSchema ?? null;
      if (!optionsSchema && twistInfo.twistOptions) {
        try {
          optionsSchema = typeof twistInfo.twistOptions === "string"
            ? JSON.parse(twistInfo.twistOptions)
            : twistInfo.twistOptions;
        } catch { /* ignore parse errors */ }
      }
      return c.json({
        providers: [], accounts: [], syncables: [], optionsSchema,
        shared: twistInfo.shared, keyOption: twistInfo.keyOption,
      });
    }

    // Connected — call getChannels to fetch available channels
    const logger = createLogger({ priority_twist_id: priorityTwistId });
    let twistWrapper;
    try {
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });
      twistWrapper = await factory({
        priorityId: twistInfo.priorityId ?? priorityTwistId,
        priorityTwistId,
      });
    } catch (error) {
      logger.error("Failed to create twist factory for no-provider connector", error as Error);
      return c.json({ providers: [], accounts: [], syncables: [] });
    }

    // Get account name (non-fatal — failure doesn't block channel fetch)
    let accountName: string | null = null;
    try {
      const accountNameResult = await twistWrapper.callCallback(
        [], "getAccountName", null, null
      );
      disposeRpc(accountNameResult);
      accountName = typeof accountNameResult === "string" ? accountNameResult : null;
    } catch (error) {
      logger.warn("getAccountName failed for no-provider connector", error as Error);
    }

    // Get channels (independent of account name)
    let syncables: any[] = [];
    try {
      const result = await twistWrapper.callCallback(
        [], "getChannels", null, null
      );
      disposeRpc(result);

      // Query source_channel to merge enabled state
      const enabledChannels = await c.var.db
        .selectFrom("source_channel")
        .select(["channel_id", "enabled", "priority_id", "create_threads"])
        .where("priority_twist_id", "=", priorityTwistId)
        .execute();
      const enabledMap = new Map(
        enabledChannels.map((ch) => [ch.channel_id, ch])
      );

      const rawChannels = Array.isArray(result) ? result : [];
      syncables = rawChannels.map((ch: any) => {
        const stored = enabledMap.get(ch.id);
        return {
          ...ch,
          provider: "_options",
          enabled: stored?.enabled ?? false,
          enabledBy: null,
          priorityId: stored?.priority_id ?? null,
          createThreads: stored?.create_threads ?? ch.createThreads ?? "all",
          currentUserHasAccess: true,
        };
      });
    } catch (error) {
      logger.error("getChannels failed for no-provider connector", error as Error);
    }

    const accounts = accountName
      ? [{ provider: "_options", actorId: priorityTwistId, name: accountName, email: null }]
      : [];

    // Include options schema and current config for editing.
    // Fall back to twist.options column for twists deployed before KV included optionsSchema.
    let optionsSchema = config.optionsSchema ?? null;
    if (!optionsSchema && twistInfo.twistOptions) {
      try {
        optionsSchema = typeof twistInfo.twistOptions === "string"
          ? JSON.parse(twistInfo.twistOptions)
          : twistInfo.twistOptions;
      } catch { /* ignore parse errors */ }
    }
    // Mask secure values in config (replace with true sentinel)
    let optionsConfig: Record<string, unknown> | null = null;
    if (optionsSchema && hasConfig) {
      const masked = { ...ptConfig };
      for (const [key, def] of Object.entries(optionsSchema)) {
        if (def.type === "text" && "secure" in def && (def as any).secure) {
          if (key in masked) {
            masked[key] = true; // Sentinel: "value exists but is hidden"
          }
        }
      }
      optionsConfig = masked;
    }

    return c.json({
      providers: [], accounts, syncables, optionsSchema, optionsConfig,
      singleChannel: config.singleChannel,
      shared: twistInfo.shared,
      keyOption: twistInfo.keyOption,
    });
  }

  // Get current user's actor ID
  const currentActorId = await getCurrentActorId(c.var.db, c.var.user.id);

  // Group providers by their Integrations tool path
  const pathToProviders = new Map<string, ProviderDeclaration[]>();
  for (const [provider, path] of Object.entries(config.integrationsMap)) {
    if (!pathToProviders.has(path)) {
      pathToProviders.set(path, []);
    }
    const providerDecl = config.providers.find((p) => p.provider === provider);
    if (providerDecl) {
      pathToProviders.get(path)!.push(providerDecl);
    }
  }

  // Query each Integrations instance and merge results
  const allProviders: any[] = [];
  const allAccounts: any[] = [];
  const allChannels: any[] = [];

  for (const [pathStr, providers] of pathToProviders) {
    const path = pathStr.split(":");
    const integrations = createReadOnlyIntegrations(
      path,
      providers,
      c.env,
      c.var.db,
      priorityTwistId,
      twistInfo.twistPackageId,
      twistInfo.environment
    );

    const data = await integrations.getIntegrationData(
      currentActorId as any
    );

    allProviders.push(...data.providers);
    allAccounts.push(...data.accounts);
    allChannels.push(...data.syncables);
  }

  return c.json({
    providers: allProviders,
    accounts: allAccounts,
    syncables: allChannels,
    singleChannel: config.singleChannel,
    shared: twistInfo.shared,
    keyOption: twistInfo.keyOption,
  });
});

// POST /twist/:id/integrations/auth
// Generate auth URL for the modal.
const AuthRequestSchema = z.object({
  provider: z.string(),
  redirectUri: z.string(),
  platform: z.enum(["ios", "android", "desktop"]).optional(),
  enabledScopeGroups: z.array(z.string()).optional(),
});

twistIntegrations.post("/twist/:id/integrations/auth", async (c) => {
  const priorityTwistId = c.req.param("id");

  const rawBody = await c.req.json();
  const parseResult = AuthRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const { provider, redirectUri, platform } = parseResult.data;

  const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
  if (!twistInfo) {
    return c.json({ message: "Twist not found" }, 404);
  }

  const config = await loadTwistConfig(
    c.env,
    twistInfo.twistPackageId,
    twistInfo.version
  );
  if (!config) {
    return c.json({ message: "Twist config not found" }, 404);
  }

  // Find the Integrations path for this provider
  const integrationsPathStr = config.integrationsMap[provider];
  if (!integrationsPathStr) {
    return c.json(
      { message: `Provider ${provider} not configured for this twist` },
      400
    );
  }

  // Find scopes for the provider
  const providerDecl = config.providers.find((p) => p.provider === provider);
  if (!providerDecl) {
    return c.json(
      { message: `Provider ${provider} not found in twist config` },
      400
    );
  }

  // Resolve final scopes including optional scope groups
    let finalScopes = [...providerDecl.scopes];
    const { enabledScopeGroups } = parseResult.data;
    if (providerDecl.optionalScopes) {
      for (const group of providerDecl.optionalScopes) {
        // If client sent explicit selections, use those; otherwise use defaults
        const isEnabled = enabledScopeGroups
          ? enabledScopeGroups.includes(group.id)
          : group.default;
        if (isEnabled) {
          finalScopes.push(...group.scopes);
        }
      }
      finalScopes = [...new Set(finalScopes)];
    }

    // Create a callback token pointing to the Integrations tool's onAuth method
  const callbacksId = c.env.CALLBACKS.idFromName(priorityTwistId);
  const callbacksStub = c.env.CALLBACKS.get(callbacksId);
  const callback = await callbacksStub.create({
    priorityTwistId,
    path: integrationsPathStr.split(":"),
    functionName: "onAuth",
    extraArgs: [],
  });

  // Generate the auth URL
  const result = await Integrations.GenerateAuthUrl({
    provider: provider as any,
    scopes: finalScopes,
    enabledScopeGroups,
    callback: callback as any,
    redirectUri,
    platform,
    env: c.env,
    storage: c.env.STORAGE,
  });

  if (!result) {
    return c.json(
      { message: `Failed to generate auth URL for ${provider}` },
      500
    );
  }

  return c.json({ ...result, callback: String(callback) });
});

// POST /twist/:id/integrations/connect
// For no-provider connectors: saves options, calls getChannels, returns channel list.
const ConnectRequestSchema = z.object({
  options: z.record(z.string(), z.any()),
});

twistIntegrations.post("/twist/:id/integrations/connect", async (c) => {
  const priorityTwistId = c.req.param("id");

  const rawBody = await c.req.json();
  const parseResult = ConnectRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const { options } = parseResult.data;

  const logger = createLogger({ priority_twist_id: priorityTwistId });

  const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
  if (!twistInfo) {
    return c.json({ message: "Twist not found" }, 404);
  }

  const kvConfig = await loadTwistConfig(
    c.env,
    twistInfo.twistPackageId,
    twistInfo.version
  );
  if (!kvConfig) {
    return c.json({ message: "Twist config not found" }, 404);
  }

  try {
    // Load options schema from KV config to process secure options
    const fullKv = await c.env.TWIST_CONFIG.get(
      `${twistInfo.twistPackageId}:${twistInfo.version}`
    );
    let optSchema: OptionsSchema | undefined;
    if (fullKv) {
      const parsed = JSON.parse(fullKv);
      optSchema = parsed.optionsSchema as OptionsSchema | undefined;
    }

    // Determine auth model from twist metadata
    const isIndividualKey = !twistInfo.shared && !!twistInfo.keyOption;

    // Process secure options and save config
    let cleanedConfig = options;
    if (optSchema && c.env.AI_KEY_ENCRYPTION_KEY) {
      if (isIndividualKey && twistInfo.keyOption) {
        // Individual key: store the key option per-user, rest shared
        const keyOptionField = twistInfo.keyOption;
        const keyValue = options[keyOptionField];

        // Save key option per-user
        if (typeof keyValue === "string" && keyValue.length > 0) {
          const keySchema: OptionsSchema = { [keyOptionField]: optSchema[keyOptionField] };
          await saveSecureOptions(
            c.var.db,
            c.env.AI_KEY_ENCRYPTION_KEY,
            priorityTwistId,
            keySchema,
            { [keyOptionField]: keyValue },
            c.var.user.id
          );
        }

        // Save remaining options as shared (without the key field)
        const sharedOptions = { ...options };
        delete sharedOptions[keyOptionField];
        const sharedSchema = { ...optSchema };
        delete sharedSchema[keyOptionField];
        cleanedConfig = Object.keys(sharedSchema).length > 0
          ? await saveSecureOptions(
              c.var.db,
              c.env.AI_KEY_ENCRYPTION_KEY,
              priorityTwistId,
              sharedSchema,
              sharedOptions
            )
          : sharedOptions;
        // Remove key field from config (it's stored per-user)
        delete cleanedConfig[keyOptionField];
      } else {
        // Shared key: save all options as shared (existing behavior)
        cleanedConfig = await saveSecureOptions(
          c.var.db,
          c.env.AI_KEY_ENCRYPTION_KEY,
          priorityTwistId,
          optSchema,
          options
        );
      }
    }

    // Save config to priority_twist
    await c.var.db
      .updateTable("priority_twist")
      .set({ config: JSON.stringify(cleanedConfig) })
      .where("id", "=", priorityTwistId)
      .execute();

    // Instantiate the twist and call getChannels(null, null) on the connector
    const factory = twistFactory({
      env: c.env,
      ctx: c.executionCtx as ExecutionContext,
      db: c.var.db,
    });

    const twistWrapper = await factory({
      priorityId: twistInfo.priorityId ?? priorityTwistId,
      priorityTwistId,
    });

    // Call getChannels(null, null) directly on the connector (path=[])
    const result = await twistWrapper.callCallback(
      [], // twist-level callback
      "getChannels",
      null, // auth
      null  // token
    );
    disposeRpc(result);

    // Result should be the channel list — annotate with defaults since
    // getChannels() returns raw channels without enabled/access metadata
    const rawChannels = Array.isArray(result) ? result : [];

    // Store channels so enableSync can find linkTypes (matches OAuth flow's setChannels)
    if (kvConfig && rawChannels.length > 0) {
      const integrationsPath = kvConfig.integrationsMap["_options"];
      if (integrationsPath) {
        try {
          const storeResult = await twistWrapper.callCallback(
            integrationsPath.split(":"),
            "setChannels",
            "_options",
            c.var.user.id,
            rawChannels
          );
          disposeRpc(storeResult);
        } catch (error) {
          logger.warn("Failed to store channel access", error as Error);
        }
      }
    }

    const syncables = rawChannels.map((ch: any) => ({
      ...ch,
      provider: "_options",
      enabled: false,
      enabledBy: null,
      priorityId: null,
      createThreads: ch.createThreads ?? "all",
      currentUserHasAccess: true,
    }));

    // Get account name (non-fatal)
    let accountName: string | null = null;
    try {
      const nameResult = await twistWrapper.callCallback(
        [], "getAccountName", null, null
      );
      disposeRpc(nameResult);
      accountName = typeof nameResult === "string" ? nameResult : null;
    } catch (error) {
      logger.warn("getAccountName failed during connect", error as Error);
    }

    // Persist account name in config so sources/summary can show it
    if (accountName) {
      const updatedConfig = { ...cleanedConfig, _accountName: accountName };
      await c.var.db
        .updateTable("priority_twist")
        .set({ config: JSON.stringify(updatedConfig) })
        .where("id", "=", priorityTwistId)
        .execute();
    }

    // Record connection for user_connected tracking
    try {
      await c.var.db
        .insertInto("priority_twist_connection")
        .values({
          priority_twist_id: priorityTwistId,
          user_id: c.var.user.id,
          provider: "_key",
          actor_id: c.var.user.id,
          connected_at: new Date().toISOString(),
        })
        .onConflict((oc) =>
          oc
            .columns(["priority_twist_id", "user_id", "provider"])
            .doUpdateSet({
              connected_at: new Date().toISOString(),
            })
        )
        .execute();
    } catch (error) {
      logger.error("Failed to record priority_twist_connection for key connector", error as Error);
    }

    logger.info("No-provider connect successful", {
      channel_count: syncables.length,
      account_name: accountName,
    });

    return c.json({ syncables, accountName });
  } catch (error) {
    logger.error("Error connecting no-provider connector", error as Error);
    return c.json(
      {
        error: `Connection failed: ${
          error instanceof Error ? error.message : "Unknown error"
        }`,
      },
      400
    );
  }
});

// POST /twist/:id/syncables/:provider/:syncableId/enable
// Enable a channel. Optionally accepts { priorityId } in body.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/:syncableId/enable",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");
    const channelId = c.req.param("syncableId");

    // Parse optional body for priorityId and createThreads
    let priorityId: string | undefined;
    let createThreads: string | undefined;
    try {
      const body = await c.req.json();
      priorityId = body?.priorityId;
      if (typeof body?.createThreads === "string" &&
          ["all", "actionable", "manual"].includes(body.createThreads)) {
        createThreads = body.createThreads;
      }
    } catch {
      // No body or invalid JSON — fine, fields stay undefined
    }

    const logger = createLogger({ priority_twist_id: priorityTwistId });

    const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
    if (!twistInfo) {
      return c.json({ message: "Twist not found" }, 404);
    }

    const config = await loadTwistConfig(
      c.env,
      twistInfo.twistPackageId,
      twistInfo.version
    );
    if (!config) {
      return c.json({ message: "Twist config not found" }, 404);
    }

    const integrationsPathStr = config.integrationsMap[provider];
    if (!integrationsPathStr) {
      return c.json(
        { message: `Provider ${provider} not configured` },
        400
      );
    }

    // Get current user's actor ID
    const currentActorId = await getCurrentActorId(c.var.db, c.var.user.id);
    if (!currentActorId) {
      return c.json({ message: "No actor found for current user" }, 400);
    }

    // Check connection limit before enabling channel
    const limitCheck = await checkChannelConnectionLimit(
      c.var.db,
      c.var.user.id,
      priorityTwistId,
      priorityId ?? null
    );
    if (!limitCheck.allowed) {
      return c.json(limitCheck.error.toJSON(), 403);
    }

    try {
      // Create twist wrapper and call enableSync via callCallback
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });

      const twistWrapper = await factory({
        priorityId: twistInfo.priorityId!,
        priorityTwistId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "enableSync",
        provider,
        channelId,
        currentActorId,
        undefined, // title
        priorityId,
        createThreads
      );
      disposeRpc(result);

      logger.info("Channel enabled", {
        provider,
        channel_id: channelId,
        actor_id: currentActorId,
        priority_id: priorityId,
      });

      return c.json({ success: true });
    } catch (error) {
      if (error instanceof PlanLimitError) {
        return c.json(error.toJSON(), 403);
      }
      logger.error("Error enabling channel", error as Error, {
        provider,
        channel_id: channelId,
      });
      return c.json(
        {
          message: `Failed to enable channel: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

// POST /twist/:id/syncables/:provider/:syncableId/disable
// Disable a channel.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/:syncableId/disable",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");
    const channelId = c.req.param("syncableId");

    const logger = createLogger({ priority_twist_id: priorityTwistId });

    const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
    if (!twistInfo) {
      return c.json({ message: "Twist not found" }, 404);
    }

    const config = await loadTwistConfig(
      c.env,
      twistInfo.twistPackageId,
      twistInfo.version
    );
    if (!config) {
      return c.json({ message: "Twist config not found" }, 404);
    }

    const integrationsPathStr = config.integrationsMap[provider];
    if (!integrationsPathStr) {
      return c.json(
        { message: `Provider ${provider} not configured` },
        400
      );
    }

    try {
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });

      const twistWrapper = await factory({
        priorityId: twistInfo.priorityId!,
        priorityTwistId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "disableSync",
        provider,
        channelId
      );
      disposeRpc(result);

      logger.info("Channel disabled", {
        provider,
        channel_id: channelId,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error disabling channel", error as Error, {
        provider,
        channel_id: channelId,
      });
      return c.json(
        {
          message: `Failed to disable channel: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

// PATCH /twist/:id/syncables/:provider/:syncableId
// Update the priority routing for an already-enabled channel.
const ChannelPrioritySchema = z.object({
  priorityId: z.string().nullable(),
});

twistIntegrations.patch(
  "/twist/:id/syncables/:provider/:syncableId",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");
    const channelId = c.req.param("syncableId");

    const rawBody = await c.req.json();
    const parseResult = ChannelPrioritySchema.safeParse(rawBody);
    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }
    const { priorityId } = parseResult.data;

    const logger = createLogger({ priority_twist_id: priorityTwistId });

    const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
    if (!twistInfo) {
      return c.json({ message: "Twist not found" }, 404);
    }

    const config = await loadTwistConfig(
      c.env,
      twistInfo.twistPackageId,
      twistInfo.version
    );
    if (!config) {
      return c.json({ message: "Twist config not found" }, 404);
    }

    const integrationsPathStr = config.integrationsMap[provider];
    if (!integrationsPathStr) {
      return c.json(
        { message: `Provider ${provider} not configured` },
        400
      );
    }

    try {
      // Use read-only Integrations to set channel priority directly
      const providerDecl = config.providers.filter((p) => p.provider === provider);
      const integrations = createReadOnlyIntegrations(
        integrationsPathStr.split(":"),
        providerDecl,
        c.env,
        c.var.db,
        priorityTwistId,
        twistInfo.twistPackageId,
        twistInfo.environment
      );

      await integrations.setChannelPriority(
        provider as any,
        channelId,
        priorityId
      );

      logger.info("Channel priority updated", {
        provider,
        channel_id: channelId,
        priority_id: priorityId ?? undefined,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error updating channel priority", error as Error, {
        provider,
        channel_id: channelId,
      });
      return c.json(
        {
          message: `Failed to update channel priority: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

// POST /twist/:id/syncables/:provider/refresh
// Re-fetch the channel list from the external service for a provider+actor.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/refresh",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");

    const logger = createLogger({ priority_twist_id: priorityTwistId });

    const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
    if (!twistInfo) {
      return c.json({ message: "Twist not found" }, 404);
    }

    const config = await loadTwistConfig(
      c.env,
      twistInfo.twistPackageId,
      twistInfo.version
    );
    if (!config) {
      return c.json({ message: "Twist config not found" }, 404);
    }

    const integrationsPathStr = config.integrationsMap[provider];
    if (!integrationsPathStr) {
      return c.json(
        { message: `Provider ${provider} not configured` },
        400
      );
    }

    // Get current user's actor ID
    const currentActorId = await getCurrentActorId(c.var.db, c.var.user.id);
    if (!currentActorId) {
      return c.json({ message: "No actor found for current user" }, 400);
    }

    try {
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });

      const twistWrapper = await factory({
        priorityId: twistInfo.priorityId!,
        priorityTwistId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "refreshChannels",
        provider,
        currentActorId
      );
      disposeRpc(result);

      logger.info("Channels refreshed", {
        provider,
        actor_id: currentActorId,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error refreshing channels", error as Error, {
        provider,
      });
      return c.json(
        {
          message: `Failed to refresh channels: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

// DELETE /twist/:id/integrations/:provider/:actorId
// Remove an account (auth token) for a provider.
twistIntegrations.delete(
  "/twist/:id/integrations/:provider/:actorId",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");
    const actorId = c.req.param("actorId");

    const logger = createLogger({ priority_twist_id: priorityTwistId });

    const twistInfo = await resolveTwistInfo(c.var.db, priorityTwistId);
    if (!twistInfo) {
      return c.json({ message: "Twist not found" }, 404);
    }

    const config = await loadTwistConfig(
      c.env,
      twistInfo.twistPackageId,
      twistInfo.version
    );
    if (!config) {
      return c.json({ message: "Twist config not found" }, 404);
    }

    const integrationsPathStr = config.integrationsMap[provider];
    if (!integrationsPathStr) {
      return c.json(
        { message: `Provider ${provider} not configured` },
        400
      );
    }

    try {
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });

      const twistWrapper = await factory({
        priorityId: twistInfo.priorityId!,
        priorityTwistId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "removeAuth",
        provider,
        actorId
      );
      disposeRpc(result);

      logger.info("Integration removed", {
        provider,
        actor_id: actorId,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error removing integration", error as Error, {
        provider,
        actor_id: actorId,
      });
      return c.json(
        {
          message: `Failed to remove integration: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

export default twistIntegrations;
