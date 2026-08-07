import {
  type Action,
  type Thread,
  type ThreadUpdate,
  type Actor,
  type ActorId,
  ITool,
  type Link,
  type LinkUpdate,
  type NewThread,
  type NewThreadWithNotes,
  type NewNote,
  type NewFocus,
  type Note,
  type NoteUpdate,
  type PlanOperation,
  type Focus,
  type FocusUpdate,
  type TodayItem,
  Uuid,
} from "..";
import {
  type Schedule,
  type NewSchedule,
} from "../schedule";
import {
  type Goal,
  type GoalStatus,
  type GoalUpdate,
  type NewGoal,
} from "../goal";
import type { Callback } from "./callbacks";

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
  /**
   * List/query all Threads owned by the twist's user.
   * Update any Thread (title, tags, archived, type, focus) regardless of creator.
   * Create Notes on any Thread (not just own or mentioned).
   * All Create permissions.
   */
  Full,
}

export enum FocusAccess {
  /**
   * Create new Focuses for the twist owner.
   * Update Focuses created by the twist.
   */
  Create,
  /**
   * Read all Focuses owned by the twist's user.
   * Create new Focuses for the twist owner.
   * Update and archive any Focus owned by the twist's user.
   */
  Full,
}

export enum ContactAccess {
  /** Read existing contact details. Without this, only the ID will be provided. */
  Read,
}

export enum LinkAccess {
  /** Read links on any thread owned by the twist's user. */
  Read,
  /** Read + update links, including moving links between threads owned by the twist's user. */
  Full,
}

export enum GoalAccess {
  /** Read the owner's goals. */
  Read,
  /**
   * Read, create, update, and archive the owner's goals.
   * All Read permissions.
   */
  Manage,
}

