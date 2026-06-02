import {
  type Actor,
  type ActorId,
  type NewContact,
  type NewLinkWithNotes,
  ITool,
} from "..";
import type { JSONValue } from "../utils/types";
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
  /** Per-channel link type configs. Overrides twist-level linkTypes when present. */
  linkTypes?: LinkTypeConfig[];
};

/**
 * Describes a link type that a connector creates.
 * Used for display in the UI (icons, labels).
 */
export type LinkTypeConfig = {
  /** Machine-readable type identifier (e.g., "issue", "pull_request") */
  type: string;
  /** Human-readable label (e.g., "Issue", "Pull Request") */
  label: string;
  /**
   * Connector's word for a note on a linked item of this type — used by the
   * Flutter app to adapt note/composer copy ("Add a comment" on Linear,
   * "Add a message" on Slack, "Add a reply" on Gmail). Defaults to "note"
   * when omitted. Use the singular noun in title case (e.g. "Comment").
   */
  noteLabel?: string;
  /**
   * Placeholder shown in the editor when this link type is the target of a
   * new thread (NewThreadPage). Example: "Send a Gmail email".
   * If unset, Plot derives "Create a new {connector} {label.toLowerCase()}".
   */
  composePlaceholder?: string;
  /**
   * Label for the Send button on NewThreadPage when this link type is the
   * target. Example: "Send". If unset, defaults to "Create".
   */
  composeVerb?: string;
  /**
   * Placeholder shown in the in-thread editor for the default reply mode.
   * Example: "Reply" (Gmail), "Add a comment" (Linear). If unset, Plot derives
   * "Add a {noteLabel.toLowerCase()}" or "Add a note".
   */
  replyPlaceholder?: string;
  /**
   * Label for the Send button in the in-thread editor. Example: "Send"
   * (Gmail), "Comment" (Linear). If unset, defaults to "Send".
   */
  replyVerb?: string;
  /** URL to an icon for this link type (light mode). Prefer Iconify `logos/*` URLs. */
  logo?: string;
  /** URL to an icon for dark mode. Use when the default logo is invisible on dark backgrounds (e.g., Iconify `simple-icons/*` with `?color=`). */
  logoDark?: string;
  /** URL to a monochrome icon (uses `currentColor`). Prefer Iconify `simple-icons/*` URLs without a `?color=` param. */
  logoMono?: string;
  /** Possible status values for this type */
  statuses?: Array<{
    /** Machine-readable status (e.g., "open", "done") */
    status: string;
    /** Human-readable label (e.g., "Open", "Done") */
    label: string;
    /** Whether this status represents completion (done, closed, merged, cancelled, etc.) */
    done?: boolean;
    /**
     * Mark the thread `active=true` in Plot when a link enters this status.
     * Use for messaging-style flags where the user has indicated they want
     * to act on the thread now — Gmail's "starred", Slack's "later", etc.
     * The Plot user can later un-flag the thread without breaking the
     * connector relationship.
     */
    active?: boolean;
    /**
     * Marks this status as the connector's "to-do" / active state. When a
     * user brings a done thread back into Plot's agenda, done-status links
     * are flipped to the status marked `todo: true` (e.g. Gmail's "starred",
     * Linear's "unstarted"); connectors that don't mark one fall back to the
     * first non-done status.
     */
    todo?: boolean;
  }>;
  /** Whether this link type supports displaying and changing the assignee */
  supportsAssignee?: boolean;
  /** Default thread creation mode for this link type: 'all' | 'actionable' | 'manual' */
  defaultCreateThreads?: string;
  /**
   * Opt-in: declares this link type is composable from Plot via
   * `Connector.onCreateLink`. Omit to make the link type sync-only (no
   * "Create new …" picker entry).
   *
   * Connectors that need multiple compose modes for what users perceive as
   * the same kind of thing (e.g. Slack channel post vs DM) should declare
   * **separate linkTypes**, one per user-facing thread type. That keeps
   * each linkType isomorphic to one filter chip.
   */
  compose?: ComposeConfig;
  /**
   * Per-connector contact roles. Examples:
   *   email   → [{id:"to",label:"To",default:true},{id:"cc",label:"CC"},{id:"bcc",label:"BCC",hidden:true}]
   *   calendar → [{id:"required",label:"Required",default:true},{id:"optional",label:"Optional"}]
   *
   * Plot uses this list to render a role picker on each contact chip in the
   * composer and to label non-default roles on existing threads. Exactly one
   * role should be marked `default: true`. Connectors that don't distinguish
   * roles (Slack, Linear) omit this field entirely.
   */
  contactRoles?: ContactRoleConfig[];
  /**
   * Whether contacts on an existing thread can be added, removed, or have
   * their role changed (email-style mid-thread recipient changes). When
   * false, the thread's contact list is fixed after creation. Defaults to
   * false when omitted.
   */
  supportsContactChanges?: boolean;
  /**
   * Whether a note/reply on this link type can carry a link (a pasted URL or
   * connector-created item) that Plot forwards to the source. When false (the
   * default), the "Add link" button is hidden for threads of this link type.
   * Only set true if the connector's reply path actually forwards the link
   * action to the source. Private Plot notes (no link type) always allow links.
   */
  supportsLinks?: boolean;
  /**
   * Whether a note/reply on this link type can carry an uploaded file that Plot
   * forwards to the source as an attachment. When false (the default), the
   * "Attach file" button is hidden for threads of this link type. Only set true
   * if the connector's reply path actually uploads file actions to the source.
   * Private Plot notes (no link type) always allow attachments.
   */
  supportsFileAttachments?: boolean;
  /**
   * Declares how sharing on threads of this link type is scoped:
   *
   * - `"thread"` (default): one roster shared across all notes in the
   *   thread. Native Plot threads, Slack DMs, calendar events.
   * - `"channel"`: visibility is the external channel's membership;
   *   the per-thread `contacts` array is ignored for sharing UI.
   *   Slack channels, Linear projects.
   * - `"message"`: each note carries its own recipient set via
   *   `note.access_contacts`; the thread roster is the union across
   *   all messages. Email.
   *
   * Omit to default to `"thread"`. When set to `"message"`, every
   * note this connector ingests must populate `access_contacts`
   * explicitly (never NULL).
   */
  sharingModel?: "thread" | "channel" | "message";
};

