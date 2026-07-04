import type { Kysely } from "kysely";
import { Hono } from "hono";
import type { Context } from "hono";
import { z } from "zod";

import type { DB } from "../db";
import { createDb } from "../db";
import type { Bindings } from "../env";
import { twistFactory } from "../twist";
import { PROVIDER_CONFIGS } from "../provider";
import { Integrations } from "../twist/tools/integrations";
import { Store } from "../twist/tools/store";
import { createLogger } from "@plotday/worker-util";
import { enqueueChannelRouter } from "../state/channel-router";
import type { ProviderDeclaration } from "../twist/tools/factory";
import { resolveOwnerContact } from "../utils/owner-contact";
import { disposeRpc } from "../utils/rpc";
import {
  checkChannelConnectionLimit,
  getBillableConnectionAddonCount,
  twistAddonBlocksNeeded,
  PlanLimitError,
} from "../utils/limits";
import { handleValidationError } from "../utils/validation";
import type { OptionsSchema } from "@plotday/twister/options";
import { saveSecureOptions } from "../utils/secure-options";
import { resolveRequestedScopes } from "../twist/tools/auth-scope";
import {
  type OptionalScopeGroup as ProductScopeGroup,
  type ProductInfo,
  type ProductStatus,
  computeProductStatus,
} from "./product-status";
import { reconcileAddonQuantityDown } from "../stripe/addons";
import { createStripeClient } from "../stripe/utils";
import { provisionAddonForConsentedEnable } from "./upgrade";

const twistIntegrations = new Hono<{ Bindings: Bindings }>();

/** Query team domains for smart channel default suggestions. */
async function getTeamDomains(
  db: Kysely<DB>
): Promise<Record<string, string[]>> {
  const rows = await db
    .selectFrom("domain")
    .select(["team_id", "name"])
    .where("team_id", "is not", null)
    .execute();

  const result: Record<string, string[]> = {};
  for (const row of rows) {
    const orgId = String(row.team_id);
    if (!result[orgId]) result[orgId] = [];
    result[orgId].push(row.name);
  }
  return result;
}

// ============================================================================
// Helpers
// ============================================================================

/**
 * Look up twist_instance metadata needed for integration operations.
 */
async function resolveTwistInfo(db: Kysely<DB>, twistInstanceId: string) {
  const row = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .leftJoin("team", "team.id", "twist_instance.team_id")
    .select([
      "twist_instance.twist_id as twistId",
      "twist_instance.account_label as accountLabel",
      "twist_instance.team_id as teamId",
      "team.name as teamName",
      "twist.version",
      "twist.environment",
      "twist.options_schema as twistOptions",
      "twist.shared",
      "twist.key_option as keyOption",
      "twist.premium",
      "twist.twist_package_id as twistPackageId",
    ])
    .where("twist_instance.id", "=", twistInstanceId)
    .where("twist_instance.archived_at", "is", null)
    .executeTakeFirst();

  return row ?? null;
}

/**
 * Verify the caller has access to a twist_instance.
 *
 * - "read": owner or any team member (when team-scoped).
 * - "write": owner or team admin (when team-scoped).
 *
 * Routes should return 404 on `ok: false` to avoid leaking twist
 * existence to unrelated users.
 */
async function checkTwistAccess(
  db: Kysely<DB>,
  twistInstanceId: string,
  userId: string,
  level: "read" | "write"
): Promise<{ ok: true } | { ok: false }> {
  const row = await db
    .selectFrom("twist_instance")
    .select(["owner_id", "team_id"])
    .where("id", "=", twistInstanceId)
    .executeTakeFirst();
  if (!row) return { ok: false };
  if (row.owner_id === userId) return { ok: true };
  if (row.team_id != null) {
    const membership = await db
      .selectFrom("team_user")
      .select("role")
      .where("team_id", "=", row.team_id)
      .where("user_id", "=", userId)
      .executeTakeFirst();
    if (membership) {
      if (level === "read") return { ok: true };
      if (membership.role === "admin") return { ok: true };
    }
  }
  return { ok: false };
}

const twistNotFoundResponse = { message: "Twist not found" } as const;

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
  fixedChannels: boolean;
  channelNoun: { singular: string; plural: string } | null;
  autoThreading: boolean;
  access: string[] | null;
  connectorLinkTypes?: any[];
  /** Per-product metadata for combined connectors; null for plain connectors. */
  products: ProductInfo[] | null;
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
    fixedChannels: parsed.sourceProvider?.fixedChannels === true,
    channelNoun: parsed.sourceProvider?.channelNoun ?? null,
    autoThreading: parsed.sourceProvider?.autoThreading === true,
    access: parsed.sourceProvider?.access ?? null,
    connectorLinkTypes: parsed.sourceProvider?.linkTypes ?? undefined,
    // Mirrors how _providers/linkTypes are read: prefer the sourceProvider
    // metadata in KV; fall back to the _products mirror in permissions.
    products:
      parsed.sourceProvider?.products ?? parsed.permissions?._products ?? null,
  };
}

/**
 * Find the current user's canonical contact ID. Resolves the PRIMARY contact
 * deterministically (see {@link resolveOwnerContact}) so the actor used to
 * enable a channel here matches the actor the connection's auth token is bound
 * under — otherwise sync throws "has no stored credentials — reconnect" for
 * users with more than one linked contact.
 */
async function getCurrentActorId(
  db: Kysely<DB>,
  userId: string
): Promise<string | null> {
  const contact = await resolveOwnerContact(db, userId);
  return contact?.id ?? null;
}

