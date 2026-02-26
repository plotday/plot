import type { NewSchedule, NewScheduleOccurrence, Schedule } from "./schedule";
import { type Tag } from "./tag";
import { type Callback } from "./tools/callbacks";
import { type AuthProvider } from "./tools/integrations";
import { type JSONValue } from "./utils/types";
import { Uuid } from "./utils/uuid";

export { Tag } from "./tag";
export { Uuid } from "./utils/uuid";
export { type JSONValue } from "./utils/types";
export { type AuthProvider } from "./tools/integrations";

/**
 * @fileoverview
 * Core Plot entity types for working with threads, notes, priorities, and contacts.
 *
 * ## Type Pattern: Null vs Undefined Semantics
 *
 * Plot entity types use a consistent pattern to distinguish between missing, unset, and explicitly cleared values:
 *
 * ### Entity Types (Thread, Priority, Note, Actor)
 * - **Required fields**: No `?`, cannot be `undefined`
 *   - Example: `id: Uuid`, `type: ThreadType`
 * - **Nullable fields**: Use `| null` to allow explicit clearing
 *   - Example: `assignee: ActorId | null`, `done: Date | null`
 *   - `null` = field is explicitly unset/cleared
 *   - Non-null value = field has a value
 * - **Optional nullable fields**: Use `?` with `| null` for permission-based access
 *   - Example: `email?: string | null`, `name?: string | null`
 *   - `undefined` = field not included (e.g., no permission to access)
 *   - `null` = field included but not set
 *   - Value = field has a value
 *
 * ### New* Types (NewThread, NewNote, NewPriority)
 * Used for creating or updating entities. Support partial updates by distinguishing omitted vs cleared fields:
 * - **Required fields**: Must be provided (no `?`)
 *   - Example: `type: ThreadType` in NewThread
 * - **Optional fields**: Use `?` to make them optional
 *   - Example: `title?: string`, `author?: NewActor`
 *   - `undefined` (omitted) = don't set/update this field
 *   - Provided value = set/update this field
 * - **Optional nullable fields**: Use `?` with `| null` to support clearing
 *   - Example: `assignee?: NewActor | null`
 *   - `undefined` (omitted) = don't change assignee
 *   - `null` = clear the assignee
 *   - NewActor = set/update the assignee
 *
 * This pattern allows API consumers to:
 * 1. Omit fields they don't want to change (undefined)
 * 2. Explicitly clear fields by setting to null
 * 3. Set or update fields by providing values
 *
 * @example
 * ```typescript
 * // Creating a new thread
 * const newThread: NewThread = {
 *   type: ThreadType.Action,  // Required
 *   title: "Review PR",          // Optional, provided
 *   assignee: null,              // Optional nullable, explicitly clearing
 *   // priority is omitted (undefined), will auto-select or use default
 * };
 *
 * // Updating a thread - only change what's specified
 * const update: ThreadUpdate = {
 *   id: threadId,
 *   done: new Date(),       // Mark as done
 *   assignee: null,         // Clear assignee
 *   // title is omitted, won't be changed
 * };
 * ```
 */

/**
 * Represents a unique user, contact, or twist in Plot.
 *
 * ActorIds are used throughout Plot for:
 * - Activity authors and assignees
 * - Tag creators (actor_id in activity_tag/note_tag)
 * - Mentions in activities and notes
 * - Any entity that can perform actions in Plot
 */
export type ActorId = string & { readonly __brand: "ActorId" };

/**
 * Theme colors for priorities.
 */
export enum ThemeColor {
  /** Catalyst - Green */
  Catalyst = 0,
  /** Call to Adventure - Blue */
  CallToAdventure = 1,
  /** Rising Action - Purple */
  RisingAction = 2,
  /** Momentum - Pink-Purple */
  Momentum = 3,
  /** Turning Point - Pink */
  TurningPoint = 4,
  /** Breakthrough - Orange */
  Breakthrough = 5,
  /** Climax - Olive */
  Climax = 6,
  /** Resolution - Blue-Gray */
  Resolution = 7,
}

/**
 * Represents a priority context within Plot.
 *
 * Priorities are similar to projects in other apps. All Activity is in a Priority.
 * Priorities can be nested.
 */
export type Priority = {
  /** Unique identifier for the priority */
  id: Uuid;
  /** Human-readable title for the priority */
  title: string;
  /** Whether this priority has been archived */
  archived: boolean;
  /**
   * Optional key for referencing this priority.
   * Keys are unique per priority tree (a user's personal priorities or the root of a shared priority).
   */
  key: string | null;
  /** Optional theme color for the priority (0-7). If not set, inherits from parent or defaults to 7 (Resolution). */
  color: ThemeColor | null;
};

