import {
  type Activity,
  type ActivitySource,
  type Contact,
  ITool,
  type NewActivity,
  type NewPriority,
  type Priority,
  type Tools,
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
 *     this.plot = tools.get(Plot);
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
export class Plot extends ITool {
  static readonly id = "plot";

  constructor(_tools: Tools) {
    super();
  }

  call(_name: string, _args: any, _context: any): Promise<any> {
    throw new Error("Method not implemented.");
  }

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
  createActivity(_activity: NewActivity): Promise<Activity> {
    throw new Error("Method not implemented.");
  }

  /**
   * Creates a new priority in the Plot system.
   *
   * Priorities serve as organizational containers for activities and agents.
   * The created priority will be automatically assigned a unique ID.
   *
   * @param priority - The priority data to create
   * @returns Promise resolving to the complete created priority
   */
  createPriority(_priority: NewPriority): Promise<Priority> {
    throw new Error("Method not implemented.");
  }

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
  getThread(_activity: Activity): Promise<Activity[]> {
    throw new Error("Method not implemented.");
  }

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
  getActivityBySource(_source: ActivitySource): Promise<Activity | null> {
    throw new Error("Method not implemented.");
  }

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
  addContacts(_contacts: Array<Contact>): Promise<void> {
    throw new Error("Method not implemented.");
  }

  /**
   * Creates multiple activities in a single batch operation.
   *
   * This method efficiently creates multiple activities at once, which is
   * more performant than calling createActivity() multiple times individually.
   * All activities are created with the same author and access control rules.
   *
   * @param activities - Array of activity data to create
   * @returns Promise resolving to array of created activities
   */
  createActivities(_activities: NewActivity[]): Promise<Activity[]> {
    throw new Error("Method not implemented.");
  }
}
