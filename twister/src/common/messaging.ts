import type { ActivityLink, NewActivityWithNotes, Serializable } from "../index";

/**
 * Represents a successful messaging service authorization.
 *
 * Returned by messaging tools when authorization completes successfully.
 * The auth token is an opaque identifier that can be used for subsequent
 * messaging operations.
 */
export type MessagingAuth = {
  /** Opaque token for messaging operations */
  authToken: string;
};

/**
 * Represents a channel from an external messaging service.
 *
 * Contains metadata about a specific channel that can be synced
 * with Plot.
 */
export type MessageChannel = {
  /** Unique identifier for the channel within the provider */
  id: string;
  /** Human-readable name of the channel (e.g., "Inbox", "#general", "My Team Thread") */
  name: string;
  /** Optional description or additional details about the channel */
  description: string | null;
  /** Whether this is the user's primary/default channel (e.g. email inbox) */
  primary: boolean;
};

/**
 * Configuration options for messaging synchronization.
 *
 * Controls the time range and other parameters for messaging sync operations.
 * Used to limit sync scope and optimize performance.
 */
export type MessageSyncOptions = {
  /** Earliest date to sync events from (inclusive) */
  timeMin?: Date;
};

/**
 * Base interface for email and chat integration tools.
 *
 * All synced messages/emails are converted to ActivityWithNotes objects.
 * Each email thread or chat conversation becomes an Activity with Notes for each message.
 *
 * **Recommended Data Sync Strategy:**
 * Use Activity.source (thread URL or ID) and Note.key (message ID) for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export type MessagingTool = {
  /**
   * Initiates the authorization flow for the service.
   *
   * @param callback - Function receiving (auth, ...extraArgs) when auth completes
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise resolving to an ActivityLink to initiate the auth flow
   */
  requestAuth<
    TArgs extends Serializable[],
    TCallback extends (auth: MessagingAuth, ...args: TArgs) => any
  >(
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<ActivityLink>;

  /**
   * Retrieves the list of conversation channels (inboxes, channels) accessible to the user.
   *
   * @param authToken - Authorization token from successful auth flow
   * @returns Promise resolving to array of available conversation channels
   */
  getChannels(authToken: string): Promise<MessageChannel[]>;

  /**
   * Begins synchronizing messages from a specific channel.
   *
   * Email threads and chat conversations are converted to NewActivityWithNotes objects.
   *
   * **Recommended Implementation** (Strategy 2 - Upsert via Source/Key):
   * - Set Activity.source to the thread/conversation URL or stable ID (e.g., "slack:{channelId}:{threadTs}")
   * - Use Note.key for individual messages (e.g., "message-{messageId}")
   * - Each message becomes a separate note with unique key for upserts
   * - No manual ID tracking needed - Plot handles deduplication automatically
   * - Send NewActivityWithNotes for all threads (creates new or updates existing)
   * - Set activity.unread = false for initial sync, true for incremental updates
   *
   * **Alternative** (Strategy 3 - Advanced cases):
   * - Use Uuid.Generate() and store ID mappings when creating multiple activities per thread
   * - See SYNC_STRATEGIES.md for when this is appropriate
   *
   * @param options - Sync configuration options
   * @param options.authToken - Authorization token for access
   * @param options.channelId - ID of the channel (e.g., channel, inbox) to sync
   * @param options.timeMin - Earliest date to sync events from (inclusive)
   * @param callback - Function receiving (thread, ...extraArgs) for each synced conversation
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TArgs extends Serializable[],
    TCallback extends (thread: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      authToken: string;
      channelId: string;
    } & MessageSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void>;

  /**
   * Stops synchronizing messages from a specific channel.
   *
   * @param authToken - Authorization token for access
   * @param channelId - ID of the channel to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(authToken: string, channelId: string): Promise<void>;
};