/**
 * Type for creating new priorities.
 *
 * Supports multiple creation patterns:
 * - Provide a specific UUID for the priority
 * - Provide a key for upsert within the user's priorities
 * - Omit both to auto-generate a new UUID
 *
 * Optionally specify a parent priority by ID or key for hierarchical structures.
 */
export type NewPriority = Pick<Priority, "title"> &
  Partial<Omit<Priority, "id" | "title">> &
  (
    | {
        /**
         * Unique identifier for the priority, generated by Uuid.Generate().
         * Specifying an ID allows tools to track and upsert priorities.
         */
        id: Uuid;
      }
    | {
        /**
         * Unique key for the priority within the user's priorities.
         * Can be used to upsert without knowing the UUID.
         * For example, "@plot" identifies the Plot priority.
         */
        key: string;
      }
    | {
        /* Neither id nor key is required. An id will be generated and returned. */
      }
  ) & {
    /** Add the new priority as the child of another priority */
    parent?: { id: Uuid } | { key: string };
  };

/**
 * Type for updating existing priorities.
 * Must provide either id or key to identify the priority to update.
 */
export type PriorityUpdate = ({ id: Uuid } | { key: string }) &
  Partial<Pick<Priority, "title" | "archived">>;

/**
 * Enumeration of supported thread types in Plot.
 *
 * Each thread type has different behaviors and rendering characteristics
 * within the Plot application.
 */
export enum ThreadType {
  /** A note or piece of information without actionable requirements */
  Note,
  /** An actionable item that can be completed */
  Action,
  /** A scheduled occurrence with start and optional end time */
  Event,
}

/**
 * Kinds of threads. Used only for visual categorization (icon).
 */
export enum ThreadKind {
  document = "document", // any external document or item in an external system
  messages = "messages", // emails and chat threads
  meeting = "meeting", // in-person meeting
  videoconference = "videoconference",
  phone = "phone",
  focus = "focus",
  meal = "meal",
  exercise = "exercise",
  family = "family",
  travel = "travel",
  social = "social",
  entertainment = "entertainment",
}

/**
 * Enumeration of supported action types.
 *
 * Different action types have different behaviors when clicked by users
 * and may require different rendering approaches.
 */
export enum ActionType {
  /** External web links that open in browser */
  external = "external",
  /** Authentication flows for connecting services */
  auth = "auth",
  /** Callback actions that trigger twist methods when clicked */
  callback = "callback",
  /** Video conferencing links with provider-specific handling */
  conferencing = "conferencing",
  /** File attachment links stored in R2 */
  file = "file",
}

/**
 * Video conferencing providers for conferencing links.
 *
 * Used to identify the conferencing platform and provide
 * provider-specific UI elements (titles, icons, etc.).
 */
export enum ConferencingProvider {
  /** Google Meet */
  googleMeet = "googleMeet",
  /** Zoom */
  zoom = "zoom",
  /** Microsoft Teams */
  microsoftTeams = "microsoftTeams",
  /** Cisco Webex */
  webex = "webex",
  /** Other or unknown conferencing provider */
  other = "other",
}

/**
 * Represents a clickable action attached to a thread.
 *
 * Thread actions are rendered as buttons that enable user interaction with threads.
 * Different action types have specific behaviors and required fields for proper functionality.
 *
 * @example
 * ```typescript
 * // External action - opens URL in browser
 * const externalAction: Action = {
 *   type: ActionType.external,
 *   title: "Open in Google Calendar",
 *   url: "https://calendar.google.com/event/123",
 * };
 *
 * // Conferencing action - opens video conference with provider info
 * const conferencingAction: Action = {
 *   type: ActionType.conferencing,
 *   url: "https://meet.google.com/abc-defg-hij",
 *   provider: ConferencingProvider.googleMeet,
 * };
 *
 * // Integrations action - initiates OAuth flow
 * const authAction: Action = {
 *   type: ActionType.auth,
 *   title: "Continue with Google",
 *   provider: AuthProvider.Google,
 *   scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
 *   callback: "callback-token-for-auth-completion"
 * };
 *
 * // Callback action - triggers a twist method
 * const callbackAction: Action = {
 *   type: ActionType.callback,
 *   title: "📅 Primary Calendar",
 *   token: "callback-token-here"
 * };
 * ```
 */
