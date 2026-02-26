import type {
  ThreadMeta,
} from "../index";

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
 * Base interface for document service integration sources.
 *
 * All synced documents are converted to ThreadWithNotes objects.
 * Each document becomes a Thread with Notes for the description and comments.
 *
 * Sources save threads directly via `integrations.saveThread()` rather than
 * passing data through callbacks to a separate twist.
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Source declares providers and lifecycle callbacks in build()
 * 3. getChannels returns available folders
 * 4. User enables folders in the modal -> onChannelEnabled fires
 * 5. Source fetches documents and saves them directly via integrations.saveThread()
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source and Note.key for automatic upserts.
 *
 * - Set `Thread.source` to `"{provider}:file:{fileId}"` (e.g., `"google-drive:file:abc123"`)
 * - Use `Note.key` for document details:
 *   - key: `"summary"` for the document description or metadata summary
 *   - key: `"comment-{commentId}"` for individual comments (unique per comment)
 *   - key: `"reply-{commentId}-{replyId}"` for comment replies
 * - No manual ID tracking needed - Plot handles deduplication automatically
 * - Send NewThreadWithNotes for all documents (creates new or updates existing)
 * - Set `thread.unread = false` for initial sync, omit for incremental updates
 */
export type DocumentSource = {
  /**
   * Retrieves the list of folders accessible to the user.
   *
   * @param folderId - A folder ID to use for auth lookup
   * @returns Promise resolving to array of available folders
   */
  getFolders(folderId: string): Promise<DocumentFolder[]>;

  /**
   * Begins synchronizing documents from a specific folder.
   *
   * Documents are converted to NewThreadWithNotes objects.
   *
   * Auth is obtained automatically via integrations.get(provider, folderId).
   *
   * @param options - Sync configuration options
   * @param options.folderId - ID of the folder to sync
   * @param options.timeMin - Earliest date to sync documents from (inclusive)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync(
    options: {
      folderId: string;
    } & DocumentSyncOptions,
  ): Promise<void>;

  /**
   * Stops synchronizing documents from a specific folder.
   *
   * @param folderId - ID of the folder to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(folderId: string): Promise<void>;

  /**
   * Adds a comment to a document.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync notes added to threads back as comments on the external document.
   *
   * Auth is obtained automatically. The tool should extract its own ID
   * from meta (e.g., fileId).
   *
   * @param meta - Thread metadata containing the tool's document identifier
   * @param body - The comment text content
   * @param noteId - Optional Plot note ID for deduplication
   * @returns The external comment key (e.g. "comment-123") for dedup, or void
   */
  addDocumentComment?(
    meta: ThreadMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void>;

  /**
   * Adds a reply to an existing comment thread on a document.
   *
   * Auth is obtained automatically. The tool should extract its own ID
   * from meta (e.g., fileId).
   *
   * @param meta - Thread metadata containing the tool's document identifier
   * @param commentId - The external comment ID to reply to
   * @param body - The reply text content
   * @param noteId - Optional Plot note ID for deduplication
   * @returns The external reply key (e.g. "reply-123-456") for dedup, or void
   */
  addDocumentReply?(
    meta: ThreadMeta,
    commentId: string,
    body: string,
    noteId?: string,
  ): Promise<string | void>;
};
