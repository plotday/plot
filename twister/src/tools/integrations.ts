import { type Actor, type ActorId, type ActivityLink, ITool, Serializable } from "..";

/**
 * Built-in tool for managing OAuth authentication flows.
 *
 * The Integrations tool provides a unified interface for requesting user authorization
 * from external service providers like Google and Microsoft. It handles the
 * OAuth flow creation, token management, and callback integration.
 *
 * @example
 * ```typescript
 * class CalendarTool extends Tool {
 *   private auth: Integrations;
 *
 *   constructor(id: string, tools: ToolBuilder) {
 *     super();
 *     this.integrations = tools.get(Integrations);
 *   }
 *
 *   async requestAuth() {
 *     return await this.integrations.request({
 *       provider: AuthProvider.Google,
 *       scopes: ["https://www.googleapis.com/auth/calendar.readonly"]
 *     }, {
 *       functionName: "onAuthComplete",
 *       context: { provider: "google" }
 *     });
 *   }
 *
 *   async onAuthComplete(authResult: Authorization, context: any) {
 *     const authToken = await this.integrations.get(authResult.provider, authResult.actor.id);
 *   }
 * }
 * ```
 */
export abstract class Integrations extends ITool {
  /**
   * Initiates an OAuth authentication flow.
   *
   * Creates an authentication link that users can click to authorize access
   * to the specified provider with the requested scopes. When authorization
   * completes, the callback will be invoked with the Authorization and any extraArgs.
   *
   * @param auth - Authentication configuration
   * @param auth.provider - The OAuth provider to authenticate with
   * @param auth.scopes - Array of OAuth scopes to request
   * @param callback - Function receiving (authorization, ...extraArgs)
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, must be serializable)
   * @returns Promise resolving to an ActivityLink for the auth flow
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract request<
    TArgs extends Serializable[],
    TCallback extends (auth: Authorization, ...args: TArgs) => any
  >(
    auth: {
      provider: AuthProvider;
      scopes: string[];
    },
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<ActivityLink>;

  /**
   * Retrieves an access token (refreshing it first if necessary).
   *
   * Looks up the token by provider and actor ID. If the given actor hasn't
   * directly authenticated but is linked (same user_id) to a contact that has,
   * returns that linked contact's token.
   *
   * Returns null if no valid token is found.
   *
   * @param provider - The OAuth provider to retrieve a token for
   * @param actorId - The actor (contact) ID to look up
   * @returns Promise resolving to the access token or null if no longer available
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract get(provider: AuthProvider, actorId: ActorId): Promise<AuthToken | null>;
}

/**
 * Enumeration of supported OAuth providers.
 *
 * Each provider has different OAuth endpoints, scopes, and token formats.
 * The Integrations tool handles the provider-specific implementation details.
 */
export enum AuthProvider {
  /** Google OAuth provider for Google Workspace services */
  Google = "google",
  /** Microsoft OAuth provider for Microsoft 365 services */
  Microsoft = "microsoft",
  /** Notion OAuth provider for Notion workspaces */
  Notion = "notion",
  /** Slack OAuth provider for Slack workspaces */
  Slack = "slack",
  /** Atlassian OAuth provider for Jira and Confluence */
  Atlassian = "atlassian",
  /** Linear OAuth provider for Linear workspaces */
  Linear = "linear",
  /** Monday.com OAuth provider */
  Monday = "monday",
  /** GitHub OAuth provider for GitHub repositories and organizations */
  GitHub = "github",
  /** Asana OAuth provider for Asana workspaces */
  Asana = "asana",
  /** HubSpot OAuth provider for HubSpot CRM */
  HubSpot = "hubspot",
}

/**
 * Represents a completed authorization from an OAuth flow.
 *
 * Contains the provider, granted scopes, and the actor (contact) that was authorized.
 * Tokens are looked up by (provider, actorId) rather than a random ID.
 */
export type Authorization = {
  /** The OAuth provider this authorization is for */
  provider: AuthProvider;
  /** Array of OAuth scopes this authorization covers */
  scopes: string[];
  /** The external account that was authorized (e.g., the Google account) */
  actor: Actor;
};

/**
 * Represents a stored OAuth authentication token.
 *
 * Contains the actual access token and the scopes it was granted,
 * which may be a subset of the originally requested scopes.
 */
export type AuthToken = {
  /** The OAuth access token */
  token: string;
  /** Array of granted OAuth scopes */
  scopes: string[];
  /**
   * Provider-specific metadata as key-value pairs.
   *
   * For Slack (AuthProvider.Slack):
   * - authed_user_id: The authenticated user's Slack ID
   * - bot_user_id: The bot user's Slack ID
   * - team_name: The Slack workspace/team name
   */
  provider?: Record<string, string>;
};
