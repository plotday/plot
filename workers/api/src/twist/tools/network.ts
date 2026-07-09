import {
  AuthProvider,
  type Authorization,
} from "@plotday/twister/tools/integrations";
import { type Network as INetwork } from "@plotday/twister/tools/network";
import type { Store as IStore } from "@plotday/twister/tools/store";

import { createDb } from "../../db";
import { type TwistEnvironment, type Bindings } from "../../env";
import { CallbackError } from "../../errors";
import type { CallbacksState } from "../../state/callbacks";
import { createLogger } from "@plotday/worker-util";
import {
  createPushSubscription,
  createTopic,
  deleteSubscription,
  deleteTopic,
  grantTopicPublisher,
} from "../../utils/pubsub";
import { disposeRpc, getRpcFunctionName } from "../../utils/rpc";
import { type ToolPermission } from "../permissions";
import { Tool } from "./tool";

export type NetworkOptions = {
  urls?: string[];
  callbacks?: DurableObjectNamespace<CallbacksState>;
  twistInstanceId?: string;
  twistId?: string;
  environment?: TwistEnvironment;
  baseUrl?: string;
  path?: string[];
  store?: IStore;
  env?: Bindings;
};

export type WebhookRequest = {
  method: string;
  headers: Record<string, string>;
  params: Record<string, string>;
  body: any;
  rawBody?: string;
};

/**
 * Mapping of Slack event types to required OAuth scopes.
 * Used to filter callbacks based on granted scopes.
 */
const SLACK_EVENT_SCOPES: Record<string, string[]> = {
  // Message events
  message: ["channels:history", "groups:history", "im:history", "mpim:history"],
  "message.channels": ["channels:history"],
  "message.groups": ["groups:history"],
  "message.im": ["im:history"],
  "message.mpim": ["mpim:history"],

  // Channel events
  channel_created: ["channels:read"],
  channel_deleted: ["channels:read"],
  channel_archive: ["channels:read"],
  channel_unarchive: ["channels:read"],
  channel_rename: ["channels:read"],

  // Reaction events
  reaction_added: ["reactions:read"],
  reaction_removed: ["reactions:read"],

  // User events
  user_change: ["users:read"],
  team_join: ["users:read"],

  // App events
  app_mention: ["app_mentions:read"],
  app_home_opened: [],

  // Deauthorization events. These require no OAuth scope — Slack delivers them
  // to any app the workspace has installed. Listed here (with no required
  // scopes) so `checkSlackEventScopes` returns them to every team callback,
  // letting connectors tear down / flag re-auth when a user revokes their token
  // (`tokens_revoked`) or an admin removes the app (`app_uninstalled`).
  tokens_revoked: [],
  app_uninstalled: [],

  // File events
  file_created: ["files:read"],
  file_deleted: ["files:read"],
  file_shared: ["files:read"],
};

/**
 * Gmail-related OAuth scopes that indicate the authorization should use Pub/Sub webhooks.
 * If an authorization contains any of these scopes, createWebhook will return a Pub/Sub topic
 * instead of a standard webhook URL.
 */
export const GMAIL_SCOPES = ["https://www.googleapis.com/auth/gmail.modify"];


/**
 * Checks if a callback's scopes satisfy the requirements for a Slack event.
 */
function checkSlackEventScopes(
  eventType: string,
  callbackScopes: string[]
): boolean {
  const requiredScopes = SLACK_EVENT_SCOPES[eventType];

  // If no specific scopes are required, allow all callbacks
  if (!requiredScopes || requiredScopes.length === 0) {
    return true;
  }

  // Check if callback has at least one of the required scopes
  return requiredScopes.some((scope) => callbackScopes.includes(scope));
}

/**
 * Built-in tool for requesting HTTP access permissions and managing webhooks.
 */
export class Network extends Tool implements INetwork {
  private callbacks?: DurableObjectStub<CallbacksState>;
  private callbacksNamespace?: DurableObjectNamespace<CallbacksState>;
  private twistInstanceId?: string;
  private twistId?: string;
  private environment?: TwistEnvironment;
  private baseUrl?: string;
  private path?: string[];
  private store?: IStore;
  private env?: Bindings;

  public static readonly PATH = "/hook/:token";

