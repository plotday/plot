import type { NewThreadWithNotes, Serializable } from "../index";

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
 * Base interface for email and chat integration tools.
 *
 * All synced messages/emails are converted to ThreadWithNotes objects.
 * Each email thread or chat conversation becomes a Thread with Notes for each message.
 *
 * **Architecture: Tools Build, Twists Save**
 *
 * Messaging tools follow Plot's core architectural principle:
 * - **Tools**: Fetch external data and transform it into Plot format (NewThread objects)
 * - **Twists**: Receive the data and decide what to do with it (create, update, filter, etc.)
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Tool declares providers and lifecycle callbacks in build()
 * 3. onAuthorized lists available channels and calls setSyncables()
 * 4. User enables channels in the modal → onSyncEnabled fires
 * 5. **Tool builds NewThread objects** and passes them to the twist via callback
 * 6. **Twist decides** whether to save using createThread/updateThread
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source (thread URL or ID) and Note.key (message ID) for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export type MessagingTool = {
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
   * @param callback - Function receiving (thread, ...extraArgs) for each synced conversation
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TArgs extends Serializable[],
    TCallback extends (thread: NewThreadWithNotes, ...args: TArgs) => any
  >(
    options: {
      channelId: string;
    } & MessageSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void>;

  /**
   * Stops synchronizing messages from a specific channel.
   *
   * @param channelId - ID of the channel to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(channelId: string): Promise<void>;
};