export type Action =
  | {
      /** External web link that opens in browser */
      type: ActionType.external;
      /** Display text for the action button */
      title: string;
      /** URL to open when clicked */
      url: string;
    }
  | {
      /** Video conferencing action with provider-specific handling */
      type: ActionType.conferencing;
      /** URL to join the conference */
      url: string;
      /** Conferencing provider for UI customization */
      provider: ConferencingProvider;
    }
  | {
      /** Authentication action that initiates an OAuth flow */
      type: ActionType.auth;
      /** Display text for the auth button */
      title: string;
      /** OAuth provider (e.g., "google", "microsoft") */
      provider: string;
      /** Array of OAuth scopes to request */
      scopes: string[];
      /** Callback token for auth completion notification */
      callback: Callback;
    }
  | {
      /** Callback action that triggers a twist method when clicked */
      type: ActionType.callback;
      /** Display text for the callback button */
      title: string;
      /** Token identifying the callback to execute */
      callback: Callback;
    }
  | {
      /** File attachment action stored in R2 */
      type: ActionType.file;
      /** Unique identifier for the stored file */
      fileId: string;
      /** Original filename */
      fileName: string;
      /** File size in bytes */
      fileSize: number;
      /** MIME type of the file */
      mimeType: string;
    };

/**
 * Represents metadata about a thread, typically from an external system.
 *
 * Thread metadata enables storing additional information about threads,
 * which is useful for synchronization, linking back to external systems,
 * and storing tool-specific data.
 *
 * Must be valid JSON data (strings, numbers, booleans, null, objects, arrays).
 * Functions and other non-JSON values are not supported.
 *
 * @example
 * ```typescript
 * // Calendar event metadata
 * await plot.createThread({
 *   type: ThreadType.Event,
 *   title: "Team Meeting",
 *   start: new Date("2024-01-15T10:00:00Z"),
 *   meta: {
 *     calendarId: "primary",
 *     htmlLink: "https://calendar.google.com/event/abc123",
 *     conferenceData: { ... }
 *   }
 * });
 *
 * // Project issue metadata
 * await plot.createThread({
 *   type: ThreadType.Action,
 *   title: "Fix login bug",
 *   meta: {
 *     projectId: "TEAM",
 *     issueNumber: 123,
 *     url: "https://linear.app/team/issue/TEAM-123"
 *   }
 * });
 * ```
 */
export type ThreadMeta = {
  /** Source-specific properties and metadata */
  [key: string]: JSONValue;
};

/**
 * Tags on an item, along with the actors who added each tag.
 */
export type Tags = { [K in Tag]?: ActorId[] };

/**
 * A set of tags to add to an item, along with the actors adding each tag.
 */
export type NewTags = { [K in Tag]?: NewActor[] };

/**
 * Common fields shared by both Thread and Note entities.
 */
export type ThreadCommon = {
  /** Unique identifier for the thread */
  id: Uuid;
  /**
   * When this thread was originally created in its source system.
   *
   * For threads created in Plot, this is when the user created it.
   * For threads synced from external systems (GitHub issues, emails, calendar events),
   * this is the original creation time in that system.
   *
   * Defaults to the current time when creating new threads.
   */
  created: Date;
  /** Information about who created the thread */
  author: Actor;
  /** Whether this thread is private (only visible to author) */
  private: boolean;
  /** Whether this thread has been archived */
  archived: boolean;
  /** Tags attached to this thread. Maps tag ID to array of actor IDs who added that tag. */
  tags: Tags;
  /** Array of actor IDs (users, contacts, or twists) mentioned in this thread via @-mentions */
  mentions: ActorId[];
};

/**
 * Common fields shared by all thread types (Note, Action, Event).
 * Does not include the discriminant `type` field or type-specific fields like `done`.
 */
