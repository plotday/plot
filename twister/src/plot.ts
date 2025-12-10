import { type Tag } from "./tag";
import { type Callback } from "./tools/callbacks";

export { Tag } from "./tag";

/**
 * Represents a unique user, contact, or twist in Plot.
 *
 * Note contacts (i.e. people not using Plot) are also represented by ActorIds. They may be
 * people interacting with other connected services (e.g. an email sender or event attendee).
 */
export type ActorId = string & { readonly __brand: "ActorId" };

/**
 * Represents a priority context within Plot.
 *
 * Priorities are similar to projects in other apps. All Activity is in a Priority.
 * Priorities can be nested.
 */
export type Priority = {
  /** Unique identifier for the priority */
  id: string;
  /** Human-readable title for the priority */
  title: string;
};

/**
 * Type for creating new priorities.
 *
 * Excludes the auto-generated ID field and adds an optional parentId
 * for creating hierarchical priority structures.
 */
export type NewPriority = Omit<Priority, "id"> & {
  /** Optional ID of the parent priority for creating hierarchies */
  parentId?: string;
};

/**
 * Enumeration of supported activity types in Plot.
 *
 * Each activity type has different behaviors and rendering characteristics
 * within the Plot application.
 */
export enum ActivityType {
  /** A note or piece of information without actionable requirements */
  Note,
  /** An actionable item that can be completed */
  Action,
  /** A scheduled occurrence with start and optional end time */
  Event,
}

/**
 * Enumeration of supported activity link types.
 *
 * Different link types have different behaviors when clicked by users
 * and may require different rendering approaches.
 */
