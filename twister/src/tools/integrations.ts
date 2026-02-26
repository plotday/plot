import {
  type Actor,
  type ActorId,
  type NewContact,
  type NewLinkWithNotes,
  type Note,
  type Thread,
  type ThreadMeta,
  ITool,
  Serializable,
} from "..";
import type { Uuid } from "../utils/uuid";

/**
 * A resource that can be synced (e.g., a calendar, project, channel).
 * Returned by getChannels() and managed by users in the twist setup/edit modal.
 */
export type Channel = {
  /** External ID shared across users (e.g., Google calendar ID) */
  id: string;
  /** Display name shown in the UI */
  title: string;
  /** Optional nested channel resources (e.g., subfolders) */
  children?: Channel[];
};

/**
 * Configuration for an OAuth provider in a source's build options.
 * Declares the provider, scopes, and lifecycle callbacks.
 */
/**
 * Describes a link type that a source creates.
 * Used for display in the UI (icons, labels).
 */
export type LinkTypeConfig = {
  /** Machine-readable type identifier (e.g., "issue", "pull_request") */
  type: string;
  /** Human-readable label (e.g., "Issue", "Pull Request") */
  label: string;
  /** Filename of a static asset in the source's assets/ directory (e.g., "issue.svg") */
  logo?: string;
  /** Possible status values for this type */
  statuses?: Array<{
    /** Machine-readable status (e.g., "open", "done") */
    status: string;
    /** Human-readable label (e.g., "Open", "Done") */
    label: string;
  }>;
};

export type IntegrationProviderConfig = {
  /** The OAuth provider */
  provider: AuthProvider;
  /** OAuth scopes to request */
  scopes: string[];
  /** Registry of link types this source creates */
  linkTypes?: LinkTypeConfig[];
  /** Returns available channels for the authorized actor. Must not use Plot tool. */
  getChannels: (auth: Authorization, token: AuthToken) => Promise<Channel[]>;
  /** Called when a channel resource is enabled for syncing */
  onChannelEnabled: (channel: Channel) => Promise<void>;
  /** Called when a channel resource is disabled */
  onChannelDisabled: (channel: Channel) => Promise<void>;
  /**
   * Called when a thread created by this source is updated by the user.
   * Used for write-back to external services (e.g., marking an issue as done).
   */
  onThreadUpdated?: (thread: Thread) => Promise<void>;
  /**
   * Called when a note is created on a thread owned by this source.
   * Used for write-back to external services (e.g., adding a comment to an issue).
   */
  onNoteCreated?: (note: Note, meta: ThreadMeta) => Promise<void>;

};

/**
 * Options passed to Integrations in the build() method.
 */
export type IntegrationOptions = {
  /** Provider configurations with lifecycle callbacks */
  providers: IntegrationProviderConfig[];
};

/**
 * Built-in tool for managing OAuth authentication and channel resources.
 *
 * The Integrations tool:
 * 1. Declares providers/scopes in build options with lifecycle callbacks
 * 2. Manages channel resources (calendars, projects, etc.) per actor
 * 3. Returns tokens for the user who enabled sync on a channel
 * 4. Supports per-actor auth via actAs() for write-back operations
 * 5. Provides saveThread/saveContacts/archiveThreads for Sources to save data directly
 *
 * Auth and channel management is handled in the twist edit modal in Flutter,
 * removing the need for sources to create auth activities or selection UIs.
 *
 * @example
 * ```typescript
 * class CalendarSource extends Source<CalendarSource> {
 *   static readonly PROVIDER = AuthProvider.Google;
 *   static readonly SCOPES = ["https://www.googleapis.com/auth/calendar"];
 *
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations, {
 *         providers: [{
 *           provider: AuthProvider.Google,
 *           scopes: CalendarSource.SCOPES,
 *           getChannels: this.getChannels,
 *           onChannelEnabled: this.onChannelEnabled,
 *           onChannelDisabled: this.onChannelDisabled,
 *         }]
 *       }),
 *     };
 *   }
 *
 *   async getChannels(auth: Authorization, token: AuthToken): Promise<Channel[]> {
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
   * Retrieves an access token for a channel resource.
   *
   * Returns the token of the user who enabled sync on the given channel.
   * If the channel is not enabled or the token is expired/invalid, returns null.
   *
   * @param provider - The OAuth provider
   * @param channelId - The channel resource ID (e.g., calendar ID)
   * @returns Promise resolving to the access token or null
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract get(provider: AuthProvider, channelId: string): Promise<AuthToken | null>;

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

  /**
   * Saves a link with notes to the source's priority.
   *
   * Creates a thread+link pair. The thread is a lightweight container;
   * the link holds the external entity data (source, meta, type, status, etc.).
   *
   * This method is available only to Sources (not regular Twists).
   *
   * @param link - The link with notes to save
   * @returns Promise resolving to the saved thread's UUID
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract saveLink(link: NewLinkWithNotes): Promise<Uuid>;

  /**
   * Saves contacts to the source's priority.
   *
   * @param contacts - Array of contacts to save
   * @returns Promise resolving to the saved actors
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract saveContacts(contacts: NewContact[]): Promise<Actor[]>;

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
