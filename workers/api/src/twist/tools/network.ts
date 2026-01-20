import {
  AuthProvider,
  type Authorization,
} from "@plotday/twister/tools/integrations";
import { type Network as INetwork } from "@plotday/twister/tools/network";
import type { Store as IStore } from "@plotday/twister/tools/store";

import { type TwistEnvironment, type Bindings } from "../../env";
import { CallbacksState } from "../../state/callbacks";
import { createLogger } from "../../utils/logger";
import {
  createPushSubscription,
  createTopic,
  deleteSubscription,
  deleteTopic,
} from "../../utils/pubsub";
import { getRpcFunctionName } from "../../utils/rpc";
import { type ToolPermission } from "../permissions";
import { Tool } from "./tool";

export type NetworkOptions = {
  urls?: string[];
  callbacks?: DurableObjectNamespace<CallbacksState>;
  priorityTwistId?: string;
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
export const GMAIL_SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/gmail.modify",
  "https://www.googleapis.com/auth/gmail.compose",
  "https://mail.google.com/", // Full Gmail access
];

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
  private priorityTwistId?: string;
  private twistId?: string;
  private environment?: TwistEnvironment;
  private baseUrl?: string;
  private path?: string[];
  private store?: IStore;
  private env?: Bindings;

  public static readonly PATH = "/hook/:token";

  private static GetCallbacksStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    /// Usually priorityTwistId. For Slack webhooks, we use the Slack team ID.
    key: string
  ) {
    const callbacksId = callbacks.idFromName(key);
    return callbacks.get(callbacksId);
  }

  static async HandleWebhook(
    callbacks: DurableObjectNamespace<CallbacksState>,
    token: string,
    request: WebhookRequest
  ) {
    return await CallbacksState.CallCallback(callbacks, token, request);
  }

  /**
   * Handles Slack webhook routing to multiple callbacks based on team_id.
   * Filters callbacks by event type and granted scopes.
   */
  static async HandleSlackWebhook(
    callbacks: DurableObjectNamespace<CallbacksState>,
    request: WebhookRequest
  ): Promise<any> {
    // Extract team_id from Slack webhook payload
    const teamId = request.body?.team_id;
    if (!teamId) {
      const logger = createLogger();
      logger.warn("Slack webhook missing team_id");
      return { ok: false, error: "Missing team_id" };
    }

    // Extract event type
    const eventType = request.body?.event?.type;
    if (!eventType) {
      const logger = createLogger();
      logger.warn("Slack webhook missing event type");
      return { ok: false, error: "Missing event type" };
    }

    // Get callbacks for this team
    const callbacksStub = Network.GetCallbacksStub(callbacks, teamId);
    const teamCallbacks = await callbacksStub.get(teamId);

    if (!teamCallbacks || teamCallbacks.length === 0) {
      const logger = createLogger();
      logger.warn("No callbacks registered for Slack team", { team_id: teamId });
      return { ok: true, message: "No callbacks registered" };
    }

    // Filter callbacks by event scopes
    const matchingCallbacks = teamCallbacks.filter(
      (cb: { callback: string; meta?: Record<string, any> }) => {
        const scopes = cb.meta?.scopes || [];
        return checkSlackEventScopes(eventType, scopes);
      }
    );

    if (matchingCallbacks.length === 0) {
      const logger = createLogger();
      logger.warn("No callbacks with required scopes for event", {
        event_type: eventType,
        team_id: teamId,
      });
      return { ok: true, message: "No matching callbacks" };
    }

    // Call all matching callbacks in parallel
    const results = await Promise.allSettled(
      matchingCallbacks.map(
        (cb: { callback: string; meta?: Record<string, any> }) =>
          CallbacksState.CallCallback(callbacks, cb.callback, request)
      )
    );

    // Log any failures
    const failures = results.filter(
      (r: PromiseSettledResult<any>) => r.status === "rejected"
    );
    if (failures.length > 0) {
      const logger = createLogger();
      logger.error("Slack webhook callbacks failed", {
        failed_count: failures.length,
        total_count: results.length,
        failures,
      });
    }

    return { ok: true, processed: results.length };
  }

  /**
   * Handles Gmail webhook routing via Google Pub/Sub.
   * Decodes the callback token from the topic ID and calls the callback directly.
   */
  static async HandleGmailWebhook(
    callbacks: DurableObjectNamespace<CallbacksState>,
    token: string,
    request: WebhookRequest
  ): Promise<any> {
    if (!token) {
      const logger = createLogger();
      logger.warn("Gmail webhook missing token");
      return { ok: false, error: "Missing token" };
    }

    // Call the callback directly using the token
    return await CallbacksState.CallCallback(callbacks, token, request);
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
    if (options?.callbacks && options.priorityTwistId) {
      this.callbacksNamespace = options.callbacks;
      this.callbacks = Network.GetCallbacksStub(
        options.callbacks,
        options.priorityTwistId
      );
      this.priorityTwistId = options.priorityTwistId;
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

    // Retrieve integration data from store
    const tokenKey = `auth_token:${authorization.id}`;
    const tokenData = await this.store.get<{
      access_token: string;
      refresh_token?: string;
      scopes: string[];
      team?: {
        id: string;
        name: string;
      };
    }>(tokenKey);

    if (!tokenData) {
      throw new Error(
        `No integration found for authorization ${authorization.id}`
      );
    }

    if (!tokenData.team?.id) {
      throw new Error("Slack integration missing team_id");
    }

    const teamId = tokenData.team.id;
    const scopes = tokenData.scopes || [];

    // For Slack webhooks, we use team_id for DO sharding to enable
    // webhook routing without knowing the priorityTwistId in advance.
    // Get CallbacksState DO for this team_id.
    const teamCallbacksId = this.callbacksNamespace!.idFromName(teamId);
    const teamCallbacksStub = this.callbacksNamespace!.get(teamCallbacksId);

    // Create callback with team_id as key for routing
    // Store the actual priorityTwistId in meta for callback execution
    const callbackToken = await teamCallbacksStub.create({
      priorityTwistId: this.priorityTwistId!,
      path: this.path!,
      functionName: callbackFunctionName,
      extraArgs,
      key: teamId,
      meta: {
        scopes,
        authorization: authorization.id,
        priorityTwistId: this.priorityTwistId, // Store for reference
      },
    });

    // Return encoded webhook identifier that includes team ID and callback token
    // Format: slack://{teamId}:{callbackToken}
    // This allows deleteWebhook() to properly clean up the callback
    return `slack://${teamId}:${callbackToken}`;
  }

  /**
   * Creates a Gmail-specific webhook using Google Pub/Sub.
   * Each webhook gets its own dedicated Pub/Sub topic and push subscription.
   *
   * @returns Pub/Sub topic name (e.g., "projects/plot-prod/topics/gmail-webhook-abc123")
   *          instead of a webhook URL
   */
  private async createGmailWebhook(
    authorization: Authorization,
    callbackFunctionName: string,
    extraArgs?: any[]
  ): Promise<string> {
    if (!this.store) {
      throw new Error("Store not initialized for Gmail webhooks");
    }

    // Retrieve integration data from store
    const tokenKey = `auth_token:${authorization.id}`;
    const tokenData = await this.store.get<{
      access_token: string;
      refresh_token?: string;
      scopes: string[];
    }>(tokenKey);

    if (!tokenData) {
      throw new Error(
        `No integration found for authorization ${authorization.id}`
      );
    }

    const scopes = tokenData.scopes || [];

    // Verify authorization contains Gmail scopes
    const hasGmailScope = scopes.some((scope) => GMAIL_SCOPES.includes(scope));
    if (!hasGmailScope) {
      throw new Error(
        `Authorization ${authorization.id} does not have Gmail scopes. ` +
          `Required: ${GMAIL_SCOPES.join(", ")}`
      );
    }

    // Get GCP configuration from environment
    if (
      !this.env?.GCP_PROJECT_ID ||
      !this.env?.GCP_SERVICE_ACCOUNT_EMAIL ||
      !this.env?.GCP_SERVICE_ACCOUNT_KEY
    ) {
      throw new Error(
        "GCP configuration missing. Required: GCP_PROJECT_ID, GCP_SERVICE_ACCOUNT_EMAIL, GCP_SERVICE_ACCOUNT_KEY"
      );
    }

    const pubsubConfig = {
      projectId: this.env.GCP_PROJECT_ID,
      serviceAccountEmail: this.env.GCP_SERVICE_ACCOUNT_EMAIL,
      serviceAccountKey: this.env.GCP_SERVICE_ACCOUNT_KEY,
    };

    try {
      // First, create the callback to get a token
      // Use standard callback creation with priorityTwistId for DO sharding
      const callbackToken = await this.callbacks!.create({
        priorityTwistId: this.priorityTwistId!,
        path: this.path!,
        functionName: callbackFunctionName,
        extraArgs,
        meta: {
          scopes,
          authorization: authorization.id,
        },
      });

      // Encode the callback token into the topic ID
      // This allows us to decode the token when receiving Pub/Sub messages
      const topicId = `gmail-${callbackToken}`;

      // Create Pub/Sub topic with the encoded token
      const topicName = await createTopic(pubsubConfig, topicId);

      // Create Push subscription pointing to our webhook endpoint
      // The endpoint URL includes the topic ID (which contains the token)
      const pushEndpoint = `${this.baseUrl}/hook/gmail/${topicId}`;
      await createPushSubscription(pubsubConfig, {
        topicName,
        subscriptionName: topicId, // Use same ID for subscription
        pushEndpoint,
      });

      // Return Pub/Sub topic name (NOT a webhook URL)
      return topicName;
    } catch (error) {
      throw new Error(
        `Failed to create Gmail webhook: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }

  async createWebhook<TCallback extends (request: any, ...args: any[]) => any>(
    options: {
      provider?: AuthProvider;
      authorization?: Authorization;
    },
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<string> {
    const { provider, authorization } = options;
    if (
      !this.callbacks ||
      !this.priorityTwistId ||
      !this.twistId ||
      !this.environment ||
      !this.baseUrl ||
      !this.path
    ) {
      throw new Error("Webhook functionality not initialized");
    }

    // Create callback token from the provided function
    // The callback is to a function on the parent, so use parent path
    const callbackFunctionName = await getRpcFunctionName(callback);
    if (!callbackFunctionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
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

    // Handle Gmail webhooks (Google provider with Gmail scopes)
    if (provider === AuthProvider.Google && authorization) {
      // Check if authorization has Gmail scopes
      const tokenKey = `auth_token:${authorization.id}`;
      const tokenData = await this.store?.get<{
        scopes: string[];
      }>(tokenKey);

      if (tokenData) {
        const scopes = tokenData.scopes || [];
        const hasGmailScope = scopes.some((scope) =>
          GMAIL_SCOPES.includes(scope)
        );

        if (hasGmailScope) {
          return this.createGmailWebhook(
            authorization,
            callbackFunctionName,
            extraArgs
          );
        }
      }
    }

    // Default webhook creation for non-provider-specific webhooks
    const token = await this.callbacks.create({
      priorityTwistId: this.priorityTwistId,
      path: this.path,
      functionName: callbackFunctionName,
      extraArgs: extraArgs,
    });
    return this.tokenToUrl(token);
  }

  async deleteWebhook(url: string): Promise<void> {
    if (!this.callbacks) {
      throw new Error("Webhook functionality not initialized");
    }

    // Handle Slack webhooks (format: slack://{teamId}:{callbackToken})
    if (url.startsWith("slack://")) {
      const encoded = url.substring(8); // Remove "slack://" prefix
      const colonIndex = encoded.indexOf(":");
      if (colonIndex === -1) {
        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
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

    // Handle Gmail webhooks (format: projects/{projectId}/topics/gmail-{callbackToken})
    if (url.startsWith("projects/") && url.includes("/topics/gmail-")) {
      // Extract topic ID (gmail-{token})
      const topicParts = url.split("/topics/");
      if (topicParts.length !== 2) {
        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
        logger.warn("Invalid Gmail webhook format", { url });
        return;
      }

      const topicId = topicParts[1]; // e.g., "gmail-abc123xyz789"
      const callbackToken = topicId.startsWith("gmail-")
        ? topicId.substring(6) // Remove "gmail-" prefix
        : topicId;

      // Extract project ID from topic name
      const projectIdMatch = url.match(/projects\/([^/]+)/);
      if (!projectIdMatch) {
        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
        logger.warn("Could not extract project ID from Gmail webhook", { url });
        return;
      }
      const projectId = projectIdMatch[1];

      // Get GCP configuration
      if (
        !this.env?.GCP_PROJECT_ID ||
        !this.env?.GCP_SERVICE_ACCOUNT_EMAIL ||
        !this.env?.GCP_SERVICE_ACCOUNT_KEY
      ) {
        const logger = createLogger({ priority_twist_id: this.priorityTwistId });
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
          const logger = createLogger({ priority_twist_id: this.priorityTwistId });
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
          const logger = createLogger({ priority_twist_id: this.priorityTwistId });
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
      const logger = createLogger({ priority_twist_id: this.priorityTwistId });
      logger.warn("Could not extract token from webhook URL", { url });
      return;
    }
    await this.callbacks.delete(token);
  }

  private tokenToUrl(token: string): string {
    return `${this.baseUrl}/hook/${token}`;
  }

  private urlToToken(url: string): string | null {
    if (!this.baseUrl) return null;

    const webhookPrefix = `${this.baseUrl}/hook/`;
    if (!url.startsWith(webhookPrefix)) {
      return null;
    }
    return url.substring(webhookPrefix.length);
  }
}