export enum TodayAccess {
  /** Read the user's Today snapshot items and Today-thread id. */
  Read,
  /**
   * Read + adjust Today items: re-rank within a section, check items off,
   * and dismiss items from the snapshot. Includes all Read permissions.
   */
  Manage,
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
 * Filter for querying links from connected source channels.
 */
export type LinkFilter = {
  /** Only return links from these channel IDs. */
  channelIds?: string[];
  /** Only return links created/updated after this date. */
  since?: Date;
  /** Only return links of this type. */
  type?: string;
  /** Maximum number of links to return. */
  limit?: number;
};

type SearchResultBase = {
  thread: { id: string; title: string | null };
  focus: { id: string; title: string | null };
  similarity: number;
};

export type NoteSearchResult = SearchResultBase & {
  type: 'note';
  id: string;
  content: string | null;
};

export type LinkSearchResult = SearchResultBase & {
  type: 'link';
  id: string;
  title: string | null;
  sourceUrl: string | null;
  content: string | null;
};

export type SearchResult = NoteSearchResult | LinkSearchResult;

/** Default number of search results returned */
export const SEARCH_DEFAULT_LIMIT = 10;
/** Maximum number of search results allowed */
export const SEARCH_MAX_LIMIT = 30;

export type SearchOptions = {
  /** Max results to return (default: 10, max: 30) */
  limit?: number;
  /** Minimum similarity score 0-1 (default: 0.3) */
  threshold?: number;
  /**
   * Scope search to this focus. Must be owned by the twist owner. When
   * omitted, the server scopes the search across all of the owner's focuses.
   */
  focusId?: string;
};

/**
 * Built-in tool for interacting with the core Plot data layer.
 *
 * The Plot tool provides twists with the ability to create and manage threads,
 * focuses, and contacts within the Plot system. This is the primary interface
 * for twists to persist data and interact with the Plot database.
 *
 * @example
 * ```typescript
 * class MyTwist extends Twist<MyTwist> {
 *   build(build: ToolBuilder) {
 *     return {
 *       plot: build(Plot, {
 *         thread: { access: ThreadAccess.Create },
 *       }),
 *     };
 *   }
 *
 *   async activate() {
 *     // Create a welcome thread with an opening note
 *     await this.tools.plot.createThread({
 *       title: "Welcome to Plot!",
 *       notes: [{
 *         content: "Get started with Plot:",
 *         actions: [{
 *           type: ActionType.external,
 *           title: "Get Started",
 *           url: "https://plot.day/docs"
 *         }]
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
   *       },
   *       note: {
   *         intents: [{
   *           description: "Schedule meetings",
   *           examples: ["Schedule a meeting tomorrow"],
   *           handler: this.onSchedulingIntent
   *         }],
   *       },
   *       link: true,
   *       focus: {
   *         access: FocusAccess.Full
   *       },
   *       contact: {
   *         access: ContactAccess.Read
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
      /** When true, auto-mention this twist on new notes in threads where it authored content. */
      defaultMention?: boolean;
    };
    note?: {
      /** When true, auto-mention this twist on new notes in threads where it was @-mentioned. */
      defaultMention?: boolean;
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
       * Single conversational handler for mentions.
       *
       * When set, EVERY mention of this twist is routed directly to this
       * handler — intent matching (and the built-in "What can you do?" /
       * "Remove yourself" intents) is skipped. Use this to build a
       * general-purpose conversational assistant that responds to any
       * request, rather than classifying into a fixed set of `intents`.
       *
       * `handler` and `intents` are mutually exclusive; when both are
       * present, `handler` takes precedence and `intents` is ignored.
       *
       * @example
       * ```typescript
       * note: {
       *   defaultMention: true,
       *   handler: this.respond, // (note: Note) => Promise<void>
       * }
       * ```
       */
      handler?: (note: Note) => Promise<void>;
    };
    /** Enable link processing from connected source channels. */
    link?: true | {
      /** Access level for links. When omitted with `link: true`, only source channel links are accessible. */
      access?: LinkAccess;
    };
    focus?: {
      access?: FocusAccess;
    };
    contact?: {
      access?: ContactAccess;
    };
    /**
     * Enable goal operations. Goals are per-user intentions ("ship X by
     * Friday", "3 hours a week on leads") that shape Plot's day planning.
     */
    goals?: {
      access: GoalAccess;
    };
    /**
     * Access to the user's Today snapshot (per-day priorities/updates items
     * and the persistent Today chat thread id).
     */
    today?: {
      access: TodayAccess;
    };
    /** Enable semantic search across notes and links owned by the twist's user. */
    search?: true;
    /**
     * When true, admin write operations (on threads/notes/links/focuses not created by this twist)
     * require user approval via plan actions instead of executing immediately.
     * Read operations and operations on the twist's own content still work directly.
     */
    requireApproval?: boolean;
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
   * For the twist's own tags, use `twistTags`: a record mapping tag ID to a
   * boolean, where true adds the tag and false removes it. Tags not included
   * in the update remain unchanged.
   *
   * Set `focus` to move the thread to a different focus.
   *
   * Scheduling is handled separately via `createSchedule()` / `updateSchedule()`.
   *
   * @param thread - The thread update containing the ID or source and fields to change
   * @returns Promise that resolves when the update is complete
   * @throws Error if the thread does not exist
   *
   * @example
   * ```typescript
   * // Archive a thread
   * await this.tools.plot.updateThread({
   *   id: threadId,
   *   archived: true
   * });
   *
   * // Add and remove the twist's tags
   * await this.tools.plot.updateThread({
   *   id: threadId,
   *   twistTags: {
   *     [Tag.Todo]: true,  // Add the to-do tag
   *     [Tag.Done]: false  // Remove the done tag
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
   * await this.tools.plot.createNote({
   *   thread: { id: "thread-123" },
   *   content: "Discussion notes from the meeting...",
   *   contentType: "markdown"
   * });
   *
   * // Create a note with actions
   * await this.tools.plot.createNote({
   *   thread: { id: "thread-456" },
   *   content: "Meeting recording available",
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
   * await this.tools.plot.createNotes([
   *   {
   *     thread: { id: "thread-123" },
   *     content: "First message in thread"
   *   },
   *   {
   *     thread: { id: "thread-123" },
   *     content: "Second message in thread"
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
   * await this.tools.plot.updateNote({
   *   id: "note-123",
   *   content: "Updated content with more details"
   * });
   *
   * // Add tags to a note
   * await this.tools.plot.updateNote({
   *   id: "note-456",
   *   twistTags: {
   *     [Tag.Todo]: true
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
   * Creates a new focus in the Plot system.
   *
   * Focuses serve as organizational containers for threads and twists.
   * The created focus will be automatically assigned a unique ID.
   *
   * @param focus - The focus data to create
   * @returns Promise resolving to the complete created focus
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createFocus(focus: NewFocus): Promise<Focus & { created: boolean }>;

  /**
   * Retrieves a focus by ID or key.
   *
   * Archived focuses are included in the results.
   *
   * @param focus - Focus lookup by ID or key
   * @returns Promise resolving to the matching focus or null if not found
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getFocus(
    focus: { id: Uuid } | { key: string }
  ): Promise<Focus | null>;

  /**
   * Updates an existing focus in the Plot system.
   *
   * The focus is identified by either its ID or key.
   * Only the fields specified in the update will be changed.
   *
   * @param update - Focus update containing ID/key and fields to change
   * @returns Promise that resolves when the update is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateFocus(update: FocusUpdate): Promise<void>;

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
   * Returns the full Actor for the user who installed this twist.
   * Useful for per-user operations like schedule creation, or when
   * the owner's name or email is needed.
   */
  abstract getOwner(): Promise<Actor>;

  /**
   * Returns the user ID (`twist_instance.owner_id`) that installed this
   * twist. This is the same value exposed on Twist via `this.userId`.
   */
  abstract getUserId(): Promise<string>;

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
   * const threadId = await this.tools.plot.createThread({
   *   title: "Team standup"
   * });
   * await this.tools.plot.createSchedule({
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
   * Retrieves all schedules for a thread.
   *
   * @param threadId - The thread whose schedules to retrieve
   * @returns Promise resolving to array of schedules for the thread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getSchedules(threadId: Uuid): Promise<Schedule[]>;

  /**
   * Creates a new goal for the twist owner.
   *
   * Requires `goals: { access: GoalAccess.Manage }`.
   *
   * @param goal - The goal data to create (`title` required)
   * @returns Promise resolving to the created goal
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createGoal(goal: NewGoal): Promise<Goal>;

  /**
   * Lists the twist owner's goals (archived goals are excluded).
   *
   * Requires `goals: { access: GoalAccess.Read }` (or Manage).
   *
   * @param filter - Optional status filter
   * @returns Promise resolving to the matching goals
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getGoals(filter?: { status?: GoalStatus }): Promise<Goal[]>;

  /**
   * Partially updates an existing goal. Omitted fields are left unchanged;
   * `null` clears a nullable field. Setting `status: "completed"` records
   * the completion time server-side; moving away from `completed` clears it.
   *
   * Requires `goals: { access: GoalAccess.Manage }`.
   *
   * @param update - The goal update containing the ID and fields to change
   * @returns Promise resolving to the updated goal
   * @throws Error if the goal does not exist
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateGoal(update: GoalUpdate): Promise<Goal>;

  /**
   * Archives a goal (soft delete — the row is kept server-side as agent
   * memory; goals are never hard-deleted). Prefer
   * `updateGoal({ id, status: "dropped" })` for "cancel my goal", which
   * keeps it visible in goal listings.
   *
   * Requires `goals: { access: GoalAccess.Manage }`.
   *
   * @param id - The goal id to archive
   * @throws Error if the goal does not exist
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract archiveGoal(id: Uuid): Promise<void>;

  /**
   * Lists the user's current Today snapshot: all non-archived items for the
   * latest generated day, ordered by section ("priorities" first) then rank.
   *
   * Requires `today` access ({@link TodayAccess.Read} or higher).
   *
   * @returns Promise resolving to the current Today items (may be empty)
   */
  abstract getTodayItems(): Promise<TodayItem[]>;

  /**
   * Adjusts one Today item. Only the provided fields change:
   * - `rank` reorders the item within its section (ascending; lower is higher)
   * - `checked: true` stamps the item's checked state; `false` clears it
   * - `dismissed: true` removes the item from the snapshot (archives it)
   *
   * Requires {@link TodayAccess.Manage}.
   *
   * @param update - The item id plus the fields to change
   * @returns Promise that resolves when the update is complete
   * @throws Error if the item does not exist or belongs to another user
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateTodayItem(update: {
    id: Uuid;
    rank?: number;
    checked?: boolean;
    dismissed?: boolean;
  }): Promise<void>;

  /**
   * Returns the id of the user's persistent Today chat thread, or null if
   * it has not been created yet (first snapshot generation pending).
   *
   * Requires `today` access ({@link TodayAccess.Read} or higher).
   */
  abstract getTodayThreadId(): Promise<Uuid | null>;

  /**
   * Retrieves links from connected source channels.
   *
   * Requires `link: true` in Plot options.
   *
   * @param filter - Optional filter criteria for links
   * @returns Promise resolving to array of links with their notes
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getLinks(filter?: LinkFilter): Promise<Array<{ link: Link; notes: Note[] }>>;

  /**
   * Searches notes and links using semantic similarity.
   *
   * Requires `search: true` in Plot options.
   *
   * @param query - The search query text
   * @param options - Optional search configuration
   * @returns Promise resolving to array of search results ordered by similarity
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract search(query: string, options?: SearchOptions): Promise<SearchResult[]>;

  /**
   * Lists threads owned by the twist's user.
   *
   * Requires `ThreadAccess.Full`.
   *
   * @param options - Query options for filtering threads
   * @returns Promise resolving to array of threads
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getThreads(options?: {
    /**
     * Focus to list threads from. Must be owned by the twist owner.
     * When omitted, defaults to the owner's Inbox.
     */
    focusId?: Uuid;
    /** Include archived threads. Default: false. */
    includeArchived?: boolean;
    /** Maximum number of threads to return. Default: 50, max: 200. */
    limit?: number;
    /** Number of threads to skip for pagination. Default: 0. */
    offset?: number;
  }): Promise<Thread[]>;

  /**
   * Lists focuses owned by the twist's user.
   *
   * Requires `FocusAccess.Full`.
   *
   * @param options - Query options for filtering focuses
   * @returns Promise resolving to array of focuses
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getFocuses(options?: {
    /** Include archived focuses. Default: false. */
    includeArchived?: boolean;
  }): Promise<Focus[]>;

  /**
   * Updates a link.
   *
   * Requires `LinkAccess.Full`. Set `threadId` to move the link to a different thread.
   *
   * @param link - The link update containing the ID and fields to change
   * @returns Promise that resolves when the update is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract updateLink(link: LinkUpdate): Promise<void>;

  /**
   * Creates a plan of operations for user approval.
   *
   * Returns an Action that can be attached to a note. The user can approve,
   * deny, or request changes. On approval, operations are executed by the API.
   *
   * Requires `requireApproval: true` in Plot options.
   *
   * @param options - Plan configuration
   * @returns An Action of type `plan` to attach to a note
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createPlan(options: {
    /** Human-readable title summarizing the plan */
    title: string;
    /** Array of operations to execute on approval */
    operations: PlanOperation[];
    /** Callback invoked with (action, approved: boolean) when the user responds */
    callback: Callback;
  }): Action;
}
