import type {
  Thread,
  ThreadMeta,
} from "../index";

/**
 * Represents a project from an external project management service.
 *
 * Contains metadata about a specific project/board/workspace that can be synced
 * with Plot. Different project providers may have additional
 * provider-specific properties.
 */
export type Project = {
  /** Unique identifier for the project within the provider */
  id: string;
  /** Human-readable name of the project (e.g., "Q1 Roadmap", "Engineering") */
  name: string;
  /** Optional description or additional details about the project */
  description: string | null;
  /** Optional project key/abbreviation (e.g., "PROJ" in Jira, "ENG" in Linear) */
  key: string | null;
};

/**
 * Configuration options for project synchronization.
 *
 * Controls the time range and other parameters for project sync operations.
 * Used to limit sync scope and optimize performance.
 */
export type ProjectSyncOptions = {
  /** Earliest date to sync issues from (inclusive) */
  timeMin?: Date;
};

/**
 * Base interface for project management integration sources.
 *
 * All synced issues/tasks are converted to ThreadWithNotes objects.
 * Each issue becomes a Thread with Notes for the description and comments.
 *
 * Sources save threads directly via `integrations.saveThread()` rather than
 * passing data through callbacks to a separate twist.
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Source declares providers and lifecycle callbacks in build()
 * 3. getChannels returns available projects
 * 4. User enables projects in the modal -> onChannelEnabled fires
 * 5. Source fetches issues and saves them directly via integrations.saveThread()
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source (issue URL) and Note.key for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export type ProjectSource = {
  /**
   * Retrieves the list of projects accessible to the user.
   *
   * @param projectId - A project ID to use for auth lookup
   * @returns Promise resolving to array of available projects
   */
  getProjects(projectId: string): Promise<Project[]>;

  /**
   * Begins synchronizing issues from a specific project.
   *
   * Auth is obtained automatically via integrations.get(provider, projectId).
   *
   * @param options - Sync configuration options
   * @param options.projectId - ID of the project to sync
   * @param options.timeMin - Earliest date to sync issues from (inclusive)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync(
    options: {
      projectId: string;
    } & ProjectSyncOptions,
  ): Promise<void>;

  /**
   * Stops synchronizing issues from a specific project.
   *
   * @param projectId - ID of the project to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(projectId: string): Promise<void>;

  /**
   * Updates an issue/task with new values.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync thread updates back to the external service.
   *
   * Auth is obtained automatically via integrations.get(provider, projectId)
   * using the projectId from thread.meta.
   *
   * @param thread - The updated thread
   * @returns Promise that resolves when the update is synced
   */
  updateIssue?(thread: Thread): Promise<void>;

  /**
   * Adds a comment to an issue/task.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync notes added to threads back as comments on the external service.
   *
   * Auth is obtained automatically. The tool should extract its own ID
   * from meta (e.g., linearId, taskGid, issueKey).
   *
   * @param meta - Thread metadata containing the tool's issue/task identifier
   * @param body - The comment text content
   * @param noteId - Optional Plot note ID, used by tools that support comment metadata (e.g. Jira)
   * @returns The external comment key (e.g. "comment-123") for dedup, or void
   */
  addIssueComment?(
    meta: ThreadMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void>;
};

/** @deprecated Use ProjectSource instead */
export type ProjectTool = ProjectSource;