/**
 * Create a standalone Integrations instance for read-only operations.
 * Uses stub lifecycle callbacks since mutations are not needed.
 */
function createReadOnlyIntegrations(
  path: string[],
  providers: ProviderDeclaration[],
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  db: Kysely<DB>,
  twistInstanceId: string,
  twistPackageId: string,
  environment: string
): Integrations {
  // Create stub provider configs (no lifecycle callbacks needed for read-only).
  // Carry optionalScopes + access so getIntegrationData can surface them
  // to the connect modal (toggles + permission bullets).
  const providerConfigs = providers.map((p) => ({
    provider: p.provider as any,
    scopes: p.scopes,
    ...(p.optionalScopes ? { optionalScopes: p.optionalScopes } : {}),
    ...(p.access ? { access: p.access } : {}),
    getChannels: async () => [],
    onChannelEnabled: async () => {},
    onChannelDisabled: async () => {},
  }));

  const store = new Store({
    path,
    storage: env.STORAGE,
    twistInstanceId,
  });

  return new Integrations({
    path,
    store,
    env,
    ctx,
    db,
    twistInstanceId,
    twistId: twistPackageId,
    environment: environment as any,
    integrationOptions: { providers: providerConfigs },
  });
}

/**
 * Flattens a (possibly nested) syncables tree to the ids of channels that are
 * currently enabled. Used to count a combined connector's enabled channels per
 * product (the namespaced id prefix identifies the product).
 */
function collectEnabledChannelIds(syncables: any[]): string[] {
  const ids: string[] = [];
  const walk = (nodes: any[]) => {
    for (const node of nodes ?? []) {
      if (node?.enabled && typeof node.id === "string") ids.push(node.id);
      if (Array.isArray(node?.children)) walk(node.children);
    }
  };
  walk(syncables);
  return ids;
}

/**
 * Builds the combined-connector `products` + `productStatus` response fields.
 * Returns an empty object when the connector declares no products, so plain
 * connectors are unchanged (the app's `isComposite` stays false).
 *
 * `optionalScopeGroups` are gathered from the providers surfaced to the modal
 * (each `provider.optionalScopes` entry, `{ id, scopes }`). `grantedScopes` is
 * the union of scopes granted across the connection's accounts. `syncables` is
 * the channel tree; its enabled leaves drive the no-channels reason.
 */
function buildProductFields(
  products: ProductInfo[] | null,
  optionalScopeGroups: ProductScopeGroup[],
  grantedScopes: string[],
  syncables: any[],
): { products: ProductInfo[]; productStatus: ProductStatus[] } | Record<string, never> {
  if (!products || products.length === 0) return {};
  const enabledChannelIds = collectEnabledChannelIds(syncables);
  const productStatus = computeProductStatus(
    products,
    optionalScopeGroups,
    grantedScopes,
    enabledChannelIds,
  );
  return { products, productStatus };
}

/**
 * Gathers the optional scope groups declared by the modal's providers, in the
 * `{ id, scopes }` shape computeProductStatus expects.
 */
function collectOptionalScopeGroups(providers: any[]): ProductScopeGroup[] {
  const groups: ProductScopeGroup[] = [];
  for (const p of providers ?? []) {
    for (const g of p?.optionalScopes ?? []) {
      if (g?.id && Array.isArray(g.scopes)) {
        groups.push({ id: g.id, scopes: g.scopes });
      }
    }
  }
  return groups;
}

/**
 * Reconciles the scope's Stripe add-on subscription quantity down to the
 * current billable connection count. Cancels the subscription when the count
 * reaches zero.
 *
 * Invoked by the period-boundary reconcile cron (`reconcileAddonsAtPeriodEnd`
 * in `stripe/addon-period-reconcile.ts`) at each Stripe billing-period
 * boundary — NOT eagerly when a connection is disabled or removed. Disabling
 * a connection leaves the credit purchased (and reusable) until the next
 * period boundary triggers this function.
 *
 * The billable count is `getBillableConnectionAddonCount`: regular connections
 * beyond the plan pool PLUS active add-on-required (premium) connectors. This
 * correctly handles regular-beyond-pool connections as well as premium ones.
 *
 * Exported so it can be tested directly without going through the HTTP layer.
 *
 * No-ops when the scope has no `stripe_addon_subscription_id` (Apple-billed
 * or no add-ons purchased yet).
 */
export async function reconcileScopeAddonBillingDown(args: {
  db: Kysely<DB>;
  stripe: Parameters<typeof reconcileAddonQuantityDown>[0]["stripe"];
  scope: { userId: string } | { teamId: string };
}): Promise<void> {
  const { db, stripe, scope } = args;
  const isTeam = "teamId" in scope;

  const sub = isTeam
    ? await db
        .selectFrom("team_subscription")
        .select("stripe_addon_subscription_id")
        .where("team_id", "=", (scope as { teamId: string }).teamId)
        .executeTakeFirst()
    : await db
        .selectFrom("user_subscription")
        .select("stripe_addon_subscription_id")
        .where("user_id", "=", (scope as { userId: string }).userId)
        .executeTakeFirst();

  if (!sub?.stripe_addon_subscription_id) return;

  const activeCount = await getBillableConnectionAddonCount(db, scope);

  const result = await reconcileAddonQuantityDown({
    stripe,
    addonSubscriptionId: sub.stripe_addon_subscription_id,
    activeCount,
  });

  if (isTeam) {
    const teamId = (scope as { teamId: string }).teamId;
    await db
      .updateTable("team_subscription")
      .set({
        premium_connection_addons: result.quantity,
        ...(result.canceled ? { stripe_addon_subscription_id: null } : {}),
      })
      .where("team_id", "=", teamId)
      .execute();
  } else {
    const userId = (scope as { userId: string }).userId;
    await db
      .updateTable("user_subscription")
      .set({
        premium_connection_addons: result.quantity,
        ...(result.canceled ? { stripe_addon_subscription_id: null } : {}),
      })
      .where("user_id", "=", userId)
      .execute();
  }
}

