import type {
  ActivityLink,
  ActivityMeta,
  NewActivityWithNotes,
  Serializable,
} from "../index";

/**
 * Represents a successful document service authorization.
 *
 * Returned by document tools when authorization completes successfully.
 * The auth token is an opaque identifier that can be used for subsequent
 * document operations.
 */
export type DocumentAuth = {
  /** Opaque token for document operations */
  authToken: string;
};

/**
 * Represents a folder from an external document service.
 *
 * Contains metadata about a specific folder that can be synced
 * with Plot. Different document providers may have additional
 * provider-specific properties.
 */
export type DocumentFolder = {
  /** Unique identifier for the folder within the provider */
  id: string;
  /** Human-readable name of the folder */
  name: string;
  /** Optional description or additional details about the folder */
  description: string | null;
  /** Whether this is a root-level folder (e.g., "My Drive" in Google Drive) */
  root: boolean;
};

/**
 * Configuration options for document synchronization.
 *
 * Controls the time range and other parameters for document sync operations.
 * Used to limit sync scope and optimize performance.
 */
export type DocumentSyncOptions = {
  /** Earliest date to sync documents from (inclusive) */
  timeMin?: Date;
};

/**
 * Base interface for document service integration tools.
 *
 * All synced documents are converted to ActivityWithNotes objects.
 * Each document becomes an Activity with Notes for the description and comments.
 *
 * **Recommended Data Sync Strategy:**
 * Use Activity.source and Note.key for automatic upserts.
 *
 * - Set `Activity.source` to `"{provider}:file:{fileId}"` (e.g., `"google-drive:file:abc123"`)
 * - Use `Note.key` for document details:
 *   - key: `"summary"` for the document description or metadata summary
 *   - key: `"comment-{commentId}"` for individual comments (unique per comment)
 *   - key: `"reply-{commentId}-{replyId}"` for comment replies
 * - No manual ID tracking needed - Plot handles deduplication automatically
 * - Send NewActivityWithNotes for all documents (creates new or updates existing)
 * - Set `activity.unread = false` for initial sync, omit for incremental updates
 */
export type DocumentTool = {
  /**
   * Initiates the authorization flow for the document service.
   *
   * @param callback - Function receiving (auth, ...extraArgs) when auth completes
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise resolving to an ActivityLink to initiate the auth flow
   */
  requestAuth<
    TArgs extends Serializable[],
    TCallback extends (auth: DocumentAuth, ...args: TArgs) => any
  >(
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<ActivityLink>;

  /**
   * Retrieves the list of folders accessible to the user.
   *
   * @param authToken - Authorization token from successful auth flow
   * @returns Promise resolving to array of available folders
   */
  getFolders(authToken: string): Promise<DocumentFolder[]>;

  /**
   * Begins synchronizing documents from a specific folder.
   *
   * Documents are converted to NewActivityWithNotes objects.
   *
   * **Recommended Implementation:**
   * - Set Activity.source to `"{provider}:file:{fileId}"`
   * - Use Note.key for document details:
   *   - key: "summary" for description (upserts on changes)
   *   - key: "comment-{commentId}" for individual comments (unique per comment)
   *   - key: "reply-{commentId}-{replyId}" for comment replies
   * - Send NewActivityWithNotes for all documents (creates new or updates existing)
   * - Set activity.unread = false for initial sync, omit for incremental updates
   *
   * @param options - Sync configuration options
   * @param options.authToken - Authorization token for access
   * @param options.folderId - ID of the folder to sync
   * @param options.timeMin - Earliest date to sync documents from (inclusive)
   * @param callback - Function receiving (activity, ...extraArgs) for each synced document
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TArgs extends Serializable[],
    TCallback extends (activity: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      authToken: string;
      folderId: string;
    } & DocumentSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void>;

  /**
   * Stops synchronizing documents from a specific folder.
   *
   * @param authToken - Authorization token for access
   * @param folderId - ID of the folder to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(authToken: string, folderId: string): Promise<void>;

  /**
   * Adds a comment to a document.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync notes added to activities back as comments on the external document.
   *
   * The tool should extract its own ID from meta (e.g., fileId).
   *
   * @param authToken - Authorization token for access
   * @param meta - Activity metadata containing the tool's document identifier
   * @param body - The comment text content
   * @param noteId - Optional Plot note ID for deduplication
   * @returns The external comment key (e.g. "comment-123") for dedup, or void
   */
  addDocumentComment?(
    authToken: string,
    meta: ActivityMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void>;

  /**
   * Adds a reply to an existing comment thread on a document.
   *
   * @param authToken - Authorization token for access
   * @param meta - Activity metadata containing the tool's document identifier
   * @param commentId - The external comment ID to reply to
   * @param body - The reply text content
   * @param noteId - Optional Plot note ID for deduplication
   * @returns The external reply key (e.g. "reply-123-456") for dedup, or void
   */
  addDocumentReply?(
    authToken: string,
    meta: ActivityMeta,
    commentId: string,
    body: string,
    noteId?: string,
  ): Promise<string | void>;
};