/**
 * Declares how a link type is composable from Plot via
 * `Connector.onCreateLink`. Attached to {@link LinkTypeConfig.compose}.
 */
export type ComposeConfig = {
  /**
   * Selects the destination model for the "Create new …" picker.
   *
   * - `"channels"` (default): one chip per enabled channel (e.g. a Linear
   *   team, a Slack channel). Existing behaviour for task-tracker / calendar
   *   connectors.
   * - `"contacts"`: one chip per connection (account); the user picks
   *   recipients from their contacts. The runtime pre-resolves the chosen
   *   Plot contacts to platform account IDs via the per-connection
   *   `contact_external_account` rows and delivers them as
   *   `CreateLinkDraft.recipients`. Contacts without a row for this specific
   *   connection are filtered out of the picker — used by closed-roster
   *   messaging platforms (Slack DM, Teams DM, Google Chat DM, LinkedIn DM).
   * - `"addresses"`: one chip per connection; the picker accepts any
   *   contact with an addressable identifier (e.g. an email) or a free-form
   *   typed address. The runtime fills `recipients` for contacts with a
   *   connection-scoped row and falls back to the contact's primary address
   *   (e.g. `contact.email`) when no row exists. Free-form addresses arrive
   *   via the thread's `inviteEmails`. Used by open address spaces like
   *   Gmail.
   */
  targets?: "channels" | "contacts" | "addresses";
  /**
   * Status to assign newly-created links. Should match an entry in the
   * parent linkType's `statuses[]`, OR a symbolic id that the connector's
   * `onCreateLink` resolves itself (e.g. Linear's `"unstarted"` category is
   * resolved per-team to a state UUID inside the connector — see
   * `connectors/linear/src/linear.ts`).
   */
  status: string;
  /**
   * Optional override for the picker chip / "Create new …" copy. Defaults
   * to the parent linkType's `label`. Use to disambiguate compose entries
   * when the parent label alone isn't specific enough (e.g. "Direct
   * messages" for a DM-mode compose on a chat connector).
   */
  label?: string;
};

/**
 * Declares one contact role for a connector's link type. See
 * `LinkTypeConfig.contactRoles`.
 */
export type ContactRoleConfig = {
  /** Stable machine id, e.g. "to" / "cc" / "bcc" / "required" / "optional". */
  id: string;
  /** Display label shown next to a contact chip, e.g. "To", "CC", "Required". */
  label: string;
  /** Exactly one role per linkType should be marked default. */
  default?: boolean;
  /**
   * Hidden roles are visible only to (a) the contact themselves and
   * (b) the user who added them. The API filters them out of every other
   * viewer's `thread.contacts` and `thread.contactMeta`. Use for BCC-style
   * semantics where other recipients must not see the hidden contact.
   */
  hidden?: boolean;
};