type ThreadFields = ThreadCommon & {
  /**
   * Globally unique, stable identifier for the item in an external system.
   * MUST use immutable system-generated IDs, not human-readable slugs or titles.
   *
   * Recommended format: `${domain}:${type}:${id}`
   *
   * Examples:
   *   - `linear:issue:549dd8bd-2bc9-43d1-95d5-4b4af0c5af1b` (Linear issue by UUID)
   *   - `jira:10001:issue:12345` (Jira issue by numeric ID with cloud ID)
   *   - `gmail:thread:18d4e5f2a3b1c9d7` (Gmail thread by system ID)
   *
   * ⚠️ AVOID: URLs with mutable components like team names or issue keys
   *   - Bad: `https://linear.app/team/issue/TEAM-123/title` (team and title can change)
   *   - Bad: `jira:issue:PROJECT-42` (issue key can change)
   *
   * When set, uniquely identifies the thread within a priority tree for upsert operations.
   */
  source: string | null;
  /** The display title/summary of the thread */
  title: string;
  /** Optional kind for additional categorization within the thread */
  kind: ThreadKind | null;
  /**
   * The actor assigned to this thread.
   *
   * **For actions (tasks):**
   * - If not provided (undefined), defaults to the user who installed the twist (twist owner)
   * - To create an **unassigned action**, explicitly set `assignee: null`
   * - For synced tasks from external systems, typically set `assignee: null` for unassigned items
   *
   * **For notes and events:** Assignee is optional and typically null.
   * When marking a thread as done, it becomes an Action; if no assignee is set,
   * the twist owner is assigned automatically.
   *
   * @example
   * ```typescript
   * // Create action assigned to twist owner (default behavior)
   * const task: NewThread = {
   *   type: ThreadType.Action,
   *   title: "Follow up on email"
   *   // assignee omitted → defaults to twist owner
   * };
   *
   * // Create UNASSIGNED action (for backlog items)
   * const backlogTask: NewThread = {
   *   type: ThreadType.Action,
   *   title: "Review PR #123",
   *   assignee: null  // Explicitly set to null
   * };
   *
   * // Create action with explicit assignee
   * const assignedTask: NewThread = {
   *   type: ThreadType.Action,
   *   title: "Deploy to production",
   *   assignee: {
   *     id: userId as ActorId,
   *     type: ActorType.User,
   *     name: "Alice"
   *   }
   * };
   * ```
   */
  assignee: Actor | null;
  /** The priority context this thread belongs to */
  priority: Priority;
  /** Metadata about the thread, typically from an external system that created it */
  meta: ThreadMeta | null;
  /** Sort order for the thread (fractional positioning) */
  order: number;
  /** Array of interactive actions attached to the thread (external, conferencing, callback) */
  actions: Array<Action> | null;
  /** The schedule associated with this thread, if any */
  schedule?: Schedule;
};

export type Thread = ThreadFields &
  (
    | { type: ThreadType.Note }
    | {
        type: ThreadType.Action;
        /**
         * Timestamp when the thread was marked as complete. Null if not completed.
         */
        done: Date | null;
      }
    | { type: ThreadType.Event }
  );

export type ThreadWithNotes = Thread & {
  notes: Note[];
};

export type NewThreadWithNotes = NewThread & {
  notes: Omit<NewNote, "thread">[];
};

/**
 * Configuration for automatic priority selection based on thread similarity.
 *
 * Maps thread fields to scoring weights or required exact matches:
 * - Number value: Maximum score for similarity matching on this field
 * - `true` value: Required exact match - threads must match exactly or be excluded
 *
 * Scoring rules:
 * - content: Uses vector similarity on thread embedding (cosine similarity)
 * - type: Exact match on ThreadType
 * - mentions: Percentage of existing thread's mentions that appear in new thread
 * - meta.field: Exact match on top-level meta fields (e.g., "meta.sourceId")
 *
 * When content is `true`, applies a strong similarity threshold to ensure only close matches.
 * Default (when neither priority nor pickPriority specified): `{content: true}`
 *
 * @example
 * ```typescript
 * // Require exact content match with strong similarity
 * pickPriority: { content: true }
 *
 * // Score based on content (max 100 points) and require exact type match
 * pickPriority: { content: 100, type: true }
 *
 * // Match on meta and score content
 * pickPriority: { "meta.projectId": true, content: 50 }
 * ```
 */
export type PickPriorityConfig = {
  content?: number | true;
  type?: number | true;
  mentions?: number | true;
  [key: `meta.${string}`]: number | true;
};

