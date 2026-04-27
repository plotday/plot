import { type Actor, type ActorId, type Link, type NewLinkWithNotes, type Note, type Thread } from "./plot";
import type { ScheduleContactStatus } from "./schedule";
import {
  type AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  type LinkTypeConfig,
  type SyncContext,
} from "./tools/integrations";
import { Twist } from "./twist";

/**
 * Fields captured in Plot when a user initiates creation of a new external
 * item via a connector's `onCreateLink` hook.
 *
 * Thread-agnostic on purpose — connectors do not receive the Plot thread.
 * The platform attaches the returned `NewLinkWithNotes` to the originating
 * thread once `onCreateLink` resolves.
 */
/**
 * Result returned from {@link Connector.onNoteCreated} and
 * {@link Connector.onNoteUpdated} to report what the external system now
 * has stored for the note.
 *
 * The runtime hashes `externalContent` and stores it as the note's sync
 * baseline. On the next sync-in, if the incoming content hashes to the
 * same value, the runtime knows the external side hasn't changed and
 * preserves Plot's (possibly formatted) content. When the external side
 * is edited, the hash diverges and the runtime overwrites Plot's content
 * with the new external version.
 *
 * Omitting `externalContent` skips baseline tracking — the next sync-in
 * will overwrite Plot's content (previous behavior). Always provide it
 * when the write-back's return value reflects what the external system
 * actually stored (often lossy plain-text), so the round-trip does not
 * clobber the original Plot markdown.
 *
 * The hash covers only the content string — the runtime intentionally
 * does not include a content-type in the hash, so write-back and sync-in
 * do not have to agree on a content-type label for the same underlying
 * bytes. Return exactly the string your connector's sync-in path will
 * emit as `NewNote.content` for this note on the next re-ingest.
 *
 * For back-compat, `onNoteCreated` may also return a plain string, which
 * is treated as `{ key }` with no baseline.
 */
export type NoteWriteBackResult = {
  /**
   * External system identifier assigned to this note. Set as the note's
   * `key` for future upsert matching. Required when the runtime does not
   * already know the key (i.e., from `onNoteCreated`); ignored from
   * `onNoteUpdated` when the key was already established on create.
   */
  key?: string;
  /**
   * The content string as the external system now stores it, post-write.
   * For systems whose write-back returns a representation of what was
   * actually stored (e.g. Google Drive comment `content` after a create),
   * pass that verbatim. For systems that only accept plain text, this
   * will often be a lossy plain-text version of the Plot markdown — that
   * is exactly the point: storing the lossy form as baseline lets the
   * next sync-in recognize it and skip overwriting the richer Plot
   * version.
   *
   * Must exactly match the string your connector's sync-in path emits as
   * `NewNote.content` for this note on re-ingest.
   */
  externalContent?: string;
};

