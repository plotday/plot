import { type ActivityLink, ITool } from "..";
import { type NoFunctions } from "./callbacks";

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
 *       level: AuthLevel.User,
 *       scopes: ["https://www.googleapis.com/auth/calendar.readonly"]
 *     }, {
 *       functionName: "onAuthComplete",
 *       context: { provider: "google" }
 *     });
 *   }
 *
 *   async onAuthComplete(authResult: Authorization, context: any) {
 *     const authToken = await this.integrations.get(authResult);
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
   * @param auth.level - The authorization level (priority-scoped or user-scoped)
   * @param auth.scopes - Array of OAuth scopes to request
   * @param callback - Function receiving (authorization, ...extraArgs)
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, must be serializable)
   * @returns Promise resolving to an ActivityLink for the auth flow
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract request<
    TCallback extends (auth: Authorization, ...args: any[]) => any
  >(
    auth: {
      provider: AuthProvider;
      level: AuthLevel;
      scopes: string[];
    },
    callback: TCallback,
    ...extraArgs: TCallback extends (auth: any, ...rest: infer R) => any
      ? NoFunctions<R>
      : []
  ): Promise<ActivityLink>;

  /**
   * Retrieves an access token (refreshing it first if necessary).
   *
   * Returns null if the authorization is no longer valid or has been revoked.
   *
   * @param authorization - The authorization from the request callback
   * @returns Promise resolving to the access token or null if no longer available
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract get(authorization: Authorization): Promise<AuthToken | null>;
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
 * Enumeration of authorization levels for OAuth flows.
 *
 * Different levels determine the scope and storage of authentication tokens.
 */
export enum AuthLevel {
  /** Priority-scoped authorization shared across agents in a priority */
  Priority = "priority",
  /** User-scoped authorization specific to individual users */
  User = "user",
}

/**
 * Represents authorization criteria for token lookup.
 *
 * Used to specify which authentication token to retrieve from storage
 * based on provider, scopes, and authorization ID.
 */
export type Authorization = {
  /** Unique identifier for this authorization */
  id: string;
  /** The OAuth provider this authorization is for */
  provider: AuthProvider;
  /** Array of OAuth scopes this authorization covers */
  scopes: string[];
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