/**
 * Type for creating new threads.
 *
 * Requires only the thread type, with all other fields optional.
 * The author will be automatically assigned by the Plot system based on
 * the current execution context. The ID can be optionally provided by
 * tools for tracking and update detection purposes.
 *
 * **Important: Defaults for Actions**
 *
 * When creating a Thread of type `Action`:
 * - **`assignee` omitted** → Defaults to twist owner → Assigned action
 *
 * To create unassigned backlog items (common for synced tasks), you MUST explicitly set:
 * - `assignee: null` → Unassigned
 *
 * Scheduling is handled separately via the Schedule type.
 * Use `plot.createSchedule()` to schedule threads.
 *
 * Priority can be specified in three ways:
 * 1. Explicit priority: `priority: { id: "..." }` - Use specific priority (disables pickPriority)
 * 2. Pick priority config: `pickPriority: { ... }` - Auto-select based on similarity
 * 3. Neither: Defaults to `pickPriority: { content: true }` for automatic matching
 *
 * @example
 * ```typescript
 * // Action assigned to twist owner
 * const urgentTask: NewThread = {
 *   type: ThreadType.Action,
 *   title: "Review pull request"
 *   // assignee omitted → defaults to twist owner
 * };
 *
 * // UNASSIGNED backlog item (for synced tasks)
 * const backlogTask: NewThread = {
 *   type: ThreadType.Action,
 *   title: "Refactor user service",
 *   assignee: null    // Must explicitly set to null
 * };
 *
 * // Note
 * const note: NewThread = {
 *   type: ThreadType.Note,
 *   title: "Meeting notes"
 * };
 *
 * // Event (schedule separately with plot.createSchedule())
 * const event: NewThread = {
 *   type: ThreadType.Event,
 *   title: "Team standup"
 * };
 * ```
 */
export type NewThread = (
  | { type: ThreadType.Note; done?: never }
  | { type: ThreadType.Action; done?: Date | null }
  | { type: ThreadType.Event; done?: never }
) &
  Partial<
    Omit<
      ThreadFields,
      "author" | "assignee" | "priority" | "tags" | "mentions" | "id" | "source"
    >
  > &
  (
    | {
        /**
         * Unique identifier for the thread, generated by Uuid.Generate().
         * Specifying an ID allows tools to track and upsert threads.
         */
        id: Uuid;
      }
    | {
        /**
         * Canonical URL for the item in an external system.
         * For example, https://acme.atlassian.net/browse/PROJ-42 could represent a Jira issue.
         * When set, it uniquely identifies the thread within a priority tree. This performs
         * an upsert.
         */
        source: string;
      }
    | {
        /* Neither id nor source is required. An id will be generated and returned. */
      }
  ) &
  (
    | {
        /** Explicit priority (required when specified) - disables automatic priority matching */
        priority: Pick<Priority, "id">;
      }
    | {
        /** Configuration for automatic priority selection based on similarity */
        pickPriority?: PickPriorityConfig;
      }
  ) & {
    /**
     * The person that created the item. By default, it will be the twist itself.
     */
    author?: NewActor;

    /**
     * The person that assigned to the item.
     */
    assignee?: NewActor | null;

    /**
     * All tags to set on the new thread.
     */
    tags?: NewTags;

    /**
     * Whether the thread should be marked as unread for users.
     * - undefined/omitted (default): Thread is unread for users, except auto-marked
     *   as read for the author if they are the twist owner (user)
     * - true: Thread is explicitly unread for ALL users (use sparingly)
     * - false: Thread is marked as read for all users in the priority at creation time
     *
     * For the default behavior, omit this field entirely.
     * Use false for initial sync to avoid marking historical items as unread.
     */
    unread?: boolean;

    /**
     * Whether the thread is archived.
     * - true: Archive the thread
     * - false: Unarchive the thread
     * - undefined (default): Preserve current archive state
     *
     * Best practice: Set to false during initial syncs to ensure threads
     * are unarchived. Omit during incremental syncs to preserve user's choice.
     */
    archived?: boolean;

    /**
     * Optional preview content for the thread. Can be Markdown formatted.
     * The preview will be automatically generated from this content (truncated to 100 chars).
     *
     * - string: Use this content for preview generation
     * - null: Explicitly disable preview (no preview will be shown)
     * - undefined (default): Fall back to legacy behavior (generate from first note with content)
     *
     * This field is write-only and won't be returned when reading threads.
     */
    preview?: string | null;

    /**
     * Optional schedules to create alongside the thread.
     *
     * When provided, schedules are created after the thread is inserted.
     * The threadId is automatically filled from the created thread.
     *
     * For calendar integrations, this replaces the old start/end/recurrenceRule
     * fields that were previously on the thread itself.
     *
     * @example
     * ```typescript
     * const event: NewThread = {
     *   type: ThreadType.Event,
     *   title: "Team standup",
     *   schedules: [{
     *     start: new Date("2025-01-15T10:00:00Z"),
     *     end: new Date("2025-01-15T10:30:00Z"),
     *     recurrenceRule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"
     *   }]
     * };
     * ```
     */
    schedules?: Array<Omit<NewSchedule, "threadId">>;

    /**
     * Optional schedule occurrence overrides. For recurring schedules,
     * these define per-occurrence modifications (e.g., rescheduled meetings,
     * per-occurrence RSVP tags).
     *
     * Requires a schedule to be present (either via `schedules` field or
     * an existing schedule on the thread).
     */
    scheduleOccurrences?: NewScheduleOccurrence[];
  };