export type CreateLinkDraft = {
  /** The channel (account + resource) the new item belongs to. */
  channelId: string;
  /** Link type identifier, matches a `LinkTypeConfig.type`. */
  type: string;
  /** Status the user selected. Matches a `statuses[].status` for `type`. */
  status: string;
  /** Title of the originating Plot thread (post AI title generation). */
  title: string;
  /** Markdown content of the thread's first note, or null if none. */
  noteContent: string | null;
  /**
   * Contacts attached to the originating Plot thread, excluding the
   * creating user. Use these as recipients (email, chat DM members, etc.)
   * when the external item is a message or invite. An empty list means
   * the user did not add anyone to the thread.
   */
  contacts: Actor[];
};

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
   * The UI will show channel config inline instead of a channel list.
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
   * The framework dispatches this in three cases:
   *  1. **Initial enable** — user toggled the channel on for the first time.
   *  2. **Auto-enable** — `setChannels` discovered a new channel on a
   *     connection with `auto_enable_new_channels` set.
   *  3. **Recovery after re-auth** — the user re-authorized a previously-
   *     broken connection. The framework calls `onChannelEnabled` for every
   *     channel that was already enabled at the time of re-auth, with
   *     `context.recovering = true`. See {@link SyncContext.recovering}.
   *
   * Implementations should be **idempotent and overwrite stored state**:
   * the same channel may receive multiple `onChannelEnabled` calls across
   * its lifetime. Use unconditional `this.set()` writes rather than
   * coalesce/skip-if-present logic so a recovery dispatch wipes stale
   * cursors and state from the prior session.
   *
   * **Sync state tracking is automatic.** The framework stamps the
   * connection as "syncing" when it dispatches this method and clears
   * that state when:
   *  - the connector calls `tools.integrations.channelSyncCompleted(id)`
   *    once the initial backfill is done, OR
   *  - this method throws an unhandled exception (auto-cleared so the UI
   *    doesn't get stuck in "syncing" forever).
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
   * async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
   *   // Recovery: drop stale cursors so the next sync re-walks history.
   *   if (context?.recovering) {
   *     await this.clear(`last_sync_token_${channel.id}`);
   *   }
   *
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
   * @param context - Optional sync context (plan-based hints, recovery flag)
   */
  abstract onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void>;

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
   * Called when a user creates a thread in Plot that should create a new
   * item in this connector's external system.
   *
   * A connector opts in to Plot-initiated creation by declaring a status
   * with `createDefault: true` on the relevant `LinkTypeConfig`. When a
   * user picks "Create new <type>" from the Add link modal and the thread
   * is synced, the runtime calls this method with the draft fields.
   *
   * Implementations should create the item in the external service and
   * return a `NewLinkWithNotes` describing the created item. The platform
   * attaches the returned link to the originating thread — do not call
   * `integrations.saveLink` yourself.
   *
   * Returning `null` aborts creation silently (the thread is still saved
   * without a link).
   *
   * @param draft - The fields captured in Plot for the new item.
   * @returns The link to attach, or null to abort creation.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
    return Promise.resolve(null);
  }

  /**
   * Called when a note is created on a thread owned by this connector.
   * Override to write back comments to the external service
   * (e.g., adding a comment to a Linear issue).
   *
   * Returning a string or {@link NoteWriteBackResult} links the Plot note
   * to its external counterpart. A plain string sets the note's `key`.
   * A `NoteWriteBackResult` additionally sets a sync baseline (via
   * `externalContent`) so the next sync-in can recognize the round-tripped
   * content and preserve Plot's formatted version. See
   * {@link NoteWriteBackResult} for details.
   *
   * @param note - The created note
   * @param thread - The thread the note belongs to (includes thread.meta with connector-specific data)
   * @returns Optional note key or NoteWriteBackResult for external dedup + baseline tracking
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteCreated(note: Note, thread: Thread): Promise<string | NoteWriteBackResult | void> {
    return Promise.resolve();
  }

  /**
   * Called when a note on a thread owned by this connector is updated.
   * Override to write back changes to the external service
   * (e.g., syncing reaction tags as emoji reactions, or editing a comment
   * whose content changed in Plot).
   *
   * Return a {@link NoteWriteBackResult} with `externalContent` to update
   * the sync baseline after a successful write-back, so the next sync-in
   * recognizes the external version as already-seen and preserves Plot's
   * content.
   *
   * @param note - The updated note (includes current tags)
   * @param thread - The thread the note belongs to (includes thread.meta with connector-specific data)
   * @returns Optional NoteWriteBackResult for baseline tracking
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
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
   * Connectors receive the authorization in addition to the activating actor.
   * When this runs, `this.userId` is already populated with the installing
   * user's ID.
   *
   * Default implementation does nothing. Override for custom setup.
   *
   * @param context - The activation context
   * @param context.auth - The completed OAuth authorization
   * @param context.actor - The actor who activated the connector
   */
  // @ts-ignore - Connector.activate() has a Connector-specific context type.
  activate(context: { auth?: Authorization; actor?: Actor }): Promise<void> {
    return Promise.resolve();
  }
}

/** @deprecated Use `Connector` instead. */
export { Connector as Source };
