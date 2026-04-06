import { type Actor, type ActorId, type Link, type Note, type Thread } from "./plot";
import type { ScheduleContactStatus } from "./schedule";
import {
  type AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  type LinkTypeConfig,
} from "./tools/integrations";
import { Twist } from "./twist";

/**
 * Base class for connectors — twists that sync data from external services.
 *
 * Connectors declare a single OAuth provider and scopes, and implement channel
 * lifecycle methods for discovering and syncing external resources. They save
 * data directly via `integrations.saveLink()` instead of using the Plot tool.
 *
 * @example
 * ```typescript
 * class LinearConnector extends Connector<LinearConnector> {
 *   readonly provider = AuthProvider.Linear;
 *   readonly scopes = ["read", "write"];
 *   readonly linkTypes = [{
 *     type: "issue",
 *     label: "Issue",
 *     statuses: [
 *       { status: "open", label: "Open" },
 *       { status: "done", label: "Done" },
 *     ],
 *   }];
 *
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations),
 *     };
 *   }
 *
 *   async getChannels(auth: Authorization, token: AuthToken): Promise<Channel[]> {
 *     const teams = await this.listTeams(token);
 *     return teams.map(t => ({ id: t.id, title: t.name }));
 *   }
 *
 *   async onChannelEnabled(channel: Channel) {
 *     const issues = await this.fetchIssues(channel.id);
 *     for (const issue of issues) {
 *       await this.tools.integrations.saveLink(issue);
 *     }
 *   }
 *
 *   async onChannelDisabled(channel: Channel) {
 *     // Clean up webhooks, sync state, etc.
 *   }
 * }
 * ```
 */
export abstract class Connector<TSelf> extends Twist<TSelf> {
  /**
   * Static marker to identify Connector subclasses without instanceof checks
   * across worker boundaries.
   */
  static readonly isConnector = true;

  // ---- Identity (abstract — every connector must declare) ----

  /** The OAuth provider this connector authenticates with. */
  readonly provider?: AuthProvider;

  /** OAuth scopes to request for this connector. */
  readonly scopes?: string[];

  // ---- Auth model ----

  /**
   * When true, one credential is shared across all users in the workspace,
   * entered once by the installer. When false (default), each user provides
   * their own credential.
   *
   * Applies to both OAuth and key-based connectors:
   * - Shared OAuth: e.g. Slack bot token (workspace-level)
   * - Shared key: e.g. Attio workspace API key
   * - Individual OAuth: e.g. Google Calendar (per-user)
   * - Individual key: e.g. Fellow (per-user API key)
   */
  readonly shared?: boolean;

  /**
   * The Options field name that contains the authentication key (e.g. "apiKey").
   * Must reference a `secure: true` field in the Options schema.
   *
   * When set, this connector uses key-based auth instead of OAuth.
   * For individual connectors (`shared` is false), this field is stored
   * per-user rather than in shared config.
   */
  readonly keyOption?: string;

  // ---- Optional metadata ----

  /**
   * When true, this connector has a single implicit channel.
   * `getChannels()` must return exactly one Channel.
   * The UI will show channel config (priority, create threads) inline
   * instead of a channel list.
   */
  readonly singleChannel?: boolean;

  /**
   * Registry of link types this connector creates (e.g., issue, event, message).
   * Used for display in the UI (icons, labels, statuses).
   */
  readonly linkTypes?: LinkTypeConfig[];

  /**
   * When true, this connector is mentioned by default on replies to threads it created.
   * When false (default), this connector cannot be mentioned at all.
   *
   * Set this to true for connectors with bidirectional sync (e.g., issue trackers,
   * messaging) where user replies should be written back to the external service.
   */
  static readonly handleReplies?: boolean;

  // ---- Account identity (abstract — every connector must implement) ----

  /**
   * Returns a human-readable name for the connected account.
   * Shown in the connections list and edit modal to identify this connection.
   *
   * For OAuth connectors, this is typically the workspace or organization name
   * (e.g., "Acme Corp" for a Linear workspace). For API key connectors, this
   * could be the workspace name from the external service.
   *
   * Override this in your connector to return a meaningful account name.
   *
   * @param auth - The authorization (null for no-provider connectors)
   * @param token - The access token (null for no-provider connectors)
   * @returns Promise resolving to the account display name
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getAccountName(
    auth: Authorization | null,
    token: AuthToken | null
  ): Promise<string | null> {
    return Promise.resolve(null);
  }

  // ---- Channel lifecycle (abstract — every connector must implement) ----

  /**
   * Returns available channels for the authorized actor.
   * Called after OAuth is complete, during the setup/edit modal.
   *
   * @param auth - The completed authorization with provider and actor info
   * @param token - The access token for making API calls
   * @returns Promise resolving to available channels for the user to select
   */
  abstract getChannels(
    auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]>;