export type ThreadFilter = {
  type?: ActorType;
  meta?: {
    [key: string]: JSONValue;
  };
};

/**
 * Fields supported by bulk updates via `match`. Only simple scalar fields
 * that can be applied uniformly across many threads are included.
 */
type ThreadBulkUpdateFields = Partial<
  Pick<ThreadFields, "kind" | "title" | "private" | "archived" | "meta" | "order" | "actions">
> & {
  /** Update the type of all matching threads. */
  type?: ThreadType;
  /**
   * Timestamp when the threads were marked as complete. Null to clear.
   * Setting done will automatically set the type to Action if not already.
   */
  done?: Date | null;
};

/**
 * Fields supported by single-thread updates via `id` or `source`.
 * Includes all bulk fields plus assignee, tags, and preview.
 */
type ThreadSingleUpdateFields = ThreadBulkUpdateFields &
  Partial<Pick<ThreadFields, "assignee">> & {
    /**
     * Tags to change on the thread. Use an empty array of NewActor to remove a tag.
     * Use twistTags to add/remove the twist from tags to avoid clearing other actors' tags.
     */
    tags?: NewTags;

    /**
     * Add or remove the twist's tags.
     * Maps tag ID to boolean: true = add tag, false = remove tag.
     * This is allowed on all threads the twist has access to.
     */
    twistTags?: Partial<Record<Tag, boolean>>;

    /**
     * Optional preview content for the thread. Can be Markdown formatted.
     * The preview will be automatically generated from this content (truncated to 100 chars).
     *
     * - string: Use this content for preview generation
     * - null: Explicitly disable preview (no preview will be shown)
     * - undefined (omitted): Preserve current preview value
     *
     * This field is write-only and won't be returned when reading threads.
     */
    preview?: string | null;
  };

export type ThreadUpdate =
  | (({ id: Uuid } | { source: string }) & ThreadSingleUpdateFields)
  | ({
      /**
       * Update all threads matching the specified criteria. Only threads
       * that match all provided fields and were created by the twist will be updated.
       */
      match: ThreadFilter;
    } & ThreadBulkUpdateFields);

/**
 * Represents a note within a thread.
 *
 * Notes contain the detailed content (note text, actions) associated with a thread.
 * They are always ordered by creation time within their parent thread.
 */
export type Note = ThreadCommon & {
  /**
   * Globally unique, stable identifier for the note within its thread.
   * Can be used to upsert without knowing the id.
   *
   * Use one of these patterns:
   *   - Hardcoded semantic keys for fixed note types: "description", "cancellation"
   *   - External service IDs for dynamic collections: `comment:${immutableId}`
   *
   * Examples:
   *   - `"description"` (for a Jira issue's description note)
   *   - `"comment:12345"` (for a specific comment by ID)
   *   - `"gmail:msg:18d4e5f2a3b1c9d7"` (for a Gmail message within a thread)
   *
   * Ensure IDs are immutable - avoid human-readable slugs or titles.
   */
  key: string | null;
  /** The parent thread this note belongs to */
  thread: Thread;
  /** Primary content for the note (markdown) */
  content: string | null;
  /** Array of interactive actions attached to the note */
  actions: Array<Action> | null;
  /** The note this is a reply to, or null if not a reply */
  reNote: { id: Uuid } | null;
};

/**
 * Type for creating new notes.
 *
 * Requires the thread reference, with all other fields optional.
 * Can provide id, key, or neither for note identification:
 * - id: Provide a specific UUID for the note
 * - key: Provide an external identifier for upsert within the thread
 * - neither: A new note with auto-generated UUID will be created
 */
export type NewNote = Partial<
  Omit<
    Note,
    "author" | "thread" | "tags" | "mentions" | "id" | "key" | "reNote"
  >
