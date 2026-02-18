import { type Actor, type ActorId, ITool, Serializable } from "..";
import type { Uuid } from "../utils/uuid";

/**
 * A resource that can be synced (e.g., a calendar, project, channel).
 * Returned by getSyncables() and managed by users in the twist setup/edit modal.
 */
export type Syncable = {
  /** External ID shared across users (e.g., Google calendar ID) */
  id: string;
  /** Display name shown in the UI */
  title: string;
};

/**
 * Configuration for an OAuth provider in a tool's build options.
 * Declares the provider, scopes, and lifecycle callbacks.
 */
export type IntegrationProviderConfig = {
  /** The OAuth provider */
  provider: AuthProvider;
  /** OAuth scopes to request */
  scopes: string[];
  /** Returns available syncables for the authorized actor. Must not use Plot tool. */
  getSyncables: (auth: Authorization, token: AuthToken) => Promise<Syncable[]>;
  /** Called when a syncable resource is enabled for syncing */
  onSyncEnabled: (syncable: Syncable) => Promise<void>;
  /** Called when a syncable resource is disabled */
  onSyncDisabled: (syncable: Syncable) => Promise<void>;
};

/**
 * Options passed to Integrations in the build() method.
 */
export type IntegrationOptions = {
  /** Provider configurations with lifecycle callbacks */
  providers: IntegrationProviderConfig[];
};

/**
 * Built-in tool for managing OAuth authentication and syncable resources.
 *
 * The redesigned Integrations tool:
 * 1. Declares providers/scopes in build options with lifecycle callbacks
 * 2. Manages syncable resources (calendars, projects, etc.) per actor
 * 3. Returns tokens for the user who enabled sync on a syncable
 * 4. Supports per-actor auth via actAs() for write-back operations
 *
 * Auth and syncable management is handled in the twist edit modal in Flutter,
 * removing the need for tools to create auth activities or selection UIs.
 *
 * @example
 * ```typescript
 * class CalendarTool extends Tool<CalendarTool> {
 *   static readonly PROVIDER = AuthProvider.Google;
 *   static readonly SCOPES = ["https://www.googleapis.com/auth/calendar"];
 *
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations, {
 *         providers: [{
 *           provider: AuthProvider.Google,
 *           scopes: CalendarTool.SCOPES,
 *           getSyncables: this.getSyncables,
 *           onSyncEnabled: this.onSyncEnabled,
 *           onSyncDisabled: this.onSyncDisabled,
 *         }]
 *       }),
 *     };
 *   }
 *
 *   async getSyncables(auth: Authorization, token: AuthToken): Promise<Syncable[]> {
 *     const calendars = await this.listCalendars(token);
 *     return calendars.map(c => ({ id: c.id, title: c.name }));
 *   }
 * }
 * ```
 */
export abstract class Integrations extends ITool {
  /**
   * Merge scopes from multiple tools, deduplicating.
   *
   * @param scopeArrays - Arrays of scopes to merge
   * @returns Deduplicated array of scopes
   */
  static MergeScopes(...scopeArrays: string[][]): string[] {
    return Array.from(new Set(scopeArrays.flat()));
  }

  /**
   * Retrieves an access token for a syncable resource.
   *
   * Returns the token of the user who enabled sync on the given syncable.
   * If the syncable is not enabled or the token is expired/invalid, returns null.
   *
   * @param provider - The OAuth provider
   * @param syncableId - The syncable resource ID (e.g., calendar ID)
   * @returns Promise resolving to the access token or null
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract get(provider: AuthProvider, syncableId: string): Promise<AuthToken | null>;

  /**
   * Execute a callback as a specific actor, requesting auth if needed.
   *
   * If the actor has a valid token, calls the callback immediately with it.
   * If the actor has no token, creates a private auth note in the specified
   * activity prompting them to connect. Once they authorize, this callback fires.
   *
   * @param provider - The OAuth provider
   * @param actorId - The actor to act as
   * @param activityId - The activity to create an auth note in (if needed)
   * @param callback - Function to call with the token
   * @param extraArgs - Additional arguments to pass to the callback
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract actAs<
    TArgs extends Serializable[],
    TCallback extends (token: AuthToken, ...args: TArgs) => any
  >(
    provider: AuthProvider,
    actorId: ActorId,
    activityId: Uuid,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void>;

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