  private static GetCallbacksStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    /// Usually twistInstanceId. For Slack webhooks, we use the Slack team ID.
    key: string
  ) {
    const callbacksId = callbacks.idFromName(key);
    return callbacks.get(callbacksId);
  }

  /**
   * Enumerate Slack callback tokens matching a team + event type.
   *
   * Slack webhooks are routed by team_id (not twist_instance) because the
   * team is the only identifier in the signed payload. The same team can
   * have many callbacks registered across multiple twist instances, and
   * each callback declares which OAuth scopes it needs. This returns the
   * subset of team callbacks whose declared scopes satisfy `eventType`.
   *
   * The `/hook/slack` ingress calls this and then enqueues one
   * `WebhookMessage` per token so each callback retries independently and
   * a slow callback cannot stall Slack's HTTP 200 window or delay the
   * other callbacks for the same event. Previously callbacks were fanned
   * out via `Promise.allSettled` inside the request, which amplified
   * tail-latency outages.
   */
  static async GetSlackCallbacks(
    callbacks: DurableObjectNamespace<CallbacksState>,
    teamId: string,
    eventType: string
  ): Promise<string[]> {
    const callbacksStub = Network.GetCallbacksStub(callbacks, teamId);
    // @ts-ignore TS2589: DO stub response type inference is excessively deep
    const rawResult: any = await callbacksStub.get(teamId);
    disposeRpc(callbacksStub);
    const teamCallbacks: Array<{
      callback: string;
      meta?: Record<string, any>;
    }> = rawResult ? Array.from(rawResult) : [];

    if (teamCallbacks.length === 0) {
      return [];
    }

    return teamCallbacks
      .filter((cb) => checkSlackEventScopes(eventType, cb.meta?.scopes || []))
      .map((cb) => cb.callback);
  }

  /**
   * Returns permissions required by this Network tool instance.
   * @param options - Network tool options
   * @returns Array of ToolPermissions for the requested URLs
   */
  static Permissions(options?: NetworkOptions): ToolPermission[] {
    const urls = options?.urls || [];
    return urls.map((url) => ({
      domain: "network",
      entity: url,
      flags: ["use"] as const,
    }));
  }

  constructor(options?: NetworkOptions) {
    super();

    // Initialize webhook functionality if options provided
    if (options?.callbacks && options.twistInstanceId) {
      this.callbacksNamespace = options.callbacks;
      this.callbacks = Network.GetCallbacksStub(
        options.callbacks,
        options.twistInstanceId
      );
      this.twistInstanceId = options.twistInstanceId;
      this.twistId = options.twistId;
      this.environment = options.environment;
      this.baseUrl = options.baseUrl;
      this.store = options.store;
      this.env = options.env;
      // Remove final element, which is the ID of this tool
      this.path = options.path?.slice(0, -1);
    }
  }

  /**
   * Creates a Slack-specific webhook using team_id for routing.
   * Multiple callbacks for the same team share the same webhook URL.
   */
  private async createSlackWebhook(
    authorization: Authorization,
    callbackFunctionName: string,
    extraArgs?: any[]
  ): Promise<string> {
    if (!this.store) {
      throw new Error("Store not initialized for provider-specific webhooks");
    }

    // Retrieve integration data from store. `providerData.team.id` is the
    // shape populated by the Slack entry in PROVIDER_CONFIGS.parseTokenResponse
    // (see workers/api/src/provider.ts). Slack's OAuth v2 response puts team
    // info under `team`, and `onAuth` persists the whole parsed response as
    // `StoredTokenData.providerData` — there is no top-level `team` field.
    type SlackTokenData = {
      access_token: string;
      refresh_token?: string;
      scopes: string[];
      providerData?: {
        team?: {
          id: string;
          name: string;
        };
      };
    };
    const tokenKey = `auth_token:${authorization.provider}:${authorization.actor.id}`;
    let tokenData = await this.store.get<SlackTokenData>(tokenKey);

    // The stored authorization's actor can go stale — e.g. after an
    // archive+reconnect the connection's auth actor differs from the actor the
    // live token now lives under (a sibling contact of the same user). Re-
    // resolve the same way integrations.get()/getActorToken does: start from
    // the channel's `enabledBy` actor (recorded against THIS connection's
    // channel) and walk that actor's own linked contacts (same user_id). This
    // is provably one principal / one workspace — it never scans for an
    // arbitrary token that could belong to a different workspace.
    if (!tokenData?.providerData?.team?.id && this.env) {
      const channelId =
        typeof extraArgs?.[0] === "string" ? extraArgs[0] : undefined;
      if (channelId) {
        const config = await this.store.get<{ enabledBy?: string }>(
          `channel_config:${authorization.provider}:${channelId}`
        );
        const enabledBy = config?.enabledBy;
        if (enabledBy) {
          // Direct token under the enabledBy actor.
          let scoped = await this.store.get<SlackTokenData>(
            `auth_token:${authorization.provider}:${enabledBy}`
          );
          // Else a linked contact of enabledBy's user (same person).
          if (!scoped?.providerData?.team?.id) {
            const db = createDb(this.env);
            try {
              const contact = await db
                .selectFrom("contact")
                .select("user_id")
                .where("id", "=", enabledBy)
                .executeTakeFirst();
              if (contact?.user_id) {
                const siblings = await db
                  .selectFrom("contact")
                  .select("id")
                  .where("user_id", "=", contact.user_id)
                  .where("id", "!=", enabledBy)
                  .execute();
                for (const s of siblings) {
                  const cand = await this.store.get<SlackTokenData>(
                    `auth_token:${authorization.provider}:${s.id}`
                  );
                  if (cand?.providerData?.team?.id) {
                    scoped = cand;
                    break;
                  }
                }
              }
            } finally {
              await db.destroy();
            }
          }
          if (scoped?.providerData?.team?.id) {
            tokenData = scoped;
          }
        }
      }
    }


    if (!tokenData) {
      throw new Error(
        `No integration found for authorization ${authorization.provider}:${authorization.actor.id}`
      );
    }

    const teamId = tokenData.providerData?.team?.id;
    if (!teamId) {
      throw new Error("Slack integration missing team_id");
    }

    const scopes = tokenData.scopes || [];

    // For Slack webhooks, we use team_id for DO sharding to enable
    // webhook routing without knowing the twistInstanceId in advance.
    // Get CallbacksState DO for this team_id.
    const teamCallbacksId = this.callbacksNamespace!.idFromName(teamId);
    const teamCallbacksStub = this.callbacksNamespace!.get(teamCallbacksId);

    // Create callback with team_id as key for routing
    // Store the actual twistInstanceId in meta for callback execution
    const callbackToken = await teamCallbacksStub.create({
      twistInstanceId: this.twistInstanceId!,
      path: this.path!,
      functionName: callbackFunctionName,
      extraArgs,
      key: teamId,
      meta: {
        scopes,
        provider: authorization.provider,
        actorId: authorization.actor.id,
        twistInstanceId: this.twistInstanceId, // Store for reference
      },
    });


    // Return encoded webhook identifier that includes team ID and callback token
    // Format: slack://{teamId}:{callbackToken}
    // This allows deleteWebhook() to properly clean up the callback
    return `slack://${teamId}:${callbackToken}`;
  }

  /**
   * Per-variant configuration for the two Google Pub/Sub push products we
   * support. Gmail (`users.watch`) and Google Workspace Events (Chat, etc.)
   * are distinct: each requires its own publisher service account, ingress
   * route, and topic-name prefix, and the gmail route decodes a different
   * message envelope than the workspace route. The topic prefix is also load
   * bearing — `deleteWebhook` and the `/hook/*` handlers key off it.
   */
  private static readonly PUBSUB_VARIANTS = {
    gmail: {
      topicPrefix: "gmail",
      // Gmail's users.watch() sends a verification publish from this account,
      // so the topic must grant it publish access or the watch is rejected.
      publisher: "gmail-api-push@system.gserviceaccount.com",
      route: "gmail",
      label: "Gmail",
    },
    // Google Workspace Events service agent (Chat, etc.).
    workspace: {
      topicPrefix: "ps",
      publisher: "chat-api-push@system.gserviceaccount.com",
      route: "pubsub",
      label: "Pub/Sub",
    },
  } as const;

  /**
   * Creates a Google Pub/Sub-backed webhook for the given push product.
   * Each webhook gets its own dedicated Pub/Sub topic and push subscription,
   * and the call returns the topic name (e.g.
   * "projects/plot-prod/topics/gmail-abc123") to hand to the relevant Google
   * API (`users.watch`, Workspace Events `createSubscription`) instead of a
   * webhook URL.
   */
  private async createGooglePubSubWebhook(
    variant: "gmail" | "workspace",
    callbackFunctionName: string,
    extraArgs?: any[]
  ): Promise<string> {
    if (
      !this.env?.GCP_PROJECT_ID ||
      !this.env?.GCP_SERVICE_ACCOUNT_EMAIL ||
      !this.env?.GCP_SERVICE_ACCOUNT_KEY
    ) {
      throw new Error(
        "GCP configuration missing. Required: GCP_PROJECT_ID, GCP_SERVICE_ACCOUNT_EMAIL, GCP_SERVICE_ACCOUNT_KEY"
      );
    }

    const { topicPrefix, publisher, route, label } =
      Network.PUBSUB_VARIANTS[variant];

    const pubsubConfig = {
      projectId: this.env.GCP_PROJECT_ID,
      serviceAccountEmail: this.env.GCP_SERVICE_ACCOUNT_EMAIL,
      serviceAccountKey: this.env.GCP_SERVICE_ACCOUNT_KEY,
    };

    try {
      const callbackToken = await this.callbacks!.create({
        twistInstanceId: this.twistInstanceId!,
        path: this.path!,
        functionName: callbackFunctionName,
        extraArgs,
        ...(variant === "gmail"
          ? { meta: { scopes: GMAIL_SCOPES, provider: AuthProvider.Google } }
          : {}),
      });

      // Encode the callback token into the topic ID so we can decode it when
      // receiving Pub/Sub messages. Callback tokens use ":" as a separator
      // (doId:token), which is invalid in Pub/Sub topic names — replace with
      // "." (valid in topic names, absent from callback tokens).
      const topicId = `${topicPrefix}-${callbackToken.replaceAll(":", ".")}`;
      const topicName = await createTopic(pubsubConfig, topicId);

      await grantTopicPublisher(pubsubConfig, topicName, publisher);

      // Push subscription endpoint includes the topic ID (which carries the
      // token). The route differs per product so each envelope is decoded by
      // the matching /hook handler.
      const pushEndpoint = `${this.baseUrl}/hook/${route}/${topicId}`;
      await createPushSubscription(pubsubConfig, {
        topicName,
        subscriptionName: topicId, // Use same ID for subscription
        pushEndpoint,
        oidcServiceAccountEmail: pubsubConfig.serviceAccountEmail,
        audience: this.env!.GCP_PROJECT_ID,
      });

      // Return the Pub/Sub topic name (NOT a webhook URL).
      return topicName;
    } catch (error) {
      throw new Error(
        `Failed to create ${label} webhook: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }

  async createWebhook<TCallback extends (request: any, ...args: any[]) => any>(
    options: {
      provider?: AuthProvider;
      authorization?: Authorization;
      /**
       * Create a Google Pub/Sub topic instead of a webhook URL, and return
       * the topic name. Selects the push product: "gmail" (Gmail
       * `users.watch`) or "workspace" (Google Workspace Events — Chat, etc.).
       */
      pubsub?: "gmail" | "workspace";
      async?: boolean;
    },
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<string> {
    const { provider, authorization } = options;
    if (
      !this.callbacks ||
      !this.twistInstanceId ||
      !this.twistId ||
      !this.environment ||
      !this.baseUrl ||
      !this.path
    ) {
      throw new CallbackError("UNINITIALIZED", {
        operation: "createWebhook",
      });
    }

    // Create callback token from the provided function
    // The callback is to a function on the parent, so use parent path
    const callbackFunctionName = await getRpcFunctionName(callback);
    disposeRpc(callback);
    if (!callbackFunctionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    // Handle explicit Google Pub/Sub webhook request (connector opt-in).
    // `pubsub` selects the push product: "gmail" (users.watch) or "workspace"
    // (Workspace Events — Chat, etc.). This opt-in must be explicit: a
    // provider-less webhook for another Google service (Calendar, Drive) must
    // never be routed to a Pub/Sub topic, which events.watch / files.watch
    // reject as "WebHook callback must be HTTPS".
    if (options.pubsub && this.env?.GCP_PROJECT_ID) {
      return this.createGooglePubSubWebhook(
        options.pubsub === "gmail" ? "gmail" : "workspace",
        callbackFunctionName,
        extraArgs
      );
    }

    // Handle provider-specific webhook creation
    if (provider === AuthProvider.Slack) {
      if (!authorization) {
        throw new Error(
          "authorization parameter is required when provider is Slack"
        );
      }
      return this.createSlackWebhook(
        authorization,
        callbackFunctionName,
        extraArgs
      );
    }

    // Default webhook creation for non-provider-specific webhooks.
    // Webhooks default to async (queued) delivery. Callers that need
    // synchronous dispatch — e.g. Microsoft Graph validation echoes or
    // handlers that propagate HTTP status back to the sender — opt out by
    // passing `{ async: false }`.
    const token = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      functionName: callbackFunctionName,
      extraArgs: extraArgs,
    });
    return this.tokenToUrl(token, options.async !== false);
  }

  async deleteWebhook(url: string): Promise<void> {
    if (!this.callbacks) {
      throw new CallbackError("UNINITIALIZED", {
        operation: "deleteWebhook",
      });
    }

    // Handle Slack webhooks (format: slack://{teamId}:{callbackToken})
    if (url.startsWith("slack://")) {
      const encoded = url.substring(8); // Remove "slack://" prefix
      const colonIndex = encoded.indexOf(":");
      if (colonIndex === -1) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("Invalid Slack webhook format", { url });
        return;
      }

      const teamId = encoded.substring(0, colonIndex);
      const callbackToken = encoded.substring(colonIndex + 1);

      // Get team's Durable Object
      const teamCallbacksId = this.callbacksNamespace!.idFromName(teamId);
      const teamCallbacksStub = this.callbacksNamespace!.get(teamCallbacksId);

      // Delete the callback
      await teamCallbacksStub.delete(callbackToken);
      return;
    }

    // Handle Pub/Sub webhooks (format: projects/{projectId}/topics/{prefix}-{callbackToken})
    // Covers Gmail (gmail-{token}) and generic Pub/Sub (ps-{token})
    if (url.startsWith("projects/") && url.includes("/topics/")) {
      const topicParts = url.split("/topics/");
      if (topicParts.length !== 2) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("Invalid Pub/Sub webhook format", { url });
        return;
      }

      const topicId = topicParts[1]; // e.g., "gmail-abc123" or "ps-abc123"
      // Strip the provider prefix to get the callback token.
      // Callback tokens use ":" as a separator (doId:token) which was encoded
      // as "." in the topic name because colons are invalid in Pub/Sub names.
      const prefixes = ["gmail-", "ps-"];
      let callbackToken = topicId;
      for (const prefix of prefixes) {
        if (topicId.startsWith(prefix)) {
          callbackToken = topicId.substring(prefix.length);
          break;
        }
      }
      callbackToken = callbackToken.replaceAll(".", ":");

      // Extract project ID from topic name
      const projectIdMatch = url.match(/projects\/([^/]+)/);
      if (!projectIdMatch) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("Could not extract project ID from Pub/Sub webhook", { url });
        return;
      }
      const projectId = projectIdMatch[1];

      // Get GCP configuration
      if (
        !this.env?.GCP_PROJECT_ID ||
        !this.env?.GCP_SERVICE_ACCOUNT_EMAIL ||
        !this.env?.GCP_SERVICE_ACCOUNT_KEY
      ) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("GCP configuration missing, cannot delete Pub/Sub resources");
        // Continue to delete callback even if Pub/Sub cleanup fails
      } else {
        const pubsubConfig = {
          projectId: this.env.GCP_PROJECT_ID,
          serviceAccountEmail: this.env.GCP_SERVICE_ACCOUNT_EMAIL,
          serviceAccountKey: this.env.GCP_SERVICE_ACCOUNT_KEY,
        };

        const subscriptionName = `projects/${projectId}/subscriptions/${topicId}`;
        try {
          // Delete subscription first (order matters)
          await deleteSubscription(pubsubConfig, subscriptionName);
        } catch (error) {
          const logger = createLogger({ twist_instance_id: this.twistInstanceId });
          logger.warn("Failed to delete Pub/Sub subscription", {
            error_message: error instanceof Error ? error.message : String(error),
            subscription_name: subscriptionName,
          });
          // Continue to topic deletion
        }

        try {
          // Delete topic
          await deleteTopic(pubsubConfig, url);
        } catch (error) {
          const logger = createLogger({ twist_instance_id: this.twistInstanceId });
          logger.warn("Failed to delete Pub/Sub topic", {
            error_message: error instanceof Error ? error.message : String(error),
            topic_url: url,
          });
          // Continue to callback deletion
        }
      }

      // Delete the callback
      await this.callbacks.delete(callbackToken);
      return;
    }

    // Handle standard webhooks (format: {baseUrl}/hook/{token})
    const token = this.urlToToken(url);
    if (!token) {
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.warn("Could not extract token from webhook URL", { url });
      return;
    }
    await this.callbacks.delete(token);
  }

  private tokenToUrl(token: string, async: boolean = false): string {
    return `${this.baseUrl}/${async ? "hook" : "hook-sync"}/${token}`;
  }

  private urlToToken(url: string): string | null {
    if (!this.baseUrl) return null;

    const prefixes = [
      `${this.baseUrl}/hook-async/`,
      `${this.baseUrl}/hook-sync/`,
      `${this.baseUrl}/hook/`,
    ];
    for (const prefix of prefixes) {
      if (url.startsWith(prefix)) {
        return url.substring(prefix.length);
      }
    }
    return null;
  }
}