> &
  ({ id: Uuid } | { key: string } | {}) & {
    /** Reference to the parent thread (required) */
    thread:
      | Pick<Thread, "id">
      | {
          source: string;
        };

    /**
     * The person that created the item, or leave undefined to use the twist as author.
     */
    author?: NewActor;

    /**
     * Format of the note content. Determines how the note is processed:
     * - 'text': Plain text that will be converted to markdown (auto-links URLs, preserves line breaks)
     * - 'markdown': Already in markdown format (default, no conversion)
     * - 'html': HTML content that will be converted to markdown
     */
    contentType?: ContentType;

    /**
     * Tags to change on the thread. Use an empty array of NewActor to remove a tag.
     * Use twistTags to add/remove the twist from tags to avoid clearing other actors' tags.
     */
    tags?: NewTags;

    /**
     * Change the mentions on the note.
     */
    mentions?: NewActor[];

    /**
     * Whether the note should mark the parent thread as unread for users.
     * - undefined/omitted (default): Thread is unread for users, except auto-marked
     *   as read for the author if they are the twist owner (user)
     * - true: Thread is explicitly unread for ALL users (use sparingly)
     * - false: Thread is marked as read for all users in the priority at note creation time
     *
     * For the default behavior, omit this field entirely.
     * Use false for initial sync to avoid marking historical items as unread.
     */
    unread?: boolean;

    /**
     * Reference to a parent note this note is a reply to.
     * - `{ id }`: reply by UUID
     * - `{ key }`: reply by key, resolved after creation (for batch ops)
     * - `null`: explicitly not a reply
     * - `undefined` (omitted): not a reply
     */
    reNote?: { id: Uuid } | { key: string } | null;
  };

/**
 * Type for updating existing notes.
 * Must provide either id or key to identify the note to update.
 */
export type NoteUpdate = ({ id: Uuid; key?: string } | { key: string }) &
  Partial<
    Pick<Note, "private" | "archived" | "content" | "actions" | "reNote">
  > & {
    /**
     * Format of the note content. Determines how the note is processed:
     * - 'text': Plain text that will be converted to markdown (auto-links URLs, preserves line breaks)
     * - 'markdown': Already in markdown format (default, no conversion)
     * - 'html': HTML content that will be converted to markdown
     */
    contentType?: ContentType;

    /**
     * Tags to change on the note. Use an empty array of NewActor to remove a tag.
     * Use twistTags to add/remove the twist from tags to avoid clearing other actors' tags.
     */
    tags?: NewTags;

    /**
     * Add or remove the twist's tags.
     * Maps tag ID to boolean: true = add tag, false = remove tag.
     * This is allowed on all notes the twist has access to.
     */
    twistTags?: Partial<Record<Tag, boolean>>;

    /**
     * Change the mentions on the note.
     */
    mentions?: NewActor[];
  };

/**
 * Represents an actor in Plot - a user, contact, or twist.
 *
 * Actors can be associated with threads as authors, assignees, or mentions.
 * The email field is only included when ContactAccess.Read permission is granted.
 *
 * @example
 * ```typescript
 * const actor: Actor = {
 *   id: "f0ffd5f8-1635-4b13-9532-35f97446db90" as ActorId,
 *   type: ActorType.Contact,
 *   email: "john.doe@example.com",  // Only if ContactAccess.Read
 *   name: "John Doe"
 * };
 * ```
 */
export type Actor = {
  /** Unique identifier for the actor */
  id: ActorId;
  /** Type of actor (User, Contact, or Twist) */
  type: ActorType;
  /**
   * Email address (only included with ContactAccess.Read permission).
   * - `undefined`: No permission to read email
   * - `null`: Permission granted but email not set
   * - `string`: Email address
   */
  email?: string | null;
  /**
   * Display name.
   * - `undefined`: Not included due to permissions
   * - `null`: Not set
   * - `string`: Display name
   */
  name?: string | null;
};

/**
 * An existing or new contact.
 */
export type NewActor =
  | {
      /** Unique identifier for the actor */
      id: ActorId;
    }
  | NewContact;

/**
 * Enumeration of author types that can create threads.
 *
 * The author type affects how threads are displayed and processed
 * within the Plot system.
 */
export enum ActorType {
  /** Threads created by human users */
  User,
  /** Threads created by external contacts */
  Contact,
  /** Threads created by automated twists */
  Twist,
}

/**
 * Represents contact information for creating a new contact.
 *
 * Contacts are used throughout Plot for representing people associated
 * with activities, such as event attendees or task assignees.
 *
 * @example
 * ```typescript
 * const newContact: NewContact = {
 *   email: "john.doe@example.com",
 *   name: "John Doe",
 *   avatar: "https://avatar.example.com/john.jpg"
 * };
 * ```
 */
