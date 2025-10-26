import {
  type Activity,
  type ActivityMeta,
  type ActivityUpdate,
  type ActorId,
  type Contact,
  ITool,
  type NewActivity,
  type NewPriority,
  type Priority,
  type Tag,
} from "..";

/**
 * Handler function for activity intent callbacks.
 * Called when an activity with an at-mention matches a registered intent.
 */
export type IntentHandler = (activity: Activity) => Promise<void>;

/**
 * Callbacks for activity events.
 */
export type PlotActivityCallbacks = {
  /**
   * Called when an activity is updated.
   *
   * @param activity - The updated activity
   * @param changes - Optional changes object containing the previous version and tag modifications
   */
  updated?: (
    activity: Activity,
    changes?: {
      previous: Activity;
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
    }
  ) => Promise<void>;

  /**
   * Intent handlers for activity mentions.
   * When an activity mentions this agent, the system will match the activity
   * content against these intent descriptions and call the matching handler.
   *
   * @example
   * ```typescript
   * intents: {
   *   "Schedule or reschedule calendar events": this.onSchedulingRequest,
   *   "Find available meeting times": this.onAvailabilityRequest
   * }
   * ```
   */
  intents?: Record<string, IntentHandler>;
};

/**
 * Options for configuring the Plot tool.
 */
export type PlotOptions = {
  /**
   * Activity event callbacks.
   */
  activity?: PlotActivityCallbacks;
};

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
 *   constructor(id: string, tools: ToolBuilder) {
 *     super();
 *     this.plot = tools.get(Plot);
 *   }
 *
 *   async activate(priority) {
 *     // Create a welcome activity
 *     await this.plot.createActivity({
 *       type: ActivityType.Note,
 *       title: "Welcome to Plot!",
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
export abstract class Plot extends ITool {
  static readonly Options: PlotOptions;

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
  abstract createActivity(_activity: NewActivity): Promise<Activity>;

  /**
   * Updates an existing activity in the Plot system.
   *
   * Only the fields provided in the update object will be modified - all other fields
   * remain unchanged. This enables partial updates without needing to fetch and resend
   * the entire activity object.
   *
   * For tags, provide a Record<number, boolean> where true adds a tag and false removes it.
   * Tags not included in the update remain unchanged.
   *
   * When updating the parent, the activity's path will be automatically recalculated to
   * maintain the correct hierarchical structure.
   *
   * When updating scheduling fields (start, end, recurrence*), the database will
   * automatically recalculate duration and range values to maintain consistency.
   *
   * @param activity - The activity update containing the ID and fields to change
   * @returns Promise that resolves when the update is complete
   *
   * @example
   * ```typescript
   * // Mark a task as complete
   * await this.plot.updateActivity({
   *   id: "task-123",
   *   doneAt: new Date()
   * });
   *
   * // Reschedule an event
   * await this.plot.updateActivity({
   *   id: "event-456",
   *   start: new Date("2024-03-15T10:00:00Z"),
   *   end: new Date("2024-03-15T11:00:00Z")
   * });
   *
   * // Add and remove tags
   * await this.plot.updateActivity({
   *   id: "activity-789",
   *   tags: {
   *     1: true,  // Add tag with ID 1
   *     2: false  // Remove tag with ID 2
   *   }
   * });
   *
   * // Update a recurring event exception
   * await this.plot.updateActivity({
   *   id: "exception-123",
   *   occurrence: new Date("2024-03-20T09:00:00Z"),
   *   title: "Rescheduled meeting"
   * });
   * ```
   */
  abstract updateActivity(_activity: ActivityUpdate): Promise<void>;

  /**
   * Creates a new priority in the Plot system.
   *
   * Priorities serve as organizational containers for activities and agents.
   * The created priority will be automatically assigned a unique ID.
   *
   * @param priority - The priority data to create
   * @returns Promise resolving to the complete created priority
   */
  abstract createPriority(_priority: NewPriority): Promise<Priority>;

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
  abstract getThread(_activity: Activity): Promise<Activity[]>;

  /**
   * Finds an activity by its metadata.
   *
   * This method enables lookup of activities that were created from external
   * systems, using the metadata to locate the corresponding Plot activity.
   * Useful for preventing duplicate imports and maintaining sync state.
   *
   * @param meta - The activity metadata to search for
   * @returns Promise resolving to the matching activity or null if not found
   */
  abstract getActivityByMeta(_meta: ActivityMeta): Promise<Activity | null>;

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
  abstract addContacts(_contacts: Array<Contact>): Promise<void>;

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
  abstract createActivities(_activities: NewActivity[]): Promise<Activity[]>;
}
