import type { Kysely } from "kysely";

import {
  type Actor,
  type ActorId,
  ActorType,
  type ActivityLink,
  ActivityLinkType,
} from "@plotday/twister/plot";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  type AuthProvider,
  type AuthToken,
  type Authorization,
  type IntegrationOptions,
  type IntegrationProviderConfig,
  type Integrations as IAuth,
  type Syncable,
} from "@plotday/twister/tools/integrations";
import type { Uuid } from "@plotday/twister/utils/uuid";

import type { DB } from "../../db-types";
import { type Bindings, type TwistEnvironment } from "../../env";
import {
  PROVIDER_CONFIGS,
  type ProviderData,
  type StoredTokenData,
} from "../../provider";
import { CallbacksState } from "../../state/callbacks";
import superjson from "superjson";

import type { Storage } from "../../state/storage";
import { createLogger } from "@plotday/worker-util";
import { getRpcFunctionName } from "../../utils/rpc";
import type { Store } from "./store";
import { Tool } from "./tool";

const AUTH_EMAIL_CONFLICT_ERROR = "AuthEmailConflictError";

type AuthState = {
  provider: AuthProvider;
  scopes: string[];
  codeVerifier?: string; // Optional for Google Sign-In flows
  timestamp?: number; // Optional for Google Sign-In flows
  callback?: Callback;
};

type SyncableConfig = {
  enabled: boolean;
  enabledBy?: ActorId;
  title?: string | null;
};

type PendingActAs = {
  callbackToken: Callback;
  activityId: Uuid;
  noteId?: string;
};

// @ts-ignore - class correctly implements IAuth but TS can't verify due to Kysely type differences
export class Integrations extends Tool implements IAuth {
  private store: Store;
  private env: Bindings;
  private db: Kysely<DB>;
  private priorityTwistId: string;
  // These are callbacks we create and call
  private callbacks: DurableObjectStub<CallbacksState>;
  private _twistId: string;
  private _environment: TwistEnvironment;
  private path: string[];
  private providerConfigs: IntegrationProviderConfig[];

