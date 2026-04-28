import { sql, type Kysely } from "kysely";

import type { NoteWriteBackResult } from "@plotday/twister";
import {
  type Actor,
  type ActorId,
  ActorType,
  type Action,
  ActionType,
  type Link,
  type NewContact,
  type NewLinkWithNotes,
  type Note,
  type Thread,
  type ThreadMeta,
} from "@plotday/twister/plot";
import { type Callback } from "@plotday/twister/tools/callbacks";
import { Tag } from "@plotday/twister/tag";
import type {
  ArchiveLinkFilter,
  AuthProvider,
  AuthToken,
  Authorization,
  Channel,
  LinkTypeConfig,
  SyncContext,
  Integrations as IAuth,
} from "@plotday/twister/tools/integrations";
import type { Uuid } from "@plotday/twister/utils/uuid";

import type { Json } from "@plotday/db";
import type { DB } from "../../db-types";
import { type Bindings, type TwistEnvironment } from "../../env";
import {
  extractUserId,
  PROVIDER_CONFIGS,
  type ProviderData,
  type StoredTokenData,
} from "../../provider";
import { hashExternalContent } from "./hash-external-content";
import { CallbacksState } from "../../state/callbacks";
import { classifyInviteable } from "../../state/contact-classifier";
import superjson from "superjson";

import type { Storage } from "../../state/storage";
import { createLogger } from "@plotday/worker-util";
import { rpc, rpcUser } from "../../rpc";
import { notifyUserSyncByEnv } from "../../app/sync/notify";
import { getEffectivePlan } from "../../utils/plan";
import { getSyncHistoryMinDate, type PlanKey } from "../../utils/limits";
import { getRpcFunctionName } from "../../utils/rpc";
import { invokeCallback } from "../invoke-callback";
import { fromDbLink } from "./plot/converters";
import type { Plot } from "./plot/index";
import type { Store } from "./store";
import { Tool } from "./tool";
import { createSchedule } from "../../app/sync/smart-schedule";
import { unarchiveDoneLinksOnThread } from "../../app/sync/link-tags";

/** Internal provider config used by the Integrations tool. */
type IntegrationProviderConfig = {
  provider: AuthProvider;
  scopes: string[];
  optionalScopes?: Array<{
    id: string;
    label: string;
    description?: string;
    scopes: string[];
    default: boolean;
  }>;
  linkTypes?: LinkTypeConfig[];
  getChannels: (auth: Authorization, token: AuthToken) => Promise<Channel[]>;
  onChannelEnabled: (channel: Channel, context?: SyncContext) => Promise<void>;
  onChannelDisabled: (channel: Channel) => Promise<void>;
  onLinkUpdated?: (link: Link) => Promise<void>;
  onNoteCreated?: (note: Note, meta: ThreadMeta) => Promise<void>;
};

type IntegrationOptions = {
  providers: IntegrationProviderConfig[];
};

const AUTH_EMAIL_CONFLICT_ERROR = "AuthEmailConflictError";

type AuthState = {
  provider: AuthProvider;
  scopes: string[];
  codeVerifier?: string; // Optional for Google Sign-In flows
  timestamp?: number; // Optional for Google Sign-In flows
  callback?: Callback;
  enabledScopeGroups?: string[];
  // Populated when requiresHttpsRedirect substitutes the client's redirect URI:
  // clientId and redirectUri are the values actually used in the OAuth flow
  // (needed by the server-rendered GET /auth/bridge handler to finish the
  // token exchange), and bridgeUri is the original custom-scheme URI the
  // client expects to resume on.
  clientId?: string;
  redirectUri?: string;
  bridgeUri?: string;
  // Set by the plot.day/slack admin-install flow: complete the OAuth exchange
  // purely to register the app with the workspace (unlocking the install gate
  // for member connects), then discard/revoke the admin's token — no callback,
  // no account linkage, no deep-link back to the app.
  installOnly?: boolean;
};

type ChannelConfig = {
  enabled: boolean;
  enabledBy?: ActorId;
  title?: string | null;
};

type PendingActAs = {
  callbackToken: Callback;
  activityId: Uuid;
  noteId?: string;
};

/**
 * Error thrown by refreshToken() that distinguishes permanent OAuth failures
 * (refresh_token revoked / client de-authorized — must re-auth) from
 * transient ones (5xx, rate limit, network blip — retry on next webhook).
 *
 * Permanent: caller should clear the stored token. Transient: caller should
 * preserve the token so the next sync can retry.
 */
class TokenRefreshError extends Error {
  readonly permanent: boolean;
  readonly status?: number;
  readonly oauthError?: string;
  readonly body?: string;

  constructor(
    message: string,
    permanent: boolean,
    extras?: { status?: number; oauthError?: string; body?: string; cause?: unknown }
  ) {
    super(message);
    this.name = "TokenRefreshError";
    this.permanent = permanent;
    this.status = extras?.status;
    this.oauthError = extras?.oauthError;
    this.body = extras?.body;
    if (extras?.cause !== undefined) {
      (this as { cause?: unknown }).cause = extras.cause;
    }
  }
}

/**
 * RFC 6749 OAuth error codes that mean the refresh_token (or client) is
 * permanently dead. Per Google's OAuth 2.0 docs and RFC 6749:
 *  - invalid_grant: refresh_token revoked, expired, or malformed
 *  - invalid_client: client credentials wrong / app de-authorized
 *  - unauthorized_client: client not authorized for this grant type
 *  - invalid_request: malformed request (won't succeed without code change)
 *  - unsupported_grant_type: provider no longer accepts refresh grants here
 */
const PERMANENT_OAUTH_ERRORS = new Set([
  "invalid_grant",
  "invalid_client",
  "unauthorized_client",
  "invalid_request",
  "unsupported_grant_type",
]);

/**
 * Decide whether an HTTP failure from the provider's token endpoint means the
 * stored refresh_token is permanently dead. Errors of unknown shape are
 * treated as transient — better to retry an extra time than silently lose a
 * working connection.
 */
function classifyRefreshHttpError(
  status: number,
  body: string
): { permanent: boolean; oauthError?: string } {
  // 5xx, 408, 429 — provider-side or rate-limit, always transient.
  if (status >= 500 || status === 408 || status === 429) {
    return { permanent: false };
  }

  // Try to parse OAuth error code from the body.
  let oauthError: string | undefined;
  try {
    const parsed = JSON.parse(body) as { error?: unknown };
    if (typeof parsed?.error === "string") {
      oauthError = parsed.error;
    }
  } catch {
    // Non-JSON body; fall through.
  }

  if (oauthError && PERMANENT_OAUTH_ERRORS.has(oauthError)) {
    return { permanent: true, oauthError };
  }

  // 4xx without a recognized OAuth error code: don't assume permanent. A
  // misconfigured proxy, transient WAF block, or unfamiliar provider response
  // shouldn't nuke a user's auth. Leave the token in place; next retry will
  // either succeed or yield a clearer error.
  return { permanent: false, oauthError };
}

