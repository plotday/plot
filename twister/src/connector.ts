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

  // ---- Optional metadata ----

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
   * Should set up webhooks and start initial sync.
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
   * @param note - The created note
   * @param thread - The thread the note belongs to (includes thread.meta with connector-specific data)
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteCreated(note: Note, thread: Thread): Promise<void> {
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
