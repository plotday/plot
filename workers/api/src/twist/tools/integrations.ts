import { type Kysely, sql } from "kysely";

import type { NoteWriteBackResult } from "@plotday/twister";
import type { ResolvedRecipient } from "@plotday/twister/connector";
import {
  type Actor,
  type ActorId,
  ActorType,
  type Contact,
  type Link,
  type NewContact,
  type NewLinkWithNotes,
  type NewNote,
  type Note,
  type Thread,
  type ThreadMeta,
} from "@plotday/twister/plot";
import { type Callback } from "@plotday/twister/tools/callbacks";
import { Tag } from "@plotday/twister/tag";
import type {
  ArchiveLinkFilter,
  ArchiveNotesFilter,
  AuthProvider,
  AuthToken,
  Authorization,
  Channel,
  LinkTypeConfig,
  NewCustomEmoji,
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
import {
  findMissingRequiredScopes,
  isInsufficientScopeError,
  parseGrantedScopes,
} from "./auth-scope";
import { hashExternalContent } from "./hash-external-content";
import { isPlotSelfMail } from "./plot-self-mail";
import { ThreadFilingSkippedError } from "./plot/thread-helpers";
import { deleteUnipileAccount } from "./unipile/account-cleanup";
import { UnipileClient } from "./unipile/client";
import type { CallbacksState } from "../../state/callbacks";
import { classifyInviteable } from "../../state/contact-classifier";
import { invokeWebhookCallback } from "../invoke-webhook";
import superjson from "superjson";

import type { Storage } from "../../state/storage";
import { createLogger } from "@plotday/worker-util";
import { rpc, rpcUser } from "../../rpc";
import { notifyUserSyncByEnv } from "../../app/sync/notify";
import { flagConnectionNeedsReauth } from "./needs-reauth";
import { getEffectivePlan } from "../../utils/plan";
import { getSyncHistoryMinDate, type PlanKey } from "../../utils/limits";
import { disposeRpc } from "../../utils/rpc";
import { fromDbLink } from "./plot/converters";
import type { Plot } from "./plot/index";
import { linkPrimarySource, type CreateLinkOptions } from "./plot/link";
import { resolveAutoThreadAnchorWithAi } from "./plot/auto-thread";
import { Store } from "./store";
import { Tool } from "./tool";
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
  /** Plain-language bullets describing what connecting grants (Connector.access). */
  access?: string[];
  /** Friendly bullets describing the always-on (required) access. */
  description?: string[];
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
// Re-auth account-match guard: the user authed a different account than the
// one this connection is bound to. Thrown from onAuth, surfaced by
// HandleOauthCallback. The marker lives in the error MESSAGE (not just .name)
// so it survives the twist RPC boundary, where custom error names are lost.
const AUTH_ACCOUNT_MISMATCH_ERROR = "AuthAccountMismatchError";
// Dedup guard: the user tried to connect an account that is already connected
// to another instance of the same connector.
const AUTH_ACCOUNT_DUPLICATE_ERROR = "AuthAccountDuplicateError";

type AuthState = {
  provider: AuthProvider;
  scopes: string[];
  /** The subset of `scopes` that must be granted; optional scopes are excluded.
   *  Absent for sign-in flows and legacy states → treat all of `scopes` as required. */
  requiredScopes?: string[];
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
  // A token-refresh response of `insufficient_scope` means the stored grant is
  // missing a required scope and cannot be refreshed into a working token —
  // the user must re-authorize. Routes through getActorToken → flagNeedsReauth.
  "insufficient_scope",
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

/**
 * External URL where the user manages app authorization for this provider —
 * e.g. GitHub's per-app connection page, which is the only place to grant
 * organization access to an OAuth App after the initial consent screen.
 *
 * The URL embeds the provider's client id, which differs per environment, so
 * it must be built server-side from `env`. Returns null when no actionable
 * external page exists for the provider.
 */
function buildManageAccessUrl(
  provider: AuthProvider,
  env: Bindings
): string | null {
  switch (provider) {
    case "github": {
      const clientId = env.AUTH_GITHUB_ID;
      if (!clientId) return null;
      return `https://github.com/settings/connections/applications/${clientId}`;
    }
    default:
      return null;
  }
}

/**
 * The channels a connector marks as owned/default (`enabledByDefault === true`),
 * flattened from the channel tree. This is the set a brand-new connection
 * enables; the composite bankruptcy reuses it so a reconnect resumes the same
 * channels a fresh connect would.
 */
export function selectOwnedDefaultChannels(channels: Channel[]): Channel[] {
  const out: Channel[] = [];
  const walk = (nodes: Channel[]) => {
    for (const c of nodes) {
      if (c.enabledByDefault === true) out.push(c);
      if (c.children?.length) walk(c.children);
    }
  };
  walk(channels);
  return out;
}

/**
 * The bound connections that need an account backfilled into getIntegrationData.
 *
 * getIntegrationData derives the account list from `auth_token:` keys, so a
 * connection that has a `twist_instance_connection` row but no token — either
 * bankruptcy-provisioned (never authed) or token-cleared on a permanent refresh
 * failure (needs-reauth) — is missing from the accounts list. The reconnect
 * modal then can't tell which account to use (no `accountHint`, so no OAuth
 * `login_hint`). Given the token-derived `existing` accounts and the bound
 * connection rows, return the connections NOT already represented, deduped by
 * `provider:actorId` (so a reconnected account never doubles). The caller
 * enriches each with its own stored settings — these connections may still
 * carry auto-enable / auto-threading / scope-group selections that must be
 * preserved, so this helper deliberately does not fabricate them.
 */
export function boundConnectionsWithoutToken<
  C extends { provider: string; actor_id: string; email: string | null },
>(
  existing: Array<{ provider: AuthProvider; actorId: ActorId }>,
  connections: C[]
): C[] {
  const seen = new Set(existing.map((a) => `${a.provider}:${a.actorId}`));
  const out: C[] = [];
  for (const c of connections) {
    const key = `${c.provider}:${c.actor_id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(c);
  }
  return out;
}

// @ts-ignore - class correctly implements IAuth but TS can't verify due to Kysely type differences
export class Integrations extends Tool implements IAuth {
  private store: Store;
  private env: Bindings;
  private ctx: { exports: ExecutionContext["exports"] };
  private db: Kysely<DB>;
  private twistInstanceId: string;
  // These are callbacks we create and call
  private callbacks: DurableObjectStub<CallbacksState>;
  private _twistId: string;
  private _environment: TwistEnvironment;
  private path: string[];
  private providerConfigs: IntegrationProviderConfig[];
  /** Source metadata passed from factory when the twist is a Source. */
  private sourceProvider: { provider?: string; scopes?: string[]; linkTypes?: any[]; shared?: boolean; keyOption?: string; handleReplies?: boolean; autoEnableNewChannelsByDefault?: boolean; autoThreading?: boolean; autoThreadingByDefault?: boolean } | null = null;
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
    ctx: { exports: ExecutionContext["exports"] };
    db: Kysely<DB>;
    twistInstanceId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
    integrationOptions?: IntegrationOptions;
    /** Source metadata (provider, scopes, linkTypes, auth model) from the Source class. Set by factory for sources. */
    sourceProvider?: { provider?: string; scopes?: string[]; linkTypes?: any[]; shared?: boolean; keyOption?: string; handleReplies?: boolean; autoEnableNewChannelsByDefault?: boolean; autoThreading?: boolean; autoThreadingByDefault?: boolean } | null;
  }) {
    super();
    this.store = options.store;
    this.env = options.env;
    this.ctx = options.ctx;
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
        await this.flagNeedsReauth(provider, config.enabledBy, {
          trigger: "token_missing",
          reason:
            "Channel enabled but no usable token for actor (never stored or cleared by an earlier failure)",
        });
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
        await this.store.set(`channel_config:${provider}:${resolvedChannelId}`, {
          enabled: true,
          enabledBy: actorId,
        } satisfies ChannelConfig);
        return token;
      }
    }

    // Sub-connector fallback: when this Integrations is built as a sub-tool
    // of another Connector via merged scopes (e.g. GoogleContacts inside
    // Google Calendar / Drive / Chat — see public/connectors/google-*/), the
    // OAuth flow ran on the parent and stored tokens in the parent's DO,
    // not ours. Our own getChannelConfig and migration fallback both miss
    // by design. Look one level up before giving up. Skipped when this
    // tool is at the root (length 1) since there's no parent to consult.
    if (this.path.length > 1) {
      const parentStore = new Store({
        path: ["integrations"],
        storage: this.env.STORAGE,
        twistInstanceId: this.twistInstanceId,
      });
      const parentKeys = await parentStore.list(`auth_token:${provider}:`);
      for (const key of parentKeys) {
        const tokenData = await parentStore.get<StoredTokenData>(key);
        if (!tokenData) continue;
        // Skip expired tokens — leave refresh to the parent's getActorToken
        // on its next call (it owns the lifecycle, including flagNeedsReauth
        // on permanent failure).
        if (tokenData.expires_at && Date.now() > tokenData.expires_at) {
          continue;
        }
        const providerConfig = PROVIDER_CONFIGS[provider];
        return {
          token: tokenData.access_token,
          scopes: tokenData.scopes,
          provider: tokenData.providerData
            ? providerConfig?.extractMetadata?.(tokenData.providerData)
            : undefined,
        };
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

    const dispatches: any[] = [];

    // Auto-enable newly-discovered channels when the per-connection flag is on.
    const autoEnable = await this.store.get<boolean>(
      `auto_enable_new_channels:${provider}:${actorId}`
    );
    const newChannels = autoEnable
      ? flat.filter((c) => !knownIds.has(c.id))
      : [];
    if (newChannels.length > 0) {
      const syncContext = await this.buildSyncContext({
        forActor: actorId,
        provider,
      });
      for (const channel of newChannels) {
        const entry = await this.applyChannelEnabled(
          provider,
          actorId,
          channel,
          syncContext
        );
        if (entry) dispatches.push(entry);
      }
    }

    // One-shot seed of owned defaults for a bankruptcy-provisioned connection.
    dispatches.push(
      ...(await this.seedDefaultChannelsIfFlagged(provider, actorId, channels))
    );

    if (dispatches.length > 0) return { __dispatch: dispatches } as any;
  }

  /**
   * One-shot: when this connection's `seed_default_channels` flag is set and it
   * has no enabled channels yet, enable the connector's owned/default channels
   * (the set a fresh user gets), then clear the flag. Returns the
   * `onChannelEnabled` dispatch entries for the seeded channels (possibly empty).
   *
   * Set only by the Google composite bankruptcy provisioning, so this is inert
   * for every other connection. The "no enabled channels" guard means it never
   * overrides a user's own channel selection.
   */
  private async seedDefaultChannelsIfFlagged(
    provider: AuthProvider,
    actorId: ActorId,
    channels: Channel[]
  ): Promise<any[]> {
    const conn = await this.db
      .selectFrom("twist_instance_connection")
      .select(["seed_default_channels"])
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("provider", "=", provider)
      .where("actor_id", "=", actorId as string)
      .executeTakeFirst();
    if (!conn?.seed_default_channels) return [];

    // Scope is per twist_instance: the `channel` table has no actor column, and
    // a connection that carries the seed flag is a single-account connection
    // (one twist_instance_connection), so "this instance has no enabled channel"
    // is the correct guard — it never spans actors.
    const enabledRow = await this.db
      .selectFrom("channel")
      .select("channel_id")
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("enabled", "=", true)
      .limit(1)
      .executeTakeFirst();

    const dispatches: any[] = [];
    if (!enabledRow) {
      const owned = selectOwnedDefaultChannels(channels);
      if (owned.length > 0) {
        const syncContext = await this.buildSyncContext({ forActor: actorId, provider });
        for (const channel of owned) {
          const entry = await this.applyChannelEnabled(provider, actorId, channel, syncContext);
          if (entry) dispatches.push(entry);
        }
      }
    }

    // One-shot: clear regardless, so this never re-seeds (or fights a later disable).
    await this.db
      .updateTable("twist_instance_connection")
      .set({ seed_default_channels: false })
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("provider", "=", provider)
      .where("actor_id", "=", actorId as string)
      .execute();

    return dispatches;
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
   * Seed the per-connection "sync new channels" preference from the connector's
   * declared default ({@link Connector.autoEnableNewChannelsByDefault}) when no
   * explicit value has been stored yet. Called once when a connection is
   * finalized (draft activation), AFTER the user's initial channel selection
   * has been applied — so the initial selection governs which channels start
   * enabled, and only channels discovered *later* are auto-enabled.
   *
   * No-op when a value is already stored (the user's choice, or a prior seed)
   * or when the connector's default is not `true`.
   */
  async initAutoEnableDefault(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<void> {
    if (this.sourceProvider?.autoEnableNewChannelsByDefault !== true) return;
    const existing = await this.store.get<boolean>(
      `auto_enable_new_channels:${provider}:${actorId}`
    );
    if (existing !== undefined && existing !== null) return;
    await this.store.set(
      `auto_enable_new_channels:${provider}:${actorId}`,
      true
    );
  }

  /**
   * Per-connection preference: when true, this connection's conversational
   * links (marked with `autoThread`) are folded into existing threads by the
   * sequential auto-threading resolver. Default false (opt-in). Per-account
   * so the connections list can show one toggle per account, mirroring
   * `getAutoEnableNewChannels`.
   */
  async getAutoThreadingEnabled(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<boolean> {
    return (
      (await this.store.get<boolean>(
        `auto_threading_enabled:${provider}:${actorId}`
      )) ?? false
    );
  }

  async setAutoThreadingEnabled(
    provider: AuthProvider,
    actorId: ActorId,
    enabled: boolean
  ): Promise<void> {
    await this.store.set(
      `auto_threading_enabled:${provider}:${actorId}`,
      enabled
    );
  }

  /**
   * Connection-level gate read by {@link saveLink}: true when auto-threading
   * is enabled for ANY account on this connection. Avoids threading the
   * per-account (provider, actorId) through the save path — a connection's
   * DO holds only its own accounts' keys.
   */
  async isAutoThreadingEnabled(): Promise<boolean> {
    const keys = await this.store.list("auto_threading_enabled:");
    for (const key of keys) {
      if ((await this.store.get<boolean>(key)) === true) return true;
    }
    return false;
  }

  /**
   * Seed the per-connection auto-threading preference from the connector's
   * declared default ({@link Connector.autoThreadingByDefault}) when no
   * explicit value is stored yet. Called at connection activation alongside
   * {@link initAutoEnableDefault}. No-op unless the connector defaults it on.
   */
  async initAutoThreadingDefault(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<void> {
    if (this.sourceProvider?.autoThreadingByDefault !== true) return;
    const existing = await this.store.get<boolean>(
      `auto_threading_enabled:${provider}:${actorId}`
    );
    if (existing !== undefined && existing !== null) return;
    await this.store.set(
      `auto_threading_enabled:${provider}:${actorId}`,
      true
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
    syncContext: SyncContext,
    observeOnly = false
  ): Promise<any | null> {
    const title = channel.title ?? channel.id;
    // Persist the connector-level linkTypes fallback when the channel declares
    // none. Source connectors (LinkedIn/Instagram/WhatsApp) declare `linkTypes`
    // only at the class level and return bare channels from getChannels(), so
    // without this the enabled channel row's link_types is NULL — and a twist
    // in dynamic-link-types mode then resolves `user.twist.link_types` to NULL,
    // hiding the connector's compose target from the new-thread picker (#1a).
    const linkTypes = channel.linkTypes ?? this.connectorLinkTypes(provider) ?? null;

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
    // "syncing since" indicator reflects the current sync. Skipped for
    // observe-only enables (composed-channel observation) — there's no
    // backfill, so a spinner would be misleading.
    if (!observeOnly) {
      await this.markChannelSyncStarted(provider, channel.id);
    }

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
    // Pass `recovering: true` WITHOUT forActor/provider so buildSyncContext
    // doesn't eagerly consume `recovery_pending`. This dispatch path runs
    // inside the cron's RPC into the runtime worker and we have no
    // post-success hook here — a mid-flight eviction or throw between this
    // line and the connector's runTask call would otherwise leave the
    // flag cleared with no retry. The cron caller (recoverPendingConnections)
    // is responsible for clearing the flag only after the whole
    // wrapper.callCallback round-trip resolves successfully.
    const recoveryContext = await this.buildSyncContext({
      recovering: true,
    });
    const dispatches: any[] = [];
    for (const key of configKeys) {
      const channelId = key.slice(configKeyPrefix.length);
      // Defensive cleanup of legacy bogus keys written by an earlier bug
      // that interpolated an undefined parameter into the key. Without
      // this skip we'd dispatch onChannelEnabled with channel.id =
      // "undefined", which downstream connectors then send to the
      // provider API (e.g. Gmail returns "Invalid label: undefined").
      if (!channelId || channelId === "undefined" || channelId === "null") {
        await this.store.clear(key);
        continue;
      }
      const channelConfig = await this.store.get<ChannelConfig>(key);
      if (
        !channelConfig?.enabled ||
        channelConfig.enabledBy !== actorId
      ) {
        continue;
      }
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

    // Self-heal: when no channel_config entry matches the requested actor —
    // either because the DO storage was wiped, or because enabledBy points
    // at a prior actor that the onAuth migration above skipped (it only
    // runs when previousActorId !== actor.id) — fall back to the channel
    // table. applyChannelEnabled rewrites channel_config with the correct
    // enabledBy, so subsequent recovery cycles use the fast path.
    if (dispatches.length === 0) {
      const enabledChannels = await this.db
        .selectFrom("channel")
        .select(["channel_id", "title"])
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where("enabled", "=", true)
        .where("channel_id", "not in", ["undefined", "null", ""])
        .execute();
      if (enabledChannels.length > 0) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn(
          "buildRecoveryDispatches: channel_config empty for actor, recovering from channel table",
          {
            provider,
            actor_id: actorId,
            channel_count: enabledChannels.length,
          }
        );
        for (const row of enabledChannels) {
          const channel: Channel = {
            id: row.channel_id,
            title: row.title,
          };
          const entry = await this.applyChannelEnabled(
            provider,
            actorId,
            channel,
            recoveryContext
          );
          if (entry) dispatches.push(entry);
        }
      }
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

    // Single multi-row INSERT. ON CONFLICT keeps existing enabled state and
    // only refreshes title/link_types when this refresh provides them — the
    // CASE/COALESCE expressions below mirror the per-row branching the loop
    // version did via conditional updateFields.
    //
    // Postgres rejects ON CONFLICT DO UPDATE when the same statement
    // proposes duplicate constraint values, so dedupe by channel_id first.
    // (The previous loop ran separate statements, which made dup channel_ids
    // a no-op on the second pass; we replicate that by keeping the last one.)
    const dedupedByChannelId = new Map<string, Channel>();
    for (const channel of flat) {
      dedupedByChannelId.set(channel.id, channel);
    }
    const values = [...dedupedByChannelId.values()].map((channel) => {
      // Fall back to the connector-level linkTypes when the channel declares
      // none, so discovery rows for class-level-only connectors (LinkedIn etc.)
      // carry compose-bearing link_types (#1a).
      const lt = channel.linkTypes ?? this.connectorLinkTypes();
      return {
        twist_instance_id: this.twistInstanceId,
        channel_id: channel.id,
        title: channel.title ?? channel.id,
        enabled: false,
        link_types: (lt ? JSON.stringify(lt) : null) as any,
        updated_at: futureDate,
      };
    });

    await this.db
      .insertInto("channel")
      .values(values)
      .onConflict((oc) =>
        oc.columns(["twist_instance_id", "channel_id"]).doUpdateSet((eb) => ({
          updated_at: eb.ref("excluded.updated_at"),
          // Only overwrite title when the incoming row has a real title
          // (not the channel_id fallback). Mirrors the original `if
          // (channel.title)` guard.
          title: eb.fn<string>("COALESCE", [
            eb
              .case()
              .when(
                eb.ref("excluded.title"),
                "<>",
                eb.ref("excluded.channel_id")
              )
              .then(eb.ref("excluded.title"))
              .else(null)
              .end(),
            eb.ref("channel.title"),
          ]),
          // Only overwrite link_types when the incoming row provides them.
          link_types: eb.fn<unknown>("COALESCE", [
            eb.ref("excluded.link_types"),
            eb.ref("channel.link_types"),
          ]) as any,
        }))
      )
      .execute();
  }

  /**
   * Connector-level linkTypes fallback for a channel that declares none of its
   * own. Source connectors (LinkedIn/Instagram/WhatsApp) declare `linkTypes`
   * only at the class level and return bare channels from getChannels(), so the
   * persisted `channel.link_types` must fall back to the connector's declared
   * linkTypes. Mirrors the read-side resolution in {@link annotateChannelTree}
   * so what we write matches what the modal/display path computes.
   */
  private connectorLinkTypes(
    provider?: AuthProvider
  ): LinkTypeConfig[] | undefined {
    return (
      (this.sourceProvider?.linkTypes as LinkTypeConfig[] | undefined) ??
      (provider != null
        ? this.providerConfigs.find((p) => p.provider === provider)?.linkTypes
        : undefined)
    );
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
      this._plot = new PlotClass(this.internalPlotOptions());
    }
    return this._plot!;
  }

  /**
   * Construction options for the internal Plot used by source save operations
   * (saveContacts/saveLink). Forwards `sourceProvider` so `addContacts` can
   * resolve the connector's provider and write `contact_external_account`
   * bindings for synced contacts — without it, emailless relation contacts
   * (e.g. LinkedIn 1st-degree connections) get no binding and appear
   * unreachable in the new-thread connection picker (#1b).
   */
  private internalPlotOptions() {
    return {
      db: this.db,
      twistInstanceId: this.twistInstanceId,
      options: {
        thread: { access: 1 /* ThreadAccess.Create */ },
      },
      env: this.env,
      sourceProvider: this.sourceProvider,
    };
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
    // Drop Plot's own transactional emails that loop back in through a
    // connected mailbox (sign-in notices, digests sent from updates.plot.day).
    // Platform-level so it covers every email connector — see plot-self-mail.ts.
    if (isPlotSelfMail(link)) {
      return null;
    }

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

    // Auto-threading: when the connector marked this link (a conversational
    // message) and the connection opted in, decide ONCE — globally, at ingest
    // — whether it folds into the conversation's anchor thread or starts a new
    // one. `autoThread` is a directive, not a link column, so consume it
    // before createLink either way.
    const autoThread = link.autoThread ?? null;
    if (autoThread) {
      delete (link as { autoThread?: unknown }).autoThread;
    }
    let createOpts: CreateLinkOptions | undefined;
    if (autoThread && (await this.isAutoThreadingEnabled())) {
      const threadKey = await this.resolveAutoThreadFold(plot, link, autoThread);
      if (threadKey) createOpts = { threadKey };
    }

    let threadId: Uuid;
    try {
      threadId = await plot.createLink(link, createOpts);
    } catch (error) {
      if (error instanceof ThreadFilingSkippedError) {
        // Team-connector firing for a user who has no priority in the team.
        // Treat as a soft skip — saveLink already returns null for filtered
        // items, so connectors that handle null gracefully keep working.
        return null;
      }
      throw error;
    }

    // Create task schedule for assigned links
    await this.createTaskScheduleForLink(threadId);

    // Atomically apply a create-time to-do flag for the connection owner.
    // Connector save path does NOT run the status `active:true` propagation
    // (that only fires on the client /sync/links route), so this is the
    // supported way for a connector to create an owner to-do thread.
    if (link.todo !== undefined && link.todo !== null) {
      const owner = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirst();
      if (owner?.owner_id) {
        const todoDate = link.todoDate;
        await this.applyThreadToDoForUser(
          threadId,
          owner.owner_id,
          link.todo,
          todoDate ? { date: todoDate } : undefined
        );
      } else {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("saveLink: no owner_id for twist instance; skipping link.todo", {
          twist_instance_id: this.twistInstanceId,
        });
      }
    }

    return threadId;
  }

  /**
   * Resolve the auto-threading fold target for a marked link. Returns the
   * anchor thread's source (the value to use as the link's thread key) when
   * this message folds into an existing conversation, or `undefined` to leave
   * createLink on its normal new-thread path. Decided once globally and cached
   * in `conversation_message` (see ./plot/auto-thread.ts).
   */
  private async resolveAutoThreadFold(
    plot: Plot,
    link: NewLinkWithNotes,
    autoThread: { key: string; mode: "sequential" | "fold" }
  ): Promise<string | undefined> {
    const messageSource = linkPrimarySource(link);
    if (!messageSource) return undefined; // no canonical source ⇒ can't key a chain
    const twistId = await plot.getTwistId(this.twistInstanceId);
    if (twistId == null) return undefined;

    const created = link.created;
    const sourceCreatedAt =
      created instanceof Date
        ? created.toISOString()
        : typeof created === "string"
          ? created
          : new Date().toISOString();

    // Short text snippet for the continuation check: the first note's content
    // (the message body) or the link title, capped so the embedding/LLM stay
    // cheap.
    const text =
      link.notes?.find((n) => n.content)?.content ?? link.title ?? null;
    const excerpt = text && text.length > 500 ? text.slice(0, 500) : text;

    const anchorSource = await resolveAutoThreadAnchorWithAi(plot, {
      twistId,
      conversationKey: autoThread.key,
      messageSource,
      sourceCreatedAt,
      excerpt,
      mode: autoThread.mode,
    });
    // anchorSource === messageSource means "new thread" — no fold needed.
    return anchorSource && anchorSource !== messageSource
      ? anchorSource
      : undefined;
  }

  /**
   * Save a single note attached to an existing thread. See {@link saveNotes}.
   */
  async saveNote(note: NewNote): Promise<Uuid | null> {
    const [id] = await this.saveNotes([note]);
    return id ?? null;
  }

  /**
   * Save one or more notes that attach to an EXISTING thread (addressed by
   * `note.thread: { id }` or `{ source }`), each optionally carrying its own
   * note-attached (note_scoped) link via `note.link`. When `{ source }`
   * resolves to no thread, the runtime find-or-creates the thread by that
   * source. Used for augmenter content (e.g. Granola meeting notes attached to
   * a calendar event's thread).
   *
   * Unlike {@link saveLink}, this does NOT inject the connector's account
   * contact: a note attaches to a thread the owner is already a participant on
   * (created by `upsert_thread`, which files the owner's contact, or it is the
   * calendar event's existing thread), so the redaction case `injectAccountContact`
   * guards against does not arise here. The injection is also link-shaped
   * (it edits `link.accessContacts` and per-note `accessContacts`) and does
   * not translate cleanly to the standalone-note model.
   *
   * Returns one entry per input note, in order. A note that failed to save
   * (e.g. empty content, or its thread couldn't be resolved) lands as `null`
   * in its OWN slot — matching the per-slot alignment contract of
   * {@link saveLinks}.
   */
  async saveNotes(notes: NewNote[]): Promise<(Uuid | null)[]> {
    if (notes.length === 0) return [];
    const plot = this.getPlot();
    // `createNotes` collapses its result — failed/empty notes are dropped
    // rather than returned as null in-slot, so calling it once with the whole
    // batch loses positional alignment on a partial failure. Resolve each note
    // independently so the returned array is precisely per-slot aligned: the id
    // for a succeeded note, or `null` in the failed note's own slot.
    const results = await Promise.all(
      notes.map(async (note) => {
        try {
          const [id] = await plot.createNotes([note]);
          return (id as Uuid) ?? null;
        } catch {
          return null;
        }
      })
    );
    return results;
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

    // Compose send failed: the connector returned a delivery-error marker
    // (originatingNote.deliveryError set, no real link source) instead of a
    // link, because there is no external item to bind. Mark the thread's
    // opening note as failed and stop — do NOT create a link. A later retry
    // re-runs onCreateLink and creates the link on success.
    const composeFailure = (link as any).originatingNote?.deliveryError as
      | { code: string; message?: string | null }
      | null
      | undefined;
    if (
      composeFailure &&
      !(link as any).source &&
      !((link as any).sources?.length)
    ) {
      const openingNote = await this.db
        .selectFrom("note")
        .select("id")
        .where("thread_id", "=", threadId as string)
        .where("draft", "=", false)
        .orderBy("created_at", "asc")
        .limit(1)
        .executeTakeFirst();
      if (openingNote) await this.markSendFailed(openingNote.id, composeFailure);
      return;
    }

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
      priority: link.priority ?? 0,
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
      if (link.priority !== undefined) linkUpsert.priority = link.priority;
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

    // Bind the thread's opening note to the external message this hook just
    // created, so reactions/edits on the first message route back (the same
    // binding onNoteCreated gives replies). Generic across connectors: we
    // just apply the key/baseline the connector returned to the earliest
    // note on the thread. updateNoteBaseline also stamps updated_by with the
    // connector marker so the keyed note doesn't re-enter the create dispatch.
    const originatingNote = (link as any).originatingNote as
      | { key?: string; externalContent?: string; deliveryError?: { code: string; message?: string | null } | null }
      | undefined;
    if (
      originatingNote?.key ||
      originatingNote?.externalContent ||
      originatingNote?.deliveryError !== undefined
    ) {
      const openingNote = await this.db
        .selectFrom("note")
        .select("id")
        .where("thread_id", "=", threadId as string)
        .where("draft", "=", false)
        .orderBy("created_at", "asc")
        .limit(1)
        .executeTakeFirst();
      if (openingNote) {
        await this.updateNoteBaseline(openingNote.id, originatingNote);
        // Bind the opening note to the connector link AND the canonical_source
        // the inbound sync uses for the same message. The note upsert dedups
        // on (thread, link_id, key) / (thread, canonical_source, key) — without
        // these the keyed opening note can't merge with a later re-import of
        // the same message (e.g. when a reaction on it re-syncs the thread),
        // and the message round-trips as a duplicate note.
        const createdLink = await this.db
          .selectFrom("link")
          .select(["id", "source"])
          .where("thread_id", "=", threadId as string)
          .where("created_by", "=", this.twistInstanceId)
          .executeTakeFirst();
        if (createdLink?.id) {
          await this.db
            .updateTable("note")
            .set({
              link_id: createdLink.id,
              canonical_source: createdLink.source ?? null,
            })
            .where("id", "=", openingNote.id)
            .execute();
        }
      }
    }

    // The compose succeeded — drop the stashed retry spec so the thread isn't
    // re-dispatched later. (On failure the connector returns a deliveryError
    // and the spec is intentionally left for the retry path.)
    await this.db
      .updateTable("thread")
      .set({ pending_create_link: null })
      .where("id", "=", threadId as string)
      .where("pending_create_link", "is not", null)
      .execute();

    // Create task schedule for assignee, and notify.
    await this.createTaskScheduleForLink(threadId);

    // Notify sync DOs so the user sees the link appear.
    try {
      const tp = await this.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", threadId as string)
        .executeTakeFirst();
      if (tp?.priority_id) {
        await this.getPlot().notifySyncDOs(new Set([tp.priority_id]));
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
   * Upserts contacts into the connector's priority without requiring a Link.
   *
   * Use this for messaging connectors to bulk-sync workspace members so the
   * recipient picker can filter contacts by reachable platform account. Populate
   * `NewContact.source` to persist `contact_external_account` rows. Returns one
   * `Actor` per input, in order. Delegates to an internal Plot instance.
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
  // archive_links self-derives hard vs soft delete from the filter:
  //  - {channelId} on a channel whose `enabled` is already false → hard-delete
  //    (disableSync sets channel.enabled=false BEFORE dispatching
  //    onChannelDisabled, so the flag is reliably false here). The client
  //    purges via the synced channel.enabled signal.
  //  - {meta}/{type}/{status} (item-specific) → soft-delete, delivered per-link
  //    via user.link_redacted.
  // No p_hard is passed here; the SQL function decides.
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
   * Archives every NOTE this connector created (and the note-attached,
   * note_scoped links those notes carry), optionally scoped to a channel.
   * Mirror of {@link archiveLinks} for the note-attached content model — used
   * by augmenters in `onChannelDisabled`.
   *
   * Both rows are retired with `archived_at = now()` (NEVER a bare DELETE —
   * `note` and `link` are synced tables, so a delete would strand client
   * copies). When `filter.channelId` is set, the notes are scoped via their
   * `link_id` → the note-attached link's `channel_id`, and only links on that
   * channel are archived; without a channelId every note/link this connector
   * created is archived. Sync DOs for affected priorities are notified so
   * clients re-pull and apply the archive locally.
   */
  async archiveNotes(filter: ArchiveNotesFilter): Promise<void> {
    const twistInstanceId = this.twistInstanceId;
    const channelId = filter.channelId;

    // Behavioral analog of archiveLinks (NOT an implementation mirror): it
    // always soft-archives and deliberately leaves the (other-connector-owned)
    // canonical thread + its filing intact, only retiring this connector's own
    // note + note-attached link rows.
    //
    // We operate on `this.db` directly (no inner transaction) — matching
    // applyThreadToDoForUser — so the real method is exercisable by the
    // rollback-harness tests. The two UPDATEs no longer share an explicit
    // transaction; that's acceptable because this is idempotent cleanup (a
    // re-run completes any partially-applied archive).

    // Archive this connector's note-attached (note_scoped) links first so
    // the set of "links on this channel" is captured before any note
    // scoping subquery runs against the same set.
    await sql`
      UPDATE public.link
      SET archived_at = now()
      WHERE created_by = ${twistInstanceId}::uuid
        AND note_scoped = true
        AND archived_at IS NULL
        ${channelId !== undefined ? sql`AND channel_id = ${channelId}` : sql``}
    `.execute(this.db);

    // Archive this connector's notes. When scoped to a channel, restrict to
    // notes whose note-attached link is on that channel (via link_id →
    // link.channel_id); the link rows were just archived above, so match on
    // identity, not on archived state. A channel-scoped archive therefore only
    // sweeps notes WITH a link_id — linkless notes have no channel association.
    // RETURNING the touched thread_ids so we only notify priorities for threads
    // this call actually changed.
    const archivedNotes = await sql<{ thread_id: string }>`
      UPDATE public.note
      SET archived_at = now()
      WHERE created_by = ${twistInstanceId}::uuid
        AND archived_at IS NULL
        ${
          channelId !== undefined
            ? sql`AND link_id IN (
                SELECT l.id FROM public.link l
                WHERE l.created_by = ${twistInstanceId}::uuid
                  AND l.note_scoped = true
                  AND l.channel_id = ${channelId}
              )`
            : sql``
        }
      RETURNING thread_id
    `.execute(this.db);

    const threadIds = [...new Set(archivedNotes.rows.map((r) => r.thread_id))];
    if (threadIds.length === 0) return;

    // Collect the priorities filing the affected threads so sync DOs
    // re-pull and apply the archive locally.
    const rows = await sql<{ priority_id: string }>`
      SELECT DISTINCT tp.priority_id
      FROM public.thread_priority tp
      WHERE tp.thread_id IN (${sql.join(threadIds.map((id) => sql`${id}::uuid`))})
    `.execute(this.db);
    const affectedPriorityIds = rows.rows.map((r) => r.priority_id);

    if (affectedPriorityIds.length > 0) {
      const plot = this.getPlot();
      await plot.notifySyncDOs(new Set(affectedPriorityIds));
    }
  }

  /**
   * Upsert workspace custom emoji into Plot's shared cache so reactions using
   * `provider:workspace/name` refs render as images and round-trip. Idempotent;
   * keyed on `id`. Pass `archived: true` to mark an emoji removed. Workspace-
   * scoped (shared across all users of that workspace).
   *
   * Also stamps this connector's opaque custom-emoji scope
   * (`provider:workspace`) on its twist_instance so the client can offer "this
   * connection's custom emoji" via a prefix match against `custom_emoji.id`,
   * with no workspace/provider logic client-side.
   */
  async saveCustomEmoji(emoji: NewCustomEmoji[]): Promise<void> {
    if (emoji.length === 0) return;
    const now = new Date().toISOString();
    const rows = emoji.map((e) => ({
      id: e.id,
      provider: e.provider,
      workspace_id: e.workspace,
      name: e.name,
      // Alias rows have no own image; the renderer follows alias_of to the
      // canonical image, so store the empty string (image_url is NOT NULL).
      image_url: e.imageUrl ?? "",
      alias_of: e.aliasOf,
      archived_at: e.archived ? now : null,
    }));
    await this.db
      .insertInto("custom_emoji")
      .values(rows)
      .onConflict((oc) =>
        oc.column("id").doUpdateSet((eb) => ({
          provider: eb.ref("excluded.provider"),
          workspace_id: eb.ref("excluded.workspace_id"),
          name: eb.ref("excluded.name"),
          image_url: eb.ref("excluded.image_url"),
          alias_of: eb.ref("excluded.alias_of"),
          archived_at: eb.ref("excluded.archived_at"),
        }))
      )
      .execute();

    // All rows in one call share a workspace; use the first.
    const scope = `${emoji[0].provider}:${emoji[0].workspace}`;
    await this.db
      .updateTable("twist_instance")
      .set({ custom_emoji_scope: scope })
      .where("id", "=", this.twistInstanceId)
      .where((eb) =>
        eb.or([
          eb("custom_emoji_scope", "is", null),
          eb("custom_emoji_scope", "!=", scope),
        ])
      )
      .execute();
  }

  /**
   * Apply or clear to-do (active) state for a specific user on a specific
   * thread. Shared by setThreadToDo (which first resolves thread+user from a
   * source URL + actor) and saveLink (which already has the threadId and uses
   * the connection owner). Never throws on the notify step.
   */
  private async applyThreadToDoForUser(
    threadId: string,
    userId: string,
    todo: boolean,
    options?: { date?: Date | string }
  ): Promise<void> {
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });

    if (todo) {
      let dateStr: string;
      if (options?.date) {
        dateStr = typeof options.date === "string"
          ? options.date
          : options.date.toISOString().slice(0, 10);
      } else {
        dateStr = "1970-01-01";
      }

      await rpcUser(this.db, "upsert_thread_state", {
        user_id: userId,
        p_thread_id: threadId,
        p_active: true,
        p_urgent: false,
        p_importance: 50,
        p_on: `[${dateStr},)`,
        p_set_active: true,
        p_set_urgent: false,
        p_set_importance: false,
        p_set_on: true,
      });

      await this.db
        .updateTable("thread_priority")
        .set({ archived_at: null })
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .where("archived_at", "is not", null)
        .execute();

      try {
        await unarchiveDoneLinksOnThread(this.db, threadId);
      } catch (error) {
        logger.warn("applyThreadToDoForUser: unarchiveDoneLinksOnThread failed", {
          thread_id: threadId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    } else {
      await this.db
        .updateTable("thread_state")
        .set({ read_at: new Date() })
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .where("read_at", "is", null)
        .execute();
    }

    const tp = await this.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", threadId)
      .where("user_id", "=", userId)
      .executeTakeFirst();
    if (tp?.priority_id) {
      try {
        await this.getPlot().notifySyncDOs(new Set([tp.priority_id]));
      } catch (error) {
        logger.error("applyThreadToDoForUser: failed to notify sync DOs", error as Error, {
          thread_id: threadId,
        });
      }
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

    await this.applyThreadToDoForUser(link.thread_id, contact.user_id, todo, options);
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
   * files a 'do' thread_state if non-done, or marks it read if done.
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

      // When status flips to done, mark the user's thread_state read so it
      // drops out of the action tabs.
      const channelLinkTypes = await this.getChannelLinkTypesForThread(threadId);
      if (this.isStatusDone(dbLink.type, dbLink.status, channelLinkTypes.length > 0 ? channelLinkTypes : undefined)) {
        await this.db
          .updateTable("thread_state")
          .set({ read_at: new Date() })
          .where("thread_id", "=", threadId as string)
          .where("user_id", "=", contact.user_id)
          .where("read_at", "is", null)
          .execute();
      }
    } catch (error) {
      console.error("[thread_state] Failed to file thread_state from link assignment:", error);
    }
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
  /**
   * Resolve a thread's contact roster to Contact objects (id + email + name).
   *
   * onNoteCreated/onNoteUpdated dispatch must populate `thread.accessContacts`
   * so connectors can map a note's `accessContacts` (contact IDs) to outbound
   * addresses. The message-mode invariant (app/sync/notes.ts
   * `resolveAccessContactsForSend`) fills every email-thread note's
   * `access_contacts` with the full thread roster, so a connector that
   * constrains recipients by it (Gmail) needs the id→email map here. Without
   * it the allow-set resolves empty and the connector drops the send with
   * "no outbound recipients".
   */
  private async loadThreadAccessContacts(threadId: string): Promise<Contact[]> {
    const threadRow = await this.db
      .selectFrom("thread")
      .select("contacts")
      .where("id", "=", threadId)
      .executeTakeFirst();
    const contactIds = (threadRow?.contacts as string[] | undefined) ?? [];
    if (contactIds.length === 0) return [];
    const rows = await this.db
      .selectFrom("contact")
      .select(["id", "email", "name"])
      .where("id", "in", contactIds)
      .execute();
    return rows.map((r) => ({
      id: r.id as ActorId,
      email: (r.email as string | null) ?? null,
      name: (r.name as string | null) ?? null,
    }));
  }

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
        focus: { id: item.priority_id },
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
      reactions: {},
      accessContacts: (item.access_contacts as any) ?? null,
      archived: item.archived_at !== null,
      actions: item.actions,
      cta: null,
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
      focus: { id: item.priority_id },
      meta,
      accessContacts: await this.loadThreadAccessContacts(item.thread_id!),
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

      // Never (re)dispatch onNoteCreated for an archived note. Defense in depth:
      // the twist_instance_note_create view already excludes archived notes, but
      // the create dispatch is seq-cursor driven, so a note re-surfaces whenever
      // its seq bumps (e.g. archival). Sending a note the user archived — and
      // possibly never sent — is exactly the bug this guards against.
      if (item.archived_at != null) return [];

      const isMentioned = (item.mentions ?? []).includes(this.twistInstanceId);
      if (!isMentioned) return [];

      // Dispatch the reply to onNoteCreated when this connector owns the
      // thread's external counterpart — either it created the thread (synced
      // messages) or it created a link on the thread (a Plot-initiated thread
      // composed to this connector via onCreateLink, where Plot — not the
      // connector — is the thread's created_by). buildNoteAndThread resolves
      // this connector's own link on the thread and populates meta.channelId
      // from it, so a non-null channelId proves link ownership for the
      // Plot-initiated case.
      const { note, thread } = await this.buildNoteAndThread(item);
      if (!threadCreatedByThis && thread.meta?.channelId == null) return [];

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

    // Handle channel_note dispatch — route to source's onNoteCreated
    if (dispatchItem?.itemType === "channel_note" && this.sourceProvider) {
      const { item, isCreate = true } = dispatchItem;
      if (!isCreate || !item) return [];

      // Skip notes created by this twist (prevent loops)
      if (item.created_by === this.twistInstanceId) return [];

      // Never (re)dispatch onNoteCreated for an archived note (see the matching
      // guard on the "note" mention path above).
      if (item.archived_at != null) return [];

      // Skip notes created by ANY twist/connector (prevent cross-connector loops).
      // Negative updated_by indicates twist-originated writes. Channel note dispatch
      // should only fire for user-created notes (replies typed in the app), not for
      // notes created by other connectors during sync.
      if (typeof item.updated_by === "number" && item.updated_by <= 0) return [];

      // Skip notes that mention this connector — those are dispatched via the
      // "note" (mention) path, which now handles both connector-created and
      // Plot-initiated threads. Without this, a thread composed to a channel
      // that is ALSO an enabled synced channel would dispatch onNoteCreated
      // twice (here and via the mention path), double-posting to the service.
      const isMentioned = (item.mentions ?? []).includes(this.twistInstanceId);
      if (isMentioned) return [];

      const note: Note = {
        id: item.id,
        created: item.created_at ? new Date(item.created_at) : new Date(),
        thread: {
          id: item.thread_id,
          title: item.thread_title,
          focus: { id: item.priority_id },
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
        reactions: {},
        accessContacts: (item.access_contacts as any) ?? null,
        archived: item.archived_at !== null,
        actions: item.actions,
        cta: null,
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
        focus: { id: item.priority_id },
        meta,
        accessContacts: await this.loadThreadAccessContacts(
          item.thread_id as string
        ),
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

    // Handle thread_read dispatch — route to connector's onThreadRead.
    // The Plot-tool dispatch path requires plotOptions.thread.access, which
    // connectors don't declare, so dispatch from here for connector-owned threads.
    // Only the connection owner's own read is written back to the external
    // account: a connector has a single external account (the owner's), so
    // another viewer reading a shared thread must NOT mark the owner's mailbox
    // read.
    if (dispatchItem?.itemType === "thread_read" && this.sourceProvider) {
      const { item } = dispatchItem;
      if (!item?.thread_id || !item.user_id) return [];

      // Only dispatch for threads this connector created.
      const link = await this.db
        .selectFrom("link")
        .select(["meta", "channel_id", "source"])
        .where("thread_id", "=", item.thread_id as string)
        .where("created_by", "=", this.twistInstanceId)
        .executeTakeFirst();
      if (!link) return [];

      // Only the connection owner's read writes back to the external account.
      const owner = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirst();
      if (!owner || owner.owner_id !== item.user_id) return [];

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

      // Resolve actor from the reading user's primary linked contact.
      let actor: Actor = {
        id: item.user_id as ActorId,
        type: ActorType.User,
        name: null,
      };
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

      const thread: Partial<Thread> = {
        id: threadRow.id as Uuid,
        title: threadRow.title ?? "",
        archived: threadRow.archived_at !== null,
        meta,
      };

      // unread mirrors the Plot-tool path: read_at set => now read (unread=false);
      // read_at cleared => now unread (unread=true).
      const unread = !item.read_at;

      return [{
        sourceMethod: "onThreadRead",
        args: [thread, actor, unread],
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

    // Handle thread_contacts dispatch — route to connector's onContactsChanged.
    // Fired when a user changes thread-level sharing (adds/removes a contact or
    // changes a role) on a thread this connector owns. The caller
    // (`dispatchThreadContactsChanged`) has already computed the membership/role
    // diff from before/after snapshots; here we resolve the contact ids to SDK
    // Contact objects and hand the change to the connector. Like the sibling
    // handlers, the Plot-tool dispatch path needs `plotOptions.thread.access`
    // (which connectors don't declare), so we dispatch from here.
    if (dispatchItem?.itemType === "thread_contacts" && this.sourceProvider) {
      const { item } = dispatchItem as {
        item?: {
          thread_id?: string;
          added?: Array<{ contactId: string; role: string | null }>;
          removed?: Array<{ contactId: string; role: string | null }>;
          changed?: Array<{ contactId: string; from: string | null; to: string | null }>;
        };
      };
      if (!item?.thread_id) return [];

      const added = item.added ?? [];
      const removed = item.removed ?? [];
      const changed = item.changed ?? [];
      if (added.length === 0 && removed.length === 0 && changed.length === 0) {
        return [];
      }

      // Only dispatch for threads this connector created.
      const link = await this.db
        .selectFrom("link")
        .select(["meta", "channel_id", "source"])
        .where("thread_id", "=", item.thread_id)
        .where("created_by", "=", this.twistInstanceId)
        .executeTakeFirst();
      if (!link) return [];

      const threadRow = await this.db
        .selectFrom("thread")
        .select(["id", "title", "archived_at"])
        .where("id", "=", item.thread_id)
        .executeTakeFirst();
      if (!threadRow) return [];

      // Resolve every referenced contact id to an SDK Contact in one query.
      const ids = [
        ...added.map((c) => c.contactId),
        ...removed.map((c) => c.contactId),
        ...changed.map((c) => c.contactId),
      ];
      const uniqueIds = Array.from(new Set(ids));
      const contactRows = uniqueIds.length
        ? await this.db
            .selectFrom("contact")
            .select(["id", "name", "email"])
            .where("id", "in", uniqueIds)
            .execute()
        : [];
      const contactById = new Map<string, Contact>();
      for (const row of contactRows) {
        contactById.set(row.id as string, {
          id: row.id as ActorId,
          name: row.name ?? null,
          email: row.email ?? null,
        });
      }
      const resolve = (id: string): Contact =>
        contactById.get(id) ?? { id: id as ActorId, name: null, email: null };

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

      const changes = {
        added: added.map((c) => ({ contact: resolve(c.contactId), role: c.role })),
        removed: removed.map((c) => ({ contact: resolve(c.contactId), role: c.role })),
        changed: changed.map((c) => ({ contact: resolve(c.contactId), from: c.from, to: c.to })),
      };

      return [{
        sourceMethod: "onContactsChanged",
        args: [thread, changes],
      }];
    }

    // Handle note_reaction dispatch — route to connector's onNoteReactionChanged.
    // The view (`twist_instance_note_reaction_change`) has already routed this
    // event to the reactor's own connector instance via twist_instance_for_actor,
    // so the connector method runs under the reactor's auth automatically and
    // the write-back (`api.addReaction` etc.) is correctly attributed.
    if (dispatchItem?.itemType === "note_reaction" && this.sourceProvider) {
      const { item } = dispatchItem;
      if (!item || !item.note_id || !item.emoji || !item.actor_id) {
        return [];
      }

      const noteRow = await this.db
        .selectFrom("note")
        .select(["id", "thread_id", "key", "content", "created_by", "created_at", "updated_at"])
        .where("id", "=", item.note_id as string)
        .executeTakeFirst();
      if (!noteRow?.thread_id) {
        return [];
      }

      const threadRow = await this.db
        .selectFrom("thread")
        .select(["id", "title", "archived_at"])
        .where("id", "=", noteRow.thread_id as string)
        .executeTakeFirst();
      if (!threadRow) {
        return [];
      }

      // Resolve thread meta from a link this connector owns on this thread
      // (the same source we'd use for any other dispatch on this thread).
      const link = await this.db
        .selectFrom("link")
        .select(["meta", "channel_id", "source", "created_by"])
        .where("thread_id", "=", noteRow.thread_id as string)
        .where("created_by", "=", this.twistInstanceId)
        .executeTakeFirst();

      const meta: ThreadMeta = {
        ...((link?.meta as Record<string, unknown>) ?? {}),
        channelId: link?.channel_id ?? null,
        linkSource: link?.source ?? null,
      } as ThreadMeta;


      const thread: Partial<Thread> = {
        id: threadRow.id as Uuid,
        title: threadRow.title ?? "",
        archived: threadRow.archived_at !== null,
        meta,
      };

      const note: Partial<Note> = {
        id: noteRow.id as Uuid,
        key: noteRow.key ?? null,
        content: noteRow.content ?? null,
      };

      const actor: Actor = {
        id: item.actor_id as ActorId,
        type: ActorType.Contact,
        name: null,
      };

      return [{
        sourceMethod: "onNoteReactionChanged",
        args: [note, thread, actor, item.emoji as string, item.archived_at == null],
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
          recipients?: ResolvedRecipient[];
          inviteEmails?: string[];
        };
      };
      if (!threadId || !draft) return [];

      // For link types whose compose.targets is "contacts" or "addresses",
      // pre-resolve the picked contacts to their platform account IDs so
      // connectors don't need to do their own contact lookup in onCreateLink.
      // Contacts without a matching contact_external_account row are silently
      // dropped — the connector can detect the gap via
      // contacts.length vs recipients.length.
      //
      // Resolution is skipped (recipients stays undefined) for channel-target
      // link types and when no contacts were picked.
      const provider = this.sourceProvider.provider;
      if (provider && draft.contacts.length > 0) {
        // Resolve the link type config for this draft's type. Check
        // channel-level linkTypes first (from the DB row), then fall back to
        // the connector-level declaration in sourceProvider.linkTypes.
        let linkTypeConfig: LinkTypeConfig | undefined;
        try {
          const channelRow = await this.db
            .selectFrom("channel")
            .select("link_types")
            .where("twist_instance_id", "=", this.twistInstanceId)
            .where("channel_id", "=", draft.channelId)
            .executeTakeFirst();
          if (channelRow?.link_types) {
            const parsed: unknown = typeof channelRow.link_types === "string"
              ? JSON.parse(channelRow.link_types)
              : channelRow.link_types;
            if (Array.isArray(parsed)) {
              linkTypeConfig = (parsed as LinkTypeConfig[]).find((lt) => lt.type === draft.type);
            }
          }
        } catch {
          // Non-fatal: fall through to sourceProvider fallback
        }
        if (!linkTypeConfig) {
          const sourceLinkTypes = this.sourceProvider.linkTypes as LinkTypeConfig[] | undefined;
          linkTypeConfig = sourceLinkTypes?.find((lt) => lt.type === draft.type);
        }

        const composeTargets = linkTypeConfig?.compose?.targets;
        if (
          composeTargets === "contacts" ||
          composeTargets === "addresses"
        ) {
          const contactIds = draft.contacts.map((c) => c.id);

          // Resolve each contact's role (e.g. to/cc/bcc) from the
          // originating thread's contact_meta so role-aware connectors can
          // honor it. Gmail in particular must keep CC/BCC recipients out
          // of the To: header — placing a BCC recipient in To: exposes them
          // to everyone else on the message (privacy leak). Missing entries
          // → null, which the connector treats as its default role.
          const roleByContactId = new Map<string, string>();
          try {
            const threadRow = await this.db
              .selectFrom("thread")
              .select("contact_meta")
              .where("id", "=", threadId)
              .executeTakeFirst();
            const meta: unknown =
              threadRow?.contact_meta == null
                ? null
                : typeof threadRow.contact_meta === "string"
                  ? JSON.parse(threadRow.contact_meta)
                  : threadRow.contact_meta;
            if (meta && typeof meta === "object") {
              for (const [cid, entry] of Object.entries(
                meta as Record<string, unknown>,
              )) {
                const role = (entry as { role?: unknown } | null)?.role;
                if (typeof role === "string") roleByContactId.set(cid, role);
              }
            }
          } catch {
            // Non-fatal: recipients fall back to null role (connector default).
          }

          // Scope by twist_instance_id (the connection): two Slack workspaces
          // with the same Plot contact have separate `contact_external_account`
          // rows, one per workspace. Returning only this connection's rows is
          // what lets the dispatched message route to the right workspace.
          const rows = await this.db
            .selectFrom("contact_external_account")
            .innerJoin("contact", "contact.id", "contact_external_account.contact_id")
            .where("contact_external_account.twist_instance_id", "=", this.twistInstanceId)
            .where("contact_external_account.contact_id", "in", contactIds)
            .select([
              "contact.id",
              "contact.name",
              "contact_external_account.account_id",
            ])
            .execute();

          if (composeTargets === "contacts") {
            draft.recipients = rows.map((r) => ({
              id: r.id as Uuid,
              name: r.name ?? null,
              externalAccountId: r.account_id,
              role: roleByContactId.get(r.id) ?? null,
            }));
          } else {
            // "addresses": fall back to contact.email (lowercased) for any
            // picked contact without a connection-scoped row. Contacts with
            // neither a row nor an email are dropped silently.
            const byContactId = new Map(rows.map((r) => [r.id, r] as const));
            const missingIds = contactIds.filter((id) => !byContactId.has(id as Uuid));
            const fallbackRows = missingIds.length
              ? await this.db
                  .selectFrom("contact")
                  .select(["id", "name", "email"])
                  .where("id", "in", missingIds)
                  .execute()
              : [];
            const fallbackById = new Map(fallbackRows.map((r) => [r.id, r] as const));
            const recipients: ResolvedRecipient[] = [];
            for (const contactId of contactIds) {
              const row = byContactId.get(contactId as Uuid);
              if (row) {
                recipients.push({
                  id: row.id as Uuid,
                  name: row.name ?? null,
                  externalAccountId: row.account_id,
                  role: roleByContactId.get(row.id) ?? null,
                });
                continue;
              }
              const fallback = fallbackById.get(contactId);
              if (fallback?.email) {
                recipients.push({
                  id: fallback.id as Uuid,
                  name: fallback.name ?? null,
                  externalAccountId: fallback.email.toLowerCase(),
                  role: roleByContactId.get(fallback.id) ?? null,
                });
              }
            }
            draft.recipients = recipients;
          }
        }
      }

      // Pass the draft's channelId and type through forwardTo so
      // saveCreatedLink can default them on the returned link if the
      // connector omitted them. That way connectors don't have to remember
      // to echo channelId/type on every onCreateLink return — status label
      // resolution and other channel-scoped rendering would silently fail
      // otherwise.
      const createEntries: any[] = [{
        sourceMethod: "onCreateLink",
        args: [draft],
        forwardTo: {
          functionName: "saveCreatedLink",
          prependArgs: [threadId, draft.channelId, draft.type],
        },
      }];

      // Observe the composed channel so inbound events (replies/reactions) on
      // this thread sync back. Only for bidirectional connectors
      // (handleReplies) and only when the channel isn't already enabled.
      // Dispatched observeOnly so the connector registers webhooks but skips
      // historical backfill — the user posted one thread, they didn't opt to
      // sync the whole channel's history.
      if (
        this.sourceProvider.handleReplies &&
        this.sourceProvider.provider &&
        draft.channelId
      ) {
        const alreadyEnabled = await this.db
          .selectFrom("channel")
          .select("channel_id")
          .where("twist_instance_id", "=", this.twistInstanceId)
          .where("channel_id", "=", draft.channelId)
          .where("enabled", "=", true)
          .executeTakeFirst();
        if (!alreadyEnabled) {
          const observeContext = await this.buildSyncContext();
          observeContext.observeOnly = true;
          const enablerActorId = (await this.getPlot().getUserId()) as ActorId;
          const observeEntry = await this.applyChannelEnabled(
            this.sourceProvider.provider as AuthProvider,
            enablerActorId,
            // Title defaults to the channel id; the connector's getChannels /
            // setChannels refreshes it with the real name on next sync.
            { id: draft.channelId, title: draft.channelId },
            observeContext,
            true
          );
          if (observeEntry) createEntries.push(observeEntry);
        }
      }

      return createEntries as any;
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
   *
   * `details` (optional) carries the reason this connection was flagged. When
   * a row is *newly* flagged it's emitted to PostHog as `connector_needs_reauth`
   * — the DB column only stores a timestamp, so this is the only durable record
   * of *why* the connection demanded re-auth (worker logs age out within days).
   */
  private async flagNeedsReauth(
    provider: AuthProvider,
    actorId: ActorId,
    details?: {
      trigger:
        | "refresh_permanent"
        | "no_refresh_token"
        | "insufficient_scope"
        | "token_missing"
        | "connector_signal";
      reason: string;
      oauthError?: string | null;
      status?: number | null;
    }
  ): Promise<void> {
    // The actual write + client notify + telemetry live in the shared
    // `flagConnectionNeedsReauth` helper so every "this connection's credential
    // is dead" path (OAuth refresh failures here, missing Unipile credentials
    // in the messaging tool's assertAccount) produces identical state.
    await flagConnectionNeedsReauth(this.db, this.env, {
      twistInstanceId: this.twistInstanceId,
      provider,
      actorId,
      details,
    });
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
    await this.flagNeedsReauth(provider, config.enabledBy, {
      trigger: "connector_signal",
      reason: `Connector reported a permanent auth error for channel ${channelId}`,
    });
  }

  /**
   * Sweep-time re-auth signal. The daily channel-refresh sweep calls a
   * connector's getChannels via the stored token; if the token is missing a
   * required scope the provider returns a 403 (e.g. Google
   * ACCESS_TOKEN_SCOPE_INSUFFICIENT). That error reaches the sweep only as a
   * flattened `__TWIST_ERROR__` string, so we classify it here and flag the
   * connection for re-auth. Returns true when it flagged.
   *
   * Conservative by design: only the explicit insufficient-scope markers flag.
   * A generic 403 (ACL, transient WAF) is left alone — a false positive would
   * force a needless reconnect.
   */
  async flagReauthIfInsufficientScope(
    provider: AuthProvider,
    actorId: ActorId,
    rawErrorMessage: string
  ): Promise<boolean> {
    if (!isInsufficientScopeError(rawErrorMessage)) return false;
    await this.flagNeedsReauth(provider, actorId, {
      trigger: "insufficient_scope",
      reason: rawErrorMessage,
    });
    return true;
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
            await this.flagNeedsReauth(provider, actorId, {
              trigger: "refresh_permanent",
              reason,
              oauthError: refreshErr.oauthError,
              status: refreshErr.status,
            });
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
      await this.flagNeedsReauth(provider, actorId, {
        trigger: "no_refresh_token",
        reason: "Access token expired and no refresh_token is stored",
      });
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
        // Reset the watchdog's recovery budget — this sync attempt ended, so a
        // later re-enable starts fresh. See recover-stuck-syncs.ts.
        .set({ initial_sync_completed_at: nowIso, initial_sync_attempts: 0 })
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
   * Remove the auth keys persisted for an actor during onAuth. onAuth stores
   * the token (and enabled scope groups) BEFORE the account-match / dedup
   * guards run, so when a guard rejects the just-authed account those keys are
   * left behind. getIntegrationData lists accounts by scanning `auth_token:`
   * keys, so an orphaned token surfaces the rejected account as a phantom
   * second account on a connection that must only ever have one. Call this
   * before each guard rejection to undo the speculative writes.
   */
  private async clearStoredAuthForActor(
    provider: AuthProvider,
    actorId: ActorId
  ): Promise<void> {
    // Best-effort: this runs immediately before a guard's tagged throw
    // (AUTH_ACCOUNT_MISMATCH/DUPLICATE), which HandleOauthCallback maps to a
    // specific user-facing message. A transient store failure here must not
    // mask that tagged error — swallow and log, then let the guard throw.
    try {
      await this.store.clear(`auth_token:${provider}:${actorId}`);
      await this.store.clear(`enabled_scope_groups:${provider}:${actorId}`);
    } catch (error) {
      createLogger({ twist_instance_id: this.twistInstanceId }).warn(
        "clearStoredAuthForActor failed (best-effort cleanup)",
        {
          provider,
          actor_id: actorId,
          error: error instanceof Error ? error.message : String(error),
        }
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

    // Parse provider-specific data if handler exists (may be async). For
    // hosted-auth providers the caller already builds the providerData (we
    // don't have an OAuth response to parse), so fall through to it when
    // there's no parser or the parser returned null.
    const parsedFromTokenInfo =
      (await config?.parseTokenResponse?.(tokenInfo)) ?? null;
    const providerData =
      parsedFromTokenInfo ?? (tokenInfo.providerData as ProviderData | null) ?? null;

    // Extract email from providerData and link to contact, building actor.
    // For providers that don't surface an email (e.g. Slack user-token-only
    // OAuth), fall back to the provider's user id so buildActor can dedupe
    // the auth to a single contact linked to the twist_instance owner.
    const email = this.extractEmail(providerData);
    const providerUserId = extractUserId(tokenInfo.provider, providerData);
    let actor: Actor;
    try {
      if (config?.authMode === "hosted") {
        // Hosted connections (LinkedIn/Instagram/WhatsApp) belong to the
        // connecting OWNER. Bind the token to the owner's primary contact — the
        // SAME contact activateDraft enables the channel under
        // (`contact WHERE user_id = owner_id`). An email-resolved contact
        // (buildActor) diverges from that whenever the provider email is
        // absent, mismatched, populated late, or duplicated — and then every
        // sync fails with "has no stored credentials — reconnect". Binding to
        // the owner contact keeps onAuth and the channel's enabledBy in lockstep
        // (and stops spurious duplicate contacts).
        const owner = await this.db
          .selectFrom("twist_instance")
          .select("owner_id")
          .where("id", "=", this.twistInstanceId)
          .executeTakeFirst();
        const ownerContact = owner?.owner_id
          ? await this.db
              .selectFrom("contact")
              .select(["id", "name"])
              .where("user_id", "=", owner.owner_id)
              .executeTakeFirst()
          : null;
        actor = ownerContact?.id
          ? {
              id: ownerContact.id as ActorId,
              type: ActorType.Contact,
              name: ownerContact.name ?? null,
            }
          : await this.buildActor(email, tokenInfo.provider, providerUserId);
      } else {
        actor = await this.buildActor(email, tokenInfo.provider, providerUserId);
      }
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

    // Store provider ID mapping for source-based contact lookup. The row is
    // scoped to (twist_instance_id, account_id) so the same OAuth account
    // can be linked to multiple twist instances (e.g. one Slack workspace
    // per Slack connection) without collision.
    if (providerUserId && contact) {
      try {
        await this.db
          .insertInto("contact_external_account")
          .values({
            contact_id: actor.id,
            twist_instance_id: this.twistInstanceId,
            provider: tokenInfo.provider,
            account_id: providerUserId,
            data_fetched_at: new Date().toISOString(),
          })
          .onConflict((oc) =>
            oc.columns(["twist_instance_id", "account_id"]).doUpdateSet((eb) => ({
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
      // Prior connection state for THIS instance. Fetched OUTSIDE the
      // write try/catch below so the guard rejections that follow actually
      // propagate to HandleOauthCallback instead of being swallowed as a
      // logged warning.
      const previousRow = await this.db
        .selectFrom("twist_instance_connection")
        .select(["actor_id", "needs_reauth_at"])
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where("user_id", "=", contact.user_id)
        .where("provider", "=", tokenInfo.provider)
        .executeTakeFirst();
      const previousActorId = previousRow?.actor_id ?? null;
      isRecovery = previousRow?.needs_reauth_at != null;

      // Re-auth account-match guard. A connection is bound to one account.
      // If this instance already has a connection and the user just
      // authenticated a DIFFERENT account, reject — re-auth must stay on the
      // original account, otherwise the connection would silently re-point at
      // a different mailbox. (login_hint pre-selects the right account, so
      // this mainly fires when the user deliberately picks another.) To move
      // a connection to a different account, remove it and add a new one.
      if (previousActorId && previousActorId !== actor.id) {
        // A re-auth that resolves a DIFFERENT actor usually means the user
        // picked another account/mailbox — reject so the connection doesn't
        // silently re-point. But ALLOW it when the SAME upstream account is
        // being re-bound to a corrected contact (e.g. an earlier bind resolved
        // the wrong contact — before the hosted-auth email fix): the connection
        // stays on the same account, just under the right actor.
        const prevToken = await this.store.get<StoredTokenData>(
          `auth_token:${tokenInfo.provider}:${previousActorId}`
        );
        const sameUpstreamAccount =
          !!prevToken?.access_token &&
          prevToken.access_token === effectiveAccessToken;
        if (!sameUpstreamAccount) {
          const expected = await this.db
            .selectFrom("contact")
            .select("email")
            .where("id", "=", previousActorId)
            .executeTakeFirst();
          const expectedEmail = expected?.email ?? null;
          // Undo the token + scope-group writes for the rejected account so it
          // doesn't linger as a phantom second account in getIntegrationData.
          await this.clearStoredAuthForActor(tokenInfo.provider, actor.id);
          throw new Error(
            `${AUTH_ACCOUNT_MISMATCH_ERROR}: re-auth used a different account` +
              (expectedEmail ? ` (expected ${expectedEmail})` : "")
          );
        }
        createLogger({ twist_instance_id: this.twistInstanceId }).info(
          "onAuth: re-binding the same account to a corrected contact",
          {
            provider: tokenInfo.provider,
            previous_actor_id: previousActorId,
            new_actor_id: actor.id,
          }
        );
      }

      // Dedup guard. Brand-new connect (this instance has no connection yet)
      // for an account that is already connected on ANOTHER instance of the
      // SAME connector. Prevents duplicate connections of one account — the
      // bug that left users with two Gmail connections, the second of which
      // received a non-refreshable token and 401'd after ~1h. Scoped to the
      // same twist package (twist_id) so connecting one Google account to
      // both Gmail and Calendar (different connectors) stays allowed.
      //
      // Only ACTIVE connections count: committed (draft = false) AND has at
      // least one enabled channel. A committed-but-channel-less orphan (left
      // behind when a user backs out after OAuth but before picking channels)
      // must NOT silently block a re-connect of the same account. See
      // isActiveConnection in active-connection.ts for the shared definition.
      if (!previousActorId) {
        const selfInstance = await this.db
          .selectFrom("twist_instance")
          .select("twist_id")
          .where("id", "=", this.twistInstanceId)
          .executeTakeFirst();
        if (selfInstance) {
          const duplicate = await this.db
            .selectFrom("twist_instance_connection as tic")
            .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
            .select("tic.twist_instance_id")
            .where("ti.twist_id", "=", selfInstance.twist_id)
            .where("ti.archived_at", "is", null)
            .where("ti.draft", "=", false) // ignore in-progress (uncommitted) setups
            .where("tic.user_id", "=", contact.user_id)
            .where("tic.provider", "=", tokenInfo.provider)
            .where("tic.actor_id", "=", actor.id)
            .where("tic.twist_instance_id", "!=", this.twistInstanceId)
            // Only an ACTIVE connection (>=1 enabled channel) blocks a re-connect.
            // A committed-but-channel-less orphan must not silently block the user.
            .where((eb) =>
              eb.exists(
                eb
                  .selectFrom("channel as ch")
                  .select("ch.id")
                  .whereRef("ch.twist_instance_id", "=", "tic.twist_instance_id")
                  .where("ch.enabled", "=", true),
              ),
            )
            .executeTakeFirst();
          if (duplicate) {
            // Undo the token + scope-group writes for the rejected account so it
            // doesn't linger as a phantom account in getIntegrationData.
            await this.clearStoredAuthForActor(tokenInfo.provider, actor.id);
            throw new Error(
              `${AUTH_ACCOUNT_DUPLICATE_ERROR}: account already connected to this connector`
            );
          }
        }
      }

      try {
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

    // Call legacy callback token if provided (for backward compat / direct request() calls)
    if (callbackToken) {
      try {
        const _result = await invokeWebhookCallback(
          this.env,
          this.ctx,
          callbackToken,
          authorization
        );
        disposeRpc(_result);
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

    // For hosted-auth providers (LinkedIn, etc.) the token's access_token is
    // the Unipile account id. Capture it now so we can delete the upstream
    // account after the local token is cleared.
    let hostedAccountId: string | null = null;
    if (PROVIDER_CONFIGS[provider]?.authMode === "hosted") {
      const existing = await this.store.get<StoredTokenData>(tokenKey);
      hostedAccountId = existing?.access_token ?? null;
    }

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

    // Delete the upstream Unipile account, unless another live hosted token
    // still references it (channel reassignment). For personal hosted accounts
    // there is never another owner, so this deletes. Best-effort.
    if (hostedAccountId) {
      const stillReferenced = await this.hostedAccountStillReferenced(
        provider,
        hostedAccountId
      );
      if (!stillReferenced) {
        await deleteUnipileAccount(this.env, hostedAccountId);
      }
    }

    // Return dispatch info for the entrypoint to invoke locally
    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  /**
   * True iff some OTHER stored auth token for this provider still points at the
   * given Unipile account id. removeAuth has already cleared the removed
   * actor's token, so a match here means a different actor still owns the
   * account (the channel-reassignment case) and we must not delete it upstream.
   */
  private async hostedAccountStillReferenced(
    provider: AuthProvider,
    accountId: string
  ): Promise<boolean> {
    const keys = await this.store.list(`auth_token:${provider}:`);
    for (const key of keys) {
      const token = await this.store.get<StoredTokenData>(key);
      if (token?.access_token === accountId) return true;
    }
    return false;
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
    providers: Array<{ provider: AuthProvider; scopes: string[]; optionalScopes?: any[]; access?: string[]; description?: string[] }>;
    accounts: Array<{
      provider: AuthProvider;
      actorId: ActorId;
      email: string | null;
      name: string | null;
      autoEnableNewChannels: boolean;
      autoThreadingEnabled: boolean;
      enabledScopeGroups?: string[];
      // External URL where the user manages app authorization for this
      // provider (e.g. GitHub's "manage organization access" page). Surfaced
      // by the modal when present; null/omitted otherwise.
      manageAccessUrl?: string | null;
    }>;
    syncables: Array<{
      provider: AuthProvider;
      id: string;
      title: string;
      enabledByDefault?: boolean;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      currentUserHasAccess: boolean;
      children?: Array<{
        provider: AuthProvider;
        id: string;
        title: string;
        enabledByDefault?: boolean;
        enabled: boolean;
        enabledBy: ActorId | undefined;
        currentUserHasAccess: boolean;
        children?: any[];
      }>;
    }>;
    // OAuth scopes actually granted to this connection, unioned across every
    // connected account/actor. Used by the combined-connector productStatus
    // computation to tell which products' scopes the user consented to.
    grantedScopes: string[];
  }> {
    const providers = this.providerConfigs.map(p => ({
      provider: p.provider,
      scopes: p.scopes,
      ...(p.optionalScopes ? { optionalScopes: p.optionalScopes } : {}),
      // `description` mirrors `access` for backwards-compat with pre-access
      // Flutter clients that still read the old `description` field; it can be
      // dropped once those clients are gone.
      ...(p.access ? { access: p.access, description: p.access } : {}),
    }));

    // Resolve all contact IDs belonging to the current user so we can
    // correctly mark currentUserHasAccess for linked contacts.
    const currentUserContactIds = new Set<string>();
    let currentUserId: string | null = null;
    if (currentActorId) {
      currentUserContactIds.add(currentActorId);
      const currentContact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", currentActorId)
        .executeTakeFirst();
      if (currentContact?.user_id) {
        currentUserId = currentContact.user_id;
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
      autoThreadingEnabled: boolean;
      enabledScopeGroups?: string[];
      manageAccessUrl?: string | null;
    }> = [];

    // Track which channel IDs have access from any current-user contact
    const channelAccessByCurrentUser = new Set<string>();

    // Union of OAuth scopes granted across every connected account/actor.
    const grantedScopesSet = new Set<string>();

    // Collect channel trees per provider (merged across actors)
    type AnnotatedChannel = {
      provider: AuthProvider;
      id: string;
      title: string;
      enabledByDefault?: boolean;
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

        // Fan out the independent reads — token data, contact, scope group
        // selections, auto-enable flag, and channel access tree. Each is a
        // separate Durable Object / DB round-trip with no inter-dependency,
        // so doing them sequentially adds latency for nothing.
        const [
          tokenData,
          contactRow,
          enabledScopeGroups,
          autoEnableSetting,
          autoThreadingSetting,
          actorChannels,
        ] = await Promise.all([
          this.store.get<StoredTokenData>(tokenKey),
          actorId
            ? this.db
                .selectFrom("contact")
                .select("user_id")
                .where("id", "=", actorId)
                .executeTakeFirst()
            : Promise.resolve(undefined),
          this.store.get<string[]>(
            `enabled_scope_groups:${provider}:${actorId}`
          ),
          this.store.get<boolean>(
            `auto_enable_new_channels:${provider}:${actorId}`
          ),
          this.store.get<boolean>(
            `auto_threading_enabled:${provider}:${actorId}`
          ),
          this.getChannelAccess(provider, actorId as ActorId),
        ]);

        // Self-heal: hosted-auth providers (LinkedIn, future WhatsApp/Instagram)
        // can land here with an empty providerData.fullName when the initial
        // /users/me probe at auth time failed (rate limit, transient). Re-try
        // the probe lazily here so the modal eventually shows the right label
        // without forcing the user to re-auth — important because the auth
        // hop itself is rate-limited by the provider and risks an account
        // ban under repeated attempts.
        const refreshedTokenData = await this.maybeRefreshHostedProviderData(
          provider,
          actorId,
          tokenData
        );
        const effectiveTokenData = refreshedTokenData ?? tokenData;

        // Accumulate granted scopes (combined-connector productStatus reads
        // this union to decide which products' scopes were consented to).
        for (const s of effectiveTokenData?.scopes ?? []) {
          grantedScopesSet.add(s);
        }

        const email = effectiveTokenData
          ? this.extractEmail(effectiveTokenData.providerData)
          : null;

        // contact.name is intentionally NOT used as the account label — it's
        // the connected person's display name, not the workspace/account
        // disambiguator the modal is trying to show.
        const contactUserId = contactRow?.user_id ?? null;

        // Prefer the provider-level account label (Slack workspace, Notion
        // workspace, Atlassian site, …) — it's the useful disambiguator for
        // "which connection is this?". For providers that only expose an
        // email (Google, Microsoft) the email is surfaced separately below.
        // For providers whose `extractAccountLabel` returns the email we also
        // reuse it as the label so the UI shows something.
        const name: string | null = effectiveTokenData?.providerData
          ? (PROVIDER_CONFIGS[provider]?.extractAccountLabel?.(
              effectiveTokenData.providerData
            ) ?? null)
          : null;

        // Fall back to the connector's declared default when the user has
        // never set an explicit preference (null). This is display-only — the
        // enforcement path in setChannels reads the raw stored value, and the
        // default is persisted for enforcement at connection activation (see
        // initAutoEnableDefault). The user's explicit toggle always wins.
        const autoEnableNewChannels =
          autoEnableSetting ??
          this.sourceProvider?.autoEnableNewChannelsByDefault ??
          false;
        // Same display-only fallback for the auto-threading toggle state.
        const autoThreadingEnabled =
          autoThreadingSetting ??
          this.sourceProvider?.autoThreadingByDefault ??
          false;

        accounts.push({
          provider,
          actorId: actorId as ActorId,
          email,
          name,
          autoEnableNewChannels,
          autoThreadingEnabled,
          ...(enabledScopeGroups ? { enabledScopeGroups } : {}),
          ...(buildManageAccessUrl(provider, this.env)
            ? { manageAccessUrl: buildManageAccessUrl(provider, this.env) }
            : {}),
        });

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

    // Backfill bound connections that have no auth_token yet — a connection
    // has a twist_instance_connection row but no token when it's
    // bankruptcy-provisioned (never authed) or its token was cleared on a
    // permanent refresh failure (needs-reauth). The token scan above misses
    // these, so the reconnect modal can't show / pre-select which account to
    // sign in as (empty accounts → null accountHint → no OAuth login_hint).
    // Scoped to the current user so a shared instance never leaks another
    // user's bound account/email to the viewer.
    if (this.providerConfigs.length > 0 && currentUserId) {
      const boundRows = await this.db
        .selectFrom("twist_instance_connection as tic")
        .leftJoin("contact as c", "c.id", "tic.actor_id")
        .select(["tic.provider", "tic.actor_id", "c.email"])
        .where("tic.twist_instance_id", "=", this.twistInstanceId)
        .where("tic.user_id", "=", currentUserId)
        .where(
          "tic.provider",
          "in",
          this.providerConfigs.map((p) => p.provider)
        )
        .execute();
      // Only the rows with no token-based account, enriched with their OWN
      // stored settings — a token-cleared needs-reauth account may still carry
      // auto-enable / auto-threading / scope-group selections that must survive.
      for (const conn of boundConnectionsWithoutToken(accounts, boundRows)) {
        const provider = conn.provider as AuthProvider;
        const actorId = conn.actor_id as ActorId;
        const [autoEnableSetting, autoThreadingSetting, enabledScopeGroups] =
          await Promise.all([
            this.store.get<boolean>(
              `auto_enable_new_channels:${provider}:${actorId}`
            ),
            this.store.get<boolean>(
              `auto_threading_enabled:${provider}:${actorId}`
            ),
            this.store.get<string[]>(
              `enabled_scope_groups:${provider}:${actorId}`
            ),
          ]);
        accounts.push({
          provider,
          actorId,
          email: conn.email,
          name: null,
          autoEnableNewChannels:
            autoEnableSetting ??
            this.sourceProvider?.autoEnableNewChannelsByDefault ??
            false,
          autoThreadingEnabled:
            autoThreadingSetting ??
            this.sourceProvider?.autoThreadingByDefault ??
            false,
          ...(enabledScopeGroups ? { enabledScopeGroups } : {}),
        });
      }
    }

    // Pre-fetch all channel rows for this twist instance in a single DB
    // query. The previous per-channel `getChannelConfig` call did one DB
    // SELECT + one Durable Object read per channel, sequentially — for
    // connectors with many channels (e.g. Drive with many shared drives /
    // folders) that waterfall dominated the response time. After
    // mirrorChannelsToDb above, every channel reachable from the DO access
    // tree should be present in this row set.
    const dbChannels = await this.db
      .selectFrom("channel")
      .select(["channel_id", "enabled", "title"])
      .where("twist_instance_id", "=", this.twistInstanceId)
      .execute();
    const dbChannelMap = new Map(
      dbChannels.map((c) => [c.channel_id, c])
    );

    // Annotate channel trees with config and access info
    const annotateChannelTree = async (
      provider: AuthProvider,
      channels: Channel[]
    ): Promise<AnnotatedChannel[]> => {
      const result: AnnotatedChannel[] = [];
      for (const channel of channels) {
        const dbRow = dbChannelMap.get(channel.id);
        // Fast path: channel was mirrored to DB. `enabledBy` is only stored
        // in DO KV and is currently unused by the modal client, so we skip
        // the per-channel KV fetch in this path. If we later need it,
        // pre-fetch all `channel_config:*` keys via a batch DO read.
        // Slow-path fallback: channel missing from DB (mirror failed or hasn't
        // run for this channel yet) — read both DB row and KV config. Single-
        // call latency, only triggered for the rare un-mirrored channel.
        const channelConfig = dbRow
          ? { enabled: dbRow.enabled, enabledBy: undefined, title: dbRow.title }
          : await this.getChannelConfig(provider, channel.id);
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
          // Carry the connector's default-enable signal (tri-state) through to
          // the setup UI. Stored verbatim in the DO channel-access tree by
          // setChannels, so it survives without a DB column. Propagate `false`
          // too (it means "exclude by default"), omitting only undefined.
          ...(channel.enabledByDefault != null
            ? { enabledByDefault: channel.enabledByDefault }
            : {}),
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

    return {
      providers,
      accounts,
      syncables: allChannels,
      grantedScopes: Array.from(grantedScopesSet),
    };
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
   * For hosted-auth providers, lazily refill `providerData.fullName` /
   * `email` from the vendor when the values landed empty at auth time.
   * Returns the updated tokenData if a refresh happened, null otherwise.
   *
   * Failure is non-fatal: this is best-effort backfill for UI labels.
   */
  private async maybeRefreshHostedProviderData(
    provider: AuthProvider,
    actorId: string,
    tokenData: StoredTokenData | null
  ): Promise<StoredTokenData | null> {
    if (!tokenData) return null;
    if (PROVIDER_CONFIGS[provider]?.authMode !== "hosted") return null;
    const hosted = (tokenData.providerData ?? {}) as Partial<{
      fullName: string | null;
      accountId: string;
    }>;
    if (hosted.fullName) return null;
    const accountId = hosted.accountId ?? tokenData.access_token;
    if (!accountId) return null;

    try {
      const { UnipileClient } = await import("./unipile/client");
      const client = new UnipileClient(this.env);

      // Three-stage probe to maximise the chance of getting a friendly name:
      //   1. /v2/:account_id/users/me — minimal, returns the member id always
      //   2. /v2/:account_id/users/:id — rich profile (the LinkedIn /users/me
      //      endpoint can omit display_name for the calling member)
      //   3. /v2/accounts/:id — Unipile's stored account label as fallback
      const me = await client.getOwnProfile({ accountId });

      let fullName = me.display_name && me.display_name.trim() ? me.display_name : null;
      let email = me.specifics?.email ?? null;
      const userId = me.id ?? null;

      if ((!fullName || !email) && userId) {
        try {
          const rich = await client.getAttendee({ accountId, providerId: userId });
          if (!fullName && rich.display_name && rich.display_name.trim()) fullName = rich.display_name;
          if (!email && rich.specifics?.email) email = rich.specifics.email;
        } catch {
          // Best-effort: the rich attendee probe failing is not fatal.
        }
      }

      if (!fullName) {
        try {
          const account = await client.getAccount(accountId);
          if (account.name && account.name.trim()) fullName = account.name;
        } catch {
          // Best-effort: the account-label fallback failing is not fatal.
        }
      }

      // Even if we don't get a name, persist the userId / accountId we know.
      const existing = (tokenData.providerData ?? {}) as Record<string, unknown>;
      const merged: StoredTokenData = {
        ...tokenData,
        providerData: {
          ...existing,
          accountId: accountId,
          accountType:
            (existing.accountType as string | undefined) ?? "LINKEDIN",
          fullName: fullName ?? (existing.fullName as string | null) ?? null,
          email: email ?? (existing.email as string | null) ?? null,
          userId:
            userId ??
            (existing.userId as string | undefined) ??
            accountId,
        } as ProviderData,
      };
      await this.store.set(`auth_token:${provider}:${actorId}`, merged);
      return merged;
    } catch {
      // Vendor probe failed — accept the stale data, try again next modal open.
      return null;
    }
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
          // Scope to this twist instance: re-auth on the same connection
          // dedupes to the existing contact, while a brand-new connection
          // with the same OAuth account creates its own row (and may
          // resolve to a separate contact, since Slack-style platforms
          // partition identity by workspace).
          const existing = await this.db
            .selectFrom("contact_external_account")
            .innerJoin(
              "contact",
              "contact.id",
              "contact_external_account.contact_id"
            )
            .select(["contact.id", "contact.name"])
            .where("contact_external_account.twist_instance_id", "=", this.twistInstanceId)
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
    if (!config || !config.tokenUrl) {
      // Either programmer error / misconfiguration (unknown provider) or a
      // non-OAuth provider (e.g. LinkedIn cookie auth) that has no refresh
      // path. Treat as permanent so we don't keep an unrefreshable token
      // around forever — the user must reconnect via the provider's
      // dedicated auth endpoint.
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
    params: Record<string, string>,
    env: Bindings,
    ctx: { exports: ExecutionContext["exports"] }
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

      // Scope-grant verification. Google (and other OAuth providers with
      // granular consent screens) lets the user uncheck individual
      // permissions on the consent page — the token exchange still
      // succeeds, but the resulting token is missing the unchecked
      // scopes. Without this check the connector's getChannels would
      // fire next, hit a 403 on the missing scope, and surface as a
      // PostHog error while the user sees a connection that silently
      // produced no channels. Fail fast with a user-friendly message
      // instead so the auth button can re-display.
      const grantedScopes = parseGrantedScopes(
        tokenResponse,
        PROVIDER_CONFIGS[authState.provider]
      );
      // Enforce only REQUIRED scopes. Optional scopes the user declined on the
      // consent screen are tolerated — the connector degrades gracefully.
      // Fallback to the full requested set when requiredScopes is absent
      // (sign-in flows, legacy in-flight states) to preserve strict behaviour.
      const enforcedScopes = authState.requiredScopes ?? authState.scopes;
      if (grantedScopes && enforcedScopes?.length) {
        const providerConfig = PROVIDER_CONFIGS[authState.provider];
        const missing = findMissingRequiredScopes(
          enforcedScopes,
          grantedScopes,
          providerConfig?.emailScopes ?? []
        );
        if (missing.length > 0) {
          const providerName = providerConfig?.name ?? authState.provider;
          return new Response(
            JSON.stringify({
              error: `${providerName} access wasn't fully granted. Please try again and grant the required permissions so Plot can sync.`,
            }),
            {
              status: 400,
              headers: { "Content-Type": "application/json" },
            }
          );
        }
      }

      // Call the wrapped callback (onAuth) with token info. Routed
      // through invokeWebhookCallback so the connector's onAuth runs in
      // this worker context, not inside the CallbacksState DO.
      if (authState.callback) {
        try {
          const result = await invokeWebhookCallback(
            env,
            ctx,
            authState.callback,
            {
              // Spread all token response fields (provider-specific fields included)
              ...tokenResponse,
              // Add our metadata. Persist GRANTED scopes so connectors can gate
              // optional features on what the user actually consented to.
              provider: authState.provider,
              scopes: grantedScopes ?? authState.scopes,
              client_id: clientId,
            }
          );
          disposeRpc(result);
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
          if (errorMessage.includes(AUTH_ACCOUNT_MISMATCH_ERROR)) {
            const expected = errorMessage.match(/expected ([^)]+)\)/)?.[1];
            return new Response(
              JSON.stringify({
                error: expected
                  ? `That's a different account than this connection uses. Please sign in with ${expected}. To connect a different account, remove this connection and add a new one.`
                  : "That's a different account than this connection uses. Please sign in with the account it was set up with. To connect a different account, remove this connection and add a new one.",
              }),
              {
                status: 409,
                headers: { "Content-Type": "application/json" },
              }
            );
          }
          if (errorMessage.includes(AUTH_ACCOUNT_DUPLICATE_ERROR)) {
            return new Response(
              JSON.stringify({
                error:
                  "This account is already connected. Open the existing connection to manage it — you don't need to add it again.",
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
    if (!config || !config.tokenUrl) {
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
      // GitHub's token endpoint returns form-encoded by default; Accept: json
      // forces a JSON body. Other providers already return JSON, so this is a
      // no-op for them.
      Accept: "application/json",
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
    requiredScopes,
    callback,
    redirectUri,
    platform,
    forceBridge,
    env,
    storage,
    enabledScopeGroups,
    accountHint,
  }: {
    provider: AuthProvider;
    scopes: string[];
    requiredScopes?: string[];
    callback?: Callback;
    redirectUri: string;
    platform?: "ios" | "android" | "desktop";
    forceBridge?: boolean;
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
    if (config.authMode === "hosted") {
      return await Integrations.GenerateHostedAuthUrl({
        provider,
        callback,
        redirectUri,
        env,
        storage,
      });
    }
    if (!config.authUrl) {
      // Non-OAuth provider (e.g. LinkedIn cookie auth). The client must use
      // that provider's dedicated auth endpoint instead of the OAuth flow.
      const logger = createLogger();
      logger.error("Provider does not use OAuth", { provider });
      throw new Error(
        `Provider ${provider} does not use OAuth; use its dedicated auth endpoint`
      );
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
    //
    // `forceBridge` lets a client opt every provider into the bridge for its
    // session — used by the Windows app, which can't receive a custom-scheme
    // callback because the runner doesn't register `plotday://`. The bridge
    // deep-links to the http://localhost:<port> URI the client passes in,
    // which the FlutterWebAuth2 local server captures.
    let effectiveRedirectUri = redirectUri;
    let bridgeUri: string | undefined;
    const bridgeEndpoint = `${env.API_ROOT}/auth/bridge`;
    if (
      (config.requiresHttpsRedirect || forceBridge) &&
      redirectUri !== bridgeEndpoint
    ) {
      bridgeUri = redirectUri;
      effectiveRedirectUri = bridgeEndpoint;
    }

    const authState: AuthState = {
      provider,
      scopes: allScopes,
      requiredScopes,
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
    // login_hint. login_hint is a standard OAuth param honored by both Google
    // and Microsoft, and pre-fills the account so the user skips the chooser.
    if (accountHint && (provider === "google" || provider === "microsoft")) {
      additionalParams.login_hint = accountHint;
      if (provider === "google") {
        // Force the consent screen on Google re-auth. Google only re-issues a
        // refresh_token when access_type=offline is paired with prompt=consent
        // (or on a first-ever authorization); for an already-consented account,
        // any prompt other than "consent" returns an access-token-only grant
        // with no refresh_token. That token expires in ~1h and can't refresh,
        // so getActorToken clears it and re-flags reauth — an infinite re-auth
        // loop. Forcing consent (login_hint still pre-selects the account)
        // guarantees the refresh_token comes back.
        additionalParams.prompt = "consent";
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

  static async GenerateHostedAuthUrl({
    provider,
    callback,
    redirectUri,
    env,
    storage,
  }: {
    provider: AuthProvider;
    callback?: Callback;
    redirectUri: string;
    env: Bindings;
    storage: DurableObjectNamespace<Storage>;
  }): Promise<{ url: string; clientId: string; state: string }> {
    const state = crypto.randomUUID();

    // Stash the in-flight auth so the webhook handler and the /auth completion
    // path can pair the inbound account_id with this state token.
    const storageStub = storage.idFromName("auth");
    const storageObj = storage.get(storageStub);
    await storageObj.set(
      `hosted_auth:${state}`,
      superjson.stringify({
        provider,
        callback: callback ? String(callback) : null,
        redirectUri,
        createdAt: Date.now(),
      })
    );

    // Map the API provider name to Unipile's source enum.
    const sourceMap: Record<string, "LINKEDIN" | "WHATSAPP" | "INSTAGRAM"> = {
      linkedin: "LINKEDIN",
      whatsapp: "WHATSAPP",
      instagram: "INSTAGRAM",
    };
    const source = sourceMap[provider];
    if (!source) {
      throw new Error(`Provider ${provider} not supported for hosted auth`);
    }

    const client = new UnipileClient(env);
    const { url } = await client.createHostedAuthLink({
      providers: [source],
      name: state,
      successRedirectUrl: `${env.API_ROOT}/auth/hosted/success?state=${state}`,
      failureRedirectUrl: `${env.API_ROOT}/auth/hosted/failure?state=${state}`,
      notifyUrl: `${env.API_ROOT}/hook/messaging`,
      expiresAt: new Date(Date.now() + 30 * 60 * 1000),
    });

    return { url, clientId: "hosted", state };
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
      // Stamp updated_by with this connector's marker so the note-create /
      // note-update dispatch views (which exclude `updated_by_uuid(pt.id)`)
      // skip it on the next poll. Without this, the seq bump from this UPDATE
      // re-qualifies the note for onNoteCreated and it re-posts in a loop.
      .set({ key, updated_by: this.connectorUpdatedBy() })
      .where("id", "=", noteId)
      .execute();
  }

  /**
   * This connector instance's `updated_by` marker, computed by the same
   * `updated_by_uuid()` the dispatch views check, so a note stamped with it
   * is recognised as "last written by this connector" and excluded from
   * re-dispatch. Computed in SQL (not the TS `truncateUuidForUpdatedBy`
   * helper) to guarantee it matches the view's value exactly.
   */
  private connectorUpdatedBy() {
    return sql<number>`updated_by_uuid(${this.twistInstanceId}::uuid)::int`;
  }

  /**
   * Apply a {@link NoteWriteBackResult} after a connector's
   * `onNoteCreated`/`onNoteUpdated` returned one. Sets the note's `key`
   * (when the connector just established it) and stores the sync baseline
   * hash of `externalContent` so the next sync-in can recognize the
   * round-tripped content and preserve Plot's stored version.
   *
   * Stamps `updated_by` with this connector's marker so the note-create /
   * note-update dispatch views skip the note on the next poll. The UPDATE
   * bumps the note's seq regardless, so without this stamp the note would
   * re-qualify for onNoteCreated and re-post to the external system in a
   * loop (the views exclude only `updated_by_uuid(pt.id)`, not arbitrary
   * client writes).
   */
  async updateNoteBaseline(
    noteId: string,
    result: NoteWriteBackResult
  ): Promise<void> {
    // Delivery-failure signalling is orthogonal to key/baseline. A write-back
    // that reports `deliveryError` records the failure on the note (and marks
    // the thread unread); any other return clears a previously-recorded
    // failure (e.g. a successful retry).
    if (result.deliveryError) {
      await this.markSendFailed(noteId, result.deliveryError);
      // A failure return carries no key/externalContent — nothing else to do.
      return;
    }
    await this.clearSendFailed(noteId);

    const patch: { key?: string; external_content_hash?: string; link_id?: string } = {};
    if (typeof result.key === "string" && result.key.length > 0) {
      patch.key = result.key;
    }
    if (typeof result.externalContent === "string") {
      patch.external_content_hash = await hashExternalContent(
        result.externalContent
      );
    }
    if (Object.keys(patch).length === 0) return;
    // Bind the written-back note to this connector's link on the thread. The
    // note upsert dedups on (thread, link_id, key); without link_id a keyed
    // Plot-authored note (a reply, or the opening message) can't merge with a
    // later re-import of the same external message and round-trips as a
    // duplicate. canonical_source is backfilled by the upsert's cross-index
    // step on that merge.
    if (patch.key) {
      const note = await this.db
        .selectFrom("note")
        .select("thread_id")
        .where("id", "=", noteId)
        .executeTakeFirst();
      if (note?.thread_id) {
        const link = await this.db
          .selectFrom("link")
          .select("id")
          .where("thread_id", "=", note.thread_id)
          .where("created_by", "=", this.twistInstanceId)
          .executeTakeFirst();
        if (link?.id) patch.link_id = link.id;
      }
    }
    await this.db
      .updateTable("note")
      .set({ ...patch, updated_by: this.connectorUpdatedBy() })
      .where("id", "=", noteId)
      .execute();
  }

  /**
   * Record that an outbound send / write-back for `noteId` failed and could
   * not be recovered, so the app can surface a "Failed to send" affordance.
   * Sets `note.delivery_error` and marks the thread unread for the note's
   * author (the sender). Called from the write-back path when a connector
   * returns a `deliveryError`, from the dispatch-error fallback in the
   * entrypoint when a write-back throws, and from the compose path.
   *
   * Idempotent: only writes (and bumps `seq` → re-syncs) when the recorded
   * error actually changes. The seq bump would otherwise re-qualify the note
   * for the channel-note dispatch view (which is seq-cursor driven and does
   * not filter on `updated_by`) and re-fire `onNoteCreated` on the next poll;
   * the `IS DISTINCT FROM` guard bounds that to a single extra cycle, and the
   * connector's own send idempotency guard prevents an actual re-send.
   */
  async markSendFailed(
    noteId: string,
    error: { code: string; message?: string | null }
  ): Promise<void> {
    const code = error.code;
    const message = error.message ?? null;
    const payload = JSON.stringify({ code, message });
    const res = await this.db
      .updateTable("note")
      .set({
        delivery_error: sql<Json>`${payload}::jsonb`,
        updated_by: this.connectorUpdatedBy(),
      })
      .where("id", "=", noteId)
      .where(sql<boolean>`note.delivery_error IS DISTINCT FROM ${payload}::jsonb`)
      .executeTakeFirst();

    // Only mark unread when we actually changed the error (avoids re-flagging
    // a thread the user has already seen for an unchanged, still-failing send).
    if (!res.numUpdatedRows || res.numUpdatedRows === 0n) return;

    const note = await this.db
      .selectFrom("note")
      .select(["thread_id", "created_by"])
      .where("id", "=", noteId)
      .executeTakeFirst();
    if (!note?.thread_id || !note.created_by) return;
    try {
      await rpcUser(this.db, "upsert_thread_state", {
        user_id: note.created_by,
        p_thread_id: note.thread_id,
        p_active: false,
        p_urgent: false,
        p_importance: 50,
        // p_read_at omitted → NULL; with p_set_read_at: true this marks the
        // thread unread for the sender (race-safe via p_note_created_at).
        p_set_active: false,
        p_set_urgent: false,
        p_set_importance: false,
        p_set_read_at: true,
        p_note_created_at: new Date().toISOString(),
      });
    } catch (err) {
      createLogger({ twist_instance_id: this.twistInstanceId }).error(
        "markSendFailed: failed to mark thread unread",
        err as Error,
        { note_id: noteId, thread_id: note.thread_id }
      );
    }
  }

  /**
   * Clear a previously-recorded send failure on `noteId` (e.g. after a
   * successful retry or any later successful write-back). Idempotent — the
   * `delivery_error IS NOT NULL` guard means it only bumps `seq` (re-syncing
   * the cleared state to the client) when there was actually an error.
   */
  async clearSendFailed(noteId: string): Promise<void> {
    await this.db
      .updateTable("note")
      .set({ delivery_error: null, updated_by: this.connectorUpdatedBy() })
      .where("id", "=", noteId)
      .where("delivery_error", "is not", null)
      .execute();
  }
}
