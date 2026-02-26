/**
 * Represents a channel from an external messaging service.
 *
 * Contains metadata about a specific channel that can be synced
 * with Plot. Different messaging providers may have additional
 * provider-specific properties.
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
 * Base interface for email and chat integration sources.
 *
 * All synced messages/emails are converted to ThreadWithNotes objects.
 * Each email thread or chat conversation becomes a Thread with Notes for each message.
 *
 * Sources save threads directly via `integrations.saveThread()` rather than
 * passing data through callbacks to a separate twist.
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Source declares providers and lifecycle callbacks in build()
 * 3. getChannels returns available messaging channels
 * 4. User enables channels in the modal -> onChannelEnabled fires
 * 5. Source fetches messages and saves them directly via integrations.saveThread()
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source (thread URL or ID) and Note.key (message ID) for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export type MessagingSource = {
  /**
   * Retrieves the list of conversation channels (inboxes, channels) accessible to the user.
   *
   * @param channelId - A channel ID to use for auth lookup
   * @returns Promise resolving to array of available conversation channels
   */
  getChannels(channelId: string): Promise<MessageChannel[]>;

  /**
   * Begins synchronizing messages from a specific channel.
   *
   * Auth is obtained automatically via integrations.get(provider, channelId).
   *
   * @param options - Sync configuration options
   * @param options.channelId - ID of the channel (e.g., channel, inbox) to sync
   * @param options.timeMin - Earliest date to sync events from (inclusive)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync(
    options: {
      channelId: string;
    } & MessageSyncOptions,
  ): Promise<void>;

  /**
   * Stops synchronizing messages from a specific channel.
   *
   * @param channelId - ID of the channel to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(channelId: string): Promise<void>;
};
