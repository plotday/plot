import {
  type Thread,
  type ThreadUpdate,
  type Actor,
  type ActorId,
  ITool,
  type NewThread,
  type NewThreadWithNotes,
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
import {
  type Schedule,
  type NewSchedule,
  type ScheduleUpdate,
} from "../schedule";

export enum ThreadAccess {
  /**
   * Create new Note on a Thread where the twist was mentioned.
   * Add/remove tags on Thread or Note where the twist was mentioned.
   */
  Respond,
  /**
   * Create new Thread.
   * Create new Note in a Thread the twist created.
   * All Respond permissions.
   */
  Create,
}

/** @deprecated Use ThreadAccess instead */
export const ActivityAccess = ThreadAccess;
/** @deprecated Use ThreadAccess instead */
export type ActivityAccess = ThreadAccess;

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
 * Intent handler for thread mentions.
 * Defines how the twist should respond when mentioned in a thread.
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
 * The Plot tool provides twists with the ability to create and manage threads,
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
 *     // Create a welcome thread
 *     await this.plot.createThread({
 *       type: ThreadType.Note,
 *       title: "Welcome to Plot!",
 *       actions: [{
 *         title: "Get Started",
 *         type: ActionType.external,
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
   *       thread: {
   *         access: ThreadAccess.Create
   *       }
   *     })
   *   };
   * }
   *
   * // Full configuration with callbacks
   * build(build: ToolBuilder) {
   *   return {
   *     plot: build(Plot, {
   *       thread: {
   *         access: ThreadAccess.Create,
   *         updated: this.onThreadUpdated
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
    thread?: {
      /**
       * Capability to create Notes and modify tags.
       * Must be explicitly set to grant permissions.
       */
      access?: ThreadAccess;
      /**
       * Called when a thread created by this twist is updated.
       * This is often used to implement two-way sync with an external system.
       *
       * @param thread - The updated thread
       * @param changes - Changes to the thread and the previous version
       */
      updated?: (
        thread: Thread,
        changes: {
          tagsAdded: Record<Tag, ActorId[]>;
          tagsRemoved: Record<Tag, ActorId[]>;
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
       * Called when a note is created on a thread created by this twist.
       * This is often used to implement two-way sync with an external system,
       * such as syncing notes as comments back to the source system.
       *
       * Notes created by the twist itself are automatically filtered out to prevent loops.
       * The parent thread is available via note.thread.
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
   * Creates a new thread in the Plot system.
   *
   * The thread will be automatically assigned an ID and author information
   * based on the current execution context. All other fields from NewThread
   * will be preserved in the created thread.
   *
   * @param thread - The thread data to create
   * @returns Promise resolving to the created thread's ID
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createThread(
    thread: NewThread | NewThreadWithNotes
  ): Promise<Uuid>;

  /**
   * Creates multiple threads in a single batch operation.
   *
   * This method efficiently creates multiple threads at once, which is
   * more performant than calling createThread() multiple times individually.
   * All threads are created with the same author and access control rules.
   *
   * @param threads - Array of thread data to create
   * @returns Promise resolving to array of created thread IDs
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createThreads(
    threads: (NewThread | NewThreadWithNotes)[]
  ): Promise<Uuid[]>;

  /**
   * Updates an existing thread in the Plot system.
   *
   * **Important**: This method only updates existing threads. It will throw an error
   * if the thread does not exist. Use `createThread()` to create or update (upsert)
   * threads.
   *
   * Only the fields provided in the update object will be modified - all other fields
   * remain unchanged. This enables partial updates without needing to fetch and resend
   * the entire thread object.
   *
   * For tags, provide a Record<number, boolean> where true adds a tag and false removes it.
   * Tags not included in the update remain unchanged.
   *
   * When updating the parent, the thread's path will be automatically recalculated to
   * maintain the correct hierarchical structure.
   *
   * Scheduling is handled separately via `createSchedule()` / `updateSchedule()`.
   *
   * @param thread - The thread update containing the ID or source and fields to change
   * @returns Promise that resolves when the update is complete
   * @throws Error if the thread does not exist
   *
   * @example
   * ```typescript
   * // Mark a task as complete
   * await this.plot.updateThread({
   *   id: "task-123",
   *   done: new Date()
   * });
   *
   * // Add and remove tags
   * await this.plot.updateThread({
   *   id: "thread-789",
   *   tags: {
   *     1: true,  // Add tag with ID 1
   *     2: false  // Remove tag with ID 2
   *   }
   * });
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateThread(thread: ThreadUpdate): Promise<void>;

  /**
   * Retrieves all notes within a thread.
   *
   * Notes are detailed entries within a thread, ordered by creation time.
   * Each note can contain markdown content, actions, and other detailed information
   * related to the parent thread.
   *
   * @param thread - The thread whose notes to retrieve
   * @returns Promise resolving to array of notes in the thread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getNotes(thread: Thread): Promise<Note[]>;

  /**
   * Creates a new note in a thread.
   *
   * Notes provide detailed content within a thread, supporting markdown,
   * actions, and other rich content. The note will be automatically assigned
   * an ID and author information based on the current execution context.
   *
   * @param note - The note data to create
   * @returns Promise resolving to the created note's ID
   *
   * @example
   * ```typescript
   * // Create a note with content
   * await this.plot.createNote({
   *   thread: { id: "thread-123" },
   *   note: "Discussion notes from the meeting...",
   *   contentType: "markdown"
   * });
   *
   * // Create a note with actions
   * await this.plot.createNote({
   *   thread: { id: "thread-456" },
   *   note: "Meeting recording available",
   *   actions: [{
   *     type: ActionType.external,
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
   *     thread: { id: "thread-123" },
   *     note: "First message in thread"
   *   },
   *   {
   *     thread: { id: "thread-123" },
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
   * Retrieves a thread by ID or source.
   *
   * This method enables lookup of threads either by their unique ID or by their
   * source identifier (canonical URL from an external system). Archived threads
   * are included in the results.
   *
   * @param thread - Thread lookup by ID or source
   * @returns Promise resolving to the matching thread or null if not found
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getThread(
    thread: { id: Uuid } | { source: string }
  ): Promise<Thread | null>;

  /**
   * Retrieves a note by ID or key.
   *
   * This method enables lookup of notes either by their unique ID or by their
   * key (unique identifier within the thread). Archived notes are included
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
   * Priorities serve as organizational containers for threads and twists.
   * The created priority will be automatically assigned a unique ID.
   *
   * @param priority - The priority data to create
   * @returns Promise resolving to the complete created priority
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createPriority(priority: NewPriority): Promise<Priority & { created: boolean }>;

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
   * Contacts are used for associating people with threads, such as
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

  /**
   * Creates a new schedule for a thread.
   *
   * Schedules define when a thread occurs in time. A thread can have
   * multiple schedules (shared and per-user).
   *
   * @param schedule - The schedule data to create
   * @returns Promise resolving to the created schedule
   *
   * @example
   * ```typescript
   * // Schedule a timed event
   * const threadId = await this.plot.createThread({
   *   type: ThreadType.Event,
   *   title: "Team standup"
   * });
   * await this.plot.createSchedule({
   *   threadId,
   *   start: new Date("2025-01-15T10:00:00Z"),
   *   end: new Date("2025-01-15T10:30:00Z"),
   *   recurrenceRule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"
   * });
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createSchedule(schedule: NewSchedule): Promise<Schedule>;

  /**
   * Updates an existing schedule.
   *
   * Only the fields provided in the update object will be modified.
   *
   * @param schedule - The schedule update containing the ID and fields to change
   * @returns Promise resolving to the updated schedule
   *
   * @example
   * ```typescript
   * // Reschedule
   * await this.plot.updateSchedule({
   *   id: scheduleId,
   *   start: new Date("2025-03-20T10:00:00Z"),
   *   end: new Date("2025-03-20T11:00:00Z")
   * });
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateSchedule(schedule: ScheduleUpdate): Promise<Schedule>;

  /**
   * Retrieves all schedules for a thread.
   *
   * @param threadId - The thread whose schedules to retrieve
   * @returns Promise resolving to array of schedules for the thread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getSchedules(threadId: Uuid): Promise<Schedule[]>;
}