export enum ActivityLinkType {
  /** External web links that open in browser */
  external = "external",
  /** Authentication flows for connecting services */
  auth = "auth",
  /** Callback links that trigger twist methods when clicked */
  callback = "callback",
  /** Video conferencing links with provider-specific handling */
  conferencing = "conferencing",
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
 * Represents a clickable link attached to an activity.
 *
 * Activity links are rendered as buttons that enable user interaction with activities.
 * Different link types have specific behaviors and required fields for proper functionality.
 *
 * @example
 * ```typescript
 * // External link - opens URL in browser
 * const externalLink: ActivityLink = {
 *   type: ActivityLinkType.external,
 *   title: "Open in Google Calendar",
 *   url: "https://calendar.google.com/event/123",
 * };
 *
 * // Conferencing link - opens video conference with provider info
 * const conferencingLink: ActivityLink = {
 *   type: ActivityLinkType.conferencing,
 *   url: "https://meet.google.com/abc-defg-hij",
 *   provider: ConferencingProvider.googleMeet,
 * };
 *
 * // Integrations link - initiates OAuth flow
 * const authLink: ActivityLink = {
 *   type: ActivityLinkType.auth,
 *   title: "Continue with Google",
 *   provider: AuthProvider.Google,
 *   level: AuthLevel.User,
 *   scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
 *   callback: "callback-token-for-auth-completion"
 * };
 *
 * // Callback link - triggers a twist method
 * const callbackLink: ActivityLink = {
 *   type: ActivityLinkType.callback,
 *   title: "📅 Primary Calendar",
 *   token: "callback-token-here"
 * };
 * ```
 */
export type ActivityLink =
  | {
      /** External web link that opens in browser */
      type: ActivityLinkType.external;
      /** Display text for the link button */
      title: string;
      /** URL to open when clicked */
      url: string;
    }
  | {
      /** Video conferencing link with provider-specific handling */
      type: ActivityLinkType.conferencing;
      /** URL to join the conference */
      url: string;
      /** Conferencing provider for UI customization */
      provider: ConferencingProvider;
    }
  | {
      /** Authentication link that initiates an OAuth flow */
      type: ActivityLinkType.auth;
      /** Display text for the auth button */
      title: string;
      /** OAuth provider (e.g., "google", "microsoft") */
      provider: string;
      /** Authorization level ("user" or "priority") */
      level: string;
      /** Array of OAuth scopes to request */
      scopes: string[];
      /** Callback token for auth completion notification */
      callback: Callback;
    }
  | {
      /** Callback link that triggers a twist method when clicked */
      type: ActivityLinkType.callback;
      /** Display text for the callback button */
      title: string;
      /** Token identifying the callback to execute */
      callback: Callback;
    };

/**
 * Represents metadata about an activity, typically from an external system.
 *
 * Activity metadata enables tracking where activities originated from,
 * which is useful for synchronization, deduplication, and linking
 * back to external systems.
 *
 * @example
 * ```typescript
 * const googleCalendarMeta: ActivityMeta = {
 *   type: "google-calendar-event",
 *   id: "event-123",
 *   calendarId: "primary",
 *   htmlLink: "https://calendar.google.com/event/123"
 * };
 * ```
 */
export type ActivityMeta = {
  /** The type identifier for the source system */
  source: string;
  /** Additional source-specific properties */
  [key: string]: any;
};

/**
 * Represents a complete activity within the Plot system.
 *
 * Activities are the core entities in Plot, representing anything from simple notes
 * to complex recurring events. They support rich metadata including scheduling,
 * recurrence patterns, links, and external source tracking.
 *
 * @example
 * ```typescript
 * // Simple note
 * const task: Activity = {
 *   type: ActivityType.Note,
 *   title: "New campaign brainstorming ideas",
 *   content: "We could rent a bouncy castle...",
 *   author: { id: "user-1", name: "John Doe", type: ActorType.User },
 *   priority: { id: "work", title: "Work" },
 *   // ... other fields
 * };
 *
 * // Simple action
 * const action: Activity = {
 *   type: ActivityType.Action,
 *   title: "Review budget proposal",
 *   author: { id: "user-1", name: "John Doe", type: ActorType.User },
 *   priority: { id: "work", title: "Work" },
 *   // ... other fields
 * };
 *
 * // Recurring event
 * const meeting: Activity = {
 *   type: ActivityType.Event,
 *   title: "Weekly standup",
 *   recurrenceRule: "FREQ=WEEKLY;BYDAY=MO",
 *   recurrenceCount: 12,
 *   // ... other fields
 * };
 * ```
 */
export type ActivityCommon = {
  /** Unique identifier for the activity */
  id: string;
  /** Information about who created the activity */
  author: Actor;
  /** Whether this activity is in draft state (not shown in do now view) */
  draft: boolean;
  /** Whether this activity is private (only visible to author) */
  private: boolean;
  /** Tags attached to this activity. Maps tag ID to array of actor IDs who added that tag. */
  tags: Partial<Record<Tag, ActorId[]>> | null;
  /** Array of actor IDs (users, contacts, or twists) mentioned in this activity via @-mentions */
  mentions: ActorId[] | null;
};

export type Activity = ActivityCommon & {
  /** The display title/summary of the activity */
  title: string | null;
  /** The type of activity (Note, Task, or Event) */
  type: ActivityType;
  /**
   * The actor assigned to this activity.
   *
   * **For actions (tasks):** An assignee is required. If not explicitly provided when creating
   * an action, the assignee will default to the user who installed the twist (the twist owner).
   *
   * **For notes and events:** Assignee is optional and typically null.
   *
   * @example
   * ```typescript
   * // Create action with explicit assignee
   * const task: NewActivity = {
   *   type: ActivityType.Action,
   *   title: "Review PR #123",
   *   assignee: {
   *     id: userId as ActorId,
   *     type: ActorType.User,
   *     name: "Alice"
   *   }
   * };
   *
   * // Create action with auto-assignment (defaults to twist owner)
   * const task: NewActivity = {
   *   type: ActivityType.Action,
   *   title: "Follow up on email"
   *   // assignee will be set automatically to twist owner
   * };
   *
   * // Update assignee
   * await plot.updateActivity({
   *   id: activityId,
   *   assignee: {
   *     id: newUserId as ActorId,
   *     type: ActorType.User,
   *     name: "Bob"
   *   }
   * });
   * ```
   */
  assignee: Actor | null;
  /** Timestamp when the activity was marked as complete. Null if not completed. */
  doneAt: Date | null;
  /**
   * Start time of a scheduled activity. Notes are not typically scheduled unless they're about specific times.
   * For recurring events, this represents the start of the first occurrence.
   * Can be a Date object for timed events or a date string in "YYYY-MM-DD" format for all-day events.
   * Null for activities without scheduled start times.
   */
  start: Date | string | null;
  /**
   * End time of a scheduled activity. Notes are not typically scheduled unless they're about specific times.
   * For recurring events, this represents the end of the first occurrence.
   * Can be a Date object for timed events or a date string in "YYYY-MM-DD" format for all-day events.
   * Null for tasks or activities without defined end times.
   */
  end: Date | string | null;
  /**
   * For recurring activities, the last occurrence date (inclusive).
   * Can be a Date object, date string in "YYYY-MM-DD" format, or null if recurring indefinitely.
   * When both recurrenceCount and recurrenceUntil are provided, recurrenceCount takes precedence.
   */
  recurrenceUntil: Date | string | null;
  /**
   * For recurring activities, the number of occurrences to generate.
   * Takes precedence over recurrenceUntil if both are provided.
   * Null for non-recurring activities or indefinite recurrence.
   */
  recurrenceCount: number | null;
  /** The priority context this activity belongs to */
  priority: Priority;
  /** Recurrence rule in RFC 5545 RRULE format (e.g., "FREQ=WEEKLY;BYDAY=MO,WE,FR") */
  recurrenceRule: string | null;
  /** Array of dates to exclude from the recurrence pattern */
  recurrenceExdates: Date[] | null;
  /** Array of additional occurrence dates to include in the recurrence pattern */
  recurrenceDates: Date[] | null;
  /**
   * For recurring event exceptions, points to the root recurring activity.
   * Used when an individual occurrence of a recurring event is modified.
   */
  recurrence: Activity | null;
  /**
   * For recurring event exceptions, the original occurrence date being overridden.
   * Used to identify which occurrence of a recurring event this exception replaces.
   */
  occurrence: Date | null;
  /** Metadata about the activity, typically from an external system that created it */
  meta: ActivityMeta | null;
};

export type ActivityWithNotes = Activity & {
  notes: Note[];
};

export type NewActivityWithNotes = NewActivity & {
  notes: Omit<NewNote, "activity">[];
};

/**
 * Configuration for automatic priority selection based on activity similarity.
 *
 * Maps activity fields to scoring weights or required exact matches:
 * - Number value: Maximum score for similarity matching on this field
 * - `true` value: Required exact match - activities must match exactly or be excluded
 *
 * Scoring rules:
 * - content: Uses vector similarity on activity embedding (cosine similarity)
 * - type: Exact match on ActivityType
 * - mentions: Percentage of existing activity's mentions that appear in new activity
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
 * // Match on meta source and score content
 * pickPriority: { "meta.source": true, content: 50 }
 * ```
 */
export type PickPriorityConfig = {
  content?: number | true;
  type?: number | true;
  mentions?: number | true;
  [key: `meta.${string}`]: number | true;
};

/**
 * Type for creating new activities.
 *
 * Requires only the activity type, with all other fields optional.
 * The ID and author will be automatically assigned by the Plot system
 * based on the current execution context.
 *
 * Priority can be specified in three ways:
 * 1. Explicit priority: `priority: { id: "..." }` - Use specific priority (disables pickPriority)
 * 2. Pick priority config: `pickPriority: { ... }` - Auto-select based on similarity
 * 3. Neither: Defaults to `pickPriority: { content: true }` for automatic matching
 *
 * @example
 * ```typescript
 * // Explicit priority (disables automatic matching)
 * const newTask: NewActivity = {
 *   type: ActivityType.Action,
 *   title: "Review pull request",
 *   priority: { id: "work-project-123" }
 * };
 *
 * // Automatic priority matching (default behavior)
 * const newNote: NewActivity = {
 *   type: ActivityType.Note,
 *   title: "Meeting notes",
 *   content: "Discussed Q4 roadmap..."
 *   // Defaults to pickPriority: { content: true }
 * };
 *
 * // Custom priority matching
 * const newEvent: NewActivity = {
 *   type: ActivityType.Event,
 *   title: "Team standup",
 *   pickPriority: { type: true, content: 50 }
 * };
 * ```
 */
export type NewActivity = Pick<Activity, "type"> &
  Partial<Omit<Activity, "id" | "author" | "type" | "priority" | "mentions">> &
  (
    | {
        /** Explicit priority (required when specified) - disables automatic priority matching */
        priority: Pick<Priority, "id">;
      }
    | {
        /** Configuration for automatic priority selection based on similarity */
        pickPriority?: PickPriorityConfig;
      }
    | {}
  );

export type ActivityUpdate = Pick<Activity, "id"> &
  Partial<
    Pick<
      Activity,
      | "type"
      | "start"
      | "end"
      | "doneAt"
      | "title"
      | "assignee"
      | "draft"
      | "private"
      | "meta"
      | "recurrenceRule"
      | "recurrenceDates"
      | "recurrenceExdates"
      | "recurrenceUntil"
      | "recurrenceCount"
      | "occurrence"
    >
  > & {
    /**
     * Full tags object from Activity. Maps tag ID to array of actor IDs who added that tag.
     * Only allowed for activities created by the twist.
     * Use twistTags instead for adding/removing the twist's tags on other activities.
     */
    tags?: Partial<Record<Tag, ActorId[]>>;

    /**
     * Add or remove the twist's tags.
     * Maps tag ID to boolean: true = add tag, false = remove tag.
     * This is allowed on all activities the twist has access to.
     */
    twistTags?: Partial<Record<Tag, boolean>>;
  };

/**
 * Represents a note within an activity.
 *
 * Notes contain the detailed content (note text, links) associated with an activity.
 * They are always ordered by creation time within their parent activity.
 */
export type Note = Omit<ActivityCommon, "type"> & {
  /** The parent activity this note belongs to */
  activity: Activity;
  /** Primary content for the note (markdown) */
  content: string | null;
  /** Array of interactive links attached to the note */
  links: Array<ActivityLink> | null;
};

/**
 * Type for creating new notes.
 *
 * Requires the activity reference, with all other fields optional.
 */
export type NewNote = Partial<Omit<Note, "id" | "author" | "activity">> & {
  /** Reference to the parent activity (required) */
  activity: Pick<Activity, "id">;

  /**
   * Format of the note content. Determines how the note is processed:
   * - 'text': Plain text that will be converted to markdown (auto-links URLs, preserves line breaks)
   * - 'markdown': Already in markdown format (default, no conversion)
   * - 'html': HTML content that will be converted to markdown
   */
  noteType?: NoteType;
};

/**
 * Type for updating existing notes.
 */
export type NoteUpdate = Pick<Note, "id"> &
  Partial<Pick<Note, "draft" | "private" | "content" | "links" | "mentions">> & {
    /**
     * Format of the note content. Determines how the note is processed:
     * - 'text': Plain text that will be converted to markdown (auto-links URLs, preserves line breaks)
     * - 'markdown': Already in markdown format (default, no conversion)
     * - 'html': HTML content that will be converted to markdown
     */
    noteType?: NoteType;

    /**
     * Full tags object from Note. Maps tag ID to array of actor IDs who added that tag.
     * Only allowed for notes created by the twist.
     * Use twistTags instead for adding/removing the twist's tags on other notes.
     */
    tags?: Partial<Record<Tag, ActorId[]>>;

    /**
     * Add or remove the twist's tags.
     * Maps tag ID to boolean: true = add tag, false = remove tag.
     * This is allowed on all notes the twist has access to.
     */
    twistTags?: Partial<Record<Tag, boolean>>;
  };

/**
 * Represents an actor in Plot - a user, contact, or twist.
 *
 * Actors can be associated with activities as authors, assignees, or mentions.
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
  /** Email address (only included with ContactAccess.Read permission) */
  email?: string;
  /** Display name (undefined if not included due to permissions, null if not set) */
  name?: string | null;
};

/**
 * Enumeration of author types that can create activities.
 *
 * The author type affects how activities are displayed and processed
 * within the Plot system.
 */
export enum ActorType {
  /** Activities created by human users */
  User,
  /** Activities created by external contacts */
  Contact,
  /** Activities created by automated twists */
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
};

export type NoteType = "text" | "markdown" | "html";