/**
 * After a twist is removed, reconcile the scope's Stripe twist-add-on
 * subscription quantity down to the number of blocks still needed to cover
 * the remaining installed weight. Cancels the subscription when the needed
 * count reaches zero.
 *
 * Exported so it can be tested directly and invoked from the twist-removal
 * HTTP handlers in `app/twists.ts` via `waitUntil` + a fresh `createDb`.
 *
 * No-ops when the scope has no `stripe_twist_addon_subscription_id`
 * (Apple-billed or no twist add-ons purchased yet).
 */
export async function reconcileScopeTwistAddonBillingDown(args: {
  db: Kysely<DB>;
  stripe: Parameters<typeof reconcileAddonQuantityDown>[0]["stripe"];
  scope: { userId: string } | { teamId: string };
}): Promise<void> {
  const { db, stripe, scope } = args;
  const isTeam = "teamId" in scope;

  const sub = isTeam
    ? await db
        .selectFrom("team_subscription")
        .select("stripe_twist_addon_subscription_id")
        .where("team_id", "=", (scope as { teamId: string }).teamId)
        .executeTakeFirst()
    : await db
        .selectFrom("user_subscription")
        .select("stripe_twist_addon_subscription_id")
        .where("user_id", "=", (scope as { userId: string }).userId)
        .executeTakeFirst();

  if (!sub?.stripe_twist_addon_subscription_id) return;

  const activeCount = await twistAddonBlocksNeeded(db, scope);

  const result = await reconcileAddonQuantityDown({
    stripe,
    addonSubscriptionId: sub.stripe_twist_addon_subscription_id,
    activeCount,
  });

  if (isTeam) {
    const teamId = (scope as { teamId: string }).teamId;
    await db
      .updateTable("team_subscription")
      .set({
        twist_addon_count: result.quantity,
        ...(result.canceled ? { stripe_twist_addon_subscription_id: null } : {}),
      })
      .where("team_id", "=", teamId)
      .execute();
  } else {
    const userId = (scope as { userId: string }).userId;
    await db
      .updateTable("user_subscription")
      .set({
        twist_addon_count: result.quantity,
        ...(result.canceled ? { stripe_twist_addon_subscription_id: null } : {}),
      })
      .where("user_id", "=", userId)
      .execute();
  }
}

/**
 * Resolve billing scope for a consented add-on purchase at the enable step.
 *
 * For a team-owned twist: reads `team_subscription` keyed on the team.
 * For a personal twist: reads `user_subscription` keyed on the user.
 *
 * Returns the Stripe customer ID, existing add-on subscription ID (if any),
 * the table name + id value needed to write back the updated quantity, and
 * the scope metadata for Stripe's subscription metadata.
 *
 * Returns `customerId: null` when no billing record exists (caller returns 403).
 *
 * Exported so the shared `chargeConsentedAddonOrError` gate and its tests can
 * resolve the billing scope without going through the HTTP layer.
 */
export async function resolveAddonScope(
  db: Kysely<DB>,
  userId: string,
  twistInstanceId: string
): Promise<{
  customerId: string | null;
  addonSubscriptionId: string | null;
  table: "user_subscription" | "team_subscription";
  idVal: string;
  scopeMetadata: Record<string, string>;
}> {
  const twistInfo = await resolveTwistInfo(db, twistInstanceId);
  const teamId = twistInfo?.teamId ? String(twistInfo.teamId) : null;

  if (teamId) {
    const row = await db
      .selectFrom("team_subscription")
      .select(["stripe_customer_id", "stripe_addon_subscription_id"])
      .where("team_id", "=", teamId)
      .executeTakeFirst();
    return {
      customerId: row?.stripe_customer_id ?? null,
      addonSubscriptionId: row?.stripe_addon_subscription_id ?? null,
      table: "team_subscription",
      idVal: teamId,
      scopeMetadata: { team_id: teamId },
    };
  }

  const row = await db
    .selectFrom("user_subscription")
    .select(["stripe_customer_id", "stripe_addon_subscription_id"])
    .where("user_id", "=", userId)
    .executeTakeFirst();
  return {
    customerId: row?.stripe_customer_id ?? null,
    addonSubscriptionId: row?.stripe_addon_subscription_id ?? null,
    table: "user_subscription",
    idVal: userId,
    scopeMetadata: { user_id: userId },
  };
}

