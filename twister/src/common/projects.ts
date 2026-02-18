import type {
  Activity,
  ActivityMeta,
  NewActivityWithNotes,
  Serializable,
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
 * Base interface for project management integration tools.
 *
 * All synced issues/tasks are converted to ActivityWithNotes objects.
 * Each issue becomes an Activity with Notes for the description and comments.
 *
 * **Architecture: Tools Build, Twists Save**
 *
 * Project tools follow Plot's core architectural principle:
 * - **Tools**: Fetch external data and transform it into Plot format (NewActivity objects)
 * - **Twists**: Receive the data and decide what to do with it (create, update, filter, etc.)
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Tool declares providers and lifecycle callbacks in build()
 * 3. onAuthorized lists available projects and calls setSyncables()
 * 4. User enables projects in the modal → onSyncEnabled fires
 * 5. **Tool builds NewActivity objects** and passes them to the twist via callback
 * 6. **Twist decides** whether to save using createActivity/updateActivity
 *
 * **Recommended Data Sync Strategy:**
 * Use Activity.source (issue URL) and Note.key for automatic upserts.
 * See SYNC_STRATEGIES.md for detailed patterns.
 */
export type ProjectTool = {
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
   * @param callback - Function receiving (activity, ...extraArgs) for each synced issue
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TArgs extends Serializable[],
    TCallback extends (activity: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      projectId: string;
    } & ProjectSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
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
   * sync activity updates back to the external service.
   *
   * Auth is obtained automatically via integrations.get(provider, projectId)
   * using the projectId from activity.meta.
   *
   * @param activity - The updated activity
   * @returns Promise that resolves when the update is synced
   */
  updateIssue?(activity: Activity): Promise<void>;

  /**
   * Adds a comment to an issue/task.
   *
   * Optional method for bidirectional sync. When implemented, allows Plot to
   * sync notes added to activities back as comments on the external service.
   *
   * Auth is obtained automatically. The tool should extract its own ID
   * from meta (e.g., linearId, taskGid, issueKey).
   *
   * @param meta - Activity metadata containing the tool's issue/task identifier
   * @param body - The comment text content
   * @param noteId - Optional Plot note ID, used by tools that support comment metadata (e.g. Jira)
   * @returns The external comment key (e.g. "comment-123") for dedup, or void
   */
  addIssueComment?(
    meta: ActivityMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void>;
};