  /**
   * Extract provider metadata from integration options during deployment.
   * Returns provider/scopes pairs without lifecycle callbacks.
   */
  static Providers(
    options?: IntegrationOptions
  ): Array<{ provider: string; scopes: string[] }> {
    if (!options?.providers) return [];
    return options.providers.map((p) => ({
      provider: p.provider,
      scopes: [...p.scopes],
    }));
  }

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    priorityTwistId: string
  ) {
    const callbacksId = callbacks.idFromName(priorityTwistId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    store: Store;
    env: Bindings;
    db: Kysely<DB>;
    priorityTwistId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
    integrationOptions?: IntegrationOptions;
  }) {
    super();
    this.store = options.store;
    this.env = options.env;
    this.db = options.db;
    this.priorityTwistId = options.priorityTwistId;
    this._twistId = options.twistId;
    this._environment = options.environment;
    this.callbacks = Integrations.GetStub(
      options.env.CALLBACKS,
      options.priorityTwistId
    );
    this.path = options.path;
    // Provider config callbacks (onSyncEnabled, onSyncDisabled, getSyncables)
    // are no longer called as RPC stubs — they're returned as __dispatch info
    // and invoked locally by the twist worker entrypoint with proper this binding.
    // No need to dup any RPC stubs.
    this.providerConfigs = options.integrationOptions?.providers ?? [];
  }

  // ============================================================================
  // Public API (implements IAuth interface)
  // ============================================================================

  /**
   * Get a token for a syncable resource.
   * Returns the token of the user who enabled sync on the given syncable.
   */
  async get(provider: AuthProvider, syncableId: string): Promise<AuthToken | null> {
    // Look up syncable config to find who enabled it
    const configKey = `syncable_config:${provider}:${syncableId}`;
    const config = await this.store.get<SyncableConfig>(configKey);

    if (config?.enabled && config.enabledBy) {
      return this.getActorToken(provider, config.enabledBy);
    }

    // Migration fallback: no syncable_config exists for pre-redesign users.
    // Find any actor with a valid token for this provider.
    const tokenKeys = await this.store.list(`auth_token:${provider}:`);
    for (const key of tokenKeys) {
      const actorId = key.slice(`auth_token:${provider}:`.length) as ActorId;
      const token = await this.getActorToken(provider, actorId);
      if (token) {
        // Auto-create syncable_config so subsequent calls use the fast path
        await this.store.set(configKey, {
          enabled: true,
          enabledBy: actorId,
        } satisfies SyncableConfig);
        return token;
      }
    }
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
      // Actor has a valid token - call immediately
      await callback(token, ...extraArgs);
      return;
    }

    // No token - create auth request for this actor
    // @ts-ignore - TS2589: Type instantiation is excessively deep and possibly infinite
    using callbackFunctionName = await getRpcFunctionName(callback);
    if (!callbackFunctionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    // Create callback token for the deferred callback
    const callbackToken = await this.callbacks.create({
      priorityTwistId: this.priorityTwistId,
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
      priorityTwistId: this.priorityTwistId,
      path: this.path,
      functionName: "onAuth",
      extraArgs: [], // onAuth will look up pending callbacks itself
    }) as unknown as Callback;

    const authLink: ActivityLink = {
      title: `Continue with ${PROVIDER_CONFIGS[provider]?.name ?? provider}`,
      type: ActivityLinkType.auth,
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
   * Declare what syncable resources an actor has access to.
   */
  async setSyncables(
    provider: AuthProvider,
    actorId: ActorId,
    syncables: Syncable[]
  ): Promise<void> {
    const key = `syncable_access:${provider}:${actorId}`;
    await this.store.set(key, syncables);
  }

  // ============================================================================
  // Internal methods (called by API endpoints)
  // ============================================================================

  /**
   * Get a token directly for an actor (by actor ID).
   * Used internally and by API endpoints.
   */
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
          const logger = createLogger({ priority_twist_id: this.priorityTwistId });
          logger.error("Failed to refresh token", error as Error, {
            provider,
            actor_id: actorId,
          });
          // Clear expired token
          await this.store.clear(foundTokenKey);
          return null;
        }
      }

      // No refresh token or refresh failed, clear expired token
      await this.store.clear(foundTokenKey);
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

    // Extract email from providerData and link to contact, building actor
    const email = this.extractEmail(providerData);
    let actor: Actor;
    try {
      actor = await this.buildActor(email);
    } catch (error) {
      throw error;
    }

    // Store token keyed by provider + actor ID
    const tokenKey = `auth_token:${tokenInfo.provider}:${actor.id}`;
    const token: StoredTokenData = {
      client_id: tokenInfo.client_id,
      access_token: tokenInfo.access_token,
      refresh_token: tokenInfo.refresh_token ?? null,
      scopes: tokenInfo.scopes,
      expires_at: tokenInfo.expires_in
        ? Date.now() + tokenInfo.expires_in * 1000
        : null,
      providerData,
    };
    await this.store.set(tokenKey, token);

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
            const logger = createLogger({ priority_twist_id: this.priorityTwistId });
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
        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
        logger.error("Error executing original auth callback", error as Error, {
          provider: tokenInfo.provider,
          actor_id: actor.id,
        });
      }
    }

    // 3. Return dispatch for getSyncables — called locally by entrypoint with proper this binding,
    // result forwarded to setSyncables via forwardTo directive.
    const providerIndex = this.providerConfigs.findIndex(
      p => p.provider === tokenInfo.provider
    );
    if (providerIndex >= 0) {
      const authToken: AuthToken = {
        token: token.access_token,
        scopes: token.scopes,
      };
      const dispatch = {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "getSyncables"],
          args: [authorization, authToken],
          forwardTo: {
            functionName: "setSyncables",
            prependArgs: [tokenInfo.provider, actor.id],
          },
        }],
      };
      return dispatch as any;
    }
  }

  /**
   * Remove an actor's auth for a provider.
   * Handles syncable reassignment and calls onRemoved.
   */
  async removeAuth(provider: AuthProvider, actorId: ActorId): Promise<void> {
    const tokenKey = `auth_token:${provider}:${actorId}`;

    // Handle syncables this actor enabled
    const accessKey = `syncable_access:${provider}:${actorId}`;
    const actorSyncables = await this.store.get<Syncable[]>(accessKey) ?? [];

    // Accumulate dispatch entries for callbacks that need to run on the twist worker
    const dispatches: Array<{ optionPath: (string | number)[]; args: any[] }> = [];
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);

    for (const syncable of actorSyncables) {
      const configKey = `syncable_config:${provider}:${syncable.id}`;
      const syncConfig = await this.store.get<SyncableConfig>(configKey);

      if (syncConfig?.enabled && syncConfig.enabledBy === actorId) {
        // This actor enabled this syncable - need to reassign or disable
        const newOwner = await this.findAlternateOwner(provider, syncable.id, actorId);

        if (newOwner) {
          // Reassign: disable with old owner, enable with new
          if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", providerIndex, "onSyncDisabled"],
              args: [syncable],
            });
          }

          await this.store.set(configKey, {
            enabled: true,
            enabledBy: newOwner,
            title: syncable.title,
          } satisfies SyncableConfig);

          if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", providerIndex, "onSyncEnabled"],
              args: [syncable],
            });
          }
        } else {
          // No alternate owner - disable
          if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", providerIndex, "onSyncDisabled"],
              args: [syncable],
            });
          }

          await this.store.set(configKey, {
            enabled: false,
            title: syncable.title,
          } satisfies SyncableConfig);
        }
      }
    }

    // Delete auth token and syncable access
    await this.store.clear(tokenKey);
    await this.store.clear(accessKey);

    // Return dispatch info for the entrypoint to invoke locally
    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  /**
   * Enable sync for a syncable resource.
   * Called from API endpoint when user toggles sync on.
   */
  async enableSync(
    provider: AuthProvider,
    syncableId: string,
    actorId: ActorId,
    title?: string
  ): Promise<void> {
    const configKey = `syncable_config:${provider}:${syncableId}`;

    // Find the title from the actor's syncable access list if not provided
    if (!title) {
      const accessKey = `syncable_access:${provider}:${actorId}`;
      const syncables = await this.store.get<Syncable[]>(accessKey) ?? [];
      const syncable = syncables.find(s => s.id === syncableId);
      title = syncable?.title;
    }

    await this.store.set(configKey, {
      enabled: true,
      enabledBy: actorId,
      title: title ?? null,
    } satisfies SyncableConfig);

    // Return dispatch info for onSyncEnabled callback.
    // The entrypoint will invoke this locally on the twist worker with proper this binding.
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex >= 0) {
      return {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "onSyncEnabled"],
          args: [{ id: syncableId, title: title ?? syncableId }],
        }],
      } as any;
    }
  }

  /**
   * Disable sync for a syncable resource.
   * Called from API endpoint when user toggles sync off.
   */
  async disableSync(
    provider: AuthProvider,
    syncableId: string
  ): Promise<void> {
    const configKey = `syncable_config:${provider}:${syncableId}`;
    const existing = await this.store.get<SyncableConfig>(configKey);

    await this.store.set(configKey, {
      enabled: false,
      title: existing?.title ?? null,
    } satisfies SyncableConfig);

    // Return dispatch info for onSyncDisabled callback.
    // The entrypoint will invoke this locally on the twist worker with proper this binding.
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex >= 0) {
      return {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "onSyncDisabled"],
          args: [{ id: syncableId, title: existing?.title ?? syncableId }],
        }],
      } as any;
    }
  }

  /**
   * Get all integration data for the edit modal.
   * Returns accounts, providers, and syncables.
   */
  async getIntegrationData(currentActorId?: ActorId): Promise<{
    providers: Array<{ provider: AuthProvider; scopes: string[] }>;
    accounts: Array<{
      provider: AuthProvider;
      actorId: ActorId;
      email: string | null;
      name: string | null;
    }>;
    syncables: Array<{
      provider: AuthProvider;
      id: string;
      title: string;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      currentUserHasAccess: boolean;
    }>;
  }> {
    const providers = this.providerConfigs.map(p => ({
      provider: p.provider,
      scopes: p.scopes,
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
    }> = [];

    // Collect all syncables and their states
    const syncablesMap = new Map<string, {
      provider: AuthProvider;
      id: string;
      title: string;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      currentUserHasAccess: boolean;
    }>();

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

      // Build syncables for known actors
      for (const actorId of knownActorIds) {
        const tokenKey = `auth_token:${provider}:${actorId}`;
        const tokenData = await this.store.get<StoredTokenData>(tokenKey);
        const email = tokenData ? this.extractEmail(tokenData.providerData) : null;

        // Look up contact name
        let name: string | null = null;
        if (actorId) {
          const contact = await this.db
            .selectFrom("contact")
            .select("name")
            .where("id", "=", actorId)
            .executeTakeFirst();
          name = contact?.name ?? null;
        }

        accounts.push({
          provider,
          actorId: actorId as ActorId,
          email,
          name,
        });

        // Get this actor's syncable access
        const accessKey = `syncable_access:${provider}:${actorId}`;
        const actorSyncables = await this.store.get<Syncable[]>(accessKey) ?? [];

        for (const syncable of actorSyncables) {
          const configKey = `syncable_config:${provider}:${syncable.id}`;
          const syncConfig = await this.store.get<SyncableConfig>(configKey);

          const mapKey = `${provider}:${syncable.id}`;
          const existing = syncablesMap.get(mapKey);

          syncablesMap.set(mapKey, {
            provider,
            id: syncable.id,
            title: syncable.title,
            enabled: syncConfig?.enabled ?? false,
            enabledBy: syncConfig?.enabledBy,
            currentUserHasAccess: existing?.currentUserHasAccess || currentUserContactIds.has(actorId),
          });
        }
      }
    }

    // Apply visibility rules:
    // - Show all enabled syncables (even if current user doesn't have access)
    // - Show disabled syncables only if current user has access
    // - Hide disabled syncables the current user doesn't have access to
    const syncables = Array.from(syncablesMap.values()).filter(s =>
      s.enabled || s.currentUserHasAccess
    );

    return { providers, accounts, syncables };
  }

  /**
   * Re-calls getSyncables for a provider+actor using stored token,
   * updating syncable_access with the latest list.
   */
  async refreshSyncables(provider: AuthProvider, actorId: ActorId): Promise<any> {
    const token = await this.getActorToken(provider, actorId);
    if (!token) return;

    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex < 0 || !this.providerConfigs[providerIndex]?.getSyncables) return;

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

    return {
      __dispatch: [{
        optionPath: ["providers", providerIndex, "getSyncables"],
        args: [auth, token],
        forwardTo: {
          functionName: "setSyncables",
          prependArgs: [provider, actorId],
        },
      }],
    } as any;
  }

  /**
   * Migration: populate syncable_access for pre-redesign auth tokens.
   * Called during deployment upgrade phase via callPreLifecycle.
   * Scans existing auth tokens and calls getSyncables for each to
   * populate syncable_access so the edit modal shows syncables.
   */
  async preUpgrade(): Promise<any> {
    const tokenKeys = await this.store.list("auth_token:");
    const dispatches: Array<{
      optionPath: (string | number)[];
      args: any[];
      forwardTo: { functionName: string; prependArgs: any[] };
    }> = [];

    for (const key of tokenKeys) {
      // Parse "auth_token:{provider}:{actorId}"
      const parts = key.split(":");
      if (parts.length < 3) continue;
      const provider = parts[1] as AuthProvider;
      const actorId = parts.slice(2).join(":") as ActorId;

      // Skip if syncable_access already exists (already migrated)
      const accessKey = `syncable_access:${provider}:${actorId}`;
      const existing = await this.store.get(accessKey);
      if (existing) continue;

      // Get token
      const token = await this.getActorToken(provider, actorId);
      if (!token) continue;

      // Find matching provider config index
      const providerIndex = this.providerConfigs.findIndex(
        (p) => p.provider === provider
      );
      if (providerIndex < 0) continue;

      // Build Authorization for getSyncables dispatch
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

      dispatches.push({
        optionPath: ["providers", providerIndex, "getSyncables"],
        args: [auth, token],
        forwardTo: {
          functionName: "setSyncables",
          prependArgs: [provider, actorId],
        },
      });
    }

    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  // ============================================================================
  // Private helpers
  // ============================================================================

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
   */
  private async buildActor(email: string | null): Promise<Actor> {
    if (!email) {
      // No email available - create a minimal actor
      return {
        id: crypto.randomUUID() as ActorId,
        type: ActorType.Contact,
      };
    }

    try {
      // Get the user_id from the priority_twist owner
      const priorityTwist = await this.db
        .selectFrom("priority_twist")
        .select("owner_id")
        .where("id", "=", this.priorityTwistId)
        .executeTakeFirst();

      if (!priorityTwist?.owner_id) {
        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
        logger.warn("Cannot link contact: priority_twist has no owner", {
          email,
        });
        return {
          id: crypto.randomUUID() as ActorId,
          type: ActorType.Contact,
          email,
        };
      }

      const userId = priorityTwist.owner_id;

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
          })
          .returning(["id", "name"])
          .executeTakeFirst();

        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
        logger.info("Created new contact from OAuth", { email, user_id: userId });

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

        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
        logger.info("Linked existing contact from OAuth", {
          email,
          user_id: userId,
        });
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
      const logger = createLogger({ priority_twist_id: this.priorityTwistId });
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
   * Find an alternate actor who has access to a syncable (for reassignment).
   */
  private async findAlternateOwner(
    _provider: AuthProvider,
    _syncableId: string,
    _excludeActorId: ActorId
  ): Promise<ActorId | null> {
    // For now, return null - the syncable will be disabled when the owner is removed.
    // A more complete implementation would scan all actors with tokens for this provider
    // and find one who has access to the syncable.
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
      throw new Error(`Token refresh not implemented for ${provider}`);
    }

    const clientSecret = Integrations.SecretFromId(
      this.env,
      provider,
      clientId
    );

    const params = new URLSearchParams({
      client_id: clientId,
      ...(clientSecret ? { client_secret: clientSecret } : null),
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    });

    const response = await fetch(config.tokenUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token refresh failed: ${response.status} ${errorText}`);
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

      const { code, clientId, redirectUri } = params;
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
          using _result = await CallbacksState.CallCallback(
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

    const params = new URLSearchParams({
      client_id: clientId,
      ...(clientSecret ? { client_secret: clientSecret } : null),
      code,
      grant_type: "authorization_code",
      redirect_uri: redirectUri,
      ...(codeVerifier ? { code_verifier: codeVerifier } : {}),
    });

    const response = await fetch(config.tokenUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
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
  }: {
    provider: AuthProvider;
    scopes: string[];
    callback?: Callback;
    redirectUri: string;
    platform?: "ios" | "android" | "desktop";
    env: Bindings;
    storage: DurableObjectNamespace<Storage>;
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

    // Generate unique state and store globally
    const state = crypto.randomUUID();
    const authState: AuthState = {
      provider,
      scopes: allScopes,
      codeVerifier,
      timestamp: Date.now(),
      callback,
    };
    await storageObj.set(
      state,
      superjson.stringify(authState)
    );

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

    // For sign-in flows (no callback), use simplified Google OAuth params
    // For authorization flows (has callback), use full params from config
    const isSignInFlow = !callback && provider === "google";
    const additionalParams = isSignInFlow
      ? { prompt: "select_account" }
      : config.additionalParams;

    const params = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: redirectUri,
      scope: allScopes.join(" "),
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
}
