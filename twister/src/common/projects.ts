import type { ActivityLink, NewActivityWithNotes } from "../index";

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
   * Issues and tasks are converted to ActivityWithNotes objects.
   * Each object contains an Activity (with issue title and metadata) and Notes array
   * (description as first note, followed by comments).
   * The Activity.source should be set for deduplication.
   *
   * When an issue is updated, tools should check for existing Activity using
   * getActivityBySource() and add a Note rather than creating a new Activity.
   *
   * @param authToken - Authorization token for access
   * @param projectId - ID of the project to sync
   * @param callback - Function receiving (issue, ...extraArgs) for each synced issue
   * @param options - Optional configuration for limiting the sync scope (e.g., time range)
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise that resolves when sync setup is complete
   */
  startSync<
    TCallback extends (issue: NewActivityWithNotes, ...args: any[]) => any
  >(
    authToken: string,
    projectId: string,
    callback: TCallback,
    options?: ProjectSyncOptions,
    ...extraArgs: TCallback extends (issue: any, ...rest: infer R) => any
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
}
