import type {
  Thread,
  ThreadMeta,
} from "../index";

/**
 * Represents a repository from an external source control service.
 *
 * Contains metadata about a specific repository that can be synced
 * with Plot. Different source control providers may have additional
 * provider-specific properties.
 */
export type Repository = {
  /** Unique identifier for the repository within the provider */
  id: string;
  /** Human-readable name of the repository (e.g., "my-app") */
  name: string;
  /** Optional description or additional details about the repository */
  description: string | null;
  /** URL to view the repository in the browser */
  url: string | null;
  /** Owner of the repository (user or organization name) */
  owner: string | null;
  /** Default branch name (e.g., "main", "master") */
  defaultBranch: string | null;
  /** Whether the repository is private */
  private: boolean;
};

/**
 * Configuration options for source control synchronization.
 *
 * Controls the time range and other parameters for source control sync operations.
 * Used to limit sync scope and optimize performance.
 */
export type SourceControlSyncOptions = {
  /** Earliest date to sync pull requests from (inclusive) */
  timeMin?: Date;
};

/**
 * Base interface for source control integration sources.
 *
 * All synced pull requests are converted to ThreadWithNotes objects.
 * Each PR becomes a Thread with Notes for the description, comments,
 * and review summaries.
 *
 * Sources save threads directly via `integrations.saveThread()` rather than
 * passing data through callbacks to a separate twist.
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Source declares providers and lifecycle callbacks in build()
 * 3. getChannels returns available repositories
 * 4. User enables repositories in the modal -> onChannelEnabled fires
 * 5. Source fetches PRs and saves them directly via integrations.saveThread()
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source (PR URL) and Note.key for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export type SourceControlSource = {
  /**
   * Retrieves the list of repositories accessible to the user.
   *
   * @param repositoryId - A repository ID to use for auth lookup
   * @returns Promise resolving to array of available repositories
   */
  getRepositories(repositoryId: string): Promise<Repository[]>;

  /**
   * Begins synchronizing pull requests from a specific repository.
   *
   * Auth is obtained automatically via integrations.get(provider, repositoryId).
   *
   * @param options - Sync configuration options
   * @param options.repositoryId - ID of the repository to sync (owner/repo format)
   * @param options.timeMin - Earliest date to sync PRs from (inclusive)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync(
    options: {
      repositoryId: string;
    } & SourceControlSyncOptions,
  ): Promise<void>;

  /**
   * Stops synchronizing pull requests from a specific repository.
   *
   * @param repositoryId - ID of the repository to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(repositoryId: string): Promise<void>;

  /**
   * Adds a general comment to a pull request.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync notes added to threads back as comments on the external service.
   *
   * Auth is obtained automatically. The tool should extract its own ID
   * from meta (e.g., prNumber, owner, repo).
   *
   * @param meta - Thread metadata containing the tool's PR identifier
   * @param body - The comment text content
   * @param noteId - Optional Plot note ID for dedup
   * @returns The external comment key (e.g. "comment-123") for dedup, or void
   */
  addPRComment?(
    meta: ThreadMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void>;

  /**
   * Updates a pull request's review status (approve, request changes).
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync thread status changes back to the external service.
   *
   * @param thread - The updated thread with review status
   * @returns Promise that resolves when the update is synced
   */
  updatePRStatus?(thread: Thread): Promise<void>;

  /**
   * Closes a pull request without merging.
   *
   * Optional method for bidirectional sync.
   *
   * @param meta - Thread metadata containing the tool's PR identifier
   * @returns Promise that resolves when the PR is closed
   */
  closePR?(meta: ThreadMeta): Promise<void>;
};
