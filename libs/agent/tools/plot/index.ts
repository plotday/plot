import type {
  Activity,
  ActivitySource,
  BuiltInTool,
  Contact,
  NewActivity,
  NewPriority,
  Priority,
} from "../../sdk";

export { Activity, NewActivity, NewPriority, Priority };

/**
 * Built-in tool for interacting with the core Plot data layer.
 *
 * The Plot tool provides agents with the ability to create and manage activities,
 * priorities, and contacts within the Plot system. This is the primary interface
 * for agents to persist data and interact with the Plot database.
 *
 * @example
 * ```typescript
 * class MyAgent extends Agent {
 *   private plot: Plot;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.plot = tools.get<Plot>("plot");
 *   }
 *
 *   async activate(priority: Pick<Priority, "id">) {
 *     // Create a welcome activity
 *     await this.plot.createActivity({
 *       type: ActivityType.Task,
 *       title: "Welcome to Plot!",
 *       start: new Date(),
 *       links: [{
 *         title: "Get Started",
 *         type: ActivityLinkType.external,
 *         url: "https://plot.day/docs"
 *       }]
 *     });
 *   }
 * }
 * ```
 */
export interface Plot extends BuiltInTool {
  /**
   * Creates a new activity in the Plot system.
   *
   * The activity will be automatically assigned an ID and author information
   * based on the current execution context. All other fields from NewActivity
   * will be preserved in the created activity.
   *
   * @param activity - The activity data to create
   * @returns Promise resolving to the complete created activity
   */
  createActivity(activity: NewActivity): Promise<Activity>;

  /**
   * Creates a new priority in the Plot system.
   *
   * Priorities serve as organizational containers for activities and agents.
   * The created priority will be automatically assigned a unique ID.
   *
   * @param priority - The priority data to create
   * @returns Promise resolving to the complete created priority
   */
  createPriority(priority: NewPriority): Promise<Priority>;

  /**
   * Retrieves all activities in the same thread as the specified activity.
   *
   * A thread consists of related activities linked through parent-child
   * relationships or other associative connections. This is useful for
   * finding conversation histories or related task sequences.
   *
   * @param activity - The activity whose thread to retrieve
   * @returns Promise resolving to array of activities in the thread
   */
  getThread(activity: Activity): Promise<Activity[]>;

  /**
   * Finds an activity by its external source reference.
   *
   * This method enables lookup of activities that were created from external
   * systems, using the source information to locate the corresponding Plot activity.
   * Useful for preventing duplicate imports and maintaining sync state.
   *
   * @param source - The external source reference to search for
   * @returns Promise resolving to the matching activity or null if not found
   */
  getActivityBySource(source: ActivitySource): Promise<Activity | null>;

  /**
   * Adds contacts to the Plot system.
   *
   * Contacts are used for associating people with activities, such as
   * event attendees or task assignees. Duplicate contacts (by email)
   * will be merged or updated as appropriate.
   *
   * @param contacts - Array of contact information to add
   * @returns Promise that resolves when all contacts have been processed
   */
  addContacts(contacts: Array<Contact>): Promise<void>;
}