/**
 * Shared "consent before auth, charge on enable" gate for a billable connection
 * add-on. Used by every path that enables a connection: single-channel enable,
 * batch enable, and draft activate. Centralizes the three-branch consent/charge
 * logic so it lives in exactly one place.
 *
 * Runs `checkChannelConnectionLimit` for the twist instance and resolves:
 *   - allowed                              → `{ proceed: true }`
 *   - addon_required + consent + card      → charge now, `{ proceed: true }`
 *   - addon_required + consent, no card    → 402 `{ reason:"needs_card", checkout_url }`
 *   - addon_required, no/declined consent  → 403 `addon_required` (error.toJSON())
 *   - any other limit failure              → 403 error.toJSON()
 *
 * Charge-first ordering: the add-on is provisioned (charged) BEFORE the caller
 * enables the connection — the money-safe direction, consistent across all call
 * sites. Residual orphan-charge window (finding I2): if the subsequent enable
 * throws or the request is abandoned after a successful charge, the credit
 * persists for that billing cycle. This self-heals — a retry reuses the
 * already-provisioned credit (the Stripe quantity sync is idempotent), and
 * any unused credit is reconciled back down by the period-boundary reconcile
 * cron (`reconcileAddonsAtPeriodEnd`, which calls `reconcileScopeAddonBillingDown`)
 * at the scope's next Stripe billing-period boundary — not eagerly on
 * disable, so the true-up can be up to a billing period away. No behavior
 * change here; comment only.
 */
export async function chargeConsentedAddonOrError(
  c: Context<{ Bindings: Bindings }>,
  twistInstanceId: string,
  consentAddon: boolean | undefined
): Promise<{ proceed: true } | { response: Response }> {
  const limitCheck = await checkChannelConnectionLimit(
    c.var.db,
    c.var.user.id,
    twistInstanceId
  );
  if (limitCheck.allowed) return { proceed: true };

  if (limitCheck.error.reason === "addon_required" && consentAddon === true) {
    const scope = await resolveAddonScope(
      c.var.db,
      c.var.user.id,
      twistInstanceId
    );
    if (!scope.customerId) {
      return { response: c.json(limitCheck.error.toJSON(), 403) };
    }
    const res = await provisionAddonForConsentedEnable({
      stripe: createStripeClient(c.env.STRIPE_SECRET_KEY),
      db: c.var.db,
      customerId: scope.customerId,
      addonSubscriptionId: scope.addonSubscriptionId,
      scopeMetadata: scope.scopeMetadata,
      siteRoot: c.env.SITE_ROOT || "https://plot.day",
      table: scope.table,
      idVal: scope.idVal,
      captureException: (e) => c.var.tracker.captureException(e),
    });
    if (!res.ok) {
      return {
        response: c.json(
          { reason: "needs_card", checkout_url: res.checkout_url },
          402
        ),
      };
    }
    // Charged successfully — caller proceeds to enable the connection.
    return { proceed: true };
  }

  return { response: c.json(limitCheck.error.toJSON(), 403) };
}

// ============================================================================
// Endpoints
// ============================================================================