// @ts-ignore - class correctly implements IAuth but TS can't verify due to Kysely type differences
export class Integrations extends Tool implements IAuth {
  private store: Store;
  private env: Bindings;
  private db: Kysely<DB>;
  private twistInstanceId: string;
  // These are callbacks we create and call
  private callbacks: DurableObjectStub<CallbacksState>;
  private _twistId: string;
  private _environment: TwistEnvironment;
  private path: string[];
  private providerConfigs: IntegrationProviderConfig[];
  /** Source metadata passed from factory when the twist is a Source. */
  private sourceProvider: { provider?: string; scopes?: string[]; linkTypes?: any[]; shared?: boolean; keyOption?: string } | null = null;
  /** Cached sync history min date (undefined = not computed yet, null = no limit). */
  private _syncHistoryMin: Date | null | undefined = undefined;
  /**
   * Cached account contact for this twist instance's owner.
   * undefined = not computed yet, null = no connection registered.
   */
  private _accountContact:
    | { id: ActorId; email: string; name: string | null }
    | null
    | undefined = undefined;
  /**
   * Extract provider metadata from integration options during deployment.
   * Returns provider/scopes pairs without lifecycle callbacks.
   */
  static Providers(
    options?: IntegrationOptions
  ): Array<{ provider: string; scopes: string[]; linkTypes?: any[] }> {
    if (!options?.providers) return [];
    return options.providers.map((p) => ({
      provider: p.provider,
      scopes: [...p.scopes],
      linkTypes: p.linkTypes ?? [],
    }));
  }

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    twistInstanceId: string
  ) {
    const callbacksId = callbacks.idFromName(twistInstanceId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    store: Store;
    env: Bindings;
    db: Kysely<DB>;
    twistInstanceId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
    integrationOptions?: IntegrationOptions;
    /** Source metadata (provider, scopes, linkTypes, auth model) from the Source class. Set by factory for sources. */
    sourceProvider?: { provider?: string; scopes?: string[]; linkTypes?: any[]; shared?: boolean; keyOption?: string } | null;
  }) {
    super();
    this.store = options.store;
    this.env = options.env;
    this.db = options.db;
    this.twistInstanceId = options.twistInstanceId;
    this._twistId = options.twistId;
    this._environment = options.environment;
    this.callbacks = Integrations.GetStub(
      options.env.CALLBACKS,
      options.twistInstanceId
    );
    this.path = options.path;
    this.sourceProvider = options.sourceProvider ?? null;
    // Provider config callbacks (onChannelEnabled, onChannelDisabled, getChannels)
    // are no longer called as RPC stubs — they're returned as __dispatch info
    // and invoked locally by the twist worker entrypoint with proper this binding.
    // No need to dup any RPC stubs.
    this.providerConfigs = options.integrationOptions?.providers ?? [];

    // For sources using the new API (sourceProvider set), synthesize a provider config
    // so existing methods that read providerConfigs still work.
    // Skip for no-provider connectors (provider is undefined).
    if (this.sourceProvider?.provider && this.providerConfigs.length === 0) {
      this.providerConfigs = [{
        provider: this.sourceProvider.provider as AuthProvider,
        scopes: this.sourceProvider.scopes ?? [],
        linkTypes: this.sourceProvider.linkTypes,
        // Placeholder callbacks — never called directly, dispatch uses sourceMethod instead
        getChannels: async () => [],
        onChannelEnabled: async () => {},
        onChannelDisabled: async () => {},
      }];
    }
  }

  /**
   * Returns the sync history min date for this twist instance, based on the
   * owner's effective plan. Cached after first call.
   */
  async getSyncHistoryMin(): Promise<Date | null> {
    if (this._syncHistoryMin !== undefined) return this._syncHistoryMin;

    const twistInstance = await this.db
      .selectFrom("twist_instance")
      .select(["owner_id", "team_id"])
      .where("id", "=", this.twistInstanceId)
      .executeTakeFirst();

    if (!twistInstance?.owner_id) {
      this._syncHistoryMin = null;
      return null;
    }

    let plan: PlanKey;
    if (twistInstance.team_id) {
      const teamSub = await this.db
        .selectFrom("team_subscription")
        .select(["plan", "status"])
        .where("team_id", "=", String(twistInstance.team_id))
        .executeTakeFirst();
      plan =
        teamSub?.status === "active"
          ? (teamSub.plan as PlanKey)
          : "free";
    } else {
      const effective = await getEffectivePlan(this.db, twistInstance.owner_id);
      plan = effective.plan;
    }

    this._syncHistoryMin = getSyncHistoryMinDate(plan);
    return this._syncHistoryMin;
  }

  /**
   * Builds the SyncContext to pass to onChannelEnabled.
   *
   * If `forActor` and `provider` are supplied, automatically reads (and
   * clears) the connection's `recovery_pending` flag and ORs the result
   * into `recovering`. This is how a user-toggle after an auth failure
   * gets the same wipe-and-rewalk semantics as an explicit re-auth without
   * the connector having to know about it.
   *
   * @param options.recovering - When true, marks this dispatch as a recovery
   *   sync regardless of the pending flag. Use for explicit re-auth paths.
   * @param options.forActor - Actor whose connection should be checked for
   *   the pending recovery flag.
   * @param options.provider - Provider for the connection lookup.
   */
  private async buildSyncContext(
    options: {
      recovering?: boolean;
      forActor?: ActorId;
      provider?: AuthProvider;
    } = {}
  ): Promise<SyncContext> {
    const syncHistoryMin = await this.getSyncHistoryMin();
    const ctx: SyncContext = {};
    if (syncHistoryMin) ctx.syncHistoryMin = syncHistoryMin;

    let recovering = options.recovering ?? false;
    if (!recovering && options.forActor && options.provider) {
      const wasPending = await this.consumeRecoveryFlag(
        options.provider,
        options.forActor
      );
      if (wasPending) recovering = true;
    } else if (recovering && options.forActor && options.provider) {
      // Explicit recovery — also clear the flag so future dispatches don't
      // double-recover. The flag is only meaningful as a one-shot signal.
      await this.consumeRecoveryFlag(options.provider, options.forActor);
    }
    if (recovering) ctx.recovering = true;
    return ctx;
  }

  /**
   * Atomically read-and-clear `recovery_pending` for the actor's connection.
   * Returns true if the flag was previously set.
   *
   * Safe to call when the actor has no contact-linked user — returns false.
   */
  private async consumeRecoveryFlag(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<boolean> {
    const contact = await this.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actorId)
      .executeTakeFirst();
    if (!contact?.user_id) return false;

    const result = await this.db
      .updateTable("twist_instance_connection")
      .set({ recovery_pending: false })
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("user_id", "=", contact.user_id)
      .where("provider", "=", provider)
      .where("recovery_pending", "=", true)
      .executeTakeFirst();
    return (result.numUpdatedRows ?? 0n) > 0n;
  }

  // ============================================================================
  // Public API (implements IAuth interface)
  // ============================================================================

  /**
   * Get a token for a channel.
   * Returns the token of the user who enabled sync on the given channel.
   * Supports both get(channelId) and get(provider, channelId) signatures.
   */
  async get(channelIdOrProvider: string, channelId?: string): Promise<AuthToken | null> {
    // Support both signatures: get(channelId) and get(provider, channelId)
    let provider: AuthProvider;
    let resolvedChannelId: string;
    if (channelId !== undefined) {
      provider = channelIdOrProvider as AuthProvider;
      resolvedChannelId = channelId;
    } else {
      // Single-arg form: use the first provider from config
      provider = this.providerConfigs[0]?.provider;
      resolvedChannelId = channelIdOrProvider;
      // For key-based connectors with no OAuth providers, resolve the key
      if (!provider && this.sourceProvider?.keyOption) {
        return this.getKeyToken(resolvedChannelId);
      }
      if (!provider) return null;
    }

    // Look up channel config to find who enabled it
    const config = await this.getChannelConfig(provider, resolvedChannelId);

    if (config?.enabled && config.enabledBy) {
      const token = await this.getActorToken(provider, config.enabledBy);
      if (!token) {
        // Channel is enabled but the actor's token is missing/dead.
        // `getActorToken` already flags reauth on the permanent-refresh and
        // no-refresh-token paths, but a token that was never stored — or
        // was cleared by a previous failure that pre-dated this signal —
        // never goes through those paths. Flag here as a backstop so the
        // app's reauth prompt fires on the very next sync attempt.
        await this.flagNeedsReauth(provider, config.enabledBy);
      }
      return token;
    }

    // Migration fallback: no channel_config exists for pre-redesign users.
    // Find any actor with a valid token for this provider.
    const tokenKeys = await this.store.list(`auth_token:${provider}:`);
    for (const key of tokenKeys) {
      const actorId = key.slice(`auth_token:${provider}:`.length) as ActorId;
      const token = await this.getActorToken(provider, actorId);
      if (token) {
        // Auto-create channel_config so subsequent calls use the fast path
        await this.store.set(`channel_config:${provider}:${channelId}`, {
          enabled: true,
          enabledBy: actorId,
        } satisfies ChannelConfig);
        return token;
      }
    }
    return null;
  }

  /**
   * Resolve an API key for key-based connectors.
   * For individual keys, looks up the channel enabler's per-user key from secure_option.
   * For shared keys, resolves from the shared config (Options tool).
   */
  private async getKeyToken(channelId: string): Promise<AuthToken | null> {
    const keyOption = this.sourceProvider?.keyOption;
    if (!keyOption) return null;

    // Look up who enabled this channel
    const config = await this.getChannelConfig("_options" as AuthProvider, channelId);
    const enabledByUserId = config?.enabledBy;

    if (!this.sourceProvider?.shared && enabledByUserId) {
      // Individual key: look up per-user encrypted key
      const { resolveSecureOptions } = await import("../../utils/secure-options");
      const twist = await this.db
        .selectFrom("twist")
        .select("options_schema")
        .where("id", "=", this._twistId)
        .executeTakeFirst();
      const optSchema = twist?.options_schema as Record<string, unknown> | null;
      if (!optSchema || !this.env.AI_KEY_ENCRYPTION_KEY) return null;

      // Resolve the user who enabled the channel (enabledBy is actorId = userId for key connectors)
      const resolved = await resolveSecureOptions(
        this.db,
        this.env.AI_KEY_ENCRYPTION_KEY,
        this.twistInstanceId,
        { [keyOption]: optSchema[keyOption] } as any,
        {},
        enabledByUserId as string
      );

      const key = resolved[keyOption];
      if (typeof key === "string" && key.length > 0) {
        return { token: key, scopes: [] };
      }
    }

    // Shared key or fallback: the key is in the shared Options (resolved by the factory at runtime)
    // The connector should read it via this.tools.options directly
    return null;
  }

  /**
   * Execute a callback as a specific actor, requesting auth if needed.
   */
  async actAs(
    provider: AuthProvider,
    actorId: ActorId,
    activityId: Uuid,
    callback: (token: AuthToken, ...args: any[]) => any,
    ...extraArgs: any[]
  ): Promise<void> {
    // Check if actor already has a token
    const token = await this.getActorToken(provider, actorId);

    if (token) {
      // Actor has a valid token — invoke immediately via the rebuild-and-bind
      // dispatch path so `this` inside the connector method binds to the full
      // connector instance. See workers/api/src/twist/CALLBACKS.md.
      await invokeCallback(
        this.callbacks,
        this.twistInstanceId,
        callback,
        this.path.slice(0, -1),
        extraArgs,
        token
      );
      return;
    }

    // No token - create auth request for this actor
    // @ts-ignore - TS2589: Type instantiation is excessively deep and possibly infinite
    const callbackFunctionName = await getRpcFunctionName(callback);
    if (!callbackFunctionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    // Create callback token for the deferred callback
    const callbackToken = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path.slice(0, -1), // Target parent tool
      functionName: callbackFunctionName,
      extraArgs,
    }) as unknown as Callback;

    // Store pending actAs request
    const pendingKey = `pending_auth:${provider}:${actorId}`;
    const pending = await this.store.get<PendingActAs[]>(pendingKey) ?? [];

    // Get provider config for scopes
    const providerConfig = this.providerConfigs.find(p => p.provider === provider);
    if (!providerConfig) {
      throw new Error(`No provider config found for ${provider}`);
    }

    // Create auth link
    const onAuthCallback = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      functionName: "onAuth",
      extraArgs: [], // onAuth will look up pending callbacks itself
    }) as unknown as Callback;

    const authLink: Action = {
      title: `Continue with ${PROVIDER_CONFIGS[provider]?.name ?? provider}`,
      type: ActionType.auth,
      provider,
      scopes: providerConfig.scopes,
      callback: onAuthCallback,
    };

    // Create private note on the activity for this actor
    const noteId = crypto.randomUUID();
    const pendingEntry: PendingActAs = {
      callbackToken,
      activityId,
      noteId,
    };
    pending.push(pendingEntry);
    await this.store.set(pendingKey, pending);

    // Store the auth link info for the API to create the note
    // The actual note creation happens via the Plot built-in tool
    await this.store.set(`actAs_auth_link:${noteId}`, {
      actorId,
      activityId,
      provider,
      authLink,
    });
  }

  /**
   * Declare what channels an actor has access to. The DO channel_access cache
   * is the authoritative list; public.channel is a queryable mirror so ops and
   * support can see the full available list (DO state is not reachable from
   * psql). New rows are inserted with enabled=false; enable/disable state is
   * owned by enableSync/disableSync and never overwritten here.
   *
   * If `auto_enable_new_channels:${provider}:${actorId}` is set, any channel
   * that's appearing for the first time (no existing public.channel row) is
   * enabled in the same call and an `onChannelEnabled` dispatch entry is
   * returned, so periodic refreshes pick up new sources/calendars/projects
   * without user action.
   */
  async setChannels(
    provider: AuthProvider,
    actorId: ActorId,
    channels: Channel[]
  ): Promise<any> {
    // Snapshot the set of channels we already know about before mirroring so
    // we can identify newly-discovered ones for auto-enable.
    const flat = this.flattenChannels(channels);
    const knownIds = new Set<string>();
    if (flat.length > 0) {
      const existingRows = await this.db
        .selectFrom("channel")
        .select("channel_id")
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where(
          "channel_id",
          "in",
          flat.map((c) => c.id)
        )
        .execute();
      for (const row of existingRows) knownIds.add(row.channel_id);
    }

    await this.store.set(`channel_access:${provider}:${actorId}`, channels);
    await this.mirrorChannelsToDb(channels);

    // Auto-enable newly-discovered channels when the per-connection flag is on.
    const autoEnable = await this.store.get<boolean>(
      `auto_enable_new_channels:${provider}:${actorId}`
    );
    if (!autoEnable) return;

    const newChannels = flat.filter((c) => !knownIds.has(c.id));
    if (newChannels.length === 0) return;

    const syncContext = await this.buildSyncContext({
      forActor: actorId,
      provider,
    });
    const dispatches: any[] = [];
    for (const channel of newChannels) {
      const entry = await this.applyChannelEnabled(
        provider,
        actorId,
        channel,
        syncContext
      );
      if (entry) dispatches.push(entry);
    }
    if (dispatches.length > 0) return { __dispatch: dispatches } as any;
  }

  /**
   * Per-connection preference: when true, channels discovered for the first
   * time via `setChannels` are auto-enabled. Default is false.
   */
  async getAutoEnableNewChannels(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<boolean> {
    return (
      (await this.store.get<boolean>(
        `auto_enable_new_channels:${provider}:${actorId}`
      )) ?? false
    );
  }

  async setAutoEnableNewChannels(
    provider: AuthProvider,
    actorId: ActorId,
    enabled: boolean
  ): Promise<void> {
    await this.store.set(
      `auto_enable_new_channels:${provider}:${actorId}`,
      enabled
    );
  }

  /**
   * Persist enable for a channel and build the onChannelEnabled dispatch entry.
   * Shared between enableSync (user-triggered), setChannels (auto-enable on
   * newly-discovered channels), and onAuth (recovery after re-auth). Caller is
   * responsible for assembling the resulting `{ __dispatch }` envelope.
   *
   * Stamps the connection's initial-sync state to "syncing" before the
   * dispatch fires (was previously the connector's responsibility via
   * `setInitialSyncing(channelId, true)`). Attaches an `onFailure` handler
   * to the dispatch entry so an unhandled exception in `onChannelEnabled`
   * automatically clears the syncing state — preventing the UI from being
   * stuck on "syncing" forever.
   */
  private async applyChannelEnabled(
    provider: AuthProvider,
    actorId: ActorId,
    channel: Channel,
    syncContext: SyncContext
  ): Promise<any | null> {
    const title = channel.title ?? channel.id;
    const linkTypes = channel.linkTypes ?? null;

    await this.store.set(`channel_config:${provider}:${channel.id}`, {
      enabled: true,
      enabledBy: actorId,
      title,
    } satisfies ChannelConfig);

    // Upsert: setChannels/onAuth callers always have a row already (mirrored
    // by mirrorChannelsToDb or carried across re-auth), but enableSync's
    // re-add-after-archive case may not. On conflict, preserve existing
    // link_types when channel.linkTypes is null (matches the prior update-
    // only behavior).
    await this.db
      .insertInto("channel")
      .values({
        twist_instance_id: this.twistInstanceId,
        channel_id: channel.id,
        title,
        enabled: true,
        link_types: linkTypes ? (JSON.stringify(linkTypes) as any) : null,
      })
      .onConflict((oc) =>
        oc.columns(["twist_instance_id", "channel_id"]).doUpdateSet({
          enabled: true,
          title,
          ...(linkTypes ? { link_types: JSON.stringify(linkTypes) as any } : {}),
          updated_at: new Date(),
        })
      )
      .execute();

    // Mark the connection as initially-syncing so the Flutter app shows
    // a spinner. Recovery dispatches re-stamp `started_at` to now (instead
    // of coalescing to a possibly-ancient prior timestamp) so the
    // "syncing since" indicator reflects the current sync.
    await this.markChannelSyncStarted(provider, channel.id);

    const channelArg = { id: channel.id, title };
    // Failure dispatch: when onChannelEnabled throws, entrypoint.ts routes
    // through `tool.callCallback(functionName, ...args)` on the same
    // built-in tool whose dispatch produced this entry — i.e. the
    // Integrations tool itself. Calling __failChannelSync clears the
    // syncing state so the UI doesn't get stuck on "syncing" forever.
    const onFailure = {
      functionName: "__failChannelSync",
      args: [provider, channel.id],
    };

    if (this.sourceProvider) {
      return {
        sourceMethod: "onChannelEnabled",
        args: [channelArg, syncContext],
        onFailure,
      };
    }
    const providerIndex = this.providerConfigs.findIndex(
      (p) => p.provider === provider
    );
    if (providerIndex < 0) return null;
    return {
      optionPath: ["providers", providerIndex, "onChannelEnabled"],
      args: [channelArg, syncContext],
      onFailure,
    };
  }

  /**
   * Build a list of `onChannelEnabled` dispatch entries with `recovering:
   * true` for every channel currently enabled by this actor. Shared between
   * the onAuth recovery path (fast happy path) and the periodic
   * recovery-pending cron (backstop for cases that slipped past onAuth).
   *
   * Iterates channel_config keys rather than channel_access because
   * channel_config is the authoritative "what is enabled now" source —
   * channel_access can lag during re-auth. Builds the recovery context
   * ONCE so all channels share `recovering: true` (otherwise the per-call
   * flag-consume would only fire for the first channel).
   */
  private async buildRecoveryDispatches(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<any[]> {
    const configKeyPrefix = `channel_config:${provider}:`;
    const configKeys = await this.store.list(configKeyPrefix);
    const recoveryContext = await this.buildSyncContext({
      recovering: true,
      forActor: actorId,
      provider,
    });
    const dispatches: any[] = [];
    for (const key of configKeys) {
      const channelConfig = await this.store.get<ChannelConfig>(key);
      if (
        !channelConfig?.enabled ||
        channelConfig.enabledBy !== actorId
      ) {
        continue;
      }
      const channelId = key.slice(configKeyPrefix.length);
      const channel: Channel = {
        id: channelId,
        title: channelConfig.title ?? channelId,
      };
      const entry = await this.applyChannelEnabled(
        provider,
        actorId,
        channel,
        recoveryContext
      );
      if (entry) dispatches.push(entry);
    }
    return dispatches;
  }

  /**
   * Public entry point used by the recovery-pending cron. Synthesizes the
   * same recovery dispatches that re-auth would, without needing the user
   * to do anything. Returns the standard `{ __dispatch }` envelope so the
   * runtime processes the entries.
   */
  async recoverConnection(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<any> {
    const dispatches = await this.buildRecoveryDispatches(provider, actorId);
    if (dispatches.length === 0) return;
    return { __dispatch: dispatches } as any;
  }

  /**
   * Upsert discovered channels into public.channel. New channels land with
   * enabled=false; existing rows keep their enabled state and only get
   * title/link_types refreshed when the refresh provides non-null values.
   */
  private async mirrorChannelsToDb(channels: Channel[]): Promise<void> {
    const flat = this.flattenChannels(channels);
    if (flat.length === 0) return;
    const futureDate = new Date(Date.now() + 1);
    for (const channel of flat) {
      const linkTypesJson = channel.linkTypes
        ? JSON.stringify(channel.linkTypes)
        : null;
      await this.db
        .insertInto("channel")
        .values({
          twist_instance_id: this.twistInstanceId,
          channel_id: channel.id,
          title: channel.title ?? channel.id,
          enabled: false,
          link_types: linkTypesJson as any,
          updated_at: futureDate,
        })
        .onConflict((oc) => {
          const updateFields: Record<string, unknown> = { updated_at: futureDate };
          if (channel.title) updateFields.title = channel.title;
          if (linkTypesJson) updateFields.link_types = linkTypesJson;
          return oc
            .columns(["twist_instance_id", "channel_id"])
            .doUpdateSet(updateFields as any);
        })
        .execute();
    }
  }


  // ============================================================================
  // Source save operations (delegates to internal Plot instance)
  // ============================================================================

  /**
   * Get or create an internal Plot tool instance for save operations.
   * Sources use this to save threads/contacts without direct Plot access.
   * Twists are workspace-level so a single Plot instance is reused.
   */
  private _plot?: Plot;
  private getPlot(): Plot {
    if (!this._plot) {
      // Lazy import to avoid circular dependency at module load time
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { Plot: PlotClass } = require("./plot/index") as { Plot: typeof Plot };
      this._plot = new PlotClass({
        db: this.db,
        twistInstanceId: this.twistInstanceId,
        options: {
          thread: { access: 1 /* ThreadAccess.Create */ },
        },
        env: this.env,
      });
    }
    return this._plot!;
  }

  /**
   * Resolves the account-owner contact for this connector instance. The actor
   * is recorded in `twist_instance_connection` when the user completes OAuth
   * (see {@link handleAuthCallback}). Returns `null` when no connection has
   * been registered yet, or the contact row has been deleted.
   *
   * Cached per-instance; callers hitting `saveLink` in tight loops get one
   * round-trip per process rather than per thread.
   */
  async getAccountContact(): Promise<
    { id: ActorId; email: string; name: string | null } | null
  > {
    if (this._accountContact !== undefined) return this._accountContact;

    const row = await this.db
      .selectFrom("twist_instance_connection as tic")
      .innerJoin("contact as c", "c.id", "tic.actor_id")
      .select(["c.id", "c.email", "c.name"])
      .where("tic.twist_instance_id", "=", this.twistInstanceId)
      .where("c.email", "is not", null)
      .limit(1)
      .executeTakeFirst();

    this._accountContact = row?.email
      ? { id: row.id as ActorId, email: row.email, name: row.name ?? null }
      : null;
    return this._accountContact;
  }

  /**
   * Ensures the connector's account-owner contact is present on the thread's
   * accessContacts and on every note whose accessContacts is non-null. The
   * owner is implicitly a participant in everything we sync from their own
   * account, but connectors typically only see them when they appear in the
   * external item's recipients — mailing lists, aliases, and forwarded mail
   * don't surface the owner's address, and the resulting note would be
   * redacted by `user.note`'s access_contacts filter.
   *
   * Leaves `note.accessContacts === undefined` (unset) and
   * `note.accessContacts === null` untouched so connectors can still opt into
   * "inherit thread visibility" on a per-note basis.
   */
  private async injectAccountContact(link: NewLinkWithNotes): Promise<void> {
    const account = await this.getAccountContact();
    if (!account) return;

    const ownerContact: NewContact = {
      email: account.email,
      ...(account.name ? { name: account.name } : {}),
    };

    const emailLower = account.email.toLowerCase();
    const threadContacts = link.accessContacts ?? [];
    const alreadyOnThread = threadContacts.some(
      (c) => !!c.email && c.email.toLowerCase() === emailLower
    );
    if (!alreadyOnThread) {
      link.accessContacts = [...threadContacts, ownerContact];
    }

    if (!link.notes) return;
    for (const note of link.notes) {
      // `undefined` and `null` both mean "inherit thread visibility" — leave alone.
      if (note.accessContacts == null) continue;
      const alreadyOnNote = note.accessContacts.some((c) => {
        // ActorId is a branded string; NewContact is an object with email/name.
        if (typeof c === "string") return c === (account.id as string);
        const email = (c as NewContact).email;
        return !!email && email.toLowerCase() === emailLower;
      });
      if (!alreadyOnNote) {
        note.accessContacts = [...note.accessContacts, ownerContact];
      }
    }
  }

  /**
   * Saves a link with notes. Creates both a thread (container) and a link
   * (external entity). Priority resolution is delegated to
   * `prepareThreadForDb`, which routes via `match_priority_for_user` for the
   * twist owner when no explicit priority is given.
   */
  async saveLink(link: NewLinkWithNotes): Promise<Uuid | null> {
    // Filter initial-sync items by plan history limit.
    // unread === false is the reliable signal for initial sync (connector convention).
    if (link.unread === false) {
      const syncHistoryMin = await this.getSyncHistoryMin();
      if (syncHistoryMin) {
        const hasRecurrence = link.schedules?.some(s => s.recurrenceRule);
        if (!hasRecurrence) {
          // Determine the item's date from the first schedule start or link created
          const itemDate = this.extractLinkDate(link);
          if (itemDate && itemDate < syncHistoryMin) {
            return null;
          }
        }
      }
    }

    await this.injectAccountContact(link);

    const plot = this.getPlot();
    const threadId = await plot.createLink(link);

    // Propagate status tags to the thread
    await this.propagateLinkStatusTags(plot, threadId);

    // Create task schedule for assigned links
    await this.createTaskScheduleForLink(threadId);

    return threadId;
  }

  /**
   * Batch version of {@link saveLink}. Runs the saves concurrently inside the
   * worker (in bounded chunks) so the caller pays one cross-runtime round-trip
   * for N links instead of N. Order of the returned array matches the input.
   *
   * Failures on individual links DO NOT abort the batch: each failure is
   * logged and returned as `null` in its slot. Callers that need to know
   * how many succeeded can count non-null entries. This keeps one malformed
   * item from losing an entire page of synced data, which is the realistic
   * failure mode on large initial syncs from external providers.
   */
  async saveLinks(links: NewLinkWithNotes[]): Promise<(Uuid | null)[]> {
    if (links.length === 0) return [];
    // Bound concurrency so a 2,500-link page doesn't fan out to 2,500
    // simultaneous DB transactions. Kysely serializes on a single connection
    // anyway, but chunking provides isolation and back-pressure.
    const CHUNK = 10;
    const results: (Uuid | null)[] = new Array(links.length);
    for (let i = 0; i < links.length; i += CHUNK) {
      const chunk = links.slice(i, i + CHUNK);
      const settled = await Promise.allSettled(
        chunk.map((link) => this.saveLink(link))
      );
      for (let j = 0; j < settled.length; j++) {
        const r = settled[j];
        if (r.status === "fulfilled") {
          results[i + j] = r.value;
        } else {
          const source =
            (chunk[j] as { source?: string }).source ?? "(no source)";
          console.error(
            `saveLinks: link ${i + j} failed (source=${source}):`,
            r.reason
          );
          results[i + j] = null;
        }
      }
    }
    return results;
  }

  /**
   * Attaches a connector-returned link to an existing user-created thread.
   * Used by the `create_link` dispatch path: the user authored the thread in
   * Plot, the connector's `onCreateLink` created the external item, and the
   * runtime now links the two. Unlike `saveLink`, this never creates a new
   * thread — the thread already exists.
   *
   * Called as a `forwardTo` target. The `defaultChannelId` and `defaultType`
   * come from the originating `CreateLinkDraft` and are applied when the
   * connector omitted them on its returned link — this keeps downstream
   * rendering (status label lookup via channel-level `linkTypes`, etc.)
   * working without requiring every connector to remember to echo these
   * fields.
   */
  async saveCreatedLink(
    threadId: Uuid,
    defaultChannelId: string,
    defaultType: string,
    link: NewLinkWithNotes | null
  ): Promise<void> {
    if (!link) return;

    // Apply runtime defaults so the connector's return value stays focused on
    // external-system fields (external id, title, status, etc.).
    if (link.channelId === undefined || link.channelId === null) {
      (link as any).channelId = defaultChannelId;
    }
    if (link.type === undefined || link.type === null) {
      (link as any).type = defaultType;
    }

    // Look up twist_id so the thread can carry the connector branding and
    // participate in cross-user dedup if the same external item is seen
    // again via sync.
    const ptRow = await this.db
      .selectFrom("twist_instance")
      .select("twist_id")
      .where("id", "=", this.twistInstanceId)
      .executeTakeFirst();

    const updatedBy = -1; // twist-originated write
    const syncDepth = 1;

    const source = (link as any).source as string | undefined;
    const sourceCreatedAt = link.created instanceof Date
      ? link.created.toISOString()
      : (typeof link.created === "string" ? link.created : new Date().toISOString());

    // Update the thread row with twist_id, icon, and (if the link has a
    // source) a dedup key so future syncs upsert this thread instead of
    // creating a duplicate. Preserve the user-set title.
    if (ptRow) {
      const threadUpdate: Record<string, unknown> = {
        twist_id: ptRow.twist_id,
        icon: link.type
          ? `connector:${ptRow.twist_id}:${link.type}`
          : `connector:${ptRow.twist_id}`,
      };
      if (source) threadUpdate.key = link.relatedSource ?? source;
      await this.db
        .updateTable("thread")
        .set(threadUpdate as any)
        .where("id", "=", threadId as string)
        .execute();
    }

    const linkDefaults: Record<string, unknown> = {
      thread_id: threadId as string,
      created_by: this.twistInstanceId,
      author_id: this.twistInstanceId,
      updated_by: updatedBy,
      sync_depth: syncDepth,
      source_created_at: sourceCreatedAt,
      title: link.title ?? null,
      type: link.type ?? null,
      status: link.status ?? null,
      actions: (link.actions ?? null) as Json | null,
      meta: (link.meta ?? null) as Json | null,
      source_url: link.sourceUrl ?? null,
      channel_id: link.channelId ?? null,
    };

    if (source) {
      const linkUpsert: Record<string, unknown> = {
        source,
        thread_id: threadId as string,
        updated_by: updatedBy,
        sync_depth: syncDepth,
      };
      if (link.title !== undefined) linkUpsert.title = link.title;
      if (link.type !== undefined) linkUpsert.type = link.type;
      if (link.status !== undefined) linkUpsert.status = link.status;
      if (link.meta !== undefined) linkUpsert.meta = link.meta as Json | null;
      if (link.actions !== undefined) linkUpsert.actions = link.actions as Json | null;
      if (link.sourceUrl !== undefined) linkUpsert.source_url = link.sourceUrl;
      if (link.channelId !== undefined) linkUpsert.channel_id = link.channelId;
      if (link.relatedSource !== undefined) linkUpsert.related_source = link.relatedSource;

      const userId = await this.getPlot().getUserId();
      await rpcUser(this.db, "upsert_link", {
        user_id: userId,
        p_link: linkUpsert as Json,
        p_defaults: linkDefaults as Json,
      });
    } else {
      await this.db
        .insertInto("link")
        // @ts-ignore - Type mismatch between builder and actual values
        .values(linkDefaults)
        .execute();
    }

    // Propagate status tags, create task schedule for assignee, and notify.
    const plot = this.getPlot();
    await this.propagateLinkStatusTags(plot, threadId);
    await this.createTaskScheduleForLink(threadId);

    // Notify sync DOs so the user sees the link appear.
    try {
      const tp = await this.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", threadId as string)
        .executeTakeFirst();
      if (tp?.priority_id) {
        await plot.notifySyncDOs(new Set([tp.priority_id]));
      }
    } catch (error) {
      console.error("[saveCreatedLink] notifySyncDOs failed:", error);
    }
  }

  /**
   * Extracts the most relevant date from a link for sync history filtering.
   * Uses the first schedule's start time (for calendar events) or the
   * link's created date as fallback.
   */
  private extractLinkDate(link: NewLinkWithNotes): Date | null {
    // Prefer schedule start time (most relevant for calendar events)
    const scheduleStart = link.schedules?.[0]?.start;
    if (scheduleStart) {
      return typeof scheduleStart === "string" ? new Date(scheduleStart) : scheduleStart;
    }
    // Fall back to link created date
    if (link.created) {
      return link.created instanceof Date ? link.created : new Date(link.created);
    }
    return null;
  }

  /**
   * Saves contacts to the source's priority.
   * Delegates to an internal Plot instance.
   */
  async saveContacts(contacts: NewContact[]): Promise<Actor[]> {
    const plot = this.getPlot();
    return plot.addContacts(contacts);
  }

  /**
   * Archives links matching the given filter that were created by this source.
   * For each archived link's thread, if no other active links remain,
   * the thread is also archived. Notifies sync DOs for affected priorities.
   */
  async archiveLinks(filter: ArchiveLinkFilter): Promise<void> {
    const filterJson: Record<string, unknown> = {};
    if (filter.channelId !== undefined) filterJson.channelId = filter.channelId;
    if (filter.type !== undefined) filterJson.type = filter.type;
    if (filter.status !== undefined) filterJson.status = filter.status;
    if (filter.meta !== undefined) filterJson.meta = filter.meta;

    // Wrap in transaction so Hyperdrive sees the mutating RPC as a write
    const affectedPriorityIds = await this.db.transaction().execute(async (trx) => {
      return await rpc(trx, "archive_links", {
        p_created_by: this.twistInstanceId,
        // @ts-ignore - filterJson is valid JSON but Record<string, unknown> doesn't satisfy the strict Json type
        p_filter: filterJson,
      }) as unknown as string[] | null;
    });

    if (affectedPriorityIds && affectedPriorityIds.length > 0) {
      const plot = this.getPlot();
      await plot.notifySyncDOs(new Set(affectedPriorityIds));
    }
  }

  /**
   * Sets or clears todo status on a thread owned by this source.
   * Looks up the thread by source URL, then upserts or archives a per-user schedule.
   */
  async setThreadToDo(
    source: string,
    actorId: ActorId,
    todo: boolean,
    options?: { date?: Date | string }
  ): Promise<void> {
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });

    // Look up the link+thread by source URL and created_by
    const link = await this.db
      .selectFrom("link")
      .select(["id", "thread_id"])
      .where("source", "=", source)
      .where("created_by", "=", this.twistInstanceId)
      .executeTakeFirst();

    if (!link?.thread_id) {
      logger.warn(`setThreadToDo: no link found for source=${source}`);
      return;
    }

    // Resolve the user_id from the actorId (contact table)
    const contact = await this.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actorId)
      .executeTakeFirst();

    if (!contact?.user_id) {
      logger.warn(`setThreadToDo: no user_id for actorId=${actorId}`);
      return;
    }

    if (todo) {
      // Upsert a per-user schedule. With no explicit date, use the epoch
      // "Now" sentinel (1970-01-01) so the thread lands in the current
      // to-do bucket rather than being scheduled for a specific day.
      let dateStr: string;
      if (options?.date) {
        dateStr = typeof options.date === "string"
          ? options.date
          : options.date.toISOString().slice(0, 10);
      } else {
        dateStr = "1970-01-01";
      }

      const dbSchedule: Record<string, unknown> = {
        thread_id: link.thread_id,
        user_id: contact.user_id,
        on: `[${dateStr},)`,
      };

      await rpcUser(this.db, "upsert_schedule", {
        user_id: contact.user_id,
        p_schedule: dbSchedule as Json,
      });

      // Lift this user's per-user archive so the thread appears in their agenda.
      await this.db
        .updateTable("thread_priority")
        .set({ archived_at: null })
        .where("thread_id", "=", link.thread_id)
        .where("user_id", "=", contact.user_id)
        .where("archived_at", "is not", null)
        .execute();

      // Flip any done-status links (e.g. "archived") back to a non-done
      // status so the link widget stops saying "Archived" and Tag.Done is
      // cleared from the thread.
      try {
        await unarchiveDoneLinksOnThread(this.db, link.thread_id);
      } catch (error) {
        logger.warn("setThreadToDo: unarchiveDoneLinksOnThread failed", {
          thread_id: link.thread_id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    } else {
      // Archive the per-user schedule for this thread
      await this.db
        .updateTable("schedule")
        .set({ archived_at: new Date() })
        .where("thread_id", "=", link.thread_id)
        .where("user_id", "=", contact.user_id)
        .where("occurrence", "is", null)
        .where("archived_at", "is", null)
        .execute();
    }

    // Notify the user's sync DO so the Flutter client picks up the change
    // in real time. setThreadToDo is called from the twist runtime (e.g.
    // Gmail processing a star from its webhook); without this the user only
    // sees the update on the next scheduled pull.
    const tp = await this.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", link.thread_id)
      .where("user_id", "=", contact.user_id)
      .executeTakeFirst();
    if (tp?.priority_id) {
      try {
        await this.getPlot().notifySyncDOs(new Set([tp.priority_id]));
      } catch (error) {
        logger.error("setThreadToDo: failed to notify sync DOs", error as Error, {
          thread_id: link.thread_id,
        });
      }
    }
  }

  /**
   * Check if a link type+status represents completion.
   * Checks channel-level linkTypes first, falling back to twist-level.
   */
  private isStatusDone(
    type: string | null | undefined,
    status: string | null | undefined,
    channelLinkTypes?: LinkTypeConfig[]
  ): boolean {
    if (!type || !status) return false;

    // Check channel-level linkTypes first
    const sources = channelLinkTypes ?? this.providerConfigs.flatMap((p) => p.linkTypes ?? []);
    const typeConfig = sources.find((lt) => lt.type === type);
    if (!typeConfig?.statuses) return false;
    const statusDef = typeConfig.statuses.find((s) => s.status === status);
    return statusDef?.done === true;
  }

  /**
   * Create a task schedule for the assignee of a link, if applicable.
   * Queries the link row for assignee_id, resolves the contact's user_id,
   * creates a task schedule if non-done, and always recomputes outstanding_tasks.
   */
  private async createTaskScheduleForLink(
    threadId: Uuid
  ): Promise<void> {
    try {
      // Query the link to get the resolved assignee_id
      const dbLink = await this.db
        .selectFrom("link")
        .select(["assignee_id", "type", "status"])
        .where("thread_id", "=", threadId as string)
        .where("created_by", "=", this.twistInstanceId)
        .orderBy("updated_at", "desc")
        .executeTakeFirst();

      if (!dbLink?.assignee_id) return;

      // Resolve the contact's user_id
      const contact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", dbLink.assignee_id)
        .executeTakeFirst();

      if (!contact?.user_id) return;

      // Create schedule only if status is not done
      const channelLinkTypes = await this.getChannelLinkTypesForThread(threadId);
      if (!this.isStatusDone(dbLink.type, dbLink.status, channelLinkTypes.length > 0 ? channelLinkTypes : undefined)) {
        await createSchedule(this.db, contact.user_id, threadId as string, "task");
      } else {
        // Archive per-user task schedule when link status is done
        await this.db
          .updateTable("schedule")
          .set({ archived_at: new Date() })
          .where("thread_id", "=", threadId as string)
          .where("user_id", "=", contact.user_id)
          .where("reason", "=", "task")
          .where("occurrence", "is", null)
          .where("archived_at", "is", null)
          .execute();
      }

      // Always recompute outstanding_tasks (handles done→undone transitions)
      await sql`SELECT recompute_outstanding_tasks(${threadId}::uuid, ${contact.user_id}::uuid)`.execute(this.db);
    } catch (error) {
      console.error("[schedule] Failed to create task schedule from link assignment:", error);
    }
  }

  /**
   * Propagate status tags from link statuses to the parent thread.
   * Uses union semantics: a tag is present if ANY link on the thread (from this twist)
   * has a status that maps to that tag. Removes the tag only when no links contribute it.
   * Checks channel-level linkTypes first, falling back to twist-level.
   */
  private async propagateLinkStatusTags(
    plot: Plot,
    threadId: Uuid
  ): Promise<void> {
    // Collect all linkTypes — check channel-level first, then twist-level
    let allLinkTypes: LinkTypeConfig[] = await this.getChannelLinkTypesForThread(threadId);
    if (allLinkTypes.length === 0) {
      allLinkTypes = this.providerConfigs.flatMap(
        (p) => p.linkTypes ?? []
      );
    }
    if (allLinkTypes.length === 0) return;

    // Collect all possible tags from all status definitions
    const allPossibleTags = new Set<number>();
    for (const lt of allLinkTypes) {
      for (const s of lt.statuses ?? []) {
        if (s.tag !== undefined) allPossibleTags.add(s.tag);
      }
    }
    if (allPossibleTags.size === 0) return;

    // Query all links on this thread from this twist to compute union of contributed tags
    const siblingLinks = await this.db
      .selectFrom("link")
      .select(["type", "status"])
      .where("thread_id", "=", threadId as string)
      .where("created_by", "=", this.twistInstanceId)
      .execute();

    const contributedTags = new Set<number>();
    for (const sibling of siblingLinks) {
      const tag = this.getStatusTag(allLinkTypes, sibling.type, sibling.status);
      if (tag !== undefined) contributedTags.add(tag);
    }

    const updatedBy = plot.getUpdatedBy();
    const syncDepth = plot.syncDepth + 1;

    // Batch insert tags that should be present
    if (contributedTags.size > 0) {
      const tagValues = [...contributedTags].map((tagId) => ({
        thread_id: threadId as string,
        occurrence: null,
        tag_id: tagId,
        actor_id: this.twistInstanceId,
        updated_by: updatedBy,
        sync_depth: syncDepth,
      }));

      await this.db
        .insertInto("thread_tag")
        .values(tagValues)
        .onConflict((oc) =>
          oc
            .columns(["actor_id", "thread_id", "occurrence", "tag_id"])
            .doUpdateSet((eb) => ({
              updated_by: eb.ref("excluded.updated_by"),
              sync_depth: eb.ref("excluded.sync_depth"),
              archived_at: null,
            }))
        )
        .execute();
    }

    // Batch archive tags that are no longer contributed
    const tagsToArchive = [...allPossibleTags].filter((t) => !contributedTags.has(t));
    if (tagsToArchive.length > 0) {
      await this.db
        .updateTable("thread_tag")
        .set({ archived_at: new Date(), updated_by: updatedBy, sync_depth: syncDepth })
        .where("thread_id", "=", threadId as string)
        .where("actor_id", "=", this.twistInstanceId)
        .where("tag_id", "in", tagsToArchive)
        .where("archived_at", "is", null)
        .execute();
    }
  }

  /**
   * Look up the tag for a given link type + status from linkType configs.
   */
  private getStatusTag(
    linkTypes: LinkTypeConfig[],
    type: string | null | undefined,
    status: string | null | undefined
  ): number | undefined {
    if (!type || !status) return undefined;
    const typeConfig = linkTypes.find((lt) => lt.type === type);
    if (!typeConfig?.statuses) return undefined;
    const statusDef = typeConfig.statuses.find((s) => s.status === status);
    return statusDef?.tag;
  }

  /**
   * Look up channel-level linkTypes for a thread's links.
   * Queries the first link on this thread from this twist, resolves its channel_id,
   * then looks up link_types from channel.
   */
  private async getChannelLinkTypesForThread(threadId: Uuid): Promise<LinkTypeConfig[]> {
    const link = await this.db
      .selectFrom("link")
      .select("channel_id")
      .where("thread_id", "=", threadId as string)
      .where("created_by", "=", this.twistInstanceId)
      .where("channel_id", "is not", null)
      .limit(1)
      .executeTakeFirst();
    if (!link?.channel_id) return [];

    const channel = await this.db
      .selectFrom("channel")
      .select("link_types")
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("channel_id", "=", link.channel_id)
      .executeTakeFirst();
    if (!channel?.link_types) return [];

    try {
      const parsed = typeof channel.link_types === "string"
        ? JSON.parse(channel.link_types)
        : channel.link_types;
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  /**
   * Dispatch method called by the entrypoint when synced data changes.
   * Routes link updates to the appropriate source callback.
   */
  /**
   * Builds Note and Thread SDK objects from a raw note dispatch item,
   * looking up the connector's link metadata for thread context.
   */
  private async buildNoteAndThread(item: any): Promise<{ note: Note; thread: Thread }> {
    const link = await this.db
      .selectFrom("link")
      .select(["meta", "channel_id", "source"])
      .where("thread_id", "=", item.thread_id!)
      .where("created_by", "=", this.twistInstanceId)
      .executeTakeFirst();

    const note: Note = {
      id: item.id,
      created: item.created_at ? new Date(item.created_at) : new Date(),
      thread: {
        id: item.thread_id,
        title: item.thread_title,
        priority: { id: item.priority_id },
      } as any,
      author: {
        id: item.author_id ?? item.created_by,
        name: item.author_name,
        type:
          item.author_type === "user"
            ? ActorType.User
            : item.author_type === "twist_instance"
            ? ActorType.Twist
            : ActorType.Contact,
      },
      content: item.content,
      key: item.key || null,
      reNote: item.re_note_id ? { id: item.re_note_id } : null,
      mentions: item.mentions || [],
      tags: item.tags || {},
      accessContacts: (item.access_contacts as any) ?? null,
      archived: item.archived_at !== null,
      actions: item.actions,
    };

    const meta: ThreadMeta = { ...(link?.meta as any ?? {}) };
    meta.channelId = link?.channel_id ?? null;
    meta.linkSource = link?.source ?? null;

    // Resolve reNote key for reply targeting
    if (item.re_note_id) {
      const reNote = await this.db
        .selectFrom("note")
        .select("key")
        .where("id", "=", item.re_note_id)
        .executeTakeFirst();
      if (reNote?.key) {
        meta.reNoteKey = reNote.key;
      }
    }

    const thread: Thread = {
      id: item.thread_id,
      title: item.thread_title,
      priority: { id: item.priority_id },
      meta,
    } as Thread;

    return { note, thread };
  }

  async dispatch(
    dispatchItem: any
  ): Promise<Array<{ optionPath?: string[]; sourceMethod?: string; args: any[]; forwardTo?: { functionName: string; prependArgs: any[] }; deferredTagRemoval?: { noteId: string; actorId: string }; deferredNoteKeyUpdate?: { noteId: string } }>> {
    // Handle note dispatch for connectors with handleReplies — when a user
    // replies to a thread the connector created, the connector is auto-mentioned
    // but there's no Plot tool to handle intent matching or tag removal.
    // Route directly to onNoteCreated and defer tag removal.
    // Also handles note updates (tag changes) via onNoteUpdated.
    if (dispatchItem?.itemType === "note" && this.sourceProvider) {
      const { item, isCreate = true } = dispatchItem;
      if (!item) return [];

      const threadCreatedByThis = item.thread_created_by === this.twistInstanceId;

      // Note updates (tag changes, etc.) — route to onNoteUpdated
      // Unlike creates, updates to twist-created notes are expected (user adds tags
      // to synced messages), so we don't skip on created_by === twistInstanceId.
      if (!isCreate) {
        if (!threadCreatedByThis) return [];
        // Skip if any twist/connector made the update (prevent cross-connector loops).
        // Negative updated_by values indicate twist/API-originated writes.
        // Positive values indicate app client (user) writes.
        // Only dispatch onNoteUpdated for genuine user edits.
        if (typeof item.updated_by === "number" && item.updated_by <= 0) return [];

        const { note, thread } = await this.buildNoteAndThread(item);
        return [{
          sourceMethod: "onNoteUpdated",
          args: [note, thread],
          // The hook may return a NoteWriteBackResult whose externalContent
          // refreshes the sync baseline (so the next sync-in recognizes the
          // post-write external state and preserves Plot's updated content).
          deferredNoteKeyUpdate: { noteId: item.id as string },
        }];
      }

      // Skip notes created by this twist (prevent loops for new notes only)
      if (item.created_by === this.twistInstanceId) return [];

      const isMentioned = (item.mentions ?? []).includes(this.twistInstanceId);

      if (isMentioned && threadCreatedByThis) {
        const { note, thread } = await this.buildNoteAndThread(item);

        return [{
          sourceMethod: "onNoteCreated",
          args: [note, thread],
          deferredTagRemoval: {
            noteId: item.id as string,
            actorId: (item.author_id ?? item.created_by) as string,
          },
          deferredNoteKeyUpdate: { noteId: item.id as string },
        }];
      }

      return [];
    }

    // Handle channel_note dispatch — route to source's onNoteCreated
    if (dispatchItem?.itemType === "channel_note" && this.sourceProvider) {
      const { item, isCreate = true } = dispatchItem;
      if (!isCreate || !item) return [];

      // Skip notes created by this twist (prevent loops)
      if (item.created_by === this.twistInstanceId) return [];

      // Skip notes created by ANY twist/connector (prevent cross-connector loops).
      // Negative updated_by indicates twist-originated writes. Channel note dispatch
      // should only fire for user-created notes (replies typed in the app), not for
      // notes created by other connectors during sync.
      if (typeof item.updated_by === "number" && item.updated_by <= 0) return [];

      // Skip notes that mention this twist on threads it created —
      // these are already dispatched via the "note" (mention) path
      const isMentioned = (item.mentions ?? []).includes(this.twistInstanceId);
      const threadCreatedByThis = item.thread_created_by === this.twistInstanceId;
      if (isMentioned && threadCreatedByThis) return [];

      const note: Note = {
        id: item.id,
        created: item.created_at ? new Date(item.created_at) : new Date(),
        thread: {
          id: item.thread_id,
          title: item.thread_title,
          priority: { id: item.priority_id },
        } as any,
        author: {
          id: item.author_id ?? item.created_by,
          name: item.author_name,
          type:
            item.author_type === "user"
              ? ActorType.User
              : item.author_type === "twist_instance"
              ? ActorType.Twist
              : ActorType.Contact,
        },
        content: item.content,
        key: item.key || null,
        reNote: item.re_note_id ? { id: item.re_note_id } : null,
        mentions: item.mentions || [],
        tags: item.tags || {},
        accessContacts: (item.access_contacts as any) ?? null,
        archived: item.archived_at !== null,
        actions: item.actions,
      };

      // Build thread with meta populated from link metadata
      const meta: ThreadMeta = { ...(item.link_meta as any ?? {}) };
      meta.channelId = item.link_channel_id;
      meta.linkSource = item.link_source;

      // Resolve reNote key for reply targeting
      if (item.re_note_id) {
        const reNote = await this.db
          .selectFrom("note")
          .select("key")
          .where("id", "=", item.re_note_id)
          .executeTakeFirst();
        if (reNote?.key) {
          meta.reNoteKey = reNote.key;
        }
      }

      // Build a Thread object with meta populated for the onNoteCreated callback
      const thread = {
        id: item.thread_id,
        title: item.thread_title,
        priority: { id: item.priority_id },
        meta,
      };

      return [{ sourceMethod: "onNoteCreated", args: [note, thread], deferredNoteKeyUpdate: { noteId: item.id as string } }];
    }

    // Handle thread_schedule dispatch — route to connector's onThreadToDo.
    // The Plot-tool dispatch path requires plotOptions.thread.access, which
    // connectors don't declare, so dispatch from here for connector-owned threads.
    if (dispatchItem?.itemType === "thread_schedule" && this.sourceProvider) {
      const { item } = dispatchItem;
      if (!item?.thread_id) return [];

      // Only dispatch for threads this connector created
      const link = await this.db
        .selectFrom("link")
        .select(["meta", "channel_id", "source"])
        .where("thread_id", "=", item.thread_id as string)
        .where("created_by", "=", this.twistInstanceId)
        .executeTakeFirst();
      if (!link) return [];

      const threadRow = await this.db
        .selectFrom("thread")
        .select(["id", "title", "archived_at"])
        .where("id", "=", item.thread_id as string)
        .executeTakeFirst();
      if (!threadRow) return [];

      const meta: ThreadMeta = {
        ...((link.meta as Record<string, unknown>) ?? {}),
        channelId: link.channel_id ?? null,
        linkSource: link.source ?? null,
      } as ThreadMeta;

      // Resolve actor from the schedule's user_id via the user's primary linked contact
      let actor: Actor = {
        id: (item.user_id as ActorId) ?? ("" as ActorId),
        type: ActorType.User,
        name: null,
      };
      if (item.user_id) {
        const contact = await this.db
          .selectFrom("user_contact as uc")
          .innerJoin("contact as c", "c.id", "uc.contact_id")
          .select(["c.id", "c.name"])
          .where("uc.user_id", "=", item.user_id as string)
          .where("uc.linked", "=", true)
          .where("uc.primary", "=", true)
          .where("uc.archived_at", "is", null)
          .executeTakeFirst();
        if (contact) {
          actor = {
            id: contact.id as ActorId,
            name: contact.name ?? null,
            type: ActorType.User,
          };
        }
      }

      // todo=true if schedule is active (on/at set) and not archived; false
      // if cleared. Archived schedules are emitted by the view so connectors
      // learn when a thread leaves the agenda (e.g. to remove the Slack star).
      const todo =
        item.archived_at == null && (item.on != null || item.at != null);

      // Extract date from schedule's on (daterange) or at (tstzrange).
      // Only meaningful when todo=true; omit otherwise.
      let date: Date | undefined;
      if (todo) {
        if (item.on != null) {
          // daterange format: [start,end) — extract start date
          const match = String(item.on).match(/[[(](\d{4}-\d{2}-\d{2})/);
          if (match) date = new Date(match[1]);
        } else if (item.at != null) {
          // tstzrange format: ["start","end") — extract start timestamp
          const match = String(item.at).match(/[[("]([\d\-T:.+Z]+)/);
          if (match) date = new Date(match[1]);
        }
      }

      const thread: Partial<Thread> = {
        id: threadRow.id as Uuid,
        title: threadRow.title ?? "",
        archived: threadRow.archived_at !== null,
        meta,
      };

      return [{
        sourceMethod: "onThreadToDo",
        args: [thread, actor, todo, { date }],
      }];
    }

    // Handle schedule_contact dispatch — route to connector's onScheduleContactUpdated.
    // The Plot-tool dispatch path requires plotOptions.thread.access, which
    // connectors don't declare, so dispatch from here for connector-owned link schedules.
    if (dispatchItem?.itemType === "schedule_contact" && this.sourceProvider) {
      const { item } = dispatchItem;
      if (!item || item.archived_at) return [];

      // Only dispatch when the contact is one of the twist owner's linked contacts.
      // Other attendees' rows come from sync, not user action, and write-back only
      // makes sense for the user who connected the external account.
      const ownerLinked = await this.db
        .selectFrom("twist_instance as pt")
        .innerJoin("user_contact as uc", (join) =>
          join
            .onRef("uc.user_id", "=", "pt.owner_id")
            .on("uc.contact_id", "=", item.contact_id as string)
        )
        .select("pt.id")
        .where("pt.id", "=", this.twistInstanceId)
        .where("uc.linked", "=", true)
        .where("uc.archived_at", "is", null)
        .executeTakeFirst();
      if (!ownerLinked) return [];

      // Resolve link (and thread_id) for this schedule_contact. Link schedules
      // have schedule.thread_id = NULL, so we look up via link_id when available.
      let link = item.link_id
        ? await this.db
            .selectFrom("link")
            .select(["thread_id", "meta", "channel_id", "source"])
            .where("id", "=", item.link_id)
            .where("created_by", "=", this.twistInstanceId)
            .executeTakeFirst()
        : undefined;
      if (!link && item.thread_id) {
        link = await this.db
          .selectFrom("link")
          .select(["thread_id", "meta", "channel_id", "source"])
          .where("thread_id", "=", item.thread_id as string)
          .where("created_by", "=", this.twistInstanceId)
          .executeTakeFirst();
      }
      if (!link?.thread_id) return [];

      const threadRow = await this.db
        .selectFrom("thread")
        .select(["id", "title", "archived_at"])
        .where("id", "=", link.thread_id as string)
        .executeTakeFirst();
      if (!threadRow) return [];

      const meta: ThreadMeta = {
        ...((link.meta as Record<string, unknown>) ?? {}),
        channelId: link.channel_id ?? null,
        linkSource: link.source ?? null,
      } as ThreadMeta;

      const thread: Partial<Thread> = {
        id: threadRow.id as Uuid,
        title: threadRow.title ?? "",
        archived: threadRow.archived_at !== null,
        meta,
      };

      const actor: Actor = {
        id: item.contact_id as ActorId,
        type: ActorType.Contact,
        name: null,
      };

      return [{
        sourceMethod: "onScheduleContactUpdated",
        args: [thread, item.schedule_id, item.contact_id, item.status ?? null, actor],
      }];
    }

    // Handle create_link dispatch — user authored a thread in Plot marked to
    // create a new external item. Route to the connector's onCreateLink and
    // forward the returned link to saveCreatedLink to attach it to the
    // originating thread.
    if (dispatchItem?.itemType === "create_link" && this.sourceProvider) {
      const { threadId, draft } = dispatchItem as {
        threadId: string;
        draft: {
          channelId: string;
          type: string;
          status: string;
          title: string;
          noteContent: string | null;
          contacts: Array<{
            id: string;
            type: string;
            email: string | null;
            name: string | null;
          }>;
        };
      };
      if (!threadId || !draft) return [];
      // Pass the draft's channelId and type through forwardTo so
      // saveCreatedLink can default them on the returned link if the
      // connector omitted them. That way connectors don't have to remember
      // to echo channelId/type on every onCreateLink return — status label
      // resolution and other channel-scoped rendering would silently fail
      // otherwise.
      return [{
        sourceMethod: "onCreateLink",
        args: [draft],
        forwardTo: {
          functionName: "saveCreatedLink",
          prependArgs: [threadId, draft.channelId, draft.type],
        },
      } as any];
    }

    if (dispatchItem?.itemType !== "link" && dispatchItem?.itemType !== "channel_link") return [];

    // For channel_link creates, the connector itself created the link — no callback needed
    if (dispatchItem.itemType === "channel_link" && dispatchItem.isCreate) return [];

    const dbLink = dispatchItem.item;
    if (!dbLink) return [];

    // Convert DB link to SDK Link type
    const sdkLink = fromDbLink(dbLink);

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return [{ sourceMethod: "onLinkUpdated", args: [sdkLink] }];
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(
      (p) => p.onLinkUpdated
    );
    if (providerIndex < 0) return [];

    return [
      {
        optionPath: ["providers", String(providerIndex), "onLinkUpdated"],
        args: [sdkLink],
      },
    ];
  }

  // ============================================================================
  // Internal methods (called by API endpoints)
  // ============================================================================

  /**
   * Get a token directly for an actor (by actor ID).
   * Used internally and by API endpoints.
   */
  /**
   * Flag the user's twist_instance_connection so the UI can prompt them to
   * re-authenticate. Resolves user_id from the actor's contact row; orphan
   * contacts (no user_id) are skipped. Idempotent — repeated calls do not
   * overwrite an existing `needs_reauth_at`.
   *
   * Uses INSERT…ON CONFLICT so that connections with no existing
   * `twist_instance_connection` row (e.g. ones whose original
   * saveAuth-time write was lost or never ran) still get flagged.
   */
  private async flagNeedsReauth(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<void> {
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });
    try {
      const reauthContact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", actorId)
        .executeTakeFirst();

      if (!reauthContact?.user_id) {
        logger.debug(
          `Skipped needs_reauth_at: actor ${actorId} has no linked user_id`,
          { provider, actor_id: actorId }
        );
        return;
      }

      const now = new Date().toISOString();
      // Set both `needs_reauth_at` (UI prompt) and `recovery_pending`
      // (signals the next onChannelEnabled dispatch to pass `recovering:
      // true`). The two are linked but distinct: `needs_reauth_at` clears
      // when the user re-authenticates; `recovery_pending` clears when the
      // next sync dispatch consumes it. That way a user-toggle after an
      // auth gap gets the wipe-and-rewalk semantics for free.
      const result = await this.db
        .insertInto("twist_instance_connection")
        .values({
          twist_instance_id: this.twistInstanceId,
          user_id: reauthContact.user_id,
          provider,
          actor_id: actorId,
          connected_at: now,
          needs_reauth_at: now,
          recovery_pending: true,
        })
        .onConflict((oc) =>
          oc
            .columns(["twist_instance_id", "user_id", "provider"])
            .doUpdateSet({ needs_reauth_at: now, recovery_pending: true })
            .where("twist_instance_connection.needs_reauth_at", "is", null)
        )
        .executeTakeFirst();

      if ((result.numInsertedOrUpdatedRows ?? 0n) > 0n) {
        await notifyUserSyncByEnv(this.env, reauthContact.user_id);
      }
    } catch (dbError) {
      logger.warn(
        `Failed to set needs_reauth_at for ${provider} actor ${actorId}: ${(dbError as Error)?.message ?? String(dbError)}`,
        { provider, actor_id: actorId }
      );
    }
  }

  /**
   * Public re-auth signal for connectors. When a connector's API call comes
   * back with a permanent auth error (e.g. Slack `invalid_auth` /
   * `token_revoked`), call this with the channel id to surface the re-auth
   * prompt without waiting for the next refresh-token attempt to fail.
   *
   * Resolves the responsible actor from the channel config; no-op if the
   * channel is not configured or has no `enabledBy`.
   */
  async markNeedsReauth(channelId: string): Promise<void> {
    const provider = this.providerConfigs[0]?.provider;
    if (!provider) return;
    const config = await this.getChannelConfig(provider, channelId);
    if (!config?.enabledBy) return;
    await this.flagNeedsReauth(provider, config.enabledBy);
  }

  async getActorToken(provider: AuthProvider, actorId: ActorId): Promise<AuthToken | null> {
    // Direct lookup by provider + actor ID
    const tokenKey = `auth_token:${provider}:${actorId}`;
    let tokenData = await this.store.get<StoredTokenData>(tokenKey);
    let foundTokenKey = tokenKey;

    // Fallback: find a linked contact (same user_id) that has authed
    if (!tokenData) {
      const contact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", actorId)
        .executeTakeFirst();

      if (contact?.user_id) {
        const linkedContacts = await this.db
          .selectFrom("contact")
          .select("id")
          .where("user_id", "=", contact.user_id)
          .where("id", "!=", actorId)
          .execute();

        for (const linked of linkedContacts) {
          const linkedKey = `auth_token:${provider}:${linked.id}`;
          tokenData = await this.store.get<StoredTokenData>(linkedKey);
          if (tokenData) {
            foundTokenKey = linkedKey;
            break;
          }
        }
      }
    }

    if (!tokenData) {
      return null;
    }

    const config = PROVIDER_CONFIGS[provider];

    // Check if token is expired
    if (tokenData.expires_at && Date.now() > tokenData.expires_at) {
      // Token is expired, try to refresh if we have a refresh token
      if (tokenData.refresh_token && tokenData.client_id) {
        try {
          const refreshedToken = await this.refreshToken({
            clientId: tokenData.client_id,
            refreshToken: tokenData.refresh_token,
            provider,
          });

          // Update stored token - preserve providerData automatically
          const updatedToken: StoredTokenData = {
            client_id: tokenData.client_id,
            access_token: refreshedToken.access_token,
            refresh_token:
              refreshedToken.refresh_token || tokenData.refresh_token || null,
            scopes: tokenData.scopes,
            expires_at: refreshedToken.expires_in
              ? Date.now() + refreshedToken.expires_in * 1000
              : null,
            providerData: tokenData.providerData, // Preserved automatically
          };
          await this.store.set(foundTokenKey, updatedToken);

          return {
            token: refreshedToken.access_token,
            scopes: tokenData.scopes,
            provider: tokenData.providerData
              ? config?.extractMetadata?.(tokenData.providerData)
              : undefined,
          };
        } catch (error) {
          const logger = createLogger({ twist_instance_id: this.twistInstanceId });
          const refreshErr =
            error instanceof TokenRefreshError ? error : null;
          const reason = refreshErr
            ? `${refreshErr.message}${refreshErr.oauthError ? ` [${refreshErr.oauthError}]` : ""}`
            : (error as Error)?.message ?? String(error);

          if (refreshErr?.permanent) {
            logger.warn(
              `OAuth refresh permanently failed for ${provider} actor ${actorId}: ${reason}`,
              {
                provider,
                actor_id: actorId,
                status: refreshErr.status,
                oauth_error: refreshErr.oauthError,
              }
            );
            // Refresh_token is genuinely dead — user must re-authenticate.
            await this.store.clear(foundTokenKey);
            await this.flagNeedsReauth(provider, actorId);
            return null;
          }

          // Transient failure (5xx, 429, 408, network error, unknown shape).
          // Preserve the token so the next webhook / sync can retry.
          logger.warn(
            `OAuth refresh transiently failed for ${provider} actor ${actorId}: ${reason}; will retry`,
            {
              provider,
              actor_id: actorId,
              status: refreshErr?.status,
              oauth_error: refreshErr?.oauthError,
            }
          );
          if (!refreshErr) {
            // Unexpected error shape (not a TokenRefreshError). Surface it so
            // we notice if a new failure mode slips through this classifier.
            logger.error(
              "Unexpected error shape from refreshToken",
              error as Error,
              { provider, actor_id: actorId }
            );
          }
          return null;
        }
      }

      // No refresh token available — token is unrecoverable; clear it so the
      // user sees an explicit re-auth prompt rather than a silent expired token.
      await this.store.clear(foundTokenKey);
      await this.flagNeedsReauth(provider, actorId);
      return null;
    }

    return {
      token: tokenData.access_token,
      scopes: tokenData.scopes,
      provider: tokenData.providerData
        ? config?.extractMetadata?.(tokenData.providerData)
        : undefined,
    };
  }

  /**
   * Resolve the user_id that owns a given (provider, channelId) — i.e. the
   * actor that enabled the channel. Migration fallback finds any actor with
   * a stored token for the provider when no channel_config exists.
   * Returns null when no user mapping exists (key-based connectors).
   */
  private async resolveChannelUser(
    provider: AuthProvider,
    channelId: string
  ): Promise<{ userId: string } | null> {
    const config = await this.getChannelConfig(provider, channelId);
    let actorId: ActorId | undefined = config?.enabled
      ? (config.enabledBy as ActorId | undefined)
      : undefined;

    if (!actorId) {
      const tokenKeys = await this.store.list(`auth_token:${provider}:`);
      for (const key of tokenKeys) {
        const candidate = key.slice(`auth_token:${provider}:`.length) as ActorId;
        if (candidate) {
          actorId = candidate;
          break;
        }
      }
    }

    if (!actorId) return null;

    const contact = await this.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actorId)
      .executeTakeFirst();

    if (!contact?.user_id) return null;
    return { userId: contact.user_id };
  }

  /**
   * Stamp the connection as initially syncing for the user who enabled the
   * channel. Re-stamps `started_at = now` (no coalesce) so a recovery
   * dispatch resets the "syncing since" timestamp instead of preserving
   * an ancient prior value. Clears any prior `completed_at` so the UI
   * shows the spinner again.
   *
   * Called automatically by {@link applyChannelEnabled}. Connectors do not
   * call this directly.
   */
  private async markChannelSyncStarted(
    provider: AuthProvider,
    channelId: string
  ): Promise<void> {
    const resolved = await this.resolveChannelUser(provider, channelId);
    if (!resolved) return;

    const logger = createLogger({ twist_instance_id: this.twistInstanceId });
    try {
      const nowIso = new Date().toISOString();
      const result = await this.db
        .updateTable("twist_instance_connection")
        .set({
          initial_sync_started_at: nowIso,
          initial_sync_completed_at: null,
        })
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where("user_id", "=", resolved.userId)
        .where("provider", "=", provider)
        .executeTakeFirst();
      if ((result.numUpdatedRows ?? 0n) > 0n) {
        await notifyUserSyncByEnv(this.env, resolved.userId);
      }
    } catch (dbError) {
      logger.warn(
        `Failed to mark sync started for ${provider} channel ${channelId}: ${(dbError as Error)?.message ?? String(dbError)}`,
        { provider, channel_id: channelId }
      );
    }
  }

  /**
   * Connector-facing API: signal that the initial backfill (or recovery
   * sync) for a channel has fully completed. Stamps
   * `initial_sync_completed_at` so the Flutter app clears the syncing
   * indicator. Idempotent. No-op when the channel has no user mapping.
   */
  async channelSyncCompleted(channelId: string): Promise<void> {
    const provider = this.providerConfigs[0]?.provider;
    if (!provider) return;
    await this.clearChannelSyncing(provider, channelId);
  }

  /**
   * Internal: invoked by the dispatch failure handler when
   * `onChannelEnabled` throws. Clears the syncing state so the UI doesn't
   * get stuck on "syncing" forever after an unhandled exception.
   *
   * Connectors should not call this directly; see {@link channelSyncCompleted}
   * for the success path.
   */
  async __failChannelSync(provider: AuthProvider, channelId: string): Promise<void> {
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });
    logger.warn(
      `onChannelEnabled threw for ${provider} channel ${channelId}; clearing syncing state`,
      { provider, channel_id: channelId }
    );
    await this.clearChannelSyncing(provider, channelId);
  }

  /**
   * Stamp `initial_sync_completed_at = now` for the connection that owns
   * the given channel. Only stamps when a sync actually started and
   * hasn't already been marked complete (idempotent). Shared between the
   * success path (`channelSyncCompleted`) and the failure path
   * (`__failChannelSync`).
   */
  private async clearChannelSyncing(
    provider: AuthProvider,
    channelId: string
  ): Promise<void> {
    const resolved = await this.resolveChannelUser(provider, channelId);
    if (!resolved) return;

    const logger = createLogger({ twist_instance_id: this.twistInstanceId });
    try {
      const nowIso = new Date().toISOString();
      const result = await this.db
        .updateTable("twist_instance_connection")
        .set({ initial_sync_completed_at: nowIso })
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where("user_id", "=", resolved.userId)
        .where("provider", "=", provider)
        .where("initial_sync_started_at", "is not", null)
        .where("initial_sync_completed_at", "is", null)
        .executeTakeFirst();
      if ((result.numUpdatedRows ?? 0n) > 0n) {
        await notifyUserSyncByEnv(this.env, resolved.userId);
      }
    } catch (dbError) {
      logger.warn(
        `Failed to clear syncing state for ${provider} channel ${channelId}: ${(dbError as Error)?.message ?? String(dbError)}`,
        { provider, channel_id: channelId }
      );
    }
  }

  /**
   * Handle OAuth callback after token exchange.
   * Called by the OAuth callback handler.
   */
  async onAuth(
    tokenInfo: {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
      provider: AuthProvider;
      scopes: string[];
      client_id: string;
      // Raw provider response data (will be parsed)
      [key: string]: any;
    },
    callbackToken?: Callback
  ): Promise<void> {
    const config = PROVIDER_CONFIGS[tokenInfo.provider];

    // Parse provider-specific data if handler exists (may be async)
    const providerData =
      (await config?.parseTokenResponse?.(tokenInfo)) ?? null;

    // Extract email from providerData and link to contact, building actor.
    // For providers that don't surface an email (e.g. Slack user-token-only
    // OAuth), fall back to the provider's user id so buildActor can dedupe
    // the auth to a single contact linked to the twist_instance owner.
    const email = this.extractEmail(providerData);
    const providerUserId = extractUserId(tokenInfo.provider, providerData);
    let actor: Actor;
    try {
      actor = await this.buildActor(email, tokenInfo.provider, providerUserId);
    } catch (error) {
      throw error;
    }

    // buildActor may return a synthetic UUID when it can't resolve to a real
    // contact row (no email, missing owner, error path). Look up the contact
    // once so we only attempt FK-bound writes when actor.id is a real row.
    const contact = await this.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actor.id)
      .executeTakeFirst();

    // Store provider ID mapping for source-based contact lookup
    if (providerUserId && contact) {
      try {
        await this.db
          .insertInto("contact_external_account")
          .values({
            contact_id: actor.id,
            provider: tokenInfo.provider,
            account_id: providerUserId,
            data_fetched_at: new Date().toISOString(),
          })
          .onConflict((oc) =>
            oc.columns(["provider", "account_id"]).doUpdateSet((eb) => ({
              contact_id: eb.ref("excluded.contact_id"),
              data_fetched_at: eb.ref("excluded.data_fetched_at"),
            }))
          )
          .execute();
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Failed to store provider mapping", error as Error);
      }
    }

    // Store token keyed by provider + actor ID. Providers like Slack that
    // return the effective access token under a nested field (e.g.
    // authed_user.access_token for user-scoped apps) remap it here.
    const effectiveAccessToken =
      config?.extractAccessToken?.(tokenInfo) ?? tokenInfo.access_token;
    const tokenKey = `auth_token:${tokenInfo.provider}:${actor.id}`;
    const token: StoredTokenData = {
      client_id: tokenInfo.client_id,
      access_token: effectiveAccessToken,
      refresh_token: tokenInfo.refresh_token ?? null,
      scopes: tokenInfo.scopes,
      expires_at: tokenInfo.expires_in
        ? Date.now() + tokenInfo.expires_in * 1000
        : null,
      providerData,
    };
    await this.store.set(tokenKey, token);

    // Store enabled scope groups if present in the auth state
    const authStateKey = `auth_state:${tokenInfo.provider}`;
    const authState = await this.store.get<AuthState>(authStateKey);
    if (authState?.enabledScopeGroups) {
      await this.store.set(
        `enabled_scope_groups:${tokenInfo.provider}:${actor.id}`,
        authState.enabledScopeGroups
      );
    }

    // Record user connection for per-user connection tracking. Successful
    // (re-)auth also clears any prior `needs_reauth_at` flag so the UI's
    // "needs reauth" prompt disappears immediately.
    //
    // We also capture whether `needs_reauth_at` was set on the prior row.
    // When it was, this is a recovery dispatch — the connection had been
    // broken and the user just re-authorized. After the row is updated we
    // dispatch `onChannelEnabled` for every channel that was already
    // enabled, with `recovering: true` in the SyncContext, so the
    // connector drops stale cursors and re-walks history.
    let isRecovery = false;
    if (contact?.user_id) {
      try {
        // Capture the previous actor_id (if any) so we can migrate
        // channel_config.enabledBy below — re-authing with a different
        // linked email would otherwise leave channels owned by the
        // now-invalid old actor, and the next sync would re-flag reauth.
        const previousRow = await this.db
          .selectFrom("twist_instance_connection")
          .select(["actor_id", "needs_reauth_at"])
          .where("twist_instance_id", "=", this.twistInstanceId)
          .where("user_id", "=", contact.user_id)
          .where("provider", "=", tokenInfo.provider)
          .executeTakeFirst();
        const previousActorId = previousRow?.actor_id ?? null;
        isRecovery = previousRow?.needs_reauth_at != null;

        await this.db
          .insertInto("twist_instance_connection")
          .values({
            twist_instance_id: this.twistInstanceId,
            user_id: contact.user_id,
            provider: tokenInfo.provider,
            actor_id: actor.id,
            connected_at: new Date().toISOString(),
          })
          .onConflict((oc) =>
            oc
              .columns(["twist_instance_id", "user_id", "provider"])
              .doUpdateSet({
                actor_id: actor.id,
                connected_at: new Date().toISOString(),
                needs_reauth_at: null,
              })
          )
          .execute();

        // If actor_id changed (re-auth with a different linked email),
        // migrate channel_config.enabledBy from any of this user's
        // contacts to the new actor so subsequent token lookups hit the
        // freshly stored token instead of the cleared one.
        if (previousActorId && previousActorId !== actor.id) {
          try {
            const userContacts = await this.db
              .selectFrom("contact")
              .select("id")
              .where("user_id", "=", contact.user_id)
              .execute();
            const userContactIds = new Set(userContacts.map((r) => r.id));
            const configKeys = await this.store.list(
              `channel_config:${tokenInfo.provider}:`
            );
            for (const key of configKeys) {
              const channelConfig = await this.store.get<ChannelConfig>(key);
              if (
                channelConfig?.enabledBy &&
                channelConfig.enabledBy !== actor.id &&
                userContactIds.has(channelConfig.enabledBy)
              ) {
                await this.store.set(key, {
                  ...channelConfig,
                  enabledBy: actor.id,
                });
              }
            }
          } catch (error) {
            const logger = createLogger({ twist_instance_id: this.twistInstanceId });
            logger.warn(
              `Failed to migrate channel_config.enabledBy from ${previousActorId} to ${actor.id}: ${(error as Error)?.message ?? String(error)}`,
              { provider: tokenInfo.provider }
            );
          }
        }

        await notifyUserSyncByEnv(this.env, contact.user_id);
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Failed to record twist_instance_connection", error as Error);
      }
    }

    // Populate twist_instance.account_label from per-provider metadata so the
    // Connections UI and composed actor display name (notes/mentions) get a
    // disambiguating label without a client-side round-trip. Only write when
    // currently null so a user-set label is never overwritten.
    const accountLabel = providerData
      ? (config?.extractAccountLabel?.(providerData) ?? null)
      : null;
    if (accountLabel) {
      try {
        await this.db
          .updateTable("twist_instance")
          .set({ account_label: accountLabel })
          .where("id", "=", this.twistInstanceId)
          .where("account_label", "is", null)
          .execute();
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Failed to set account_label", error as Error);
      }
    }

    // Create Authorization object
    const authorization: Authorization = {
      provider: tokenInfo.provider,
      scopes: tokenInfo.scopes,
      actor,
    };

    // 1. Process pending actAs requests for this provider + actor
    const pendingKey = `pending_auth:${tokenInfo.provider}:${actor.id}`;
    const pendingRequests = await this.store.get<PendingActAs[]>(pendingKey);

    if (pendingRequests && pendingRequests.length > 0) {
      const authToken = await this.getActorToken(tokenInfo.provider, actor.id as ActorId);
      if (authToken) {
        for (const pending of pendingRequests) {
          try {
            // Call the stored callback with the token
            using _result = await this.callbacks.callCallback(
              pending.callbackToken,
              authToken
            );
          } catch (error) {
            const logger = createLogger({ twist_instance_id: this.twistInstanceId });
            logger.error("Error executing pending actAs callback", error as Error, {
              provider: tokenInfo.provider,
              actor_id: actor.id,
            });
          }
        }
      }
      // Clean up pending requests
      await this.store.clear(pendingKey);
    }

    // 2. Call legacy callback token if provided (for backward compat / direct request() calls)
    if (callbackToken) {
      try {
        using _result = await this.callbacks.callCallback(
          callbackToken,
          authorization
        );
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Error executing original auth callback", error as Error, {
          provider: tokenInfo.provider,
          actor_id: actor.id,
        });
      }
    }

    // 3. Return dispatch for getChannels — called locally by entrypoint with proper this binding,
    // result forwarded to setChannels via forwardTo directive.
    //
    // On recovery (the prior row had `needs_reauth_at` set), also dispatch
    // `onChannelEnabled` for every channel that was already enabled by this
    // actor with `recovering: true` in the SyncContext. This signals the
    // connector to drop persisted incremental cursors / sync tokens and
    // re-walk history so events that changed during the auth gap aren't
    // missed. Each dispatch entry is wrapped through {@link applyChannelEnabled}
    // so it gets the same auto-failure handling as a fresh enable.
    const authToken: AuthToken = {
      token: token.access_token,
      scopes: token.scopes,
    };
    const forwardTo = {
      functionName: "setChannels",
      prependArgs: [tokenInfo.provider, actor.id],
    };

    const recoveryDispatches: any[] = [];
    if (isRecovery) {
      try {
        recoveryDispatches.push(
          ...(await this.buildRecoveryDispatches(
            tokenInfo.provider,
            actor.id as ActorId
          ))
        );
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn(
          `Failed to build recovery dispatches for ${tokenInfo.provider} actor ${actor.id}: ${(error as Error)?.message ?? String(error)}`,
          { provider: tokenInfo.provider, actor_id: actor.id }
        );
      }
    }

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return {
        __dispatch: [
          {
            sourceMethod: "getChannels",
            args: [authorization, authToken],
            forwardTo,
          },
          ...recoveryDispatches,
        ],
      } as any;
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(
      p => p.provider === tokenInfo.provider
    );
    if (providerIndex >= 0) {
      return {
        __dispatch: [
          {
            optionPath: ["providers", providerIndex, "getChannels"],
            args: [authorization, authToken],
            forwardTo,
          },
          ...recoveryDispatches,
        ],
      } as any;
    }
  }

  /**
   * Remove an actor's auth for a provider.
   * Handles channel reassignment and calls onRemoved.
   */
  async removeAuth(provider: AuthProvider, actorId: ActorId): Promise<void> {
    const tokenKey = `auth_token:${provider}:${actorId}`;

    // Handle channels this actor enabled (flatten tree to check all levels)
    const actorChannelsTree = await this.getChannelAccess(provider, actorId);
    const actorChannels = this.flattenChannels(actorChannelsTree);

    // Accumulate dispatch entries for callbacks that need to run on the twist worker
    const dispatches: Array<{ optionPath?: (string | number)[]; sourceMethod?: string; args: any[] }> = [];
    const useSourceMethod = !!this.sourceProvider;
    const providerIndex = useSourceMethod ? -1 : this.providerConfigs.findIndex(p => p.provider === provider);
    const syncContext = await this.buildSyncContext();

    for (const channel of actorChannels) {
      const channelConfig = await this.getChannelConfig(provider, channel.id);

      if (channelConfig?.enabled && channelConfig.enabledBy === actorId) {
        // This actor enabled this channel - need to reassign or disable
        const newOwner = await this.findAlternateOwner(provider, channel.id, actorId);
        const configKey = `channel_config:${provider}:${channel.id}`;

        if (newOwner) {
          // Reassign: disable with old owner, enable with new
          if (useSourceMethod) {
            dispatches.push({ sourceMethod: "onChannelDisabled", args: [channel] });
          } else if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", String(providerIndex), "onChannelDisabled"],
              args: [channel],
            });
          }

          await this.store.set(configKey, {
            enabled: true,
            enabledBy: newOwner,
            title: channel.title,
          } satisfies ChannelConfig);

          if (useSourceMethod) {
            dispatches.push({ sourceMethod: "onChannelEnabled", args: [channel, syncContext] });
          } else if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", String(providerIndex), "onChannelEnabled"],
              args: [channel, syncContext],
            });
          }
        } else {
          // No alternate owner - disable
          if (useSourceMethod) {
            dispatches.push({ sourceMethod: "onChannelDisabled", args: [channel] });
          } else if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", String(providerIndex), "onChannelDisabled"],
              args: [channel],
            });
          }

          await this.store.set(configKey, {
            enabled: false,
            title: channel.title,
          } satisfies ChannelConfig);
        }
      }
    }

    // Delete auth token and channel access
    await this.store.clear(tokenKey);
    await this.store.clear(`channel_access:${provider}:${actorId}`);

    // Remove user connection record
    try {
      await this.db
        .deleteFrom("twist_instance_connection")
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where("actor_id", "=", actorId)
        .where("provider", "=", provider)
        .execute();
    } catch (error) {
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.error("Failed to remove twist_instance_connection", error as Error);
    }
    // Clean up old key if it exists
    await this.store.clear(`syncable_access:${provider}:${actorId}`);

    // Return dispatch info for the entrypoint to invoke locally
    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  /**
   * Enable sync for a channel.
   * Called from API endpoint when user toggles sync on.
   */
  async enableSync(
    provider: AuthProvider,
    channelId: string,
    actorId: ActorId,
    title?: string
  ): Promise<void> {
    // Find the channel from the actor's channel access list
    const channels = await this.getChannelAccess(provider, actorId);
    const channelObj = this.findChannelInTree(channels, channelId);
    if (!title) {
      title = channelObj?.title;
    }

    // Extract per-channel linkTypes if available.
    // Fall back to existing channel rows for the same channel_id
    // (handles re-add after archive, where KV may not have been populated yet).
    let linkTypes = channelObj?.linkTypes ?? null;
    if (!linkTypes) {
      const existingChannel = await this.db
        .selectFrom("channel")
        .select("link_types")
        .where("channel_id", "=", channelId)
        .where("link_types", "is not", null)
        .limit(1)
        .executeTakeFirst();
      if (existingChannel?.link_types) {
        try {
          linkTypes = typeof existingChannel.link_types === "string"
            ? JSON.parse(existingChannel.link_types)
            : existingChannel.link_types;
        } catch { /* ignore parse errors */ }
      }
    }

    // Self-heal: if the channel isn't in channel_access KV at all, prepend a
    // getChannels → setChannels dispatch to populate it. This runs before
    // onChannelEnabled on the same request, so setChannels updates title +
    // link_types on the row we just inserted.
    //
    // We only refresh when the channel is genuinely missing (no title from
    // KV and no caller-supplied title). Per-channel linkTypes being null is
    // not a trigger — most connectors expose linkTypes at the provider level
    // only, so a refresh would not populate them anyway. Previously we
    // refreshed on missing linkTypes too, which re-invoked getChannels on
    // every enable for nearly every connector — for Google Drive that
    // paginates every folder across every drive inline and blocks the HTTP
    // response for many seconds. See commit adding this note.
    const refreshDispatch = !channelObj?.title
      ? await this.buildRefreshDispatch(provider, actorId)
      : null;

    // Delegate to applyChannelEnabled so this path gets the same syncing-
    // state stamp and onFailure handler as setChannels/onAuth. Without this,
    // the Flutter app never sees `initial_syncing` flip true and the
    // ConnectionStatusTile spinner never appears for user-initiated enables.
    //
    // Pass `forActor` + `provider` so the connection's `recovery_pending`
    // flag (set by `flagNeedsReauth` after an auth gap) is consumed and
    // turned into `recovering: true` on this dispatch — the user toggling
    // a channel after fixing auth gets a clean re-sync without having to
    // disconnect/reconnect.
    const syncContext = await this.buildSyncContext({
      forActor: actorId,
      provider,
    });
    const channel: Channel = {
      id: channelId,
      title: title ?? channelId,
      ...(linkTypes ? { linkTypes } : {}),
    };
    const enableEntry = await this.applyChannelEnabled(
      provider,
      actorId,
      channel,
      syncContext
    );

    const dispatches: any[] = [];
    if (refreshDispatch) dispatches.push(refreshDispatch);
    if (enableEntry) dispatches.push(enableEntry);
    if (dispatches.length > 0) return { __dispatch: dispatches } as any;
  }

  /**
   * Disable sync for a channel.
   * Called from API endpoint when user toggles sync off.
   */
  async disableSync(
    provider: AuthProvider,
    channelId: string
  ): Promise<void> {
    const existing = await this.getChannelConfig(provider, channelId);

    await this.store.set(`channel_config:${provider}:${channelId}`, {
      enabled: false,
      title: existing?.title ?? null,
    } satisfies ChannelConfig);

    // Write to channel DB table (dual-write with KV)
    await this.db
      .updateTable("channel")
      .set({ enabled: false, updated_at: new Date() })
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("channel_id", "=", channelId)
      .execute();

    // Return dispatch info for onChannelDisabled callback.
    // The entrypoint will invoke this locally on the twist worker with proper this binding.
    const channelArg = { id: channelId, title: existing?.title ?? channelId };

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return {
        __dispatch: [{ sourceMethod: "onChannelDisabled", args: [channelArg] }],
      } as any;
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex >= 0) {
      return {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "onChannelDisabled"],
          args: [channelArg],
        }],
      } as any;
    }
  }

  /**
   * Get all integration data for the edit modal.
   * Returns accounts, providers, and channels.
   */
  async getIntegrationData(currentActorId?: ActorId): Promise<{
    providers: Array<{ provider: AuthProvider; scopes: string[]; optionalScopes?: any[] }>;
    accounts: Array<{
      provider: AuthProvider;
      actorId: ActorId;
      email: string | null;
      name: string | null;
      autoEnableNewChannels: boolean;
      enabledScopeGroups?: string[];
    }>;
    syncables: Array<{
      provider: AuthProvider;
      id: string;
      title: string;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      currentUserHasAccess: boolean;
      children?: Array<{
        provider: AuthProvider;
        id: string;
        title: string;
        enabled: boolean;
        enabledBy: ActorId | undefined;
        currentUserHasAccess: boolean;
        children?: any[];
      }>;
    }>;
  }> {
    const providers = this.providerConfigs.map(p => ({
      provider: p.provider,
      scopes: p.scopes,
      ...(p.optionalScopes ? { optionalScopes: p.optionalScopes } : {}),
    }));

    // Resolve all contact IDs belonging to the current user so we can
    // correctly mark currentUserHasAccess for linked contacts.
    const currentUserContactIds = new Set<string>();
    if (currentActorId) {
      currentUserContactIds.add(currentActorId);
      const currentContact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", currentActorId)
        .executeTakeFirst();
      if (currentContact?.user_id) {
        const linkedContacts = await this.db
          .selectFrom("contact")
          .select("id")
          .where("user_id", "=", currentContact.user_id)
          .execute();
        for (const c of linkedContacts) {
          currentUserContactIds.add(c.id);
        }
      }
    }

    // Collect accounts by scanning auth_token keys
    const accounts: Array<{
      provider: AuthProvider;
      actorId: ActorId;
      email: string | null;
      name: string | null;
      autoEnableNewChannels: boolean;
      enabledScopeGroups?: string[];
    }> = [];

    // Track which channel IDs have access from any current-user contact
    const channelAccessByCurrentUser = new Set<string>();

    // Collect channel trees per provider (merged across actors)
    type AnnotatedChannel = {
      provider: AuthProvider;
      id: string;
      title: string;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      linkTypes?: LinkTypeConfig[];
      currentUserHasAccess: boolean;
      children?: AnnotatedChannel[];
    };

    const channelTreesByProvider = new Map<AuthProvider, Channel[]>();

    for (const providerConfig of this.providerConfigs) {
      const provider = providerConfig.provider;

      // Find all actors with tokens for this provider by scanning stored keys
      const tokenKeys = await this.store.list(`auth_token:${provider}:`);
      const knownActorIds = new Set<string>();

      for (const key of tokenKeys) {
        // Parse "auth_token:{provider}:{actorId}"
        const parts = key.split(":");
        if (parts.length >= 3) {
          knownActorIds.add(parts.slice(2).join(":"));
        }
      }

      // Build accounts and collect channel trees
      for (const actorId of knownActorIds) {
        const tokenKey = `auth_token:${provider}:${actorId}`;
        const tokenData = await this.store.get<StoredTokenData>(tokenKey);
        const email = tokenData ? this.extractEmail(tokenData.providerData) : null;

        // Look up contact user_id for self-healing below; contact.name is
        // intentionally NOT used as the account label — it's the connected
        // person's display name, not the workspace/account disambiguator the
        // modal is trying to show.
        let contactUserId: string | null = null;
        if (actorId) {
          const contact = await this.db
            .selectFrom("contact")
            .select("user_id")
            .where("id", "=", actorId)
            .executeTakeFirst();
          contactUserId = contact?.user_id ?? null;
        }

        // Prefer the provider-level account label (Slack workspace, Notion
        // workspace, Atlassian site, …) — it's the useful disambiguator for
        // "which connection is this?". For providers that only expose an
        // email (Google, Microsoft) the email is surfaced separately below.
        // For providers whose `extractAccountLabel` returns the email we also
        // reuse it as the label so the UI shows something.
        const name: string | null = tokenData?.providerData
          ? (PROVIDER_CONFIGS[provider]?.extractAccountLabel?.(
              tokenData.providerData
            ) ?? null)
          : null;

        // Look up stored scope group selections
        const enabledScopeGroups = await this.store.get<string[]>(
          `enabled_scope_groups:${provider}:${actorId}`
        );

        const autoEnableNewChannels =
          (await this.store.get<boolean>(
            `auto_enable_new_channels:${provider}:${actorId}`
          )) ?? false;

        accounts.push({
          provider,
          actorId: actorId as ActorId,
          email,
          name,
          autoEnableNewChannels,
          ...(enabledScopeGroups ? { enabledScopeGroups } : {}),
        });

        // Get this actor's channel access (may be a tree)
        const actorChannels = await this.getChannelAccess(provider, actorId as ActorId);

        // Self-heal: mirror the DO access list into public.channel so ops
        // queries see the full available list even for connections that
        // predate the dual-write in setChannels. A FK violation here means
        // the twist_instance was deleted out from under stale DO storage —
        // shouldn't fail the read path.
        if (actorChannels.length > 0) {
          try {
            await this.mirrorChannelsToDb(actorChannels);
          } catch (error) {
            const logger = createLogger({ twist_instance_id: this.twistInstanceId });
            logger.warn("mirrorChannelsToDb self-heal failed", {
              provider,
              actor_id: actorId,
              error: error instanceof Error ? error.message : String(error),
            });
          }
        }

        // Track access for the current user
        if (currentUserContactIds.has(actorId)) {
          for (const s of this.flattenChannels(actorChannels)) {
            channelAccessByCurrentUser.add(`${provider}:${s.id}`);
          }

          // Self-heal: backfill twist_instance_connection for pre-existing connections
          if (contactUserId) {
            await this.db
              .insertInto("twist_instance_connection")
              .values({
                twist_instance_id: this.twistInstanceId,
                user_id: contactUserId,
                provider,
                actor_id: actorId,
                connected_at: new Date().toISOString(),
              })
              .onConflict((oc) =>
                oc
                  .columns(["twist_instance_id", "user_id", "provider"])
                  .doNothing()
              )
              .execute();
          }
        }

        // Use the first actor's tree as the canonical tree for this provider
        // (all actors with the same provider should see the same structure)
        if (!channelTreesByProvider.has(provider) && actorChannels.length > 0) {
          channelTreesByProvider.set(provider, actorChannels);
        }
      }
    }

    // Annotate channel trees with config and access info
    const annotateChannelTree = async (
      provider: AuthProvider,
      channels: Channel[]
    ): Promise<AnnotatedChannel[]> => {
      const result: AnnotatedChannel[] = [];
      for (const channel of channels) {
        const channelConfig = await this.getChannelConfig(provider, channel.id);
        const mapKey = `${provider}:${channel.id}`;

        // Resolve linkTypes: channel-level > connector-level
        const effectiveLinkTypes = channel.linkTypes
          ?? this.sourceProvider?.linkTypes as LinkTypeConfig[] | undefined
          ?? this.providerConfigs.find(p => p.provider === provider)?.linkTypes
          ?? undefined;

        const annotated: AnnotatedChannel = {
          provider,
          id: channel.id,
          title: channel.title,
          enabled: channelConfig?.enabled ?? false,
          enabledBy: channelConfig?.enabledBy,
          linkTypes: effectiveLinkTypes,
          currentUserHasAccess: channelAccessByCurrentUser.has(mapKey),
        };

        if (channel.children && channel.children.length > 0) {
          annotated.children = await annotateChannelTree(provider, channel.children);
        }

        result.push(annotated);
      }
      return result;
    };

    // Apply visibility rules recursively:
    // Show a node if it's enabled, the user has access, or any descendant matches
    const filterVisibleTree = (channels: AnnotatedChannel[]): AnnotatedChannel[] => {
      const result: AnnotatedChannel[] = [];
      for (const s of channels) {
        const filteredChildren = s.children ? filterVisibleTree(s.children) : undefined;
        const hasVisibleChildren = filteredChildren && filteredChildren.length > 0;
        if (s.enabled || s.currentUserHasAccess || hasVisibleChildren) {
          result.push({
            ...s,
            children: filteredChildren && filteredChildren.length > 0 ? filteredChildren : undefined,
          });
        }
      }
      return result;
    };

    // Build annotated and filtered channel trees per provider
    const allChannels: AnnotatedChannel[] = [];
    for (const [provider, tree] of channelTreesByProvider) {
      const annotated = await annotateChannelTree(provider, tree);
      const visible = filterVisibleTree(annotated);
      allChannels.push(...visible);
    }

    return { providers, accounts, syncables: allChannels };
  }

  /**
   * Builds the getChannels → setChannels dispatch entry for a provider+actor
   * using the stored token. Returns null if no token or no matching provider.
   * Shared between refreshChannels (user-triggered) and enableSync (self-heal).
   */
  private async buildRefreshDispatch(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<any | null> {
    const token = await this.getActorToken(provider, actorId);
    if (!token) return null;

    const tokenKey = `auth_token:${provider}:${actorId}`;
    const tokenData = await this.store.get<StoredTokenData>(tokenKey);
    const email = tokenData ? this.extractEmail(tokenData.providerData) : null;

    const auth: Authorization = {
      provider,
      scopes: tokenData?.scopes ?? [],
      actor: {
        id: actorId,
        type: ActorType.Contact,
        email: email ?? undefined,
      },
    };

    const forwardTo = {
      functionName: "setChannels",
      prependArgs: [provider, actorId],
    };

    if (this.sourceProvider) {
      return { sourceMethod: "getChannels", args: [auth, token], forwardTo };
    }

    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex < 0) return null;

    return {
      optionPath: ["providers", providerIndex, "getChannels"],
      args: [auth, token],
      forwardTo,
    };
  }

  /**
   * Re-calls getChannels for a provider+actor using stored token,
   * updating channel_access with the latest list.
   */
  async refreshChannels(provider: AuthProvider, actorId: ActorId): Promise<any> {
    const dispatch = await this.buildRefreshDispatch(provider, actorId);
    if (!dispatch) return;
    return { __dispatch: [dispatch] } as any;
  }

  /**
   * Migration: populate channel_access for pre-redesign auth tokens.
   * Called during deployment upgrade phase via callPreLifecycle.
   * Scans existing auth tokens and calls getChannels for each to
   * populate channel_access so the edit modal shows channels.
   */
  async preUpgrade(): Promise<any> {
    const tokenKeys = await this.store.list("auth_token:");
    const useSourceMethod = !!this.sourceProvider;
    const dispatches: Array<{
      optionPath?: (string | number)[];
      sourceMethod?: string;
      args: any[];
      forwardTo: { functionName: string; prependArgs: any[] };
    }> = [];

    for (const key of tokenKeys) {
      // Parse "auth_token:{provider}:{actorId}"
      const parts = key.split(":");
      if (parts.length < 3) continue;
      const provider = parts[1] as AuthProvider;
      const actorId = parts.slice(2).join(":") as ActorId;

      // Skip if channel_access already exists (already migrated)
      const accessKey = `channel_access:${provider}:${actorId}`;
      const existing = await this.store.get(accessKey);
      if (existing) continue;
      // Also check old key
      const oldExisting = await this.store.get(`syncable_access:${provider}:${actorId}`);
      if (oldExisting) continue;

      // Get token
      const token = await this.getActorToken(provider, actorId);
      if (!token) continue;

      // Build Authorization for getChannels dispatch
      const tokenData = await this.store.get<StoredTokenData>(key);
      const email = tokenData ? this.extractEmail(tokenData.providerData) : null;
      const auth: Authorization = {
        provider,
        scopes: tokenData?.scopes ?? [],
        actor: {
          id: actorId,
          type: ActorType.Contact,
          email: email ?? undefined,
        },
      };

      const forwardTo = {
        functionName: "setChannels",
        prependArgs: [provider, actorId],
      };

      if (useSourceMethod) {
        dispatches.push({
          sourceMethod: "getChannels",
          args: [auth, token],
          forwardTo,
        });
      } else {
        // Find matching provider config index
        const providerIndex = this.providerConfigs.findIndex(
          (p) => p.provider === provider
        );
        if (providerIndex < 0) continue;

        dispatches.push({
          optionPath: ["providers", providerIndex, "getChannels"],
          args: [auth, token],
          forwardTo,
        });
      }
    }

    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  // ============================================================================
  // Private helpers
  // ============================================================================

  /**
   * Read channel config with backward-compatible fallback to old storage keys.
   */

  private async getChannelConfig(provider: AuthProvider, channelId: string): Promise<ChannelConfig | null> {
    // Try channel DB table first
    const dbRow = await this.db
      .selectFrom("channel")
      .select(["enabled", "title"])
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("channel_id", "=", channelId)
      .executeTakeFirst();

    if (dbRow) {
      // DB doesn't store enabledBy — fall back to KV for that field
      const kvConfig = await this.store.get<ChannelConfig>(`channel_config:${provider}:${channelId}`);
      return {
        enabled: dbRow.enabled,
        enabledBy: kvConfig?.enabledBy,
        title: dbRow.title,
      };
    }

    // Dual-read fallback: check KV. Do NOT opportunistically create a channel
    // row here — we'd have to stamp `title = channel_id` and `link_types = NULL`
    // as sentinels, and nothing in this path arranges for them to be corrected.
    // The authoritative row is written by enableSync (which also dispatches a
    // setChannels refresh when data is incomplete).
    const config = await this.store.get<ChannelConfig>(`channel_config:${provider}:${channelId}`);
    if (config) return config;

    // Backward compat: read from old storage key prefix
    return await this.store.get<ChannelConfig>(`syncable_config:${provider}:${channelId}`);
  }

  /**
   * Read channel access list with backward-compatible fallback to old storage keys.
   */
  private async getChannelAccess(provider: AuthProvider, actorId: ActorId): Promise<Channel[]> {
    const channels = await this.store.get<Channel[]>(`channel_access:${provider}:${actorId}`);
    if (channels) return channels;
    // Backward compat: read from old storage key prefix
    return await this.store.get<Channel[]>(`syncable_access:${provider}:${actorId}`) ?? [];
  }

  /**
   * Find a channel by ID anywhere in a tree of channels.
   */
  private findChannelInTree(channels: Channel[], id: string): Channel | undefined {
    for (const s of channels) {
      if (s.id === id) return s;
      if (s.children) {
        const found = this.findChannelInTree(s.children, id);
        if (found) return found;
      }
    }
    return undefined;
  }

  /**
   * Flatten a tree of channels into a flat array.
   */
  private flattenChannels(channels: Channel[]): Channel[] {
    const result: Channel[] = [];
    for (const s of channels) {
      result.push(s);
      if (s.children) {
        result.push(...this.flattenChannels(s.children));
      }
    }
    return result;
  }

  private extractEmail(providerData: ProviderData | null): string | null {
    if (!providerData) {
      return null;
    }

    // Check for email field in provider data
    if ("email" in providerData && typeof providerData.email === "string") {
      return providerData.email.toLowerCase();
    }

    return null;
  }

  /**
   * Build an Actor for the authorized account. Links the email to a contact
   * and determines whether the actor is the owner (User) or a Contact.
   *
   * When `email` is null (e.g. Slack user-token-only OAuth) but a
   * `providerUserId` is available, dedupe on `contact_external_account`
   * and fall back to creating a contact linked to the twist_instance
   * owner. Without this, `getIntegrationData` would produce a synthetic
   * actor id not linked to any user, causing `currentUserHasAccess` to
   * be false for every channel in the edit modal.
   */
  private async buildActor(
    email: string | null,
    provider?: AuthProvider,
    providerUserId?: string | null
  ): Promise<Actor> {
    if (!email) {
      if (provider && providerUserId) {
        try {
          const existing = await this.db
            .selectFrom("contact_external_account")
            .innerJoin(
              "contact",
              "contact.id",
              "contact_external_account.contact_id"
            )
            .select(["contact.id", "contact.name"])
            .where("contact_external_account.provider", "=", provider)
            .where("contact_external_account.account_id", "=", providerUserId)
            .executeTakeFirst();
          if (existing?.id) {
            return {
              id: existing.id as ActorId,
              type: ActorType.Contact,
              name: existing.name ?? null,
            };
          }

          const twistInstance = await this.db
            .selectFrom("twist_instance")
            .select("owner_id")
            .where("id", "=", this.twistInstanceId)
            .executeTakeFirst();
          if (twistInstance?.owner_id) {
            const newContact = await this.db
              .insertInto("contact")
              .values({
                email: null,
                user_id: twistInstance.owner_id,
                name: null,
                avatar_url: null,
                inviteable: false,
              })
              .returning(["id"])
              .executeTakeFirst();
            if (newContact?.id) {
              return {
                id: newContact.id as ActorId,
                type: ActorType.Contact,
              };
            }
          }
        } catch (error) {
          const logger = createLogger({
            twist_instance_id: this.twistInstanceId,
          });
          logger.error(
            "Failed to link no-email OAuth contact to owner",
            error as Error,
            { provider }
          );
        }
      }

      // Fallback: synthetic actor (caller will skip FK-bound writes).
      return {
        id: crypto.randomUUID() as ActorId,
        type: ActorType.Contact,
      };
    }

    try {
      // Get the user_id from the twist_instance owner
      const twistInstance = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirst();

      if (!twistInstance?.owner_id) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("Cannot link contact: twist_instance has no owner", {
          email,
        });
        return {
          id: crypto.randomUUID() as ActorId,
          type: ActorType.Contact,
          email,
        };
      }

      const userId = twistInstance.owner_id;

      // Check if contact exists with this email
      const existingContact = await this.db
        .selectFrom("contact")
        .select(["id", "user_id", "name"])
        .where("email", "=", email)
        .executeTakeFirst();

      if (!existingContact) {
        // Create new contact linked to current user
        const newContact = await this.db
          .insertInto("contact")
          .values({
            email,
            user_id: userId,
            name: null,
            avatar_url: null,
            inviteable: classifyInviteable(email, null),
          })
          .returning(["id", "name"])
          .executeTakeFirst();

        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.info("Created new contact from OAuth", { email, user_id: userId });

        // Sync to Clerk so user can sign in with this email
        await this.syncEmailToClerk(userId, email);

        // If the new contact is linked to the owner, it's a User actor
        return {
          id: (newContact?.id ?? crypto.randomUUID()) as ActorId,
          type: ActorType.Contact,
          email,
          name: newContact?.name ?? null,
        };
      }

      if (existingContact.user_id === null) {
        // Unclaimed contact - link to current user
        await this.db
          .updateTable("contact")
          .set({ user_id: userId })
          .where("id", "=", existingContact.id)
          .execute();

        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.info("Linked existing contact from OAuth", {
          email,
          user_id: userId,
        });

        // Sync to Clerk so user can sign in with this email
        await this.syncEmailToClerk(userId, email);
      } else if (existingContact.user_id !== userId) {
        const error = new Error("auth_email_conflict");
        error.name = AUTH_EMAIL_CONFLICT_ERROR;
        throw error;
      }

      // If the contact is linked to the owner user, treat as User actor
      const isOwner = existingContact.user_id === userId ||
        (existingContact.user_id === null); // just linked above
      return {
        id: existingContact.id as ActorId,
        type: isOwner ? ActorType.User : ActorType.Contact,
        email,
        name: existingContact.name ?? null,
      };
    } catch (error) {
      if (error instanceof Error && error.name === AUTH_EMAIL_CONFLICT_ERROR) {
        throw error;
      }
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.error("Error building actor from email", error as Error, { email });
      // Don't throw - return a minimal actor
      return {
        id: crypto.randomUUID() as ActorId,
        type: ActorType.Contact,
        email,
      };
    }
  }

  /**
   * Sync a newly-linked email to Clerk so the user can sign in with it.
   * Non-blocking — logs errors but never throws.
   */
  private async syncEmailToClerk(userId: string, email: string): Promise<void> {
    try {
      const user = await this.db
        .selectFrom("user")
        .select("clerk_id")
        .where("id", "=", userId)
        .executeTakeFirst();
      if (!user?.clerk_id || !this.env.CLERK_SECRET_KEY) return;

      const { syncContactToClerk } = await import("../../app/link-email");
      await syncContactToClerk(this.env.CLERK_SECRET_KEY, user.clerk_id, email, {
        twist_instance_id: this.twistInstanceId,
        user_id: userId,
      });
    } catch (error) {
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.error("Failed to sync OAuth email to Clerk (non-blocking)", error as Error, {
        user_id: userId,
        email,
      });
    }
  }

  /**
   * Find an alternate actor who has access to a channel (for reassignment).
   */
  private async findAlternateOwner(
    _provider: AuthProvider,
    _channelId: string,
    _excludeActorId: ActorId
  ): Promise<ActorId | null> {
    // For now, return null - the channel will be disabled when the owner is removed.
    // A more complete implementation would scan all actors with tokens for this provider
    // and find one who has access to the channel.
    return null;
  }

  private async refreshToken({
    clientId,
    refreshToken,
    provider,
  }: {
    clientId: string;
    refreshToken: string;
    provider: AuthProvider;
  }): Promise<{
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
  }> {
    const config = PROVIDER_CONFIGS[provider];
    if (!config) {
      // Programmer error / misconfiguration — not a transient issue, but also
      // not an OAuth credential failure. Treat as permanent so we don't keep
      // an unrefreshable token around forever.
      throw new TokenRefreshError(
        `Token refresh not implemented for ${provider}`,
        true
      );
    }

    const clientSecret = Integrations.SecretFromId(
      this.env,
      provider,
      clientId
    );
    const useBasicAuth = !!config.useBasicAuth && !!clientSecret;

    const params = new URLSearchParams({
      ...(useBasicAuth ? {} : { client_id: clientId }),
      ...(!useBasicAuth && clientSecret ? { client_secret: clientSecret } : null),
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    });

    const headers: Record<string, string> = {
      "Content-Type": "application/x-www-form-urlencoded",
    };
    if (useBasicAuth) {
      headers.Authorization = `Basic ${btoa(`${clientId}:${clientSecret}`)}`;
    }

    let response: Response;
    try {
      response = await fetch(config.tokenUrl, {
        method: "POST",
        headers,
        body: params.toString(),
      });
    } catch (error) {
      // Network-layer failure (DNS, TCP reset, TLS, fetch threw). Always
      // transient — the refresh_token itself is still valid.
      throw new TokenRefreshError(
        `Token refresh network error: ${(error as Error)?.message ?? String(error)}`,
        false,
        { cause: error }
      );
    }

    if (!response.ok) {
      const errorText = await response.text();
      const { permanent, oauthError } = classifyRefreshHttpError(
        response.status,
        errorText
      );
      throw new TokenRefreshError(
        `Token refresh failed: ${response.status}${oauthError ? ` (${oauthError})` : ""} ${errorText}`,
        permanent,
        { status: response.status, oauthError, body: errorText }
      );
    }

    const tokenData = (await response.json()) as {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
    };
    return {
      access_token: tokenData.access_token,
      refresh_token: tokenData.refresh_token,
      expires_in: tokenData.expires_in,
    };
  }

  // ============================================================================
  // Static methods (OAuth infrastructure)
  // ============================================================================

  static async HandleOauthCallback(
    storage: DurableObjectNamespace<Storage>,
    callbacks: DurableObjectNamespace<CallbacksState>,
    params: Record<string, string>,
    env: Bindings
  ): Promise<Response> {
    try {
      const { state, error, provider, scopes, callback } = params;

      if (error) {
        const logger = createLogger();
        logger.error("OAuth error", new Error(error));
        return new Response(
          JSON.stringify({ error: `OAuth error: ${error}` }),
          {
            status: 400,
            headers: { "Content-Type": "application/json" },
          }
        );
      }

      let authState: AuthState;

      // Check if this is a Google Sign-In flow (no state) or standard OAuth (with state)
      if (!state && provider) {
        // Google Sign-In flow: validate direct parameters
        if (!provider) throw new Error("Missing provider parameter");

        const scopeArray = scopes ? scopes.split(",").map((s) => s.trim()) : [];

        authState = {
          provider: provider as AuthProvider,
          scopes: scopeArray,
          callback: callback as Callback | undefined,
          // No codeVerifier or timestamp for Google Sign-In
        };
      } else if (state) {
        // Standard OAuth flow: retrieve state from global storage
        const storageStub = storage.idFromName("auth");
        const storageObj = storage.get(storageStub);
        const rawAuthState = await storageObj.get(state);
        let retrievedAuthState: AuthState | null = null;
        if (rawAuthState) {
          try {
            retrievedAuthState = superjson.parse<AuthState>(rawAuthState);
          } catch {
            // Fallback to JSON.parse for backward compatibility
            retrievedAuthState = JSON.parse(rawAuthState) as AuthState;
          }
        }

        if (!retrievedAuthState) {
          return new Response(
            JSON.stringify({ error: "Invalid or expired state" }),
            {
              status: 400,
              headers: { "Content-Type": "application/json" },
            }
          );
        }

        authState = retrievedAuthState;

        // Check state timestamp (expire after 1 hour) - only for standard OAuth
        if (authState.timestamp && Date.now() - authState.timestamp > 3600000) {
          await storageObj.clear(state);
          const logger = createLogger();
          logger.error("State expired", {
            timestamp: authState.timestamp,
            age_ms: Date.now() - authState.timestamp,
          });
          return new Response(JSON.stringify({ error: "State expired" }), {
            status: 400,
            headers: { "Content-Type": "application/json" },
          });
        }

        // Cleanup state after successful validation
        await storageObj.clear(state);
      } else {
        // Neither state nor provider provided
        const logger = createLogger();
        logger.error("Missing both state and provider parameters");
        return new Response(
          JSON.stringify({
            error: "Missing required authentication parameters",
          }),
          {
            status: 400,
            headers: { "Content-Type": "application/json" },
          }
        );
      }

      const { code } = params;
      // When the client POSTs to /auth they supply clientId + redirectUri; the
      // browser-rendered bridge flow (/auth/bridge) doesn't have those, so we
      // fall back to the values captured in authState at GenerateAuthUrl time.
      const clientId = params.clientId ?? authState.clientId;
      const redirectUri = params.redirectUri ?? authState.redirectUri;
      if (!code) throw new Error("Missing code parameter");
      if (!clientId) throw new Error("Missing clientId parameter");
      if (!redirectUri) throw new Error("Missing redirectUri parameter");

      // Exchange code for tokens using static helper
      // Always include code_verifier if it exists in auth state (PKCE flow)
      const tokenResponse = await Integrations.exchangeCodeForTokens({
        clientId,
        code,
        codeVerifier: authState.codeVerifier,
        provider: authState.provider,
        redirectUri,
        env,
      });

      // Call the wrapped callback (onAuth) with token info
      if (authState.callback) {
        try {
          const _result = await CallbacksState.CallCallback(
            callbacks,
            authState.callback,
            {
            // Spread all token response fields (provider-specific fields included)
            ...tokenResponse,
            // Add our metadata
            provider: authState.provider,
            scopes: authState.scopes,
            client_id: clientId,
            }
          );
        } catch (error) {
          const errorMessage =
            error instanceof Error ? error.message : String(error);
          if (errorMessage.includes(AUTH_EMAIL_CONFLICT_ERROR)) {
            return new Response(
              JSON.stringify({
                error:
                  "The email address for this service is already associated with a different Plot account. You'll need to close that account if you want to associate it with this account.",
              }),
              {
                status: 409,
                headers: { "Content-Type": "application/json" },
              }
            );
          }
          const logger = createLogger();
          logger.error("Error executing auth callback", error as Error, {
            provider: authState.provider,
          });
          // Don't fail the auth flow even if callback fails
        }
      }

      // Sign-in flow (no callback): return tokens to the client
      if (!authState.callback) {
        return new Response(
          JSON.stringify({
            id_token: tokenResponse.id_token,
            access_token: tokenResponse.access_token,
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" },
          }
        );
      }

      return new Response(
        JSON.stringify({
          message: "Authentication successful! You can close this window.",
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }
      );
    } catch (error) {
      const logger = createLogger();
      logger.error("Error handling OAuth callback", error as Error);
      const errorMessage =
        error instanceof Error ? error.message : "Unknown error";
      return new Response(
        JSON.stringify({ error: `Authentication failed: ${errorMessage}` }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" },
        }
      );
    }
  }

  private static GenerateRandomString(length: number): string {
    const charset =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~";
    const values = crypto.getRandomValues(new Uint8Array(length));
    return Array.from(values)
      .map((x) => charset[x % charset.length])
      .join("");
  }

  private static GenerateCodeVerifier(): string {
    return Integrations.GenerateRandomString(128);
  }

  private static async GenerateCodeChallenge(
    codeVerifier: string
  ): Promise<string> {
    const encoder = new TextEncoder();
    const data = encoder.encode(codeVerifier);
    const digest = await crypto.subtle.digest("SHA-256", data);

    // Convert to base64url
    return btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "");
  }

  private static async exchangeCodeForTokens({
    code,
    codeVerifier,
    provider,
    redirectUri,
    clientId,
    env,
  }: {
    code: string;
    codeVerifier?: string;
    provider: AuthProvider;
    redirectUri: string;
    clientId: string;
    env: Bindings;
  }): Promise<{
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    [key: string]: any; // Allow any provider-specific fields
  }> {
    const config = PROVIDER_CONFIGS[provider];
    if (!config) {
      throw new Error(`Token exchange not implemented for ${provider}`);
    }

    const clientSecret = Integrations.SecretFromId(env, provider, clientId);
    const useBasicAuth = !!config.useBasicAuth && !!clientSecret;

    const params = new URLSearchParams({
      ...(useBasicAuth ? {} : { client_id: clientId }),
      ...(!useBasicAuth && clientSecret ? { client_secret: clientSecret } : null),
      code,
      grant_type: "authorization_code",
      redirect_uri: redirectUri,
      ...(codeVerifier ? { code_verifier: codeVerifier } : {}),
    });

    const headers: Record<string, string> = {
      "Content-Type": "application/x-www-form-urlencoded",
    };
    if (useBasicAuth) {
      headers.Authorization = `Basic ${btoa(`${clientId}:${clientSecret}`)}`;
    }

    const response = await fetch(config.tokenUrl, {
      method: "POST",
      headers,
      body: params.toString(),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token exchange failed: ${response.status} ${errorText}`);
    }

    const tokenData = (await response.json()) as any;

    // Return the raw token data - parsing will happen in onAuth via config.parseTokenResponse
    return tokenData;
  }

  static async GenerateAuthUrl({
    provider,
    scopes,
    callback,
    redirectUri,
    platform,
    env,
    storage,
    enabledScopeGroups,
    accountHint,
  }: {
    provider: AuthProvider;
    scopes: string[];
    callback?: Callback;
    redirectUri: string;
    platform?: "ios" | "android" | "desktop";
    env: Bindings;
    storage: DurableObjectNamespace<Storage>;
    enabledScopeGroups?: string[];
    accountHint?: string;
  }): Promise<{ url: string; clientId: string; state: string } | null> {
    const config = PROVIDER_CONFIGS[provider];
    if (!config) {
      const logger = createLogger();
      logger.error("Provider not supported", { provider });
      throw new Error(`Provider ${provider} not supported`);
    }

    // Merge email scopes with requested scopes
    const emailScopes = config.emailScopes ?? [];
    const allScopes = Array.from(new Set([...scopes, ...emailScopes]));

    // Generate fresh PKCE parameters for this specific OAuth flow
    const codeVerifier = Integrations.GenerateCodeVerifier();
    const codeChallenge = await Integrations.GenerateCodeChallenge(
      codeVerifier
    );

    // Use global auth storage
    const storageStub = storage.idFromName("auth");
    const storageObj = storage.get(storageStub);

    // Generate unique state (stored after we know the effective redirectUri)
    const state = crypto.randomUUID();

    const platformEnvKey = `${Integrations.EnvPrefix(
      provider,
      platform
    )}_ID` as keyof Bindings;
    const baseEnvKey = `${Integrations.EnvPrefix(
      provider
    )}_ID` as keyof Bindings;

    const clientId = (env[platformEnvKey] ?? env[baseEnvKey]) as string;

    if (!clientId) {
      const logger = createLogger();
      logger.error("No client ID found for provider", {
        provider,
        platform,
        platform_env_key: platformEnvKey,
        base_env_key: baseEnvKey,
        available_auth_keys: Object.keys(env).filter((k) =>
          k.startsWith("AUTH_")
        ),
      });
      return null;
    }

    // For providers that reject custom URI schemes, always route the OAuth
    // redirect through the server-rendered bridge endpoint regardless of
    // platform. This means only `${API_ROOT}/auth/bridge` needs to be
    // registered with the provider; the bridge page then deep-links back to
    // whatever URI the client originally supplied (plotday://, https://app…,
    // or http://localhost:<port> loopback).
    let effectiveRedirectUri = redirectUri;
    let bridgeUri: string | undefined;
    const bridgeEndpoint = `${env.API_ROOT}/auth/bridge`;
    if (config.requiresHttpsRedirect && redirectUri !== bridgeEndpoint) {
      bridgeUri = redirectUri;
      effectiveRedirectUri = bridgeEndpoint;
    }

    const authState: AuthState = {
      provider,
      scopes: allScopes,
      codeVerifier,
      timestamp: Date.now(),
      callback,
      enabledScopeGroups,
      clientId,
      redirectUri: effectiveRedirectUri,
      bridgeUri,
    };
    await storageObj.set(state, superjson.stringify(authState));

    // For sign-in flows (no callback), use simplified Google OAuth params
    // For authorization flows (has callback), use full params from config
    const isSignInFlow = !callback && provider === "google";
    const additionalParams: Record<string, string> = {
      ...(isSignInFlow ? { prompt: "select_account" } : config.additionalParams),
    };

    // Re-auth: caller knows which account to reconnect, so pre-select it via
    // login_hint and drop prompt=select_account so Google can skip the chooser
    // when the user is already signed into that account. login_hint is also a
    // standard OAuth param honored by Microsoft.
    if (accountHint && (provider === "google" || provider === "microsoft")) {
      additionalParams.login_hint = accountHint;
      if (provider === "google") {
        delete additionalParams.prompt;
      }
    }

    const scopeParam = config.scopeParam ?? "scope";
    const params = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: effectiveRedirectUri,
      [scopeParam]: allScopes.join(" "),
      state,
      code_challenge: codeChallenge,
      code_challenge_method: "S256",
      ...additionalParams,
    });

    const url = `${config.authUrl}?${params.toString()}`;

    return { url, clientId, state };
  }

  private static ALL_PLATFORMS: (undefined | "ios" | "android" | "desktop")[] =
    [undefined, "desktop", "ios", "android"];
  private static EnvPrefix(
    provider: AuthProvider,
    platform?: "ios" | "android" | "desktop"
  ) {
    return `AUTH_${provider.toUpperCase()}${
      platform ? `_${platform.toUpperCase()}` : ""
    }`;
  }

  private static SecretFromId(
    env: Bindings,
    provider: AuthProvider,
    id: string
  ) {
    const prefix = Integrations.ALL_PLATFORMS.map((platform) =>
      Integrations.EnvPrefix(provider, platform)
    ).find((p) => env[`${p}_ID` as keyof Bindings] === id);
    return prefix
      ? (env[`${prefix}_SECRET` as keyof Bindings] as string | undefined)
      : undefined;
  }

  /** Remove the Twisting tag from a note. Called by entrypoint for deferred tag removal. */
  async removeTagFromNote(noteId: string, actorId: string): Promise<void> {
    try {
      const pt = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirst();

      if (pt?.owner_id) {
        await rpcUser(this.db, "update_note_tags", {
          user_id: pt.owner_id,
          p_note_id: noteId,
          p_actor_id: actorId,
          p_client_id: 0,
          p_tag_updates: { [Tag.Twist]: false },
        });
      }
    } catch (error) {
      console.warn("Failed to remove deferred Twisting tag from note", {
        note_id: noteId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /** Update a note's key for external dedup. Called by entrypoint when onNoteCreated returns a plain-string key. */
  async updateNoteKey(noteId: string, key: string): Promise<void> {
    await this.db
      .updateTable("note")
      .set({ key })
      .where("id", "=", noteId)
      .execute();
  }

  /**
   * Apply a {@link NoteWriteBackResult} after a connector's
   * `onNoteCreated`/`onNoteUpdated` returned one. Sets the note's `key`
   * (when the connector just established it) and stores the sync baseline
   * hash of `externalContent` so the next sync-in can recognize the
   * round-tripped content and preserve Plot's stored version.
   *
   * Uses a bypass-only UPDATE (doesn't touch other columns) so it won't
   * wake the `sync_twist_for_note` trigger unless the hash or key actually
   * changes. We intentionally skip the `updated_at`/`updated_by` refresh.
   */
  async updateNoteBaseline(
    noteId: string,
    result: NoteWriteBackResult
  ): Promise<void> {
    const patch: { key?: string; external_content_hash?: string } = {};
    if (typeof result.key === "string" && result.key.length > 0) {
      patch.key = result.key;
    }
    if (typeof result.externalContent === "string") {
      patch.external_content_hash = await hashExternalContent(
        result.externalContent
      );
    }
    if (Object.keys(patch).length === 0) return;
    await this.db
      .updateTable("note")
      .set(patch)
      .where("id", "=", noteId)
      .execute();
  }
}
