import type { Kysely } from "kysely";
import { Hono } from "hono";
import { z } from "zod";

import type { DB } from "../db";
import type { Bindings } from "../env";
import { twistFactory } from "../twist";
import { Integrations } from "../twist/tools/integrations";
import { Store } from "../twist/tools/store";
import { createLogger } from "@plotday/worker-util";
import type { IntegrationProviderConfig } from "@plotday/twister/tools/integrations";
import type { ProviderDeclaration } from "../twist/tools/factory";
import { disposeRpc } from "../utils/rpc";
import { handleValidationError } from "../utils/validation";

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
} | null> {
  const config = await env.TWIST_CONFIG.get(`${twistPackageId}:${version}`);
  if (!config) return null;

  const parsed = JSON.parse(config);
  return {
    providers: parsed.providers ?? [],
    integrationsMap: parsed.integrationsMap ?? {},
    toolPermissions: parsed.toolPermissions ?? {},
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
  const providerConfigs: IntegrationProviderConfig[] = providers.map((p) => ({
    provider: p.provider as any,
    scopes: p.scopes,
    getSyncables: async () => [],
    onSyncEnabled: async () => {},
    onSyncDisabled: async () => {},
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
// Returns accounts, providers, and syncables for the edit modal.
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
    return c.json({ providers: [], accounts: [], syncables: [] });
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
  const allSyncables: any[] = [];

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
    allSyncables.push(...data.syncables);
  }

  return c.json({
    providers: allProviders,
    accounts: allAccounts,
    syncables: allSyncables,
  });
});

// POST /twist/:id/integrations/auth
// Generate auth URL for the modal.
const AuthRequestSchema = z.object({
  provider: z.string(),
  redirectUri: z.string(),
  platform: z.enum(["ios", "android", "desktop"]).optional(),
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
    scopes: providerDecl.scopes,
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

// POST /twist/:id/syncables/:provider/:syncableId/enable
// Enable a syncable resource.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/:syncableId/enable",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");
    const syncableId = c.req.param("syncableId");

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
        syncableId,
        currentActorId
      );
      disposeRpc(result);

      logger.info("Syncable enabled", {
        provider,
        syncable_id: syncableId,
        actor_id: currentActorId,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error enabling syncable", error as Error, {
        provider,
        syncable_id: syncableId,
      });
      return c.json(
        {
          message: `Failed to enable syncable: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

// POST /twist/:id/syncables/:provider/:syncableId/disable
// Disable a syncable resource.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/:syncableId/disable",
  async (c) => {
    const priorityTwistId = c.req.param("id");
    const provider = c.req.param("provider");
    const syncableId = c.req.param("syncableId");

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
        syncableId
      );
      disposeRpc(result);

      logger.info("Syncable disabled", {
        provider,
        syncable_id: syncableId,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error disabling syncable", error as Error, {
        provider,
        syncable_id: syncableId,
      });
      return c.json(
        {
          message: `Failed to disable syncable: ${
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