  /**
   * Called when a channel resource is enabled for syncing.
   *
   * **IMPORTANT: This method runs inline in the HTTP request handler.**
   * Any long-running work (webhook setup, API calls, sync) MUST be queued
   * as a separate task via `this.runTask()`, not executed inline. Blocking
   * here causes the client to spin waiting for the response.
   *
   * Only lightweight operations should appear directly in this method:
   * `this.set()`, `this.get()`, `this.callback()`, and `this.runTask()`.
   *
   * @example
   * ```typescript
   * async onChannelEnabled(channel: Channel): Promise<void> {
   *   await this.set(`sync_enabled_${channel.id}`, true);
   *   await this.set(`sync_state_${channel.id}`, { channelId: channel.id });
   *
   *   // Queue sync as a task — do NOT use this.run() or call sync methods inline
   *   const syncCallback = await this.callback(this.syncBatch, 1, "full", channel.id, true);
   *   await this.runTask(syncCallback);
   *
   *   // Queue webhook setup as a task — do NOT call setupWebhook() inline
   *   const webhookCallback = await this.callback(this.setupWebhook, channel.id);
   *   await this.runTask(webhookCallback);
   * }
   * ```
   *
   * @param channel - The channel that was enabled
   */
  abstract onChannelEnabled(channel: Channel): Promise<void>;

  /**
   * Called when a channel resource is disabled.
   * Should stop sync, clean up webhooks, and remove state.
   *
   * @param channel - The channel that was disabled
   */
  abstract onChannelDisabled(channel: Channel): Promise<void>;

  // ---- Write-back hooks (optional, default no-ops) ----

  /**
   * Called when a link created by this connector is updated by the user.
   * Override to write back changes to the external service
   * (e.g., changing issue status in Linear when marked done in Plot).
   *
   * @param link - The updated link
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onLinkUpdated(link: Link): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a note is created on a thread owned by this connector.
   * Override to write back comments to the external service
   * (e.g., adding a comment to a Linear issue).
   *
   * Returning a string sets the note's `key` for future upsert matching,
   * linking the Plot note to its external counterpart so that subsequent
   * syncs (reactions, edits) update the existing note instead of creating duplicates.
   *
   * @param note - The created note
   * @param thread - The thread the note belongs to (includes thread.meta with connector-specific data)
   * @returns Optional note key for external deduplication
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteCreated(note: Note, thread: Thread): Promise<string | void> {
    return Promise.resolve();
  }

  /**
   * Called when a note on a thread owned by this connector is updated.
   * Override to write back changes to the external service
   * (e.g., syncing reaction tags as emoji reactions).
   *
   * @param note - The updated note (includes current tags)
   * @param thread - The thread the note belongs to (includes thread.meta with connector-specific data)
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteUpdated(note: Note, thread: Thread): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a user reads or unreads a thread owned by this connector.
   * Override to write back read status to the external service
   * (e.g., marking an email as read in Gmail).
   *
   * @param thread - The thread that was read/unread (includes thread.meta with connector-specific data)
   * @param actor - The user who performed the action
   * @param unread - false when marked as read, true when marked as unread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onThreadRead(thread: Thread, actor: Actor, unread: boolean): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a user marks or unmarks a thread as todo.
   * Override to sync todo status to the external service
   * (e.g., starring an email in Gmail when marked as todo).
   *
   * @param thread - The thread (includes thread.meta with connector-specific data)
   * @param actor - The user who changed the todo status
   * @param todo - true when marked as todo, false when done or removed
   * @param options - Additional context
   * @param options.date - The todo date (when todo=true)
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onThreadToDo(thread: Thread, actor: Actor, todo: boolean, options: { date?: Date }): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a schedule contact's RSVP status changes on a thread owned by this connector.
   * Override to sync RSVP changes back to the external calendar.
   *
   * @param thread - The thread (includes thread.meta with connector-specific data)
   * @param scheduleId - The schedule ID
   * @param contactId - The contact whose status changed
   * @param status - The new RSVP status ('attend', 'skip', or null)
   * @param actor - The user who changed the status
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onScheduleContactUpdated(thread: Thread, scheduleId: string, contactId: ActorId, status: ScheduleContactStatus | null, actor: Actor): Promise<void> {
    return Promise.resolve();
  }

  // ---- Activation ----

  /**
   * Called when the connector is activated after OAuth is complete.
   *
   * Unlike Twist.activate() which receives a priority, Connector.activate()
   * receives the authorization and actor since connectors are not installed
   * in priorities.
   *
   * Default implementation does nothing. Override for custom setup.
   *
   * @param context - The activation context
   * @param context.auth - The completed OAuth authorization
   * @param context.actor - The actor who activated the connector
   */
  // @ts-ignore - Connector.activate() intentionally has a different signature than Twist.activate()
  activate(context: { auth?: Authorization; actor?: Actor }): Promise<void> {
    return Promise.resolve();
  }
}

/** @deprecated Use `Connector` instead. */
export { Connector as Source };
