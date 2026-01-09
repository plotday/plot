import type {
  ActivityLink,
  ActivityUpdate,
  NewActivityWithNotes,
  SyncUpdate,
} from "../index";

/**
 * Represents a successful project management service authorization.
 *
 * Returned by project management tools when authorization completes successfully.
 * The auth token is an opaque identifier that can be used for subsequent
 * project operations.
 */
export type ProjectAuth = {
  /** Opaque token for project management operations */
  authToken: string;
};

/**
 * Represents a project from an external project management service.
 *
 * Contains metadata about a specific project/board/workspace that can be synced
 * with Plot.
 */
export interface Project {
  /** Unique identifier for the project within the provider */
  id: string;
  /** Human-readable name of the project (e.g., "Q1 Roadmap", "Engineering") */
  name: string;
  /** Optional description or additional details about the project */
  description: string | null;
  /** Optional project key/abbreviation (e.g., "PROJ" in Jira, "ENG" in Linear) */
  key: string | null;
}

/**
 * Configuration options for project synchronization.
 *
 * Controls the time range and other parameters for project sync operations.
 * Used to limit sync scope and optimize performance.
 */
export interface ProjectSyncOptions {
  /** Earliest date to sync issues from (inclusive) */
  timeMin?: Date;
}

/**
 * Base interface for project management integration tools.
 *
 * All synced issues/tasks are converted to ActivityWithNotes objects.
 * Each issue becomes an Activity with Notes for the description and comments.
 *
 * **Recommended Data Sync Strategy:**
 * Use Activity.source (issue URL) and Note.key for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export interface ProjectTool {
  /**
   * Initiates the authorization flow for the service.
   *
   * @param callback - Function receiving (auth, ...extraArgs) when auth completes
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise resolving to an ActivityLink to initiate the auth flow
   */
  requestAuth<TCallback extends (auth: ProjectAuth, ...args: any[]) => any>(
    callback: TCallback,
    ...extraArgs: TCallback extends (auth: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<ActivityLink>;

  /**
   * Retrieves the list of projects accessible to the user.
   *
   * @param authToken - Authorization token from successful auth flow
   * @returns Promise resolving to array of available projects
   */
  getProjects(authToken: string): Promise<Project[]>;

  /**
   * Begins synchronizing issues from a specific project.
   *
   * Issues and tasks are converted to SyncUpdate objects, which can be either
   * new items or updates to existing items.
   *
   * **Recommended Implementation** (Strategy 2 - Upsert via Source/Key):
   * - Set Activity.source to the issue's canonical URL (e.g., Linear issue URL, Jira issue URL)
   * - Use Note.key for issue details:
   *   - key: "description" for issue description (upserts on changes)
   *   - key: "metadata" for status, priority, assignee, etc.
   *   - key: "comment-{commentId}" for individual comments (unique per comment)
   * - No manual ID tracking needed - Plot handles deduplication automatically
   * - Send NewActivityWithNotes for all issues (creates new or updates existing)
   * - Set activity.unread = false for initial sync, true for incremental updates
   *
   * **Alternative** (Strategy 3 - Advanced cases):
   * - Use Uuid.Generate() and store ID mappings when creating multiple activities per issue
   * - See SYNC_STRATEGIES.md for when this is appropriate
   *
   * @param authToken - Authorization token for access
   * @param projectId - ID of the project to sync
   * @param callback - Function receiving (syncUpdate, ...extraArgs) for each synced issue
   * @param options - Optional configuration for limiting the sync scope (e.g., time range)
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TCallback extends (
      syncUpdate: SyncUpdate,
      ...args: any[]
    ) => any
  >(
    authToken: string,
    projectId: string,
    callback: TCallback,
    options?: ProjectSyncOptions,
    ...extraArgs: TCallback extends (
      syncUpdate: any,
      ...rest: infer R
    ) => any
      ? R
      : []
  ): Promise<void>;

  /**
   * Stops synchronizing issues from a specific project.
   *
   * @param authToken - Authorization token for access
   * @param projectId - ID of the project to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(authToken: string, projectId: string): Promise<void>;

  /**
   * Updates an issue/task with new values.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync activity updates back to the external service.
   *
   * The update object contains only the fields that changed, plus id and source.
   * Uses the combination of start and done to determine workflow state:
   * - done set → Completed/Done state
   * - done null + start set → In Progress/Active state
   * - done null + start null → Backlog/Todo state
   *
   * @param authToken - Authorization token for access
   * @param update - ActivityUpdate with changed fields (includes id and source)
   * @returns Promise that resolves when the update is synced
   */
  updateIssue?(authToken: string, update: ActivityUpdate): Promise<void>;

  /**
   * Adds a comment to an issue/task.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync notes added to activities back as comments on the external service.
   *
   * @param authToken - Authorization token for access
   * @param issueId - ID or key of the issue/task to comment on
   * @param body - The comment text content
   * @returns Promise that resolves when the comment is added
   */
  addIssueComment?(
    authToken: string,
    issueId: string,
    body: string
  ): Promise<void>;
}
