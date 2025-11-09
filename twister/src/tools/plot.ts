import {
  type Activity,
  type ActivityMeta,
  type ActivityUpdate,
  type Actor,
  type ActorId,
  ITool,
  type NewActivity,
  type NewContact,
  type NewPriority,
  type Priority,
  type Tag,
} from "..";

export enum ActivityAccess {
  /**
   * Create new Activity on a thread where the twist was mentioned.
   * Add/remove tags on Activity where the twist was mentioned.
   */
  Respond,
  /**
   * Create new, top-level Activity.
   * Create new Activity in a thread the twist created.
   * All Respond permissions.
   */
  Create,
}

export enum PriorityAccess {
  /**
   * Create a new Priority within the twist's Priority.
   * Update Priority created by the twist.
   */
  Create,
  /**
   * Read all Priority within the twist's Priority.
   * Create a new Priority within the twist's Priority.
   * Update and archive any Priority within the twist's Priority.
   */
  Full,
}

export enum ContactAccess {
  /** Read existing contacts. */
  Read,
  /** Create and update contacts. */
  Write,
}

/**
 * Intent handler for activity mentions.
 * Defines how the twist should respond when mentioned in an activity.
 */
export type ActivityIntentHandler = {
  /** Human-readable description of what this intent handles */
  description: string;
  /** Example phrases or activity content that would match this intent */
  examples: string[];
  /** The function to call when this intent is matched */
  handler: (activity: Activity) => Promise<void>;
};

/**
 * Built-in tool for interacting with the core Plot data layer.
 *
 * The Plot tool provides twists with the ability to create and manage activities,
 * priorities, and contacts within the Plot system. This is the primary interface
 * for twists to persist data and interact with the Plot database.
 *
 * @example
 * ```typescript
 * class MyTwist extends Twist {
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
  static readonly Options: {
    /**
     * Activity event callbacks.
     */
    activity?: {
      access?: ActivityAccess;

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
       * When an activity mentions this twist, the system will match the activity
       * content against these intent descriptions and call the matching handler.
       *
       * @example
       * ```typescript
       * intents: [{
       *   description: "Schedule or reschedule calendar events",
       *   examples: ["Schedule a meeting tomorrow at 2pm", "Move my 3pm meeting to 4pm"],
       *   handler: this.onSchedulingRequest
       * }, {
       *   description: "Find available meeting times",
       *   examples: ["When am I free this week?", "Find time for a 1 hour meeting"],
       *   handler: this.onAvailabilityRequest
       * }]
       * ```
       */
      intents?: ActivityIntentHandler[];
    };
    priority?: {
      access?: PriorityAccess;
    };
    contact?: {
      access?: ContactAccess;
    };
  };

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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createActivity(activity: NewActivity): Promise<Activity>;

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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createActivities(activities: NewActivity[]): Promise<Activity[]>;

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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateActivity(activity: ActivityUpdate): Promise<void>;

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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getThread(activity: Activity): Promise<Activity[]>;

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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getActivityByMeta(meta: ActivityMeta): Promise<Activity | null>;

  /**
   * Creates a new priority in the Plot system.
   *
   * Priorities serve as organizational containers for activities and twists.
   * The created priority will be automatically assigned a unique ID.
   *
   * @param priority - The priority data to create
   * @returns Promise resolving to the complete created priority
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createPriority(priority: NewPriority): Promise<Priority>;

  /**
   * Adds contacts to the Plot system.
   *
   * Contacts are used for associating people with activities, such as
   * event attendees or task assignees. Duplicate contacts (by email)
   * will be merged or updated as appropriate.
   * This method requires ContactAccess.Write permission.
   *
   * @param contacts - Array of contact information to add
   * @returns Promise resolving to array of created/updated actors
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract addContacts(contacts: Array<NewContact>): Promise<Actor[]>;

  /**
   * Retrieves actors by their IDs.
   *
   * Actors represent users, contacts, or twists in the Plot system.
   * This method requires ContactAccess.Read permission.
   *
   * @param ids - Array of actor IDs to retrieve
   * @returns Promise resolving to array of actors
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getActors(ids: ActorId[]): Promise<Actor[]>;
}
