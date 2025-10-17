import { type ActivityLink, type Callback, ITool, type Tools } from "..";

/**
 * Built-in tool for managing OAuth authentication flows.
 *
 * The Auth tool provides a unified interface for requesting user authorization
 * from external service providers like Google and Microsoft. It handles the
 * OAuth flow creation, token management, and callback integration.
 *
 * @example
 * ```typescript
 * class CalendarTool extends Tool {
 *   private auth: Auth;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.auth = tools.get(Auth);
 *   }
 *
 *   async requestAuth() {
 *     return await this.auth.request({
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
 *     const authToken = await this.auth.get(authResult);
 *   }
 * }
 * ```
 */
export abstract class Auth extends ITool {
  /**
   * Initiates an OAuth authentication flow.
   *
   * Creates an authentication link that users can click to authorize access
   * to the specified provider with the requested scopes. When authorization
   * completes, the optional callback will be invoked with the results.
   *
   * @param auth - Authentication configuration
   * @param auth.provider - The OAuth provider to authenticate with
   * @param auth.level - The authorization level (priority-scoped or user-scoped)
   * @param auth.scopes - Array of OAuth scopes to request
   * @param callback - Callback receiving an Authorization
   * @returns Promise resolving to an ActivityLink for the auth flow
   */
  abstract request(
    _auth: {
      provider: AuthProvider;
      level: AuthLevel;
      scopes: string[];
    },
    _callback: Callback,
  ): Promise<ActivityLink>;

  /**
   * Retrieves an access token (refreshing it first if necessary).
   *
   * Returns null if the authorization is no longer valid or has been revoked.
   *
   * @param authorization - The authorization from the request callback
   * @returns Promise resolving to the access token or null if no longer available
   */
  abstract get(_authorization: Authorization): Promise<AuthToken | null>;
}

/**
 * Enumeration of supported OAuth providers.
 *
 * Each provider has different OAuth endpoints, scopes, and token formats.
 * The Auth tool handles the provider-specific implementation details.
 */
export enum AuthProvider {
  /** Google OAuth provider for Google Workspace services */
  Google = "google",
  /** Microsoft OAuth provider for Microsoft 365 services */
  Microsoft = "microsoft",
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
};
