// TEMPORARY one-shot endpoint: forces channel_access mirror for a specific
// twist_instance. Replicates the read path from /twist/:id/integrations
// but skips appAuthMiddleware so it can be triggered by ops without the
// owner's session. Remove this file (and its mount in index.ts) after use.

import { Hono } from "hono";

import type { Bindings } from "../env";
import { dbMiddleware } from "../middleware/db";
import type { ProviderDeclaration } from "../twist/tools/factory";
import { Integrations } from "../twist/tools/integrations";
import { Store } from "../twist/tools/store";

const TOKEN = "89b2e2c236037f04297e5bd5ba55f4df66013e67e2c10cc507f0889eeac453f7";

const internalBackfill = new Hono<{ Bindings: Bindings }>();

internalBackfill.use("*", dbMiddleware);

internalBackfill.post("/_internal/backfill-channels/:id", async (c) => {
  if (c.req.header("x-backfill-token") !== TOKEN) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const twistInstanceId = c.req.param("id");

  const twistInfo = await c.var.db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select([
      "twist.version",
      "twist.environment",
      "twist.twist_package_id as twistPackageId",
    ])
    .where("twist_instance.id", "=", twistInstanceId)
    .where("twist_instance.archived_at", "is", null)
    .executeTakeFirst();

  if (!twistInfo) return c.json({ error: "twist instance not found" }, 404);

  const raw = await c.env.TWIST_CONFIG.get(
    `${twistInfo.twistPackageId}:${twistInfo.version}`
  );
  if (!raw) return c.json({ error: "twist config missing in KV" }, 404);

  const parsed = JSON.parse(raw);
  const providersDecl: ProviderDeclaration[] = parsed.providers ?? [];
  const integrationsMap: Record<string, string> = parsed.integrationsMap ?? {};

  const pathToProviders = new Map<string, ProviderDeclaration[]>();
  for (const [provider, pathStr] of Object.entries(integrationsMap)) {
    if (!pathToProviders.has(pathStr)) pathToProviders.set(pathStr, []);
    const decl = providersDecl.find((p) => p.provider === provider);
    if (decl) pathToProviders.get(pathStr)!.push(decl);
  }

  const allChannels: any[] = [];

  for (const [pathStr, providers] of pathToProviders) {
    const path = pathStr.split(":");

    const providerConfigs = providers.map((p) => ({
      provider: p.provider as any,
      scopes: p.scopes,
      getChannels: async () => [],
      onChannelEnabled: async () => {},
      onChannelDisabled: async () => {},
    }));

    const store = new Store({
      path,
      storage: c.env.STORAGE,
      twistInstanceId,
    });

    const integrations = new Integrations({
      path,
      store,
      env: c.env,
      db: c.var.db,
      twistInstanceId,
      twistId: twistInfo.twistPackageId,
      environment: twistInfo.environment as any,
      integrationOptions: { providers: providerConfigs },
    });

    // getIntegrationData triggers mirrorChannelsToDb in its per-actor loop.
    const data = await integrations.getIntegrationData();
    allChannels.push(...data.syncables);
  }

  return c.json({ ok: true, twistInstanceId, syncables: allChannels });
});

export { internalBackfill };
