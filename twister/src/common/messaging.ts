import type { ActivityLink, NewActivityWithNotes } from "../index";

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
export interface MessageChannel {
  /** Unique identifier for the channel within the provider */
  id: string;
  /** Human-readable name of the channel (e.g., "Inbox", "#general", "My Team Thread") */
  name: string;
  /** Optional description or additional details about the channel */
  description: string | null;
  /** Whether this is the user's primary/default channel (e.g. email inbox) */
  primary: boolean;
}

/**
 * Configuration options for messaging synchronization.
 *
 * Controls the time range and other parameters for messaging sync operations.
 * Used to limit sync scope and optimize performance.
 */
export interface MessageSyncOptions {
  /** Earliest date to sync events from (inclusive) */
  timeMin?: Date;
}

/**
 * Base interface for email and chat integration tools.
 *
 * All synced messages/emails are converted to ActivityWithNotes objects.
 * Each email thread or chat conversation becomes an Activity with Notes for each message.
 */
export interface MessagingTool {
  /**
   * Initiates the authorization flow for the service.
   *
   * @param callback - Function receiving (auth, ...extraArgs) when auth completes
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise resolving to an ActivityLink to initiate the auth flow
   */
  requestAuth<TCallback extends (auth: MessagingAuth, ...args: any[]) => any>(
    callback: TCallback,
    ...extraArgs: TCallback extends (auth: any, ...rest: infer R) => any
      ? R
      : []
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
   * Email threads and chat conversations are converted to ActivityWithNotes objects.
   * Each object contains an Activity (with subject/title) and Notes array (one per message).
   * The Activity.id can be used as a stable conversation identifier.
   *
   * @param authToken - Authorization token for access
   * @param channelId - ID of the channel (e.g., channel, inbox) to sync
   * @param callback - Function receiving (thread, ...extraArgs) for each synced conversation
   * @param options - Optional configuration for limiting the sync scope (e.g., time range)
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TCallback extends (thread: NewActivityWithNotes, ...args: any[]) => any
  >(
    authToken: string,
    channelId: string,
    callback: TCallback,
    options?: MessageSyncOptions,
    ...extraArgs: TCallback extends (thread: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<void>;

  /**
   * Stops synchronizing messages from a specific channel.
   *
   * @param authToken - Authorization token for access
   * @param channelId - ID of the channel to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(authToken: string, channelId: string): Promise<void>;
}