export type NewContact = {
  /** Email address of the contact (required) */
  email: string;
  /** Optional display name for the contact */
  name?: string;
  /** Optional avatar image URL for the contact */
  avatar?: string;
  /**
   * External provider account source. Used for privacy compliance
   * (e.g. Atlassian personal data reporting for GDPR account closure).
   * Required for contacts sourced from providers that mandate personal data reporting.
   */
  source?: { provider: AuthProvider; accountId: string };
};

export type ContentType = "text" | "markdown" | "html";

/**
 * Represents an external entity linked to a thread.
 *
 * Links are created by sources to represent external entities (issues, emails, calendar events)
 * attached to a thread container. A thread can have multiple links (1:many).
 * Links store source-specific data like type, status, metadata, and embeddings.
 *
 * @example
 * ```typescript
 * // A link representing a Linear issue
 * const link: Link = {
 *   id: "..." as Uuid,
 *   threadId: "..." as Uuid,
 *   source: "linear:issue:549dd8bd-2bc9-43d1-95d5-4b4af0c5af1b",
 *   created: new Date(),
 *   author: { id: "..." as ActorId, type: ActorType.Contact, name: "Alice" },
 *   title: "Fix login bug",
 *   type: "issue",
 *   status: "open",
 *   meta: { projectId: "TEAM", url: "https://linear.app/team/TEAM-123" },
 *   assignee: null,
 *   actions: null,
 * };
 * ```
 */
export type Link = {
  /** Unique identifier for the link */
  id: Uuid;
  /** The thread this link belongs to */
  threadId: Uuid;
  /** External source identifier for dedup/upsert */
  source: string | null;
  /** When this link was originally created in its source system */
  created: Date;
  /** The actor credited with creating this link */
  author: Actor | null;
  /** Display title */
  title: string;
  /** Truncated preview */
  preview: string | null;
  /** The actor assigned to this link */
  assignee: Actor | null;
  /** Source-defined type string (e.g., issue, pull_request, email, event) */
  type: string | null;
  /** Source-defined status string (e.g., open, done, closed) */
  status: string | null;
  /** Interactive action buttons */
  actions: Array<Action> | null;
  /** Source metadata */
  meta: ThreadMeta | null;
  /** URL to the source logo image for this link's type */
  logo: string | null;
  /** URL to open the original item in its source application (e.g., "Open in Linear") */
  sourceUrl: string | null;
};

/**
 * Type for creating new links.
 *
 * Links are created by sources to represent external entities.
 * Requires a source identifier for dedup/upsert.
 */
export type NewLink = (
  | {
      /** Unique identifier for the link, generated by Uuid.Generate() */
      id: Uuid;
    }
  | {
      /**
       * Canonical ID for the item in an external system.
       * When set, uniquely identifies the link within a priority tree. This performs
       * an upsert.
       */
      source: string;
    }
  | {}
) &
  Partial<
    Omit<Link, "id" | "source" | "author" | "assignee" | "threadId">
  > & {
    /** The person that created the item. By default, it will be the twist itself. */
    author?: NewActor;
    /** The person assigned to the item. */
    assignee?: NewActor | null;
    /**
     * Whether the thread should be marked as unread for users.
     * - undefined/omitted (default): Thread is unread for users, except auto-marked
     *   as read for the author if they are the twist owner (user)
     * - false: Thread is marked as read for all users in the priority at creation time
     */
    unread?: boolean;
    /**
     * Whether the thread is archived.
     * - true: Archive the thread
     * - false: Unarchive the thread
     * - undefined (default): Preserve current archive state
     */
    archived?: boolean;
    /**
     * Configuration for automatic priority selection based on similarity.
     * Only used when the link creates a new thread.
     */
    pickPriority?: PickPriorityConfig;
    /**
     * Explicit priority (disables automatic priority matching).
     * Only used when the link creates a new thread.
     */
    priority?: Pick<Priority, "id">;
  };

/**
 * A new link with notes to save via integrations.saveLink().
 * Creates a thread+link pair, with notes attached to the thread.
 */
export type NewLinkWithNotes = NewLink & {
  /** Title for the link and its thread container */
  title: string;
  /** Notes to attach to the thread */
  notes?: Omit<NewNote, "thread">[];
  /** Schedules to create for the link */
  schedules?: Array<Omit<NewSchedule, "threadId">>;
  /** Schedule occurrence overrides */
  scheduleOccurrences?: NewScheduleOccurrence[];
};