/**
 * Context passed to onChannelEnabled with plan-based sync hints.
 * Connectors can use these hints to limit initial sync scope.
 */
export type SyncContext = {
  /**
   * Earliest date to include in initial sync, based on the user's plan.
   *
   * Non-calendar connectors should use this as their date filter (timeMin,
   * created.gte, etc.) during initial sync. Calendar connectors should
   * ignore this for API queries (to avoid missing recurring events) — the
   * API layer filters non-recurring items automatically.
   *
   * Undefined when no limit applies.
   */
  syncHistoryMin?: Date;

  /**
   * True when this is a recovery dispatch after the connection's auth was
   * restored (the user re-authorized a previously-broken connection).
   *
   * The framework calls `onChannelEnabled` again for every channel that was
   * already enabled at the time of re-auth so the connector can recover from
   * the auth gap. Connectors should:
   *
   * 1. Drop any persisted incremental sync cursors / sync tokens so the
   *    next sync re-walks history (the cursor may be stale or invalid —
   *    Google Calendar invalidates syncTokens after ~7 days).
   * 2. Re-register webhooks (any prior subscription may have been
   *    invalidated during the auth outage).
   * 3. Treat this as a backfill that walks history but does NOT spam
   *    notifications — set `unread: false` and `archived: false` on
   *    items as you would during initial sync.
   *
   * Most connectors can take the same code path as a fresh
   * `onChannelEnabled` for `recovering: true` as long as that path
   * overwrites stored state rather than appending to it.
   */
  recovering?: boolean;
};