// GET /twist/:id/integrations
// Returns accounts, providers, and channels for the edit modal.
twistIntegrations.get("/twist/:id/integrations", async (c) => {
  const twistInstanceId = c.req.param("id");

  const access = await checkTwistAccess(
    c.var.db,
    twistInstanceId,
    c.var.user.id,
    "read"
  );
  if (!access.ok) return c.json(twistNotFoundResponse, 404);

  const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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

  // Read twist_instance options once — both branches surface them in the
  // integrations modal so connector-level boolean toggles render in either
  // path.
  const pt = await c.var.db
    .selectFrom("twist_instance")
    .select("options")
    .where("id", "=", twistInstanceId)
    .executeTakeFirst();
  const ptConfig: Record<string, unknown> = pt?.options
    ? typeof pt.options === "string"
      ? JSON.parse(pt.options)
      : pt.options
    : {};
  const hasConfig = Object.keys(ptConfig).length > 0;

  if (config.providers.length === 0) {
    // No-provider connector: check if options have been configured (via /connect)

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
        access: config.access ?? null,
        shared: twistInfo.shared, keyOption: twistInfo.keyOption,
        premium: twistInfo.premium,
        accountLabel: twistInfo.accountLabel ?? null,
        teamName: twistInfo.teamName ?? null,
      });
    }

    // Connected — call getChannels to fetch available channels
    const logger = createLogger({ twist_instance_id: twistInstanceId });
    let twistWrapper;
    try {
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });
      twistWrapper = await factory({
        twistInstanceId,
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

      // Query channel to merge enabled state
      const enabledChannels = await c.var.db
        .selectFrom("channel")
        .select(["channel_id", "enabled"])
        .where("twist_instance_id", "=", twistInstanceId)
        .execute();
      const enabledMap = new Map(
        enabledChannels.map((ch) => [ch.channel_id, ch])
      );

      const rawChannels = Array.isArray(result) ? result : [];

      syncables = rawChannels.map((ch: any) => {
        const stored = enabledMap.get(ch.id);
        return {
          ...ch, // includes linkTypes from getChannels() if present
          provider: "_options",
          enabled: stored?.enabled ?? false,
          enabledBy: null,
          // Fall back to connector-level linkTypes when channel doesn't specify its own
          linkTypes: ch.linkTypes ?? config.connectorLinkTypes ?? undefined,
          currentUserHasAccess: true,
        };
      });
    } catch (error) {
      logger.error("getChannels failed for no-provider connector", error as Error);
    }

    const accounts = accountName
      ? [{ provider: "_options", actorId: twistInstanceId, name: accountName, email: null }]
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

    const teamDomains = await getTeamDomains(c.var.db);

    // No-provider connectors carry no OAuth scopes; productStatus therefore
    // reduces to channel-based enablement. Omitted entirely for connectors
    // without products (the common case here).
    const productFields = buildProductFields(
      config.products,
      [],
      [],
      syncables,
    );

    return c.json({
      providers: [], accounts, syncables, optionsSchema, optionsConfig,
      access: config.access ?? null,
      singleChannel: config.singleChannel,
      fixedChannels: config.fixedChannels,
      channelNoun: config.channelNoun,
    autoThreading: config.autoThreading,
      shared: twistInfo.shared,
      keyOption: twistInfo.keyOption,
      premium: twistInfo.premium,
      teamDomains,
      accountLabel: twistInfo.accountLabel ?? null,
      teamName: twistInfo.teamName ?? null,
      ...productFields,
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
  // Union of OAuth scopes granted across every Integrations instance — feeds
  // the combined-connector productStatus computation below.
  const grantedScopesSet = new Set<string>();
  // Instances whose read queued self-heal writes; drained after we respond
  // (see the waitUntil below) so those repair writes stay off the read path.
  const integrationsInstances: Integrations[] = [];

  for (const [pathStr, providers] of pathToProviders) {
    const path = pathStr.split(":");
    const integrations = createReadOnlyIntegrations(
      path,
      providers,
      c.env,
      c.executionCtx as unknown as { exports: ExecutionContext["exports"] },
      c.var.db,
      twistInstanceId,
      twistInfo.twistPackageId,
      twistInfo.environment
    );
    integrationsInstances.push(integrations);

    let data = await integrations.getIntegrationData(
      currentActorId as any
    );

    // Self-heal: hosted-auth providers can cache an empty channel list when
    // the token wasn't yet stored during activation. If we see a hosted-auth
    // account but zero channels, trigger refreshChannels for each connected
    // actor and re-read. Single-channel connectors are the obvious case
    // (getChannels should always return exactly one), but the same pattern
    // helps any hosted-auth provider that lands here with a stale cache.
    const hostedProviders = providers.filter(
      (p) =>
        PROVIDER_CONFIGS[p.provider as keyof typeof PROVIDER_CONFIGS]
          ?.authMode === "hosted"
    );
    if (
      hostedProviders.length > 0 &&
      data.accounts.length > 0 &&
      data.syncables.length === 0
    ) {
      try {
        const twistWrapper = await twistFactory({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          db: c.var.db,
        })({ twistInstanceId });
        for (const account of data.accounts) {
          if (!hostedProviders.some((p) => p.provider === account.provider)) {
            continue;
          }
          try {
            const r = await twistWrapper.callCallback(
              pathStr.split(":"),
              "refreshChannels",
              account.provider,
              account.actorId
            );
            disposeRpc(r);
          } catch (refreshErr) {
            const refreshLogger = createLogger({
              twist_instance_id: twistInstanceId,
              route: "GET /twist/:id/integrations",
              provider: account.provider,
              actor_id: account.actorId,
            });
            refreshLogger.warn(
              "auto-refresh channels failed",
              refreshErr instanceof Error
                ? { error: refreshErr.message }
                : { error: String(refreshErr) }
            );
          }
        }
        // Re-read after refresh attempts.
        data = await integrations.getIntegrationData(currentActorId as any);
      } catch (e) {
        const refreshLogger = createLogger({
          twist_instance_id: twistInstanceId,
          route: "GET /twist/:id/integrations",
        });
        refreshLogger.warn(
          "auto-refresh setup failed",
          e instanceof Error ? { error: e.message } : { error: String(e) }
        );
      }
    }

    allProviders.push(...data.providers);
    allAccounts.push(...data.accounts);
    allChannels.push(...data.syncables);
    for (const s of data.grantedScopes ?? []) grantedScopesSet.add(s);
  }

  // Drain the self-heal writes accumulated while reading (channel mirror + tic
  // backfill) after the response is sent, on a fresh connection — the request
  // db is torn down once this handler returns. Snapshot env/tracker into locals
  // per the waitUntil-lifetime rule.
  if (integrationsInstances.length > 0) {
    const bgEnv = c.env;
    const bgTracker = c.var.tracker;
    c.executionCtx.waitUntil(
      (async () => {
        const bgDb = createDb(bgEnv);
        try {
          for (const inst of integrationsInstances) {
            await inst.flushDeferredSelfHeal(bgDb);
          }
        } catch (error) {
          // Per-write failures are already logged inside flushDeferredSelfHeal;
          // this backstops unexpected failures (e.g. connection setup).
          bgTracker.captureException(error as Error);
        } finally {
          await bgDb.destroy();
        }
      })()
    );
  }

  const teamDomains = await getTeamDomains(c.var.db);

  // Surface connector-level Options to the integrations modal the same way
  // the no-provider branch does — connectors with a provider (LinkedIn,
  // WhatsApp, Instagram on Unipile, but also any future OAuth connector
  // with toggles) should be able to expose user-configurable booleans.
  let optionsSchema = config.optionsSchema ?? null;
  if (!optionsSchema && twistInfo.twistOptions) {
    try {
      optionsSchema = typeof twistInfo.twistOptions === "string"
        ? JSON.parse(twistInfo.twistOptions)
        : twistInfo.twistOptions;
    } catch { /* ignore parse errors */ }
  }
  let optionsConfig: Record<string, unknown> | null = null;
  if (optionsSchema && hasConfig) {
    const masked = { ...ptConfig };
    for (const [key, def] of Object.entries(optionsSchema)) {
      if (def.type === "text" && "secure" in def && (def as any).secure) {
        if (key in masked) masked[key] = true;
      }
    }
    optionsConfig = masked;
  }

  // Combined (multi-product) connectors: surface the declared products and the
  // derived per-product status. Omitted entirely for plain connectors, so the
  // app's `isComposite` gate stays false and the legacy flow is unaffected.
  const productFields = buildProductFields(
    config.products,
    collectOptionalScopeGroups(allProviders),
    Array.from(grantedScopesSet),
    allChannels,
  );

  return c.json({
    providers: allProviders,
    accounts: allAccounts,
    syncables: allChannels,
    singleChannel: config.singleChannel,
    fixedChannels: config.fixedChannels,
    channelNoun: config.channelNoun,
    autoThreading: config.autoThreading,
    optionsSchema,
    optionsConfig,
    shared: twistInfo.shared,
    keyOption: twistInfo.keyOption,
    premium: twistInfo.premium,
    teamDomains,
    accountLabel: twistInfo.accountLabel ?? null,
    teamName: twistInfo.teamName ?? null,
    ...productFields,
  });
});

// POST /twist/:id/integrations/auth
// Generate auth URL for the modal.
const AuthRequestSchema = z.object({
  provider: z.string(),
  redirectUri: z.string(),
  platform: z.enum(["ios", "android", "desktop"]).optional(),
  forceBridge: z.boolean().optional(),
  enabledScopeGroups: z.array(z.string()).optional(),
  accountHint: z.string().optional(),
});

twistIntegrations.post("/twist/:id/integrations/auth", async (c) => {
  const twistInstanceId = c.req.param("id");

  const access = await checkTwistAccess(
    c.var.db,
    twistInstanceId,
    c.var.user.id,
    "write"
  );
  if (!access.ok) return c.json(twistNotFoundResponse, 404);

  const rawBody = await c.req.json();
  const parseResult = AuthRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const { provider, redirectUri, platform, forceBridge, accountHint } =
    parseResult.data;

  const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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

  // Resolve final scopes including enabled optional scope groups.
  const { enabledScopeGroups } = parseResult.data;
  const finalScopes = resolveRequestedScopes(
    providerDecl.scopes,
    providerDecl.optionalScopes,
    enabledScopeGroups
  );

  // Create a callback token pointing to the Integrations tool's onAuth method
  const callbacksId = c.env.CALLBACKS.idFromName(twistInstanceId);
  const callbacksStub = c.env.CALLBACKS.get(callbacksId);
  const callback = await callbacksStub.create({
    twistInstanceId,
    path: integrationsPathStr.split(":"),
    functionName: "onAuth",
    extraArgs: [],
  });

  // Generate the auth URL. Hosted-auth providers (LinkedIn, WhatsApp,
  // Instagram) mint the URL via a third party (Unipile); OAuth providers build
  // it locally. A failure in that upstream — Unipile returning 401 (bad/expired
  // API key or key↔DSN mismatch) or 5xx, the provider being down, etc. — throws
  // here. Translate it into a clean 502 with an actionable message instead of
  // letting it bubble to the global handler as an opaque `500 Internal Server
  // Error`, and capture the underlying error with context for debugging.
  let result: { url: string; clientId: string; state: string } | null;
  try {
    result = await Integrations.GenerateAuthUrl({
      provider: provider as any,
      scopes: finalScopes,
      requiredScopes: providerDecl.scopes,
      enabledScopeGroups,
      callback: callback as any,
      redirectUri,
      platform,
      forceBridge,
      env: c.env,
      storage: c.env.STORAGE,
      accountHint,
    });
  } catch (err) {
    c.var.tracker.captureException(err, {
      context: "integrations:auth",
      twist_instance_id: twistInstanceId,
      provider,
    });
    return c.json(
      {
        message: `Couldn't start authentication for ${provider}. The provider may be temporarily unavailable — please try again.`,
      },
      502
    );
  }

  if (!result) {
    return c.json(
      { message: `Failed to generate auth URL for ${provider}` },
      500
    );
  }

  // Echo the resolved scopes alongside the auth URL. The browser flow uses the
  // URL directly, but the native Google Sign-In path (macOS/iOS/Android) drives
  // consent through the GoogleSignIn SDK and cannot read scopes out of the URL —
  // it needs the resolved list here so it requests exactly the enabled scope
  // groups (e.g. the combined Google connector's tasks/contacts) rather than
  // falling back to the connector's required scopes.
  return c.json({ ...result, callback: String(callback), scopes: finalScopes });
});

// POST /twist/:id/integrations/connect
// For no-provider connectors: saves options, calls getChannels, returns channel list.
const ConnectRequestSchema = z.object({
  options: z.record(z.string(), z.any()),
});

twistIntegrations.post("/twist/:id/integrations/connect", async (c) => {
  const twistInstanceId = c.req.param("id");

  const access = await checkTwistAccess(
    c.var.db,
    twistInstanceId,
    c.var.user.id,
    "write"
  );
  if (!access.ok) return c.json(twistNotFoundResponse, 404);

  const rawBody = await c.req.json();
  const parseResult = ConnectRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const { options } = parseResult.data;

  const logger = createLogger({ twist_instance_id: twistInstanceId });

  const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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
            twistInstanceId,
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
              twistInstanceId,
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
          twistInstanceId,
          optSchema,
          options
        );
      }
    }

    // Save config to twist_instance
    await c.var.db
      .updateTable("twist_instance")
      .set({ options: JSON.stringify(cleanedConfig) })
      .where("id", "=", twistInstanceId)
      .execute();

    // Instantiate the twist and call getChannels(null, null) on the connector
    const factory = twistFactory({
      env: c.env,
      ctx: c.executionCtx as ExecutionContext,
      db: c.var.db,
    });

    const twistWrapper = await factory({
      twistInstanceId,
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
      createThreads: ch.createThreads ?? "all",
      linkTypes: ch.linkTypes ?? kvConfig.connectorLinkTypes ?? undefined,
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
        .updateTable("twist_instance")
        .set({ options: JSON.stringify(updatedConfig) })
        .where("id", "=", twistInstanceId)
        .execute();
    }

    // Record connection for user_connected tracking
    try {
      await c.var.db
        .insertInto("twist_instance_connection")
        .values({
          twist_instance_id: twistInstanceId,
          user_id: c.var.user.id,
          provider: "_key",
          actor_id: c.var.user.id,
          connected_at: new Date().toISOString(),
        })
        .onConflict((oc) =>
          oc
            .columns(["twist_instance_id", "user_id", "provider"])
            .doUpdateSet({
              connected_at: new Date().toISOString(),
            })
        )
        .execute();
    } catch (error) {
      logger.error("Failed to record twist_instance_connection for key connector", error as Error);
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
// Enable a channel.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/:syncableId/enable",
  async (c) => {
    const twistInstanceId = c.req.param("id");
    const provider = c.req.param("provider");
    const channelId = c.req.param("syncableId");

    const logger = createLogger({ twist_instance_id: twistInstanceId });

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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

    // Read optional consent flag from request body (may be absent or empty).
    const body = await c.req.json<{ consentAddon?: boolean }>().catch(
      () => ({} as { consentAddon?: boolean })
    );

    // Get current user's actor ID
    const currentActorId = await getCurrentActorId(c.var.db, c.var.user.id);
    if (!currentActorId) {
      return c.json({ message: "No actor found for current user" }, 400);
    }

    // Check connection limit + charge-on-enable (consent) before enabling.
    const gate = await chargeConsentedAddonOrError(
      c,
      twistInstanceId,
      body.consentAddon
    );
    if ("response" in gate) return gate.response;

    try {
      // Create twist wrapper and call enableSync via callCallback
      const factory = twistFactory({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        db: c.var.db,
      });

      const twistWrapper = await factory({
        twistInstanceId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "enableSync",
        provider,
        channelId,
        currentActorId,
        undefined // title
      );
      disposeRpc(result);

      logger.info("Channel enabled", {
        provider,
        channel_id: channelId,
        actor_id: currentActorId,
      });

      // A newly-enabled channel has no default priority yet. Enqueue a
      // debounced router run so the LLM assigns one before threads start
      // streaming in. Fire-and-forget.
      c.executionCtx.waitUntil(
        enqueueChannelRouter(c.env, c.var.user.id).catch(() => {})
      );

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
    const twistInstanceId = c.req.param("id");
    const provider = c.req.param("provider");
    const channelId = c.req.param("syncableId");

    const logger = createLogger({ twist_instance_id: twistInstanceId });

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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
        twistInstanceId,
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

// POST /twist/:id/syncables/batch
// Apply a batch of channel enable/disable operations in a single request.
// Loads twist config + factory once and processes each entry against the
// same twist wrapper — avoids N round-trips plus N factory spin-ups when a
// user toggles multiple channels in one "Add connection" action.
twistIntegrations.post(
  "/twist/:id/syncables/batch",
  async (c) => {
    const twistInstanceId = c.req.param("id");
    const logger = createLogger({ twist_instance_id: twistInstanceId });

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const bodySchema = z.object({
      enable: z
        .array(z.object({ provider: z.string(), syncableId: z.string() }))
        .optional(),
      disable: z
        .array(z.object({ provider: z.string(), syncableId: z.string() }))
        .optional(),
      consentAddon: z.boolean().optional(),
    });

    const raw = await c.req.json();
    const parsed = bodySchema.safeParse(raw);
    if (!parsed.success) {
      return handleValidationError(parsed.error, raw);
    }

    const enables = parsed.data.enable ?? [];
    const disables = parsed.data.disable ?? [];
    if (enables.length === 0 && disables.length === 0) {
      return c.json({ success: true, enabled: [], disabled: [], errors: [] });
    }

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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

    let currentActorId: string | null = null;
    if (enables.length > 0) {
      currentActorId = await getCurrentActorId(c.var.db, c.var.user.id);
      if (!currentActorId) {
        return c.json({ message: "No actor found for current user" }, 400);
      }

      // Connection limit + charge-on-enable (consent) is twist-instance-wide;
      // one check covers every provider/channel we're about to enable.
      const gate = await chargeConsentedAddonOrError(
        c,
        twistInstanceId,
        parsed.data.consentAddon
      );
      if ("response" in gate) return gate.response;
    }

    const factory = twistFactory({
      env: c.env,
      ctx: c.executionCtx as ExecutionContext,
      db: c.var.db,
    });
    const twistWrapper = await factory({ twistInstanceId });

    const enabled: Array<{ provider: string; syncableId: string }> = [];
    const disabled: Array<{ provider: string; syncableId: string }> = [];
    const errors: Array<{
      op: "enable" | "disable";
      provider: string;
      syncableId: string;
      message: string;
    }> = [];

    for (const { provider, syncableId } of enables) {
      const integrationsPathStr = config.integrationsMap[provider];
      if (!integrationsPathStr) {
        errors.push({
          op: "enable",
          provider,
          syncableId,
          message: `Provider ${provider} not configured`,
        });
        continue;
      }
      try {
        const result = await twistWrapper.callCallback(
          integrationsPathStr.split(":"),
          "enableSync",
          provider,
          syncableId,
          currentActorId!,
          undefined
        );
        disposeRpc(result);
        enabled.push({ provider, syncableId });
      } catch (error) {
        if (error instanceof PlanLimitError) {
          return c.json(error.toJSON(), 403);
        }
        logger.warn("Batch enable failed for channel", {
          provider,
          syncable_id: syncableId,
          error: error instanceof Error ? error.message : String(error),
        });
        errors.push({
          op: "enable",
          provider,
          syncableId,
          message: error instanceof Error ? error.message : "Unknown error",
        });
      }
    }

    for (const { provider, syncableId } of disables) {
      const integrationsPathStr = config.integrationsMap[provider];
      if (!integrationsPathStr) {
        errors.push({
          op: "disable",
          provider,
          syncableId,
          message: `Provider ${provider} not configured`,
        });
        continue;
      }
      try {
        const result = await twistWrapper.callCallback(
          integrationsPathStr.split(":"),
          "disableSync",
          provider,
          syncableId
        );
        disposeRpc(result);
        disabled.push({ provider, syncableId });
      } catch (error) {
        logger.warn("Batch disable failed for channel", {
          provider,
          syncable_id: syncableId,
          error: error instanceof Error ? error.message : String(error),
        });
        errors.push({
          op: "disable",
          provider,
          syncableId,
          message: error instanceof Error ? error.message : "Unknown error",
        });
      }
    }

    logger.info("Channels batch applied", {
      enabled_count: enabled.length,
      disabled_count: disabled.length,
      error_count: errors.length,
    });

    return c.json({
      success: errors.length === 0,
      enabled,
      disabled,
      errors,
    });
  }
);

// PATCH /twist/:id/syncables/:provider/:syncableId
// Legacy no-op: channels no longer store per-channel routing.
// Kept so existing clients don't 404 when they try to write an obsolete
// priorityId field.
twistIntegrations.patch(
  "/twist/:id/syncables/:provider/:syncableId",
  async (c) => {
    const twistInstanceId = c.req.param("id");
    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);
    return c.json({ success: true });
  }
);

// POST /twist/:id/syncables/:provider/refresh
// Re-fetch the channel list from the external service for a provider+actor.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/refresh",
  async (c) => {
    const twistInstanceId = c.req.param("id");
    const provider = c.req.param("provider");

    const logger = createLogger({ twist_instance_id: twistInstanceId });

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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
        twistInstanceId,
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

// POST /twist/:id/syncables/:provider/auto-enable
// Set the per-connection "auto-enable newly discovered channels" flag.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/auto-enable",
  async (c) => {
    const twistInstanceId = c.req.param("id");
    const provider = c.req.param("provider");
    const body = await c.req.json<{ actorId?: string; enabled?: boolean }>();
    const actorId = body.actorId;
    const enabled = body.enabled === true;

    const logger = createLogger({ twist_instance_id: twistInstanceId });

    if (!actorId) {
      return c.json({ message: "actorId is required" }, 400);
    }

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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
        twistInstanceId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "setAutoEnableNewChannels",
        provider,
        actorId,
        enabled
      );
      disposeRpc(result);

      logger.info("Auto-enable new channels updated", {
        provider,
        actor_id: actorId,
        enabled,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error(
        "Error setting auto-enable new channels",
        error as Error,
        { provider, actor_id: actorId }
      );
      return c.json(
        {
          message: `Failed to update setting: ${
            error instanceof Error ? error.message : "Unknown error"
          }`,
        },
        500
      );
    }
  }
);

// POST /twist/:id/syncables/:provider/auto-threading
// Toggle the per-connection auto-threading preference (fold related messages
// into one thread). Mirrors the auto-enable route above.
twistIntegrations.post(
  "/twist/:id/syncables/:provider/auto-threading",
  async (c) => {
    const twistInstanceId = c.req.param("id");
    const provider = c.req.param("provider");
    const body = await c.req.json<{ actorId?: string; enabled?: boolean }>();
    const actorId = body.actorId;
    const enabled = body.enabled === true;

    const logger = createLogger({ twist_instance_id: twistInstanceId });

    if (!actorId) {
      return c.json({ message: "actorId is required" }, 400);
    }

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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
        twistInstanceId,
      });

      const result = await twistWrapper.callCallback(
        integrationsPathStr.split(":"),
        "setAutoThreadingEnabled",
        provider,
        actorId,
        enabled
      );
      disposeRpc(result);

      logger.info("Auto-threading updated", {
        provider,
        actor_id: actorId,
        enabled,
      });

      return c.json({ success: true });
    } catch (error) {
      logger.error("Error setting auto-threading", error as Error, {
        provider,
        actor_id: actorId,
      });
      return c.json(
        {
          message: `Failed to update setting: ${
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
    const twistInstanceId = c.req.param("id");
    const provider = c.req.param("provider");
    const actorId = c.req.param("actorId");

    const logger = createLogger({ twist_instance_id: twistInstanceId });

    const access = await checkTwistAccess(
      c.var.db,
      twistInstanceId,
      c.var.user.id,
      "write"
    );
    if (!access.ok) return c.json(twistNotFoundResponse, 404);

    const twistInfo = await resolveTwistInfo(c.var.db, twistInstanceId);
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
        twistInstanceId,
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
