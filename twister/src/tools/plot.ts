import {
  type Activity,
  type ActivityOccurrence,
  type ActivityUpdate,
  type Actor,
  type ActorId,
  ITool,
  type NewActivity,
  type NewActivityWithNotes,
  type NewContact,
  type NewNote,
  type NewPriority,
  type Note,
  type NoteUpdate,
  type Priority,
  type PriorityUpdate,
  type Tag,
  Uuid,
} from "..";

export enum ActivityAccess {
  /**
   * Create new Note on an Activity where the twist was mentioned.
   * Add/remove tags on Activity or Note where the twist was mentioned.
   */
  Respond,
  /**
   * Create new Activity.
   * Create new Note in an Activity the twist created.
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
  /** Read existing contact details. Without this, only the ID will be provided. */
  Read,
  /** Create and update contacts. */
  Write,
}

/**
 * Intent handler for activity mentions.
 * Defines how the twist should respond when mentioned in an activity.
 */
export type NoteIntentHandler = {
  /** Human-readable description of what this intent handles */
  description: string;
  /** Example phrases or activity content that would match this intent */
  examples: string[];
  /** The function to call when this intent is matched */
  handler: (note: Note) => Promise<void>;
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
  /**
   * Configuration options for the Plot tool.
   *
   * **Important**: All permissions must be explicitly requested. There are no default permissions.
   *
   * @example
   * ```typescript
   * // Minimal configuration with required permissions
   * build(build: ToolBuilder) {
   *   return {
   *     plot: build(Plot, {
   *       activity: {
   *         access: ActivityAccess.Create
   *       }
   *     })
   *   };
   * }
   *
   * // Full configuration with callbacks
   * build(build: ToolBuilder) {
   *   return {
   *     plot: build(Plot, {
   *       activity: {
   *         access: ActivityAccess.Create,
   *         updated: this.onActivityUpdated
   *       },
   *       note: {
   *         intents: [{
   *           description: "Schedule meetings",
   *           examples: ["Schedule a meeting tomorrow"],
   *           handler: this.onSchedulingIntent
   *         }],
   *         created: this.onNoteCreated
   *       },
   *       priority: {
   *         access: PriorityAccess.Full
   *       },
   *       contact: {
   *         access: ContactAccess.Write
   *       }
   *     })
   *   };
   * }
   * ```
   */
  static readonly Options: {
    activity?: {
      /**
       * Capability to create Notes and modify tags.
       * Must be explicitly set to grant permissions.
       */
      access?: ActivityAccess;
      /**
       * Called when an activity created by this twist is updated.
       * This is often used to implement two-way sync with an external system.
       *
       * @param activity - The updated activity
       * @param changes - Changes to the activity and the previous version
       */
      updated?: (
        activity: Activity,
        changes: {
          tagsAdded: Record<Tag, ActorId[]>;
          tagsRemoved: Record<Tag, ActorId[]>;
          /**
           * If present, this update is for a specific occurrence of a recurring activity.
           */
          occurrence?: ActivityOccurrence;
        }
      ) => Promise<void>;
    };
    note?: {
      /**
       * Respond to mentions in notes.
       *
       * When a note mentions this twist, the system will match the note
       * content against these intents and call the matching handler.
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
      intents?: NoteIntentHandler[];
      /**
       * Called when a note is created on an activity created by this twist.
       * This is often used to implement two-way sync with an external system,
       * such as syncing notes as comments back to the source system.
       *
       * Notes created by the twist itself are automatically filtered out to prevent loops.
       * The parent activity is available via note.activity.
       *
       * @param note - The newly created note
       */
      created?: (note: Note) => Promise<void>;
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
   * @returns Promise resolving to the created activity's ID
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createActivity(
    activity: NewActivity | NewActivityWithNotes
  ): Promise<Uuid>;

  /**
   * Creates multiple activities in a single batch operation.
   *
   * This method efficiently creates multiple activities at once, which is
   * more performant than calling createActivity() multiple times individually.
   * All activities are created with the same author and access control rules.
   *
   * @param activities - Array of activity data to create
   * @returns Promise resolving to array of created activity IDs
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createActivities(
    activities: (NewActivity | NewActivityWithNotes)[]
  ): Promise<Uuid[]>;

  /**
   * Updates an existing activity in the Plot system.
   *
   * **Important**: This method only updates existing activities. It will throw an error
   * if the activity does not exist. Use `createActivity()` to create or update (upsert)
   * activities.
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
   * @param activity - The activity update containing the ID or source and fields to change
   * @returns Promise that resolves when the update is complete
   * @throws Error if the activity does not exist
   *
   * @example
   * ```typescript
   * // Mark a task as complete
   * await this.plot.updateActivity({
   *   id: "task-123",
   *   done: new Date()
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
   * Retrieves all notes within an activity.
   *
   * Notes are detailed entries within an activity, ordered by creation time.
   * Each note can contain markdown content, links, and other detailed information
   * related to the parent activity.
   *
   * @param activity - The activity whose notes to retrieve
   * @returns Promise resolving to array of notes in the activity
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getNotes(activity: Activity): Promise<Note[]>;

  /**
   * Creates a new note in an activity.
   *
   * Notes provide detailed content within an activity, supporting markdown,
   * links, and other rich content. The note will be automatically assigned
   * an ID and author information based on the current execution context.
   *
   * @param note - The note data to create
   * @returns Promise resolving to the created note's ID
   *
   * @example
   * ```typescript
   * // Create a note with content
   * await this.plot.createNote({
   *   activity: { id: "activity-123" },
   *   note: "Discussion notes from the meeting...",
   *   contentType: "markdown"
   * });
   *
   * // Create a note with links
   * await this.plot.createNote({
   *   activity: { id: "activity-456" },
   *   note: "Meeting recording available",
   *   links: [{
   *     type: ActivityLinkType.external,
   *     title: "View Recording",
   *     url: "https://example.com/recording"
   *   }]
   * });
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createNote(note: NewNote): Promise<Uuid>;

  /**
   * Creates multiple notes in a single batch operation.
   *
   * This method efficiently creates multiple notes at once, which is
   * more performant than calling createNote() multiple times individually.
   * All notes are created with the same author and access control rules.
   *
   * @param notes - Array of note data to create
   * @returns Promise resolving to array of created note IDs
   *
   * @example
   * ```typescript
   * // Create multiple notes in one batch
   * await this.plot.createNotes([
   *   {
   *     activity: { id: "activity-123" },
   *     note: "First message in thread"
   *   },
   *   {
   *     activity: { id: "activity-123" },
   *     note: "Second message in thread"
   *   }
   * ]);
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createNotes(notes: NewNote[]): Promise<Uuid[]>;

  /**
   * Updates an existing note in the Plot system.
   *
   * **Important**: This method only updates existing notes. It will throw an error
   * if the note does not exist. Use `createNote()` to create or update (upsert) notes.
   *
   * Only the fields provided in the update object will be modified - all other fields
   * remain unchanged. This enables partial updates without needing to fetch and resend
   * the entire note object.
   *
   * @param note - The note update containing the ID or key and fields to change
   * @returns Promise that resolves when the update is complete
   * @throws Error if the note does not exist
   *
   * @example
   * ```typescript
   * // Update note content
   * await this.plot.updateNote({
   *   id: "note-123",
   *   note: "Updated content with more details"
   * });
   *
   * // Add tags to a note
   * await this.plot.updateNote({
   *   id: "note-456",
   *   twistTags: {
   *     [Tag.Important]: true
   *   }
   * });
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateNote(note: NoteUpdate): Promise<void>;

  /**
   * Retrieves an activity by ID or source.
   *
   * This method enables lookup of activities either by their unique ID or by their
   * source identifier (canonical URL from an external system). Archived activities
   * are included in the results.
   *
   * @param activity - Activity lookup by ID or source
   * @returns Promise resolving to the matching activity or null if not found
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getActivity(
    activity: { id: Uuid } | { source: string }
  ): Promise<Activity | null>;

  /**
   * Retrieves a note by ID or key.
   *
   * This method enables lookup of notes either by their unique ID or by their
   * key (unique identifier within the activity). Archived notes are included
   * in the results.
   *
   * @param note - Note lookup by ID or key
   * @returns Promise resolving to the matching note or null if not found
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getNote(note: { id: Uuid } | { key: string }): Promise<Note | null>;

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
   * Retrieves a priority by ID or key.
   *
   * Archived priorities are included in the results.
   *
   * @param priority - Priority lookup by ID or key
   * @returns Promise resolving to the matching priority or null if not found
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getPriority(
    priority: { id: Uuid } | { key: string }
  ): Promise<Priority | null>;

  /**
   * Updates an existing priority in the Plot system.
   *
   * The priority is identified by either its ID or key.
   * Only the fields specified in the update will be changed.
   *
   * @param update - Priority update containing ID/key and fields to change
   * @returns Promise that resolves when the update is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updatePriority(update: PriorityUpdate): Promise<void>;

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