/**
 * Built-in tool for managing OAuth authentication and channel resources.
 *
 * The Integrations tool:
 * 1. Manages channel resources (calendars, projects, etc.) per actor
 * 2. Returns tokens for the user who enabled sync on a channel
 * 3. Supports per-actor auth via actAs() for write-back operations
 * 4. Provides saveLink/saveContacts for Connectors to save data directly
 *
 * Connectors declare their provider, scopes, and channel lifecycle methods as
 * class properties and methods. The Integrations tool reads these automatically.
 * Auth and channel management is handled in the twist edit modal in Flutter.
 *
 * @example
 * ```typescript
 * class CalendarConnector extends Connector<CalendarConnector> {
 *   readonly provider = AuthProvider.Google;
 *   readonly scopes = ["https://www.googleapis.com/auth/calendar"];
 *
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations),
 *     };
 *   }
 *
 *   async getChannels(auth: Authorization, token: AuthToken): Promise<Channel[]> {
 *     const calendars = await this.listCalendars(token);
 *     return calendars.map(c => ({ id: c.id, title: c.name }));
 *   }
 *
 *   async onChannelEnabled(channel: Channel) {
 *     // Start syncing
 *   }
 *
 *   async onChannelDisabled(channel: Channel) {
 *     // Stop syncing
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
   * @param channelId - The channel resource ID (e.g., calendar ID)
   * @returns Promise resolving to the access token or null
   */
  abstract get(channelId: string): Promise<AuthToken | null>;
  /**
   * Retrieves an access token for a channel resource.
   *
   * @param provider - The OAuth provider (deprecated, ignored for single-provider connectors)
   * @param channelId - The channel resource ID (e.g., calendar ID)
   * @returns Promise resolving to the access token or null
   * @deprecated Use get(channelId) instead. The provider is implicit from the connector.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract get(provider: AuthProvider, channelId: string): Promise<AuthToken | null>;

  /**
   * Saves a link with notes to the connector's focus.
   *
   * Creates a thread+link pair. The thread is a lightweight container;
   * the link holds the external entity data (source, meta, type, status, etc.).
   *
   * This method is available only to Connectors (not regular Twists).
   *
   * @param link - The link with notes to save
   * @returns Promise resolving to the saved thread's UUID, or null if the
   *   link was filtered out (e.g. older than the plan's sync history limit)
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract saveLink(link: NewLinkWithNotes): Promise<Uuid | null>;

  /**
   * Batch version of {@link saveLink} — saves many links in one call.
   *
   * Connectors syncing many items per page (e.g. calendar events, issues,
   * messages) should prefer this over looping `saveLink`. Each `saveLink`
   * crosses the runtime boundary and counts against the per-execution
   * request budget; `saveLinks` collapses N saves into a single crossing.
   *
   * Failures on individual links DO NOT abort the batch. A bad item lands
   * as `null` in its slot and the rest still save. This prevents one
   * malformed record from losing an entire page of sync progress.
   *
   * This method is available only to Connectors (not regular Twists).
   *
   * @param links - Array of links with notes to save
   * @returns Array of the same length and order as `links`. Each entry is
   *   the saved thread's UUID, or `null` if the link was filtered out
   *   (e.g. older than the plan's sync history limit) OR failed to save.
   *   The two null causes are not distinguished; the save failure is
   *   logged server-side.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract saveLinks(links: NewLinkWithNotes[]): Promise<(Uuid | null)[]>;

  /**
   * Upserts contacts into the connector's focus without requiring a Link.
   *
   * Use this for messaging connectors to bulk-sync workspace members so the
   * recipient picker can filter contacts by reachable platform account. Populate
   * `NewContact.source` to persist `contact_external_account` rows (the platform
   * identity used to address the contact). Returns one `Actor` per input, in order.
   *
   * @param contacts - Contacts to upsert, keyed by `source`/`key`
   * @returns Promise resolving to the saved actors, 1:1 with input order
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract saveContacts(contacts: NewContact[]): Promise<Actor[]>;

  /**
   * Archives links matching the given filter that were created by this connector.
   *
   * For each archived link's thread, if no other non-archived links remain,
   * the thread is also archived.
   *
   * @param filter - Filter criteria for which links to archive
   * @returns Promise that resolves when archiving is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract archiveLinks(filter: ArchiveLinkFilter): Promise<void>;

  /**
   * Sets or clears todo status on a thread owned by this connector.
   *
   * @param source - The link source URL identifying the thread
   * @param actorId - The user to set the todo for
   * @param todo - true to mark as todo, false to clear/complete
   * @param options - Additional options
   * @param options.date - The todo date (when todo=true). Defaults to today.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setThreadToDo(
    source: string,
    actorId: ActorId,
    todo: boolean,
    options?: { date?: Date | string }
  ): Promise<void>;

  /**
   * Signal that initial bulk-sync (or recovery sync) for a channel is fully
   * complete. The Flutter app uses this to clear the "syncing…" indicator
   * on the connection.
   *
   * The framework automatically marks a channel as syncing when it dispatches
   * `onChannelEnabled` (whether initial-enable, auto-enable from
   * `setChannels`, or recovery after re-auth). Connectors do NOT need to
   * call anything to start tracking — only to signal completion.
   *
   * Call this exactly once when the initial backfill has finished (no more
   * pages, all phases exhausted). Do NOT call it on every incremental sync.
   *
   * If `onChannelEnabled` throws an unhandled exception, the framework
   * automatically clears the syncing state — connectors don't need a
   * `try/catch` to clear state on failure.
   *
   * No-op when no auth/user mapping exists for the channel (e.g. key-based
   * connectors that don't have a per-user OAuth association).
   *
   * @param channelId - The channel resource ID whose initial sync just finished
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract channelSyncCompleted(channelId: string): Promise<void>;

  /**
   * Flag a connection as needing re-authentication so the Flutter app
   * surfaces a re-auth prompt on the next sync.
   *
   * Call this when a connector's API call returns a permanent auth-style
   * error that the runtime can't observe through token refresh — e.g.
   * Slack `invalid_auth` / `token_revoked` / `not_authed`, or a 401 on a
   * provider that doesn't refresh. The runtime already flags reauth
   * automatically when an OAuth refresh permanently fails or when the
   * stored token is missing on a get(); only call this for cases the
   * runtime can't see.
   *
   * Idempotent: safe to call repeatedly; existing reauth flags are not
   * overwritten. No-op when the channel has no `enabledBy` actor (e.g.
   * key-based connectors).
   *
   * @param channelId - The channel resource ID whose token is bad
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract markNeedsReauth(channelId: string): Promise<void>;

}

/**
 * Filter criteria for archiving links.
 * All fields are optional; only provided fields are used for matching.
 */
export type ArchiveLinkFilter = {
  /** Filter by channel ID */
  channelId?: string;
  /** Filter by link type (e.g., "issue", "pull_request") */
  type?: string;
  /** Filter by link status (e.g., "open", "closed") */
  status?: string;
  /** Filter by metadata fields (uses containment matching) */
  meta?: Record<string, JSONValue>;
};

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
  /** Todoist OAuth provider for Todoist task management */
  Todoist = "todoist",
  /** Airtable OAuth provider for Airtable bases */
  Airtable = "airtable",
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
